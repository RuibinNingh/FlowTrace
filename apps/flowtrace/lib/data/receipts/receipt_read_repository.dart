import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/config/data_space.dart';
import '../../domain/receipts/receipt_state.dart';
import '../ledger/ledger_projection.dart' show financialFingerprint;
import '../local/app_database.dart';
import '../local/local_repository.dart';
import '../sync/receipt_ack_proof.dart';
import '../sync/snapshot_protocol.dart';

/// Captures a login generation without giving this offline reader a transport.
///
/// [invalidations] must notify every authority change, including logout and a
/// switch away and back to the same account. Keep its broadcast bridge alive
/// while watching. A plain read checks [isCurrent] before and after its SQLite
/// snapshot; a retained UI must use [ReceiptReadRepository.watch].
final class ReceiptReadLease {
  ReceiptReadLease({
    required this.space,
    required this.clientId,
    required this.epoch,
    required this.isCurrent,
    required this.invalidations,
  }) {
    syncIdentifier(clientId);
    syncIdentifier(epoch);
  }

  final DataSpace space;
  final String clientId, epoch;
  final bool Function() isCurrent;
  final Stream<void> invalidations;
}

final class ReceiptSourceQuery {
  ReceiptSourceQuery({required this.scopeId, required this.sourceId}) {
    syncIdentifier(scopeId);
    syncIdentifier(sourceId);
  }
  final String scopeId, sourceId;
}

enum ReceiptReadDisposition { ready, awaitingSourceSync, unavailable }

enum ReceiptIntentKind { metadata, sourceFinancial, linkedReceipt, unproven }

/// A scope checkpoint has its own sequence. It is never an entity revision.
final class ReceiptScopeCheckpoint {
  const ReceiptScopeCheckpoint({required this.scopeId, required this.value});
  final String scopeId, value;
}

/// A current, locally confirmed public cut under the last known authorization.
/// This is offline evidence; the server rechecks authority on a later write.
final class ReceiptSourceCut {
  const ReceiptSourceCut({
    required this.sourceId,
    required this.scopeId,
    required this.entityRevision,
    required this.checkpoint,
    required this.permissionVersion,
    required this.role,
    required this.state,
  });
  final String sourceId, scopeId, entityRevision, permissionVersion, role;
  final ReceiptScopeCheckpoint checkpoint;
  final ReceiptSourceState state;
}

/// Current book authorization, independent of whether the book has any bills.
final class ReceiptBookAuthority {
  const ReceiptBookAuthority({
    required this.scopeId,
    required this.permissionVersion,
    required this.role,
    required this.checkpoint,
  });
  final String scopeId, permissionVersion, role;
  final ReceiptScopeCheckpoint checkpoint;
}

final class ReceiptBookAuthorityRead {
  const ReceiptBookAuthorityRead._(this.reason, this.canonical, this.snapshotFingerprint);
  final String? reason, snapshotFingerprint;
  final ReceiptBookAuthority? canonical;
  bool get ready => canonical != null;
}

/// The opaque fingerprint invalidates local pagination; it grants no authority
/// and never substitutes for a ready source read or its causal proof.
final class ReceiptSourceReadBatch {
  ReceiptSourceReadBatch._(List<ReceiptSourceRead> reads, this.snapshotFingerprint)
    : reads = List.unmodifiable(reads);
  final List<ReceiptSourceRead> reads;
  final String? snapshotFingerprint;
}

/// Describes local intent separately from a server-confirmed progress cut.
/// Original payloads remain in the outbox; no private finance is expanded here.
final class ReceiptReadIntent {
  const ReceiptReadIntent({
    required this.operationId,
    required this.operationState,
    required this.kind,
  });
  final String operationId, operationState;
  final ReceiptIntentKind kind;
  bool get conflicted => {'rejected', 'blocked'}.contains(operationState);
}

final class ReceiptSourceRead {
  ReceiptSourceRead._({
    required this.disposition,
    required this.reason,
    this.canonical,
    this.localTracking,
    List<ReceiptReadIntent> intents = const [],
    Map<String, String> requiredCursors = const {},
    List<String> causalOperationIds = const [],
  }) : intents = List.unmodifiable(intents),
       requiredCursors = Map.unmodifiable(requiredCursors),
       causalOperationIds = List.unmodifiable(causalOperationIds);

  final ReceiptReadDisposition disposition;
  final String? reason;
  final ReceiptSourceCut? canonical;
  ReceiptSourceState? get canonicalState => canonical?.state;
  final ReimbursementTracking? localTracking;
  final List<ReceiptReadIntent> intents;
  final Map<String, String> requiredCursors;
  final List<String> causalOperationIds;
  bool get hasPending => intents.any((intent) => !intent.conflicted);
  bool get hasConflict => intents.any((intent) => intent.conflicted);

  static ReceiptSourceRead _hidden(String reason) => ReceiptSourceRead._(
    disposition: ReceiptReadDisposition.unavailable,
    reason: reason,
  );
}

final class _Rows {
  const _Rows(
    this.entities,
    this.shadows,
    this.operations,
    this.state,
    this.settings,
  );
  final List<StoredEntity> entities;
  final List<ConfirmedEntity> shadows;
  final List<StoredOperation> operations;
  final SpaceSyncState? state;
  final Map<String, String> settings;
}

/// One SQLite cut, no requests and no second cache of controlled server data.
final class ReceiptReadRepository {
  ReceiptReadRepository(this.repository);
  final LocalRepository repository;
  AppDatabase get _db => repository.database;

  Future<ReceiptSourceRead> read(
    ReceiptReadLease lease,
    ReceiptSourceQuery query,
  ) async => (await readMany(lease, [query])).reads.single;

  Future<_Rows> _loadRows(ReceiptReadLease lease) async {
    final space = lease.space;
    final entities = await (_db.select(_db.localEntities)..where(
      (t) => t.spaceId.equals(space.id) & t.entityType.equals('bill'),
    )).get();
    final shadows = await (_db.select(_db.serverShadows)..where(
      (t) => t.spaceId.equals(space.id) & t.entityType.equals('bill'),
    )).get();
    final operations = await (_db.select(_db.pendingOperations)
      ..where((t) => t.spaceId.equals(space.id) & t.entityType.equals('bill'))
      ..orderBy([(t) => OrderingTerm.asc(t.sequence)])).get();
    final state = await (_db.select(_db.syncStates)
      ..where((t) => t.spaceId.equals(space.id))).getSingleOrNull();
    final settings = await (_db.select(_db.appSettings)..where(
      (t) => t.key.equals('sync.scope-details.${space.id}') |
        t.key.equals('sync.scopes.${space.id}') |
        t.key.like('${receiptAckProofPrefix(space)}%') |
        t.key.like('${receiptBindingsPrefix(space)}%'),
    )).get();
    return _Rows(entities, shadows, operations, state, {
      for (final row in settings) row.key: row.value,
    });
  }

  String _fingerprint(_Rows rows) {
    final entities = [...rows.entities]..sort((a, b) => a.entityId.compareTo(b.entityId));
    final shadows = rows.shadows.where((row) => _public(row.dataJson) != null).toList()
      ..sort((a, b) => '${a.scopeId}:${a.entityId}'.compareTo('${b.scopeId}:${b.entityId}'));
    // Local input is hashed only as an invalidation signal, never interpreted
    // as canonical history. Private finance shadows are deliberately excluded.
    return syncContentHash({
      'entities': [for (final row in entities)
        [row.scopeId, row.entityId, row.serverRevision, row.deleted, row.dataJson]],
      'public_shadows': [for (final row in shadows)
        [row.scopeId, row.entityId, row.revision, row.deleted, row.dataJson]],
      'operations': [for (final row in rows.operations)
        [row.operationId, row.state, row.operationJson, row.frozenRequestJson,
         row.baseDataJson, row.appliedRevision, row.predecessorId]],
      'state': rows.state == null ? null : [rows.state!.clientId, rows.state!.epoch,
        rows.state!.status, rows.state!.cursorsJson, rows.state!.revokedScopesJson],
      'settings': rows.settings,
    });
  }

  Future<ReceiptSourceReadBatch> readMany(
    ReceiptReadLease lease,
    List<ReceiptSourceQuery> queries,
  ) async {
    final frozen = List<ReceiptSourceQuery>.unmodifiable(queries);
    if (frozen.isEmpty || frozen.length > 100) {
      throw ArgumentError('Receipt source batch requires 1–100 queries.');
    }
    ReceiptSourceReadBatch hidden(String reason) => ReceiptSourceReadBatch._(
      [for (final _ in frozen) ReceiptSourceRead._hidden(reason)], null,
    );
    if (!lease.isCurrent()) {
      return hidden('identity_changed');
    }
    try {
      final result = await _db.readSnapshot(() async {
        final rows = await _loadRows(lease);
        if (!lease.isCurrent()) return hidden('identity_changed');
        final reads = <ReceiptSourceRead>[];
        for (final query in frozen) {
          try {
            reads.add(_project(lease, query, rows));
          } on Object {
            reads.add(ReceiptSourceRead._hidden('receipt_read_unavailable'));
          }
        }
        return ReceiptSourceReadBatch._(reads, _fingerprint(rows));
      });
      return lease.isCurrent() ? result : hidden('identity_changed');
    } on Object {
      return hidden(lease.isCurrent() ? 'receipt_read_unavailable' : 'identity_changed');
    }
  }

  Future<ReceiptBookAuthorityRead> readBookAuthority(ReceiptReadLease lease, String scopeId) async {
    syncIdentifier(scopeId);
    if (!lease.isCurrent()) return const ReceiptBookAuthorityRead._('identity_changed', null, null);
    try {
      final result = await _db.readSnapshot(() async {
        final rows = await _loadRows(lease);
        final value = _bookAuthority(lease, scopeId, rows);
        return ReceiptBookAuthorityRead._(value.reason, value.canonical,
          value.ready ? _fingerprint(rows) : null);
      });
      return lease.isCurrent() ? result
        : const ReceiptBookAuthorityRead._('identity_changed', null, null);
    } on Object {
      return ReceiptBookAuthorityRead._(lease.isCurrent() ? 'receipt_read_unavailable'
        : 'identity_changed', null, null);
    }
  }

  /// Authority is subscribed before the first read. Every emission is checked
  /// again so a queued read cannot publish after an identity change. A failed or
  /// ended authority/database stream clears the cut and ends this subscription.
  Stream<ReceiptSourceRead> watch(
    ReceiptReadLease lease,
    ReceiptSourceQuery query,
  ) {
    late StreamController<ReceiptSourceRead> output;
    StreamSubscription<void>? authority;
    StreamSubscription<dynamic>? database;
    var stopped = false, reading = false, rerun = false;
    var generation = 0;

    void hide(String reason) {
      if (!stopped) output.add(ReceiptSourceRead._hidden(reason));
    }

    Future<void> stop(String reason) async {
      if (stopped) return;
      hide(reason);
      stopped = true;
      generation++;
      await authority?.cancel();
      await database?.cancel();
      await output.close();
    }

    Future<void> reload() async {
      if (stopped) return;
      if (!lease.isCurrent()) {
        hide('identity_changed');
        return;
      }
      if (reading) {
        rerun = true;
        return;
      }
      reading = true;
      do {
        rerun = false;
        final captured = generation;
        final value = await read(lease, query);
        if (!stopped && captured == generation) {
          output.add(
            lease.isCurrent()
                ? value
                : ReceiptSourceRead._hidden('identity_changed'),
          );
        }
      } while (!stopped && rerun);
      reading = false;
    }

    output = StreamController<ReceiptSourceRead>(
      onListen: () {
        authority = lease.invalidations.listen(
          (_) {
            generation++;
            final current = lease.isCurrent();
            hide(current ? 'authority_changed' : 'identity_changed');
            if (current) {
              unawaited(reload());
            }
          },
          onError: (Object error, StackTrace trace) {
            unawaited(stop('authority_stream_error'));
          },
          onDone: () {
            unawaited(stop('authority_stream_ended'));
          },
        );
        database = _db
            .customSelect(
              'SELECT 1',
              readsFrom: {
                _db.localEntities,
                _db.serverShadows,
                _db.pendingOperations,
                _db.syncStates,
                _db.appSettings,
              },
            )
            .watch()
            .listen(
              (_) {
                generation++;
                hide('receipt_data_changed');
                unawaited(reload());
              },
              onError: (Object error, StackTrace trace) {
                unawaited(stop('receipt_stream_error'));
              },
              onDone: () {
                unawaited(stop('receipt_stream_ended'));
              },
            );
      },
      onCancel: () async {
        stopped = true;
        generation++;
        await authority?.cancel();
        await database?.cancel();
      },
    );
    return output.stream;
  }

  ReceiptBookAuthorityRead _bookAuthority(ReceiptReadLease lease, String scopeId, _Rows rows) {
    ReceiptBookAuthorityRead hidden(String reason) => ReceiptBookAuthorityRead._(reason, null, null);
    final state = rows.state;
    if (!lease.space.verified || state == null) {
      return hidden('sync_state_missing');
    }
    if (state.status != 'active') {
      return hidden('sync_state_inactive');
    }
    if (state.epoch != lease.epoch || state.clientId != lease.clientId) {
      return hidden('sync_identity_mismatch');
    }
    final revoked = (jsonDecode(state.revokedScopesJson) as List)
        .cast<String>();
    if (revoked.contains(scopeId) ||
        revoked.contains(lease.space.userId)) {
      return hidden('scope_revoked');
    }
    final permissions = syncVector(
      jsonDecode(rows.settings['sync.scopes.${lease.space.id}'] ?? '{}'),
    );
    final details = syncObject(
      jsonDecode(rows.settings['sync.scope-details.${lease.space.id}'] ?? '{}'),
    );
    if (details['version'] != 1 ||
        details['epoch'] != state.epoch ||
        details['scopes'] is! List ||
        !permissions.containsKey(scopeId)) {
      return hidden('scope_unconfirmed');
    }
    final matches = (details['scopes'] as List)
        .whereType<Map>()
        .where((row) => row['scope_id'] == scopeId)
        .toList();
    if (matches.length != 1) {
      return hidden('scope_unconfirmed');
    }
    final scope = matches.single;
    if (scope['kind'] != 'book' ||
        !{'owner', 'editor', 'viewer'}.contains(scope['role']) ||
        scope['permission_version'] != permissions[scopeId]) {
      return hidden('scope_unconfirmed');
    }
    final cursors = syncVector(jsonDecode(state.cursorsJson));
    final checkpoint = cursors[scopeId];
    if (checkpoint == null) {
      return hidden('scope_checkpoint_missing');
    }
    return ReceiptBookAuthorityRead._(null, ReceiptBookAuthority(
      scopeId: scopeId, permissionVersion: permissions[scopeId]!, role: scope['role'] as String,
      checkpoint: ReceiptScopeCheckpoint(scopeId: scopeId, value: checkpoint),
    ), null);
  }

  ReceiptSourceRead _project(
    ReceiptReadLease lease,
    ReceiptSourceQuery query,
    _Rows rows,
  ) {
    final authority = _bookAuthority(lease, query.scopeId, rows);
    if (!authority.ready) return ReceiptSourceRead._hidden(authority.reason!);
    final book = authority.canonical!, state = rows.state!;
    final shadows = rows.shadows
        .where(
          (row) =>
              row.scopeId == query.scopeId && row.entityId == query.sourceId,
        )
        .toList();
    if (shadows.length != 1 || shadows.single.deleted) {
      return ReceiptSourceRead._hidden('source_unavailable');
    }
    final shadow = shadows.single;
    if (BigInt.parse(syncRevision(shadow.revision)) <= BigInt.zero) {
      return ReceiptSourceRead._hidden('source_unconfirmed');
    }
    final canonical = _public(shadow.dataJson);
    if (canonical == null ||
        (canonical['payload'] as Map)['book_id'] != query.scopeId) {
      return ReceiptSourceRead._hidden('source_public_required');
    }
    final sourceState = ReceiptSourceState.fromCanonicalPublicBill(canonical);
    final local = rows.entities
        .where((row) => row.entityId == query.sourceId)
        .firstOrNull;
    final intents = <ReceiptReadIntent>[];
    ReimbursementTracking? tracking;
    if (local != null && !local.deleted && local.scopeId == query.scopeId) {
      final raw = syncObject(jsonDecode(local.dataJson));
      final payload = raw['projection_kind'] == null
          ? raw
          : raw['projection_kind'] == 'bill_public'
          ? raw['payload']
          : null;
      if (payload is Map && payload['bill_type'] == 'expense') {
        tracking = ReimbursementTracking.fromPayload(payload);
      }
    }
    for (final operation in rows.operations) {
      if (!{
        'queued',
        'sending',
        'retry',
        'rejected',
        'blocked',
      }.contains(operation.state)) {
        continue;
      }
      final encoded = syncObject(
        jsonDecode(operation.frozenRequestJson ?? operation.operationJson),
      );
      final command = operation.frozenRequestJson == null
          ? encoded
          : syncObject((encoded['operations'] as List).single);
      final payload = syncObject(command['payload']);
      if (operation.entityId == query.sourceId) {
        final before = _public(operation.baseDataJson);
        final metadata =
            command['action'] == 'update' &&
            command['move'] == null &&
            command['scope_id'] == query.scopeId &&
            before != null &&
            financialFingerprint(syncObject(before['payload'])) ==
                financialFingerprint(payload) &&
            financialFingerprint(syncObject(canonical['payload'])) ==
                financialFingerprint(payload);
        intents.add(
          ReceiptReadIntent(
            operationId: operation.operationId,
            operationState: operation.state,
            kind: metadata
                ? ReceiptIntentKind.metadata
                : ReceiptIntentKind.sourceFinancial,
          ),
        );
      } else {
        final bindingText = rows
            .settings['${receiptBindingsPrefix(lease.space)}${operation.operationId}'];
        final binding = bindingText == null
            ? null
            : syncObject(jsonDecode(bindingText));
        ReceiptIntentKind? relation;
        if (binding != null &&
            receiptProofIdentityMatches(
              binding,
              lease.space,
              state,
              operation,
            ) &&
            binding['complete'] == true &&
            binding['preserves_hidden'] != true) {
          final sources = (binding['sources'] as List).map(syncObject);
          if (sources.any(
            (row) =>
                row['source_id'] == query.sourceId &&
                row['scope_id'] == query.scopeId,
          )) {
            relation = ReceiptIntentKind.linkedReceipt;
          }
        } else {
          relation = _pendingRelation(
            operation,
            command,
            rows.shadows,
            query.sourceId,
          );
        }
        if (relation != null) {
          intents.add(
            ReceiptReadIntent(
              operationId: operation.operationId,
              operationState: operation.state,
              kind: relation,
            ),
          );
        }
      }
    }
    final unsafe = intents
        .where((intent) => intent.kind != ReceiptIntentKind.metadata)
        .toList();
    if (unsafe.isNotEmpty) {
      final conflict = unsafe.any((intent) => intent.conflicted);
      return ReceiptSourceRead._(
        disposition: conflict
            ? ReceiptReadDisposition.unavailable
            : ReceiptReadDisposition.awaitingSourceSync,
        reason: conflict ? 'receipt_local_conflict' : 'awaiting_source_sync',
        intents: intents,
        localTracking: tracking,
      );
    }
    if (local == null ||
        local.deleted ||
        local.scopeId != query.scopeId ||
        BigInt.parse(syncRevision(local.serverRevision)) >
            BigInt.parse(shadow.revision)) {
      return ReceiptSourceRead._(
        disposition: ReceiptReadDisposition.awaitingSourceSync,
        reason: 'source_cut_not_installed',
        intents: intents,
        localTracking: tracking,
      );
    }
    final causal = receiptCausalStatus(
      space: lease.space,
      state: state,
      settings: rows.settings,
      operations: rows.operations,
      sourceId: query.sourceId,
      sourceScopeId: query.scopeId,
    );
    if (causal.disposition != ReceiptCausalDisposition.satisfied) {
      return ReceiptSourceRead._(
        disposition:
            causal.disposition == ReceiptCausalDisposition.awaitingSourceSync
            ? ReceiptReadDisposition.awaitingSourceSync
            : ReceiptReadDisposition.unavailable,
        reason: causal.reason ?? 'awaiting_source_sync',
        intents: intents,
        localTracking: tracking,
        requiredCursors: causal.requiredCursors,
        causalOperationIds: causal.operationIds,
      );
    }
    return ReceiptSourceRead._(
      disposition: ReceiptReadDisposition.ready,
      reason: null,
      localTracking: tracking,
      intents: intents,
      canonical: ReceiptSourceCut(
        sourceId: query.sourceId,
        scopeId: query.scopeId,
        entityRevision: shadow.revision,
        checkpoint: ReceiptScopeCheckpoint(
          scopeId: query.scopeId,
            value: book.checkpoint.value,
        ),
        permissionVersion: book.permissionVersion,
        role: book.role,
        state: sourceState,
      ),
    );
  }

  static Map<String, Object?>? _public(String? encoded) {
    if (encoded == null) return null;
    try {
      final raw = syncObject(jsonDecode(encoded));
      return raw['projection_kind'] == 'bill_public' &&
              raw['payload'] is Map<String, Object?>
          ? raw
          : null;
    } on Object {
      return null;
    }
  }

  static ReceiptIntentKind? _pendingRelation(
    StoredOperation operation,
    Map<String, Object?> command,
    List<ConfirmedEntity> shadows,
    String sourceId,
  ) {
    final action = command['action'];
    final after = syncObject(command['payload']);
    // An enqueue-time base can predate a successful predecessor (A -> B -> C).
    // nextPush fixes the real before when it freezes this operation. Until that
    // point, never mistake the old A base for proof that B is unaffected.
    if (operation.frozenRequestJson == null &&
        operation.predecessorId != null) {
      return ReceiptIntentKind.unproven;
    }
    Map<String, Object?>? before;
    if (action != 'create') {
      before = _public(operation.baseDataJson);
      if (before == null) {
        final candidates = shadows.where(
          (row) =>
              !row.deleted &&
              row.entityId == operation.entityId &&
              row.scopeId == command['scope_id'] &&
              row.revision == command['base_revision'],
        );
        if (candidates.length == 1) {
          before = _public(candidates.single.dataJson);
        }
      }
      if (before == null) return ReceiptIntentKind.unproven;
    }
    if (receiptPreservesHiddenFinancials(command, before)) return null;
    for (final row in [
      ?before,
      if (action != 'delete') {'payload': after},
    ]) {
      final payload = syncObject(row['payload']);
      if (!{'refund', 'reimbursement'}.contains(payload['bill_type'])) continue;
      final allocations = payload['allocations'];
      if (allocations is! List ||
          allocations.any(
            (item) => item is! Map || item['source_bill_id'] is! String,
          )) {
        return ReceiptIntentKind.unproven;
      }
      if (allocations.any(
        (item) => (item as Map)['source_bill_id'] == sourceId,
      )) {
        return ReceiptIntentKind.linkedReceipt;
      }
      if (row['hidden_allocation_count'] != null &&
          row['hidden_allocation_count'] != 0) {
        return ReceiptIntentKind.unproven;
      }
    }
    return null;
  }
}
