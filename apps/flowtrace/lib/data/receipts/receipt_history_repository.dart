import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/money/money.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../local/app_database.dart';
import '../sync/snapshot_protocol.dart';
import 'receipt_history_models.dart';
import 'receipt_read_repository.dart';

/// UI reads only: no network, schema, writes, balances or second data cache.
final class ReceiptHistoryRepository {
  ReceiptHistoryRepository(this.reader);
  final ReceiptReadRepository reader;
  AppDatabase get _db => reader.repository.database;

  String _cut(ReceiptReadLease lease, String fingerprint, Object query) => syncContentHash({
    'space': lease.space.id, 'instance': lease.space.serverInstanceId,
    'user': lease.space.userId, 'client': lease.clientId, 'epoch': lease.epoch,
    'snapshot': fingerprint, 'query': query,
  });

  ReceiptHistoryRead _hiddenHistory(String reason,
    [ReceiptReadDisposition disposition = ReceiptReadDisposition.unavailable]) =>
      ReceiptHistoryRead(disposition: disposition, reason: reason);
  ReceiptTrackingRead _hiddenTracking(String reason) =>
      ReceiptTrackingRead(disposition: ReceiptReadDisposition.unavailable, reason: reason);

  Future<List<QueryRow>> _candidates(ReceiptReadLease lease, String scopeId, {
    required int limit, required ReceiptListCursor? cursor, String? sourceId,
  }) {
    final args = <Variable<Object>>[Variable(lease.space.id), Variable(scopeId)];
    final where = <String>[
      's.space_id=?', 's.scope_id=?', "s.entity_type='bill'", 's.deleted=0',
      r"json_extract(s.data_json,'$.projection_kind')='bill_public'",
      sourceId == null
        ? r"json_extract(s.data_json,'$.payload.bill_type')='expense'"
        : r"json_extract(s.data_json,'$.payload.bill_type') IN ('refund','reimbursement')",
    ];
    if (sourceId != null) {
      where.add(r"EXISTS (SELECT 1 FROM json_each(s.data_json,'$.payload.allocations') a "
        r"WHERE json_extract(a.value,'$.source_bill_id')=?)");
      args.add(Variable(sourceId));
    } else {
      where.add(r"(json_extract(s.data_json,'$.payload.reimbursement_tracking')=1 OR "
        r"EXISTS (SELECT 1 FROM local_entities l WHERE l.space_id=s.space_id "
        r"AND l.scope_id=s.scope_id AND l.entity_type='bill' AND l.entity_id=s.entity_id "
        r"AND l.deleted=0 AND (json_extract(l.data_json,'$.payload.reimbursement_tracking')=1 "
        r"OR json_extract(l.data_json,'$.reimbursement_tracking')=1)))");
    }
    if (cursor != null) {
      where.add(r"(json_extract(s.data_json,'$.payload.business_date')<? OR "
        r"(json_extract(s.data_json,'$.payload.business_date')=? AND s.entity_id<?))");
      args.addAll([Variable(cursor.afterDate), Variable(cursor.afterDate), Variable(cursor.afterId)]);
    }
    args.add(Variable(limit + 1));
    return _db.customSelect('SELECT s.entity_id,s.revision,s.data_json FROM server_shadows s '
      'WHERE ${where.join(' AND ')} '
      r"ORDER BY json_extract(s.data_json,'$.payload.business_date') DESC,s.entity_id DESC LIMIT ?",
      variables: args, readsFrom: {_db.serverShadows, _db.localEntities}).get();
  }

  Map<String, Object?> _payload(QueryRow row, String scopeId) {
    final raw = syncObject(jsonDecode(row.read<String>('data_json')));
    final payload = syncObject(raw['payload']);
    if (raw['projection_kind'] != 'bill_public' || payload['book_id'] != scopeId ||
      BigInt.parse(syncRevision(row.read<String>('revision'))) <= BigInt.zero) {
      throw const FormatException('Invalid public receipt cut');
    }
    syncIdentifier(row.read<String>('entity_id'));
    businessDate(payload['business_date']);
    return payload;
  }

  ReceiptListCursor? _next(List<QueryRow> rows, int limit, String cut) {
    if (rows.length <= limit) return null;
    final last = rows[limit - 1];
    final payload = syncObject(syncObject(jsonDecode(last.read<String>('data_json')))['payload']);
    return ReceiptListCursor(cutFingerprint: cut, afterDate: payload['business_date'] as String,
      afterId: last.read<String>('entity_id'));
  }

  Future<void> _installed(ReceiptReadLease lease, QueryRow row, String scopeId) async {
    final local = await (_db.select(_db.localEntities)..where((t) =>
      t.spaceId.equals(lease.space.id) & t.entityType.equals('bill') &
      t.entityId.equals(row.read<String>('entity_id')))).getSingleOrNull();
    if (local == null || local.deleted || local.scopeId != scopeId ||
      BigInt.parse(syncRevision(local.serverRevision)) >
        BigInt.parse(syncRevision(row.read<String>('revision')))) {
      throw const FormatException('History cut not installed');
    }
  }

  Future<ReceiptHistoryRead> readHistory(ReceiptReadLease lease, ReceiptHistoryQuery query) async {
    if (!lease.isCurrent()) return _hiddenHistory('identity_changed');
    try {
      final value = await _db.readSnapshot(() async {
        final scopeId = query.source.scopeId;
        final book = await reader.readBookAuthority(lease, scopeId);
        if (!book.ready) return _hiddenHistory(book.reason!);
        final batch = await reader.readMany(lease, [query.source]);
        final source = batch.reads.single;
        if (source.disposition != ReceiptReadDisposition.ready || source.canonical == null) {
          return _hiddenHistory(source.reason ?? 'source_unavailable', source.disposition);
        }
        if (book.snapshotFingerprint != batch.snapshotFingerprint) {
          return _hiddenHistory('receipt_cut_changed');
        }
        final cut = _cut(lease, batch.snapshotFingerprint!, {
          'kind': 'history', 'scope': scopeId, 'source': query.source.sourceId, 'limit': query.limit,
        });
        if (query.cursor != null && query.cursor!.cutFingerprint != cut) {
          return _hiddenHistory('receipt_cursor_stale');
        }
        final rows = await _candidates(lease, scopeId, limit: query.limit,
          cursor: query.cursor, sourceId: query.source.sourceId);
        final items = <ReceiptHistoryItem>[];
        for (final row in rows.take(query.limit)) {
          await _installed(lease, row, scopeId);
          items.add(_historyItem(row, book.canonical!, source.canonical!));
        }
        final end = await reader.readBookAuthority(lease, scopeId);
        if (!end.ready || end.snapshotFingerprint != batch.snapshotFingerprint || !lease.isCurrent()) {
          return _hiddenHistory(lease.isCurrent() ? 'receipt_cut_changed' : 'identity_changed');
        }
        return ReceiptHistoryRead(disposition: ReceiptReadDisposition.ready, source: source,
          items: items, nextCursor: _next(rows, query.limit, cut));
      });
      return lease.isCurrent() ? value : _hiddenHistory('identity_changed');
    } on Object {
      return _hiddenHistory(lease.isCurrent() ? 'receipt_history_unavailable' : 'identity_changed');
    }
  }

  ReceiptHistoryItem _historyItem(QueryRow row, ReceiptBookAuthority book, ReceiptSourceCut source) {
    final payload = _payload(row, book.scopeId);
    final raw = syncObject(jsonDecode(row.read<String>('data_json')));
    final received = Money.fromJson(payload['money'], positive: true);
    final kind = switch (payload['bill_type']) {
      'refund' => ReceiptHistoryKind.refund,
      'reimbursement' => ReceiptHistoryKind.reimbursement,
      _ => throw const FormatException('Invalid history kind'),
    };
    final hidden = raw['hidden_allocation_count'];
    if (hidden is! int || hidden < 0 || hidden > 100 || payload['allocations'] is! List) {
      throw const FormatException('Invalid public allocations');
    }
    final allocations = payload['allocations'] as List;
    if (allocations.length > 100 || allocations.length + hidden > 100) {
      throw const FormatException('Invalid public allocation capacity');
    }
    final income = payload.containsKey('income_component_minor')
      ? Money(received.currency, received.currencyScale, parseMinor(payload['income_component_minor']))
      : null;
    if (income != null && (income.minor.isNegative ||
      kind == ReceiptHistoryKind.reimbursement && income.minor != BigInt.zero)) {
      throw const FormatException('Invalid receipt income');
    }
    var visibleReceipt = BigInt.zero;
    final ids = <String>{};
    Map<String, Object?>? selected;
    for (final value in allocations) {
      final allocation = syncObject(value);
      if (allocation.keys.any((key) => !{'source_bill_id', 'source_amount_minor',
        'receipt_amount_minor', 'rate'}.contains(key))) {
        throw const FormatException('Invalid allocation fields');
      }
      final id = syncIdentifier(allocation['source_bill_id']);
      if (!ids.add(id)) throw const FormatException('Duplicate source');
      parseMinor(allocation['source_amount_minor'], positive: true);
      visibleReceipt += parseMinor(allocation['receipt_amount_minor'], positive: true);
      checkedMinor(visibleReceipt);
      if (id == source.sourceId) selected = allocation;
    }
    if (selected == null || visibleReceipt > received.minor ||
      income != null && (visibleReceipt + income.minor > received.minor ||
        hidden == 0 && visibleReceipt + income.minor != received.minor)) {
      throw const FormatException('Receipt conservation mismatch');
    }
    final sourceMoney = Money(source.state.paid.currency, source.state.paid.currencyScale,
      parseMinor(selected['source_amount_minor'], positive: true));
    final receiptMoney = Money(received.currency, received.currencyScale,
      parseMinor(selected['receipt_amount_minor'], positive: true));
    if (sourceMoney.minor > source.state.paid.minor) {
      throw const FormatException('Allocation exceeds original source');
    }
    final rate = selected['rate'];
    if (rate != null && rate is! String) throw const FormatException('Invalid frozen rate');
    if (sourceMoney.currency == received.currency) {
      if (sourceMoney.currencyScale != received.currencyScale || sourceMoney.minor != receiptMoney.minor) {
        throw const FormatException('Same currency allocation mismatch');
      }
      if (rate != null) parseRate(rate);
    } else if (rate == null || convertMoney(sourceMoney, rate as String,
      received.currency, received.currencyScale).minor != receiptMoney.minor) {
      throw const FormatException('Frozen FX allocation mismatch');
    }
    return ReceiptHistoryItem(receiptId: row.read<String>('entity_id'), scopeId: book.scopeId,
      entityRevision: row.read<String>('revision'), authority: book, kind: kind,
      businessDate: payload['business_date'] as String, businessTimezone: payload['business_timezone'] as String,
      occurredAt: payload['occurred_at'] as String?, received: received,
      allocatedSource: sourceMoney, allocatedReceipt: receiptMoney, rate: rate as String?,
      incomeComponent: income, fullReceiptConservationKnown: hidden == 0 && income != null);
  }

  Future<ReceiptTrackingRead> readTracking(ReceiptReadLease lease, ReceiptTrackingQuery query) async {
    if (!lease.isCurrent()) return _hiddenTracking('identity_changed');
    try {
      final value = await _db.readSnapshot(() async {
        final book = await reader.readBookAuthority(lease, query.scopeId);
        if (!book.ready) return _hiddenTracking(book.reason!);
        final cut = _cut(lease, book.snapshotFingerprint!, {'kind': 'tracking', 'scope': query.scopeId,
          'filter': query.filter.name, 'limit': query.limit});
        if (query.cursor != null && query.cursor!.cutFingerprint != cut) {
          return _hiddenTracking('receipt_cursor_stale');
        }
        final rows = await _candidates(lease, query.scopeId, limit: query.limit, cursor: query.cursor);
        final page = rows.take(query.limit).toList();
        final items = <ReceiptTrackingItem>[];
        if (page.isNotEmpty) {
          final batch = await reader.readMany(lease, [for (final row in page)
            ReceiptSourceQuery(scopeId: query.scopeId, sourceId: row.read<String>('entity_id'))]);
          if (batch.snapshotFingerprint != book.snapshotFingerprint) return _hiddenTracking('receipt_cut_changed');
          for (var i = 0; i < page.length; i++) {
            final payload = _payload(page[i], query.scopeId), read = batch.reads[i];
            if (query.filter == ReceiptTrackingFilter.openOnly && read.canonicalState != null &&
              read.canonicalState!.remainingAllocatableMinor == BigInt.zero) continue;
            items.add(ReceiptTrackingItem(sourceId: page[i].read<String>('entity_id'),
              scopeId: query.scopeId, businessDate: payload['business_date'] as String, read: read));
          }
        }
        final end = await reader.readBookAuthority(lease, query.scopeId);
        if (!end.ready || end.snapshotFingerprint != book.snapshotFingerprint || !lease.isCurrent()) {
          return _hiddenTracking(lease.isCurrent() ? 'receipt_cut_changed' : 'identity_changed');
        }
        return ReceiptTrackingRead(disposition: ReceiptReadDisposition.ready,
          authority: book.canonical, items: items, nextCursor: _next(rows, query.limit, cut));
      });
      return lease.isCurrent() ? value : _hiddenTracking('identity_changed');
    } on Object {
      return _hiddenTracking(lease.isCurrent() ? 'receipt_tracking_unavailable' : 'identity_changed');
    }
  }

  Stream<ReceiptHistoryRead> watchHistory(ReceiptReadLease lease, ReceiptHistoryQuery query) =>
    _watch(lease, () => readHistory(lease, query), _hiddenHistory);
  Stream<ReceiptTrackingRead> watchTracking(ReceiptReadLease lease, ReceiptTrackingQuery query) =>
    _watch(lease, () => readTracking(lease, query), _hiddenTracking);

  Stream<T> _watch<T>(ReceiptReadLease lease, Future<T> Function() read, T Function(String) hidden) {
    late StreamController<T> output;
    StreamSubscription<void>? authority;
    StreamSubscription<dynamic>? database;
    var stopped = false, reading = false, rerun = false, generation = 0;
    void hide(String reason) { if (!stopped) output.add(hidden(reason)); }
    Future<void> stop(String reason) async {
      if (stopped) return;
      hide(reason); stopped = true; generation++;
      await authority?.cancel(); await database?.cancel(); await output.close();
    }
    Future<void> reload() async {
      if (stopped) return;
      if (!lease.isCurrent()) { hide('identity_changed'); return; }
      if (reading) { rerun = true; return; }
      reading = true;
      do {
        rerun = false;
        final captured = generation, value = await read();
        if (!stopped && captured == generation) {
          output.add(lease.isCurrent() ? value : hidden('identity_changed'));
        }
      } while (!stopped && rerun);
      reading = false;
    }
    output = StreamController<T>(onListen: () {
      authority = lease.invalidations.listen((_) {
        generation++; hide(lease.isCurrent() ? 'authority_changed' : 'identity_changed');
        if (lease.isCurrent()) unawaited(reload());
      }, onError: (Object error, StackTrace trace) { unawaited(stop('authority_stream_error')); },
        onDone: () { unawaited(stop('authority_stream_ended')); });
      database = _db.customSelect('SELECT 1', readsFrom: {_db.localEntities, _db.serverShadows,
        _db.pendingOperations, _db.syncStates, _db.appSettings}).watch().listen((_) {
        generation++; hide('receipt_data_changed'); unawaited(reload());
      }, onError: (Object error, StackTrace trace) { unawaited(stop('receipt_stream_error')); },
        onDone: () { unawaited(stop('receipt_stream_ended')); });
    }, onCancel: () async {
      stopped = true; generation++; await authority?.cancel(); await database?.cancel();
    });
    return output.stream;
  }
}
