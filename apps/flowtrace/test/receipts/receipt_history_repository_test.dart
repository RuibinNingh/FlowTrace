import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/receipts/receipt_history_models.dart';
import 'package:flowtrace/data/receipts/receipt_history_repository.dart';
import 'package:flowtrace/data/receipts/receipt_read_repository.dart';
import 'package:flowtrace/domain/receipts/receipt_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart';

final class _PauseCommit extends QueryInterceptor {
  Completer<void>? release, captured;
  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    final gate = release, signal = captured;
    release = null;
    captured = null;
    await inner.send();
    if (gate != null) {
      signal!.complete();
      await gate.future;
    }
  }
}

void main() {
  late QueryFixture f;
  late ReceiptReadRepository reader;
  late ReceiptHistoryRepository history;
  late ReceiptReadLease lease;
  late StreamController<void> authority;
  var current = true;

  Future<void> seed([QueryFixture? fixture]) async {
    f = fixture ?? QueryFixture();
    await f.seed();
    await f.local.writeSetting('sync.scopes.${f.space.id}',
      jsonEncode({qBook: '1', qOtherBook: '1', qUser: '1'}));
    await f.sync.applyPullPage(f.space, qEpoch, [], finalPage: true,
      checkpoint: {qBook: '3', qOtherBook: '2', qUser: '1'});
    reader = ReceiptReadRepository(f.local);
    history = ReceiptHistoryRepository(reader);
    lease = ReceiptReadLease(space: f.space, clientId: qid(5), epoch: qEpoch,
      isCurrent: () => current, invalidations: authority.stream);
  }

  Future<void> source({String? id, bool tracking = true, String paid = '10000',
    Object? remaining = '5000', bool summary = true, String refund = '3000',
    String reimbursement = '2000', String currency = 'CNY', int scale = 2}) async {
    final sourceId = id ?? qa;
    await f.putBill(sourceId, {'bill_type': 'expense',
      'money': qmoney(paid, currency: currency, scale: scale),
      'reimbursement_tracking': tracking}, revision: '7');
    final shadow = await (f.db.select(f.db.serverShadows)..where((t) =>
      t.spaceId.equals(f.space.id) & t.scopeId.equals(qBook) & t.entityId.equals(sourceId))).getSingle();
    final raw = (jsonDecode(shadow.dataJson) as Map).cast<String, Object?>();
    raw['remaining_allocatable_minor'] = remaining;
    if (summary) {
      raw['source_summary'] = {'refund_source_minor': refund, 'reimbursement_source_minor': reimbursement,
        'remaining_source_minor': remaining, 'settlement_reason': remaining != '0' ? 'open'
          : reimbursement == '0' ? 'refunded' : refund == '0' ? 'reimbursed' : 'mixed'};
    }
    await f.put('bill', sourceId, qBook, raw, revision: '7');
  }

  Future<void> receipt({String? id, String? scope, String sourceAmount = '1000',
    String received = '1000', String currency = 'CNY', String? rate,
    String kind = 'refund', String date = '2026-10-22', bool hidden = false}) async {
    final receiptId = id ?? qb, book = scope ?? qBook;
    await f.putBill(receiptId, {'bill_type': kind, 'money': qmoney(received, currency: currency),
      'business_date': date, 'account_id': qCash, 'note': '公开回款备注',
      'allocations': [if (!hidden) {'source_bill_id': qa, 'source_amount_minor': sourceAmount,
        'receipt_amount_minor': received, 'rate': rate}]}, scope: book, revision: '8');
    if (hidden) {
      final shadow = await (f.db.select(f.db.serverShadows)..where((t) =>
        t.spaceId.equals(f.space.id) & t.scopeId.equals(book) & t.entityId.equals(receiptId))).getSingle();
      final raw = (jsonDecode(shadow.dataJson) as Map).cast<String, Object?>();
      raw['hidden_allocation_count'] = 1;
      await f.put('bill', receiptId, book, raw, revision: '8');
    }
  }

  ReceiptHistoryQuery query({int limit = 50, ReceiptListCursor? cursor}) =>
    ReceiptHistoryQuery(source: ReceiptSourceQuery(scopeId: qBook, sourceId: qa),
      limit: limit, cursor: cursor);
  Future<ReceiptHistoryRead> read({int limit = 50, ReceiptListCursor? cursor}) =>
    history.readHistory(lease, query(limit: limit, cursor: cursor));

  Future<void> until(bool Function() ready) async {
    for (var i = 0; i < 100 && !ready(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(ready(), isTrue);
  }

  setUp(() async {
    current = true;
    authority = StreamController<void>.broadcast(sync: true);
    await seed();
    await source();
  });
  tearDown(() async { await authority.close(); await f.close(); });

  test('public history binds source and receipt checkpoints and never expands private finance', () async {
    await receipt();
    final result = await read();
    expect(result.disposition, ReceiptReadDisposition.ready);
    expect(result.visiblePublicOnly, isTrue);
    expect(result.source!.canonicalState!.refundSourceMinor, BigInt.from(3000));
    final row = result.items.single;
    expect(row.receiptId, qb);
    expect(row.allocatedSource.minor, BigInt.from(1000));
    expect(row.authority.checkpoint.value, '3');
    expect(row.entityRevision, '8');
    expect(row.fullReceiptConservationKnown, isTrue);
    expect(row.incomeComponent!.minor, BigInt.zero);
    expect(row.businessDate, '2026-10-22');
  });

  test('readable cross-book receipt with redacted relation is absent without erasing source summary', () async {
    await receipt();
    await receipt(id: qc, scope: qOtherBook, kind: 'reimbursement', hidden: true, received: '2000');
    final result = await read();
    expect(result.items.map((r) => r.receiptId), [qb]);
    expect(result.source!.canonicalState!.reimbursementSourceMinor, BigInt.from(2000));
    expect(result.visiblePublicOnly, isTrue);
  });

  for (final role in ['owner', 'editor', 'viewer']) {
    test('confirmed $role may query canonical history and tracking', () async {
      await f.roles(role: role);
      await receipt();
      expect((await read()).items.single.authority.role, role);
      final result = await history.readTracking(lease, ReceiptTrackingQuery(scopeId: qBook));
      expect(result.items.single.read.canonical!.role, role);
    });
  }

  test('legacy missing summary and null remaining stay unknown with real visible history', () async {
    await source(summary: false, remaining: null);
    await receipt();
    final result = await read();
    expect(result.items.length, 1);
    expect(result.source!.canonicalState!.refundSourceMinor, isNull);
    final list = await history.readTracking(lease, ReceiptTrackingQuery(
      scopeId: qBook, filter: ReceiptTrackingFilter.openOnly));
    expect(list.items.single.read.canonicalState!.remainingAllocatableMinor, isNull);
  });

  test('money above 2^53 remains exact without mixed currency totals', () async {
    await source(paid: '9007199254740993', summary: false, remaining: '125');
    await receipt(sourceAmount: '9007199254740868', received: '9007199254740868');
    final row = (await read()).items.single;
    expect(row.allocatedSource.minor.toString(), '9007199254740868');
    expect(row.received.minor.toString(), '9007199254740868');
  });

  test('frozen FX is validated from source money to actual receipt currency', () async {
    await source(remaining: '0', refund: '10000', reimbursement: '0');
    await receipt(sourceAmount: '10000', received: '1400', currency: 'USD', rate: '0.14');
    final row = (await read()).items.single;
    expect(row.allocatedSource.currency, 'CNY');
    expect(row.allocatedReceipt.currency, 'USD');
    expect(row.rate, '0.14');
    await receipt(sourceAmount: '10000', received: '1400', currency: 'USD', rate: '0.15');
    expect((await read()).disposition, ReceiptReadDisposition.unavailable);
    expect((await read()).items, isEmpty);
  });

  test('refund-only settlement is not labelled fully reimbursed and open filter excludes known zero', () async {
    await source(remaining: '0', refund: '10000', reimbursement: '0');
    final all = await history.readTracking(lease, ReceiptTrackingQuery(scopeId: qBook));
    expect(all.items.single.read.canonicalState!.settlementReason, ReceiptSettlementReason.refunded);
    expect(all.items.single.read.canonicalState!.fullyReimbursed, isFalse);
    final open = await history.readTracking(lease, ReceiptTrackingQuery(
      scopeId: qBook, filter: ReceiptTrackingFilter.openOnly));
    expect(open.items, isEmpty);
  });

  test('cancelling tracking never removes actual canonical history', () async {
    await source(tracking: false);
    await receipt();
    expect((await read()).items.single.receiptId, qb);
    expect((await history.readTracking(lease, ReceiptTrackingQuery(scopeId: qBook))).items, isEmpty);
  });

  test('local tracking intent is separate and no financial operation is enqueued by a read', () async {
    await source(tracking: false);
    final shadow = await (f.db.select(f.db.serverShadows)..where((t) =>
      t.spaceId.equals(f.space.id) & t.scopeId.equals(qBook) & t.entityId.equals(qa))).getSingle();
    final payload = (jsonDecode(shadow.dataJson)['payload'] as Map).cast<String, Object?>();
    await f.local.saveEntityAndQueue(f.space, QueuedCommand(operationId: qid(9000),
      scopeId: qBook, entityType: 'bill', entityId: qa, action: 'update', baseRevision: '7',
      payload: {...payload, 'reimbursement_tracking': true}));
    final before = await f.db.select(f.db.pendingOperations).get();
    final list = await history.readTracking(lease, ReceiptTrackingQuery(scopeId: qBook));
    expect(list.items.single.read.canonicalState!.tracking.enabled, isFalse);
    expect(list.items.single.read.localTracking!.enabled, isTrue);
    expect(list.items.single.read.hasPending, isTrue);
    final after = await f.db.select(f.db.pendingOperations).get();
    expect(after.map((r) => r.operationJson), before.map((r) => r.operationJson));
    expect(after.map((r) => r.frozenRequestJson), before.map((r) => r.frozenRequestJson));
  });

  test('pending linked receipt hides current history until the original source causal gate releases', () async {
    await f.local.saveEntityAndQueue(f.space, QueuedCommand(operationId: qid(9001),
      scopeId: qBook, entityType: 'bill', entityId: qb, action: 'create', baseRevision: '0',
      payload: {'book_id': qBook, 'bill_type': 'refund', 'money': qmoney('1000'),
        'business_date': '2026-10-22', 'business_timezone': 'Asia/Shanghai',
        'account_id': null, 'allocations': [{'source_bill_id': qa, 'source_amount_minor': '1000',
          'receipt_amount_minor': '1000', 'rate': null}]}));
    final value = await read();
    expect(value.disposition, ReceiptReadDisposition.awaitingSourceSync);
    expect(value.items, isEmpty);
    expect(value.source, isNull);
  });

  test('cursor rejects same-checkpoint canonical, tracking and ACK changes', () async {
    await receipt(id: qb, date: '2026-10-22');
    await receipt(id: qc, date: '2026-10-21');
    final first = await read(limit: 1);
    expect(first.hasMore, isTrue);
    expect((await read(limit: 1, cursor: first.nextCursor)).items.single.receiptId, qc);
    await receipt(id: qc, date: '2026-10-20');
    expect((await read(limit: 1, cursor: first.nextCursor)).reason, 'receipt_cursor_stale');
    final fresh = await read(limit: 1);
    await f.local.writeSetting('sync.receipt-acks.v1.${f.space.id}.${qid(9999)}', '{}');
    expect((await read(limit: 1, cursor: fresh.nextCursor)).reason, 'receipt_cursor_stale');
  });

  test('private finance shadow never enters the public pagination fingerprint', () async {
    await receipt(id: qb); await receipt(id: qc, date: '2026-10-21');
    final first = await read(limit: 1);
    await f.shadow('bill', qb, qUser, {'projection_kind': 'bill_private_finance',
      'account_links': {'account_id': qid(9998)}, 'note': '不可扩展的私人影子'}, revision: '999');
    expect((await read(limit: 1, cursor: first.nextCursor)).items.single.receiptId, qc);
  });

  test('empty authorized book differs from revoked or unconfirmed book', () async {
    await source(tracking: false);
    expect((await history.readTracking(lease, ReceiptTrackingQuery(scopeId: qBook))).disposition,
      ReceiptReadDisposition.ready);
    await (f.db.update(f.db.syncStates)..where((t) => t.spaceId.equals(f.space.id))).write(
      SyncStatesCompanion(revokedScopesJson: Value(jsonEncode([qBook]))));
    final revoked = await history.readTracking(lease, ReceiptTrackingQuery(scopeId: qBook));
    expect(revoked.reason, 'scope_revoked'); expect(revoked.items, isEmpty);
  });

  test('watch clears controlled rows immediately on authority and DB invalidation', () async {
    await receipt();
    final values = <ReceiptHistoryRead>[];
    final subscription = history.watchHistory(lease, query()).listen(values.add);
    try {
      await until(() => values.any((r) => r.items.isNotEmpty));
      final before = values.length;
      authority.add(null);
      await until(() => values.length > before);
      expect(values[before].items, isEmpty);
      await (f.db.update(f.db.syncStates)..where((t) => t.spaceId.equals(f.space.id))).write(
        SyncStatesCompanion(revokedScopesJson: Value(jsonEncode([qBook]))));
      await until(() => values.last.reason == 'scope_revoked');
      expect(values.last.items, isEmpty);
    } finally { await subscription.cancel(); }
  });

  test('delayed acquired snapshot cannot reappear after a still-current authority notification', () async {
    await f.close();
    final pause = _PauseCommit();
    await seed(QueryFixture(executor: pause.intercept(NativeDatabase.memory())));
    await source(); await receipt();
    final first = Completer<void>(), firstCaptured = Completer<void>();
    final second = Completer<void>(), secondCaptured = Completer<void>();
    pause.release = first; pause.captured = firstCaptured;
    final values = <ReceiptHistoryRead>[];
    final subscription = history.watchHistory(lease, query()).listen(values.add);
    try {
      await firstCaptured.future.timeout(const Duration(seconds: 2));
      authority.add(null);
      pause.release = second; pause.captured = secondCaptured;
      first.complete();
      await secondCaptured.future.timeout(const Duration(seconds: 2));
      expect(values, isNotEmpty);
      expect(values.every((r) => r.items.isEmpty), isTrue);
      second.complete();
      await until(() => values.any((r) => r.items.isNotEmpty));
    } finally {
      if (!first.isCompleted) first.complete();
      if (!second.isCompleted) second.complete();
      await subscription.cancel();
    }
  });
}
