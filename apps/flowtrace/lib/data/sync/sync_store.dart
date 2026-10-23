import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../local/app_database.dart';
import '../local/local_repository.dart';
import 'receipt_ack_proof.dart';
import 'snapshot_protocol.dart';
import 'tombstone_proof.dart';

Map<String, Object?> _object(String text) =>
    (jsonDecode(text) as Map<String, dynamic>).cast<String, Object?>();

String _destinationScope(Map command) => command['move'] is Map
    ? (command['move'] as Map)['target_scope_id'] as String
    : command['scope_id'] as String;

Set<String> _requiredScopes(Map command) => {
  command['scope_id'] as String,
  _destinationScope(command),
};

bool _cachedScopeReference(String? encoded, String scope) {
  if (encoded == null) return false;
  try {
    final root = _object(encoded);
    final records = <Map>[root];
    if (root['event'] is Map) records.add(root['event'] as Map);
    for (final row in records.toList()) {
      if (row['data'] is Map) records.add(row['data'] as Map);
    }
    return records.any(
      (row) =>
          row['scope_id'] == scope ||
          row['book_id'] == scope ||
          row['payload'] is Map && (row['payload'] as Map)['book_id'] == scope,
    );
  } on Object {
    // An unreadable cache cannot safely retain formerly controlled content.
    return true;
  }
}

BigInt _revision(String value) {
  if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
    throw const FormatException('Invalid revision');
  }
  final number = BigInt.parse(value);
  if (number > BigInt.parse('9223372036854775807')) {
    throw const FormatException('Revision out of range');
  }
  return number;
}

/// An immutable event within one server commit. The server, not the local
/// device clock, establishes its revision and permission scope.
final class SyncEvent {
  SyncEvent({
    required this.scopeId,
    required this.entityType,
    required this.entityId,
    required this.revision,
    required this.deleted,
    required Map<String, Object?> data,
  }) : dataJson = jsonEncode(data) {
    _revision(revision);
  }

  final String scopeId;
  final String entityType;
  final String entityId;
  final String revision;
  final bool deleted;
  final String dataJson;
  Map<String, Object?> get data => _object(dataJson);
}

final class FrozenPush {
  const FrozenPush(this.operationId, this.body, this.attempt);
  final String operationId;
  final String body;
  final int attempt;
}

/// Durable coordination only. Transport and account credentials are supplied
/// by the caller; this class never sends an operation across data spaces.
final class SyncStore {
  SyncStore(this.repository);
  final LocalRepository repository;
  AppDatabase get db => repository.database;
  static const _uuid = Uuid();

  Future<SpaceSyncState?> state(DataSpace space) => (db.select(
    db.syncStates,
  )..where((t) => t.spaceId.equals(space.id))).getSingleOrNull();

  Future<StoredOperation?> _operation(DataSpace space, String id) =>
      (db.select(db.pendingOperations)..where(
            (t) => t.spaceId.equals(space.id) & t.operationId.equals(id),
          ))
          .getSingleOrNull();

  Future<List<StoredOperation>> _entityOperations(
    DataSpace space,
    String type,
    String id,
  ) =>
      (db.select(db.pendingOperations)
            ..where(
              (t) =>
                  t.spaceId.equals(space.id) &
                  t.entityType.equals(type) &
                  t.entityId.equals(id) &
                  t.state.isNotIn(['applied', 'discarded']),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.sequence)]))
          .get();

  Future<ConfirmedEntity?> _shadow(
    DataSpace space,
    String scope,
    String type,
    String id,
  ) =>
      (db.select(db.serverShadows)..where(
            (t) =>
                t.spaceId.equals(space.id) &
                t.scopeId.equals(scope) &
                t.entityType.equals(type) &
                t.entityId.equals(id),
          ))
          .getSingleOrNull();

  Future<ConfirmedEntity?> _latestPublic(
    DataSpace space,
    String type,
    String id,
  ) async {
    final current = await state(space);
    final revoked = current == null
        ? <Object?>[]
        : jsonDecode(current.revokedScopesJson) as List;
    final rows =
        await (db.select(db.serverShadows)..where(
              (t) =>
                  t.spaceId.equals(space.id) &
                  t.entityType.equals(type) &
                  t.entityId.equals(id),
            ))
            .get();
    final visible = rows
        .where(
          (row) =>
              !revoked.contains(row.scopeId) &&
              !(type == 'bill' &&
                  (row.scopeId == space.userId ||
                      _object(row.dataJson)['projection_kind'] ==
                          'bill_private_finance')),
        )
        .toList();
    visible.sort((a, b) {
      final revision = _revision(b.revision).compareTo(_revision(a.revision));
      if (revision != 0) return revision;
      if (a.deleted != b.deleted) return a.deleted ? 1 : -1;
      return a.scopeId.compareTo(b.scopeId);
    });
    return visible.firstOrNull;
  }

  Future<void> _installConfirmed(DataSpace space, ConfirmedEntity confirmed) =>
      db
          .into(db.localEntities)
          .insertOnConflictUpdate(
            LocalEntitiesCompanion.insert(
              spaceId: space.id,
              scopeId: Value(confirmed.scopeId),
              entityType: confirmed.entityType,
              entityId: confirmed.entityId,
              dataJson: confirmed.dataJson,
              serverRevision: Value(confirmed.revision),
              deleted: Value(confirmed.deleted),
              updatedAt: DateTime.now().toUtc(),
            ),
          );

  Future<SyncEvent?> latestPublicProjection(
    DataSpace space,
    String type,
    String id,
  ) async {
    final row = await _latestPublic(space, type, id);
    return row == null
        ? null
        : SyncEvent(
            scopeId: row.scopeId,
            entityType: row.entityType,
            entityId: row.entityId,
            revision: row.revision,
            deleted: row.deleted,
            data: _object(row.dataJson),
          );
  }

  Future<void> configure(
    DataSpace space,
    String clientId,
    String epoch, {
    bool Function()? isCurrent,
  }) async {
    if (!space.verified) throw StateError('Unverified data space');
    var changed = false;
    await db.atomicWrite(() async {
      if (isCurrent?.call() == false) throw StateError('Identity changed');
      final current = await state(space);
      if (current == null) {
        await db
            .into(db.syncStates)
            .insert(
              SyncStatesCompanion.insert(
                spaceId: space.id,
                clientId: clientId,
                epoch: epoch,
              ),
            );
      } else if (current.epoch != epoch || current.clientId != clientId) {
        if (current.status != 'recovery_required') {
          await _backup(
            space,
            current,
            current.epoch != epoch ? 'epoch_changed' : 'client_changed',
          );
        }
        await (db.update(
          db.syncStates,
        )..where((t) => t.spaceId.equals(space.id))).write(
          const SyncStatesCompanion(status: Value('recovery_required')),
        );
        changed = true;
      }
      if (isCurrent?.call() == false) throw StateError('Identity changed');
    });
    if (changed) {
      throw StateError('Recovery review required; local data preserved');
    }
  }

  /// Freeze one request before I/O. A timeout reuses these exact bytes and ID.
  Future<FrozenPush?> nextPush(DataSpace space) => db.atomicWrite(() async {
    final current = await state(space);
    if (current == null || current.status != 'active') return null;
    final allPending = await repository.pending(space);
    final creatingBooks = <String, StoredOperation>{};
    for (final pending in allPending) {
      final command = _object(pending.operationJson);
      if (pending.entityType == 'book' &&
          command['action'] == 'create' &&
          command['scope_id'] == space.userId) {
        creatingBooks[pending.entityId] = pending;
      }
    }
    for (final operation in allPending) {
      if (!{'queued', 'sending', 'retry'}.contains(operation.state)) continue;
      final intent = _object(operation.operationJson);
      // A new local book has no server scope until its own create succeeds.
      // Its children may be saved offline in any order, but cannot send first.
      final creatingBook = creatingBooks[intent['scope_id']];
      final creatingTarget = creatingBooks[_destinationScope(intent)];
      if (creatingBook != null &&
              creatingBook.operationId != operation.operationId ||
          creatingTarget != null &&
              creatingTarget.operationId != operation.operationId) {
        continue;
      }
      if (_requiredScopes(intent).any(
        (scope) =>
            (jsonDecode(current.revokedScopesJson) as List).contains(scope),
      )) {
        await reject(space, operation.operationId, 'scope_revoked');
        continue;
      }
      final predecessor = operation.predecessorId;
      String? previousRevision;
      if (predecessor != null) {
        final previous = await _operation(space, predecessor);
        if (previous == null || previous.state != 'applied') continue;
        previousRevision = previous.appliedRevision;
        if (previousRevision == null) {
          throw StateError('Missing predecessor receipt');
        }
      }
      final declared = intent['depends_on'] as String?;
      if (declared != null) {
        final dependency = await _operation(space, declared);
        if (dependency != null && dependency.state != 'applied') continue;
      }
      var body = operation.frozenRequestJson;
      if (body == null) {
        if (predecessor != null) {
          intent['depends_on'] = predecessor;
          intent['base_revision'] = previousRevision;
        }
        body = jsonEncode({
          'protocol_version': 1,
          'client_id': current.clientId,
          'sync_epoch': current.epoch,
          'operations': [intent],
        });
      } else {
        final frozen = _object(body);
        if (frozen['client_id'] != current.clientId ||
            frozen['sync_epoch'] != current.epoch) {
          throw StateError('Frozen request belongs to another sync identity');
        }
      }
      final base = await _shadow(
        space,
        intent['scope_id'] as String,
        operation.entityType,
        operation.entityId,
      );
      await _freezeReceiptBindings(
        space,
        current,
        operation,
        body,
        // A retry must never recalculate its historical before from a newer
        // shadow. Legacy frozen operations deliberately use incomplete bindings.
        operation.frozenRequestJson == null ? base : null,
      );
      await (db.update(db.pendingOperations)..where(
            (t) =>
                t.spaceId.equals(space.id) &
                t.operationId.equals(operation.operationId),
          ))
          .write(
            PendingOperationsCompanion(
              frozenRequestJson: Value(body),
              state: const Value('sending'),
              attemptCount: Value(operation.attemptCount + 1),
              baseDataJson: operation.frozenRequestJson == null
                  ? Value(base?.dataJson)
                  : const Value.absent(),
            ),
          );
      return FrozenPush(
        operation.operationId,
        body,
        operation.attemptCount + 1,
      );
    }
    return null;
  });

  Future<void> _freezeReceiptBindings(
    DataSpace space,
    SpaceSyncState current,
    StoredOperation operation,
    String frozenBody,
    ConfirmedEntity? firstFreezeBase,
  ) async {
    final key = '${receiptBindingsPrefix(space)}${operation.operationId}';
    final previous = await repository.readSetting(key);
    final identity = <String, Object?>{
      'version': 1,
      'space_id': space.id,
      'instance_id': space.serverInstanceId,
      'user_id': space.userId,
      'epoch': current.epoch,
      'client_id': current.clientId,
      'operation_id': operation.operationId,
      'frozen_hash': receiptFrozenHash(frozenBody),
    };
    if (previous != null) {
      final saved = syncObject(jsonDecode(previous));
      if (identity.entries.any((entry) => saved[entry.key] != entry.value)) {
        throw StateError('Frozen receipt binding identity changed');
      }
      return;
    }
    final request = syncObject(jsonDecode(frozenBody));
    final command = syncObject((request['operations'] as List).single);
    final after = syncObject(command['payload']);
    Map<String, Object?>? before;
    Map<String, Object?>? beforeProjection;
    var completeBefore = command['action'] == 'create';
    final predecessorId = operation.predecessorId;
    if (predecessorId != null) {
      final predecessor = await _operation(space, predecessorId);
      if (predecessor?.state == 'applied' &&
          predecessor?.appliedRevision == command['base_revision'] &&
          predecessor?.frozenRequestJson != null) {
        final priorRequest = _object(predecessor!.frozenRequestJson!);
        final priorCommand = syncObject(
          (priorRequest['operations'] as List).single,
        );
        if (priorRequest['sync_epoch'] == current.epoch &&
            priorRequest['client_id'] == current.clientId &&
            priorCommand['entity_id'] == operation.entityId &&
            priorCommand['action'] != 'delete') {
          final priorPayload = syncObject(priorCommand['payload']);
          if (priorPayload['preserve_hidden_financial_links'] != true) {
            before = priorPayload;
            completeBefore = true;
          }
        }
      }
    }
    if (!completeBefore &&
        firstFreezeBase != null &&
        !firstFreezeBase.deleted &&
        firstFreezeBase.revision == command['base_revision']) {
      final projection = _object(firstFreezeBase.dataJson);
      if (projection['projection_kind'] == 'bill_public') {
        beforeProjection = projection;
        before = syncObject(projection['payload']);
        completeBefore =
            (projection['hidden_allocation_count'] as int? ?? 0) == 0;
      }
    }
    var relevant =
        operation.entityType == 'bill' &&
        (receiptPayloadMayAllocate(after) ||
            before != null && receiptPayloadMayAllocate(before) ||
            !completeBefore);
    var complete = completeBefore && operation.frozenRequestJson == null;
    final sources = <String, String>{};
    var preservesHidden = false;
    if (relevant &&
        receiptPreservesHiddenFinancials(command, beforeProjection)) {
      // Only the server's accepted strict preserve route can make this a
      // successful no-touch operation. Pending callers still check metadata.
      relevant = false;
      complete = true;
      preservesHidden = true;
    } else if (relevant) {
      for (final payload in [?before, after]) {
        final allocations = payload['allocations'] as List? ?? const [];
        if (allocations.length > 100) {
          throw StateError('Receipt allocation binding limit exceeded');
        }
        for (final allocation in allocations) {
          final sourceId = syncIdentifier(
            syncObject(allocation)['source_bill_id'],
          );
          final source = await _latestPublic(space, 'bill', sourceId);
          if (source == null ||
              source.deleted ||
              _object(source.dataJson)['projection_kind'] != 'bill_public') {
            complete = false;
            continue;
          }
          sources[sourceId] = source.scopeId;
        }
      }
    }
    final value = canonicalSyncJson({
      ...identity,
      'relevant': relevant,
      'complete': complete,
      'preserves_hidden': preservesHidden,
      'sources': [
        for (final source in (sources.keys.toList()..sort()))
          {'source_id': source, 'scope_id': sources[source]},
      ],
    });
    if (utf8.encode(value).length > 131072) {
      throw StateError('Receipt binding storage limit exceeded');
    }
    await _writeReceiptSidecar(space, key, value);
  }

  Future<void> _writeReceiptSidecar(
    DataSpace space,
    String key,
    String value,
  ) async {
    // One immutable binding and one proof per existing journal operation. Never
    // evict live evidence silently: exceeding the cap rolls the whole write back.
    final rows =
        await (db.select(db.appSettings)..where(
              (t) =>
                  t.key.like('${receiptBindingsPrefix(space)}%') |
                  t.key.like('${receiptAckProofPrefix(space)}%'),
            ))
            .get();
    final total = rows
        .where((row) => row.key != key)
        .fold<int>(
          utf8.encode(value).length,
          (sum, row) => sum + utf8.encode(row.value).length,
        );
    if (total > 32 * 1024 * 1024) {
      throw StateError(
        'Receipt evidence storage limit exceeded; preserve and rebuild',
      );
    }
    await repository.writeSetting(key, value);
  }

  /// Controlled source positions cannot survive a changed authorization view.
  /// Original operation/request bytes and local intent remain in the journal.
  Future<void> invalidateReceiptEvidenceForScope(
    DataSpace space,
    String scopeId,
  ) => db.atomicWrite(() async {
    await clearGroupCache(space);
    final rows =
        await (db.select(db.appSettings)..where(
              (t) =>
                  t.key.like('${receiptBindingsPrefix(space)}%') |
                  t.key.like('${receiptAckProofPrefix(space)}%'),
            ))
            .get();
    final operationIds = <String>{};
    for (final row in rows) {
      try {
        final value = _object(row.value);
        final sources = value['sources'] as List? ?? const [];
        final vector = value['scope_revisions'] as Map? ?? const {};
        if (sources.any((source) => (source as Map)['scope_id'] == scopeId) ||
            vector.containsKey(scopeId)) {
          operationIds.add(value['operation_id'] as String);
        }
      } on Object {
        // Malformed controlled evidence is never retained as trusted cache.
        await (db.delete(
          db.appSettings,
        )..where((t) => t.key.equals(row.key))).go();
      }
    }
    for (final operationId in operationIds) {
      await (db.delete(db.appSettings)..where(
            (t) =>
                t.key.equals('${receiptBindingsPrefix(space)}$operationId') |
                t.key.equals('${receiptAckProofPrefix(space)}$operationId'),
          ))
          .go();
    }
  });

  /// Full formal Applied receipt path. The engine validates transport results;
  /// this transaction rechecks the captured identity and immutable request.
  /// Revision-only legacy acknowledgement intentionally cannot create proofs.
  Future<void> acknowledgeApplied(
    DataSpace space,
    FrozenPush frozen,
    Map<String, Object?> receipt, {
    required String clientId,
    required String epoch,
    required bool Function() isCurrent,
  }) => db.atomicWrite(() async {
    if (!isCurrent()) throw StateError('Receipt identity changed');
    final current = await state(space);
    final operation = await _operation(space, frozen.operationId);
    if (current == null ||
        current.status != 'active' ||
        current.clientId != clientId ||
        current.epoch != epoch ||
        operation == null ||
        operation.frozenRequestJson != frozen.body) {
      throw StateError('Receipt frozen identity mismatch');
    }
    if (operation.state == 'discarded') return;
    final request = _object(frozen.body);
    final command = syncObject((request['operations'] as List).single);
    if (request['protocol_version'] != 1 ||
        request['client_id'] != clientId ||
        request['sync_epoch'] != epoch ||
        command['operation_id'] != frozen.operationId ||
        command['entity_id'] != operation.entityId ||
        receipt['status'] != 'applied' ||
        receipt['operation_id'] != frozen.operationId ||
        receipt['entity_id'] != operation.entityId ||
        receipt['replayed'] is! bool) {
      throw const FormatException('Invalid bound Applied receipt');
    }
    final commit = syncIdentifier(receipt['commit_id']);
    final revision = syncRevision(receipt['revision']);
    final vector = syncVector(receipt['scope_revisions']);
    if (vector.isEmpty || vector.length > 1000) {
      throw const FormatException('Applied scope vector limit');
    }
    if (operation.entityType == 'bill' &&
        !vector.containsKey(_destinationScope(command))) {
      throw const FormatException('Applied bill scope absent from vector');
    }
    final revoked = (jsonDecode(current.revokedScopesJson) as List)
        .cast<String>();
    if (vector.keys.any(revoked.contains) ||
        _requiredScopes(command).any(revoked.contains)) {
      throw StateError('Applied receipt scope is revoked');
    }
    await _freezeReceiptBindings(space, current, operation, frozen.body, null);
    final binding = syncObject(
      jsonDecode(
        (await repository.readSetting(
          '${receiptBindingsPrefix(space)}${operation.operationId}',
        ))!,
      ),
    );
    final proof = canonicalSyncJson({
      for (final field in [
        'version',
        'space_id',
        'instance_id',
        'user_id',
        'epoch',
        'client_id',
        'operation_id',
        'frozen_hash',
      ])
        field: binding[field],
      'commit_id': commit,
      'revision': revision,
      'scope_revisions': vector,
      'bindings_hash': syncContentHash(binding),
    });
    if (utf8.encode(proof).length > 131072) {
      throw StateError('Applied proof storage limit exceeded');
    }
    final key = '${receiptAckProofPrefix(space)}${operation.operationId}';
    final previous = await repository.readSetting(key);
    if (previous != null && previous != proof) {
      throw StateError('Formal Applied receipt changed');
    }
    await acknowledge(space, operation.operationId, revision);
    await _writeReceiptSidecar(space, key, proof);
    if (!isCurrent()) throw StateError('Receipt identity changed');
  });

  Future<void> acknowledge(
    DataSpace space,
    String operationId,
    String revision,
  ) => db.atomicWrite(() async {
    _revision(revision);
    final operation = await _operation(space, operationId);
    if (operation == null || operation.frozenRequestJson == null) {
      throw StateError('Receipt without a frozen operation');
    }
    if (operation.state == 'applied') {
      if (operation.appliedRevision != revision) {
        throw StateError('Receipt revision changed');
      }
      return;
    }
    // A late response must never resurrect an intent explicitly discarded
    // during conflict resolution or after permission revocation.
    if (operation.state == 'discarded') return;
    final request = _object(operation.frozenRequestJson!);
    final command = (request['operations'] as List).single as Map;
    if (_revision(revision) <= _revision(command['base_revision'] as String)) {
      throw StateError('Receipt must advance the operation base revision');
    }
    await (db.update(db.pendingOperations)..where(
          (t) => t.spaceId.equals(space.id) & t.operationId.equals(operationId),
        ))
        .write(
          PendingOperationsCompanion(
            state: const Value('applied'),
            appliedRevision: Value(revision),
            lastErrorCode: const Value(null),
          ),
        );
    final event = SyncEvent(
      // Creating a book is authorized by the personal scope, but the new
      // entity and all its later revisions belong to its own book scope.
      scopeId: operation.entityType == 'book' && command['action'] == 'create'
          ? operation.entityId
          : _destinationScope(command),
      entityType: operation.entityType,
      entityId: operation.entityId,
      revision: revision,
      deleted: command['action'] == 'delete',
      data: (command['payload'] as Map).cast<String, Object?>(),
    );
    await _writeShadow(space, event, replaceEqual: false);
    final remaining = await _entityOperations(
      space,
      operation.entityType,
      operation.entityId,
    );
    final confirmed = operation.entityType == 'bill'
        ? await _latestPublic(space, operation.entityType, operation.entityId)
        : await _shadow(space, event.scopeId, event.entityType, event.entityId);
    // Only the confirmed revision changes here. The visible local payload may
    // already contain several later edits that have not reached the server.
    await (db.update(db.localEntities)..where(
          (t) =>
              t.spaceId.equals(space.id) &
              t.entityType.equals(operation.entityType) &
              t.entityId.equals(operation.entityId),
        ))
        .write(
          LocalEntitiesCompanion(
            scopeId: remaining.isEmpty
                ? Value(confirmed?.scopeId ?? event.scopeId)
                : const Value.absent(),
            serverRevision: Value(confirmed?.revision ?? revision),
            dataJson: remaining.isEmpty && confirmed != null
                ? Value(confirmed.dataJson)
                : const Value.absent(),
            deleted: remaining.isEmpty && confirmed != null
                ? Value(confirmed.deleted)
                : const Value.absent(),
          ),
        );
    await (db.delete(db.syncConflicts)..where(
          (t) => t.spaceId.equals(space.id) & t.operationId.equals(operationId),
        ))
        .go();
  });

  Future<void> reject(
    DataSpace space,
    String operationId,
    String code, {
    Map<String, Object?>? authorizedServer,
  }) => db.atomicWrite(() async {
    final operation = await _operation(space, operationId);
    if (operation == null ||
        {'applied', 'discarded'}.contains(operation.state)) {
      return;
    }
    if (code == 'entity_deleted') {
      final previous =
          await (db.select(db.syncConflicts)..where(
                (t) =>
                    t.spaceId.equals(space.id) &
                    t.operationId.equals(operationId),
              ))
              .getSingleOrNull();
      if (previous?.code == 'entity_moved') return;
    }
    final command = _object(operation.operationJson);
    final local =
        await (db.select(db.localEntities)..where(
              (t) =>
                  t.spaceId.equals(space.id) &
                  t.entityType.equals(operation.entityType) &
                  t.entityId.equals(operation.entityId),
            ))
            .getSingleOrNull();
    await db
        .into(db.syncConflicts)
        .insertOnConflictUpdate(
          SyncConflictsCompanion.insert(
            spaceId: space.id,
            operationId: operationId,
            scopeId: command['scope_id'] as String,
            code: code,
            baseJson: Value(operation.baseDataJson),
            localJson: local?.dataJson ?? jsonEncode(command['payload']),
            serverJson: Value(
              authorizedServer == null ? null : jsonEncode(authorizedServer),
            ),
            createdAt: DateTime.now().toUtc(),
          ),
        );
    for (final pending in await _entityOperations(
      space,
      operation.entityType,
      operation.entityId,
    )) {
      await (db.update(db.pendingOperations)..where(
            (t) =>
                t.spaceId.equals(space.id) &
                t.operationId.equals(pending.operationId),
          ))
          .write(
            PendingOperationsCompanion(
              state: Value(
                pending.operationId == operationId ? 'rejected' : 'blocked',
              ),
              lastErrorCode: Value(code),
            ),
          );
    }
  });

  Future<void> retryLater(
    DataSpace space,
    String operationId,
    String code,
  ) async {
    await (db.update(db.pendingOperations)..where(
          (t) =>
              t.spaceId.equals(space.id) &
              t.operationId.equals(operationId) &
              t.state.equals('sending'),
        ))
        .write(
          PendingOperationsCompanion(
            state: const Value('retry'),
            lastErrorCode: Value(code),
          ),
        );
  }

  Future<void> _writeShadow(
    DataSpace space,
    SyncEvent event, {
    bool replaceEqual = true,
    String? canonicalEpoch,
  }) async {
    final old = await _shadow(
      space,
      event.scopeId,
      event.entityType,
      event.entityId,
    );
    if (old != null &&
        (_revision(old.revision) > _revision(event.revision) ||
            !replaceEqual && old.revision == event.revision)) {
      return;
    }
    await db
        .into(db.serverShadows)
        .insertOnConflictUpdate(
          ServerShadowsCompanion.insert(
            spaceId: space.id,
            scopeId: event.scopeId,
            entityType: event.entityType,
            entityId: event.entityId,
            revision: event.revision,
            dataJson: event.dataJson,
            deleted: event.deleted,
          ),
        );
    if (event.entityType == 'bill' && event.scopeId != space.userId) {
      final key = tombstoneProofKey(space, event.scopeId, event.entityId);
      if (canonicalEpoch != null && event.deleted) {
        await repository.writeSetting(
          key,
          jsonEncode({
            'version': 1,
            'epoch': canonicalEpoch,
            'scope_id': event.scopeId,
            'entity_type': 'bill',
            'entity_id': event.entityId,
            'revision': event.revision,
            'projection_hash': syncContentHash(event.data),
          }),
        );
      } else {
        await (db.delete(db.appSettings)..where((t) => t.key.equals(key))).go();
      }
    }
  }

  /// The caller supplies complete commit groups. All groups on this page are
  /// applied in one local transaction; only the final page advances cursors.
  Future<void> applyPullPage(
    DataSpace space,
    String epoch,
    List<List<SyncEvent>> commits, {
    required bool finalPage,
    Map<String, String>? checkpoint,
  }) => db.atomicWrite(() async {
    final current = await state(space);
    if (current == null ||
        current.epoch != epoch ||
        current.status != 'active') {
      throw StateError('Pull identity changed');
    }
    if (finalPage && checkpoint == null) {
      throw ArgumentError('Missing checkpoint');
    }
    for (final commit in commits) {
      if (commit.isEmpty || commit.length > 200) {
        throw ArgumentError('Invalid commit size');
      }
      for (final event in commit) {
        final old = await _shadow(
          space,
          event.scopeId,
          event.entityType,
          event.entityId,
        );
        if (old != null &&
            _revision(old.revision) > _revision(event.revision)) {
          continue;
        }
        await _writeShadow(space, event, canonicalEpoch: epoch);
        final pending = await _entityOperations(
          space,
          event.entityType,
          event.entityId,
        );
        if (pending.isNotEmpty) {
          if (event.entityType == 'bill' &&
              event.scopeId != space.userId &&
              event.data['projection_kind'] != 'bill_private_finance') {
            for (final operation in pending) {
              final command = _object(operation.operationJson);
              if (_revision(event.revision) <=
                  _revision(command['base_revision'] as String)) {
                continue;
              }
              final moved =
                  !event.deleted &&
                  !_requiredScopes(command).contains(event.scopeId);
              final removed =
                  event.deleted &&
                  command['move'] == null &&
                  command['action'] != 'delete' &&
                  command['scope_id'] == event.scopeId;
              if (moved || removed) {
                await reject(
                  space,
                  operation.operationId,
                  moved ? 'entity_moved' : 'entity_deleted',
                  authorizedServer: event.data,
                );
                break;
              }
            }
          }
          continue;
        }
        // Private finance is a separate projection. It must not replace the
        // public bill fields in the editable local view.
        if (event.data['projection_kind'] == 'bill_private_finance' ||
            (event.entityType == 'bill' && event.scopeId == space.userId)) {
          continue;
        }
        final local =
            await (db.select(db.localEntities)..where(
                  (t) =>
                      t.spaceId.equals(space.id) &
                      t.entityType.equals(event.entityType) &
                      t.entityId.equals(event.entityId),
                ))
                .getSingleOrNull();
        if (local != null) {
          final localRevision = _revision(local.serverRevision);
          final incomingRevision = _revision(event.revision);
          // Entity revisions are global for one UUID. Scope cursor revisions
          // are independent and must not decide which public entity is newer.
          if (localRevision > incomingRevision) continue;
          if (event.entityType == 'bill' && local.scopeId != event.scopeId) {
            // A source tombstone removes only the source projection. The
            // target may have arrived first in a different scope/page.
            if (event.deleted) continue;
            // Equal-revision live target replaces a source tombstone, while
            // an already installed live public projection stays authoritative.
            if (localRevision == incomingRevision && !local.deleted) continue;
          }
        }
        await db
            .into(db.localEntities)
            .insertOnConflictUpdate(
              LocalEntitiesCompanion.insert(
                spaceId: space.id,
                scopeId: Value(event.scopeId),
                entityType: event.entityType,
                entityId: event.entityId,
                dataJson: event.dataJson,
                serverRevision: Value(event.revision),
                deleted: Value(event.deleted),
                updatedAt: DateTime.now().toUtc(),
              ),
            );
      }
    }
    if (finalPage) {
      final prior = _object(current.cursorsJson);
      final merged = <String, Object?>{...prior};
      for (final entry in checkpoint!.entries) {
        final previous = prior[entry.key] as String? ?? '0';
        if (_revision(entry.value) < _revision(previous)) {
          throw StateError('Checkpoint moved backwards');
        }
        merged[entry.key] = entry.value;
      }
      await (db.update(db.syncStates)..where((t) => t.spaceId.equals(space.id)))
          .write(SyncStatesCompanion(cursorsJson: Value(jsonEncode(merged))));
    }
  });

  Future<List<StoredConflict>> conflicts(DataSpace space) => (db.select(
    db.syncConflicts,
  )..where((t) => t.spaceId.equals(space.id))).get();

  Future<List<RecoveryBackup>> recoveryBackups(DataSpace space) =>
      (db.select(db.syncRecoveryBackups)
            ..where((t) => t.spaceId.equals(space.id))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<void> acceptServerVersion(
    DataSpace space,
    String operationId,
    SyncEvent authorizedCurrent,
  ) => db.atomicWrite(() async {
    final operation = await _operation(space, operationId);
    final command = operation == null ? null : _object(operation.operationJson);
    final known = operation == null
        ? null
        : await _latestPublic(space, operation.entityType, operation.entityId);
    if (operation == null ||
        operation.state != 'rejected' ||
        authorizedCurrent.entityType != operation.entityType ||
        authorizedCurrent.entityId != operation.entityId ||
        (authorizedCurrent.scopeId != command!['scope_id'] &&
            !(operation.entityType == 'bill' &&
                known?.scopeId == authorizedCurrent.scopeId)) ||
        authorizedCurrent.data['projection_kind'] == 'bill_private_finance' ||
        (operation.entityType == 'bill' &&
            authorizedCurrent.scopeId == space.userId)) {
      throw StateError('Conflict identity mismatch');
    }
    for (final pending in await _entityOperations(
      space,
      operation.entityType,
      operation.entityId,
    )) {
      await (db.update(db.pendingOperations)..where(
            (t) =>
                t.spaceId.equals(space.id) &
                t.operationId.equals(pending.operationId),
          ))
          .write(const PendingOperationsCompanion(state: Value('discarded')));
      await (db.delete(db.syncConflicts)..where(
            (t) =>
                t.spaceId.equals(space.id) &
                t.operationId.equals(pending.operationId),
          ))
          .go();
    }
    await applyPullPage(space, (await state(space))!.epoch, [
      [authorizedCurrent],
    ], finalPage: false);
    final confirmed = (operation.entityType == 'bill'
        ? await _latestPublic(space, operation.entityType, operation.entityId)
        : await _shadow(
            space,
            authorizedCurrent.scopeId,
            authorizedCurrent.entityType,
            authorizedCurrent.entityId,
          ))!;
    // Another pull may already have a later confirmed version than the GET
    // used by the confirmation dialog. Show that version, never stale intent.
    await _installConfirmed(space, confirmed);
  });

  /// Reviewable copies of records differing from the restored server. This
  /// comparison never submits old records as new financial transactions.
  Future<List<Map<String, Object?>>> recoveryDifferences(
    DataSpace space,
    RecoveryBackup backup,
  ) async {
    if (backup.spaceId != space.id) throw StateError('Backup space mismatch');
    final saved = _object(backup.dataJson);
    final result = <Map<String, Object?>>[];
    for (final raw in saved['entities'] as List) {
      final row = syncObject(raw);
      final local = _object(row['dataJson'] as String);
      final current = await _shadow(
        space,
        row['scopeId'] as String,
        row['entityType'] as String,
        row['entityId'] as String,
      );
      final server = current == null ? null : _object(current.dataJson);
      Object? payload(Map<String, Object?>? data) =>
          data == null ? null : data['payload'] ?? data;
      if (current != null &&
          current.deleted == row['deleted'] &&
          canonicalSyncJson(payload(local)) ==
              canonicalSyncJson(payload(server))) {
        continue;
      }
      result.add({
        'entity_type': row['entityType'],
        'entity_id': row['entityId'],
        'scope_id': row['scopeId'],
        'difference': current == null
            ? 'missing'
            : current.deleted
            ? 'deleted'
            : 'changed',
        'local_revision': row['serverRevision'],
        'local_deleted': row['deleted'],
        'local': local,
        'server': server,
      });
    }
    for (final raw in saved['shadows'] as List) {
      final row = syncObject(raw);
      final local = _object(row['dataJson'] as String);
      final accountBalance =
          row['entityType'] == 'account' && local.containsKey('balance');
      final privateFinance = local['projection_kind'] == 'bill_private_finance';
      if (!accountBalance && !privateFinance) continue;
      final current = await _shadow(
        space,
        row['scopeId'] as String,
        row['entityType'] as String,
        row['entityId'] as String,
      );
      final server = current == null ? null : _object(current.dataJson);
      final equal =
          current != null &&
          current.deleted == row['deleted'] &&
          canonicalSyncJson(accountBalance ? local['balance'] : local) ==
              canonicalSyncJson(
                accountBalance
                    ? (server == null ? null : server['balance'])
                    : server,
              );
      if (equal) continue;
      final existing = result
          .where(
            (item) =>
                item['scope_id'] == row['scopeId'] &&
                item['entity_type'] == row['entityType'] &&
                item['entity_id'] == row['entityId'],
          )
          .firstOrNull;
      if (existing != null) {
        existing['local_confirmed'] = local;
        existing['server_confirmed'] = server;
      } else {
        result.add({
          'entity_type': row['entityType'],
          'entity_id': row['entityId'],
          'scope_id': row['scopeId'],
          'difference': current == null
              ? 'missing'
              : current.deleted
              ? 'deleted'
              : 'changed',
          'local_revision': row['revision'],
          'local_deleted': row['deleted'],
          'local': local,
          'server': server,
        });
      }
    }
    return result;
  }

  /// Explicit user resolution creates a new operation. Previously frozen
  /// requests remain unchanged and cannot be reused with another body.
  Future<void> resolveWithNewCommand(
    DataSpace space,
    String conflictedId,
    QueuedCommand replacement,
  ) => db.atomicWrite(() async {
    final old = await _operation(space, conflictedId);
    if (old == null ||
        old.state != 'rejected' ||
        replacement.operationId == conflictedId ||
        replacement.entityType != old.entityType ||
        replacement.entityId != old.entityId) {
      throw StateError('Invalid conflict resolution');
    }
    final command = _object(old.operationJson);
    if (replacement.scopeId != command['scope_id'] ||
        await _operation(space, replacement.operationId) != null) {
      throw StateError(
        'Resolution must use this scope and a fresh operation ID',
      );
    }
    final chain = await _entityOperations(space, old.entityType, old.entityId);
    final scopes = <Object?>{};
    var hasMove = replacement.move != null;
    for (final pending in chain) {
      final intent = _object(pending.operationJson);
      scopes.add(intent['scope_id']);
      hasMove = hasMove || intent['move'] != null;
    }
    if (hasMove || scopes.length > 1) {
      throw StateError('账本移动需要重新预览，不能将整条移动链改为普通更新。');
    }
    for (final pending in chain) {
      await (db.update(db.pendingOperations)..where(
            (t) =>
                t.spaceId.equals(space.id) &
                t.operationId.equals(pending.operationId),
          ))
          .write(const PendingOperationsCompanion(state: Value('discarded')));
      await (db.delete(db.syncConflicts)..where(
            (t) =>
                t.spaceId.equals(space.id) &
                t.operationId.equals(pending.operationId),
          ))
          .go();
    }
    await repository.saveEntityAndQueue(space, replacement);
  });

  /// Revocation removes server-controlled cache and quarantines unsent input.
  /// It does not claim to erase material already exported by a person.
  Future<void> revokeScope(
    DataSpace space,
    String scopeId,
  ) => db.atomicWrite(() async {
    await invalidateReceiptEvidenceForScope(space, scopeId);
    // Asset entry caches may include bodies from several shared books. Drop
    // the whole controlled read set, and invalidate already in-flight reads.
    // Frozen user configuration commands live under a different prefix.
    final assetReadNonceKey = 'assets.read.invalidate.v1.${space.id}';
    final priorNonce = await repository.readSetting(assetReadNonceKey);
    await repository.writeSetting(
      assetReadNonceKey,
      ((BigInt.tryParse(priorNonce ?? '') ?? BigInt.zero) + BigInt.one)
          .toString(),
    );
    await (db.delete(
      db.appSettings,
    )..where((t) => t.key.like('assets.read.v1.${space.id}.%'))).go();
    await (db.delete(
          db.appSettings,
        )..where((t) => t.key.like('${tombstoneProofPrefix(space)}$scopeId.%')))
        .go();
    await db.customStatement(
      "UPDATE pending_operations SET base_data_json = NULL WHERE space_id = ? AND (json_extract(operation_json, '\$.scope_id') = ? OR json_extract(operation_json, '\$.move.target_scope_id') = ?)",
      [space.id, scopeId, scopeId],
    );
    // Staged pages are server-controlled cache and may contain several
    // scopes. Discard this resumable staging set after any revocation.
    await (db.delete(
      db.snapshotPages,
    )..where((t) => t.spaceId.equals(space.id))).go();
    for (final conflict in await conflicts(space)) {
      final ownScope = conflict.scopeId == scopeId;
      final clearServer =
          ownScope || _cachedScopeReference(conflict.serverJson, scopeId);
      final clearBase =
          ownScope || _cachedScopeReference(conflict.baseJson, scopeId);
      if (!clearServer && !clearBase) continue;
      await (db.update(db.syncConflicts)..where(
            (t) =>
                t.spaceId.equals(space.id) &
                t.operationId.equals(conflict.operationId),
          ))
          .write(
            SyncConflictsCompanion(
              serverJson: clearServer
                  ? const Value(null)
                  : const Value.absent(),
              baseJson: clearBase ? const Value(null) : const Value.absent(),
              code: ownScope
                  ? const Value('scope_revoked')
                  : const Value.absent(),
            ),
          );
    }
    final pending = await repository.pending(space);
    final affected = <(String, String)>{
      for (final operation in pending)
        if (_requiredScopes(_object(operation.operationJson)).contains(scopeId))
          (operation.entityType, operation.entityId),
    };
    for (final operation in pending) {
      final body = _object(operation.operationJson);
      if (!affected.contains((operation.entityType, operation.entityId))) {
        continue;
      }
      final local =
          await (db.select(db.localEntities)..where(
                (t) =>
                    t.spaceId.equals(space.id) &
                    t.entityType.equals(operation.entityType) &
                    t.entityId.equals(operation.entityId),
              ))
              .getSingleOrNull();
      await db
          .into(db.syncConflicts)
          .insertOnConflictUpdate(
            SyncConflictsCompanion.insert(
              spaceId: space.id,
              operationId: operation.operationId,
              scopeId: scopeId,
              code: 'scope_revoked',
              localJson: local?.dataJson ?? jsonEncode(body['payload']),
              createdAt: DateTime.now().toUtc(),
            ),
          );
      await (db.update(db.pendingOperations)..where(
            (t) =>
                t.spaceId.equals(space.id) &
                t.operationId.equals(operation.operationId),
          ))
          .write(
            const PendingOperationsCompanion(
              state: Value('discarded'),
              lastErrorCode: Value('scope_revoked'),
              baseDataJson: Value(null),
            ),
          );
    }
    await (db.delete(
          db.localEntities,
        )..where((t) => t.spaceId.equals(space.id) & t.scopeId.equals(scopeId)))
        .go();
    await (db.delete(
          db.serverShadows,
        )..where((t) => t.spaceId.equals(space.id) & t.scopeId.equals(scopeId)))
        .go();
    final current = await state(space);
    if (current != null) {
      final cursors = _object(current.cursorsJson)..remove(scopeId);
      final revoked =
          (jsonDecode(current.revokedScopesJson) as List).cast<String>().toSet()
            ..add(scopeId);
      await (db.update(
        db.syncStates,
      )..where((t) => t.spaceId.equals(space.id))).write(
        SyncStatesCompanion(
          cursorsJson: Value(jsonEncode(cursors)),
          revokedScopesJson: Value(jsonEncode(revoked.toList()..sort())),
        ),
      );
    }
    for (final entity in affected) {
      final confirmed = await _latestPublic(space, entity.$1, entity.$2);
      if (confirmed != null) {
        await _installConfirmed(space, confirmed);
      } else {
        await (db.delete(db.localEntities)..where(
              (t) =>
                  t.spaceId.equals(space.id) &
                  t.entityType.equals(entity.$1) &
                  t.entityId.equals(entity.$2),
            ))
            .go();
      }
    }
  });

  /// All groups share one permission vector. Drop their controlled cache on
  /// any authorization change, keeping original outbox and local user input.
  Future<void> clearGroupCache(DataSpace space) => db.atomicWrite(() async {
    await (db.delete(
      db.groupPages,
    )..where((t) => t.spaceId.equals(space.id))).go();
    await (db.delete(
      db.groupReceipts,
    )..where((t) => t.spaceId.equals(space.id))).go();
    await (db.delete(
      db.groupPulls,
    )..where((t) => t.spaceId.equals(space.id))).go();
  });

  /// Called only after an authenticated current-scope response. Old rejected
  /// input stays quarantined even if a fresh invitation grants access again.
  Future<void> restoreScopeAccess(DataSpace space, Set<String> scopes) =>
      db.atomicWrite(() async {
        final current = await state(space);
        if (current == null) return;
        final revoked = (jsonDecode(current.revokedScopesJson) as List)
            .cast<String>()
            .where((id) => !scopes.contains(id))
            .toList();
        await (db.update(
          db.syncStates,
        )..where((t) => t.spaceId.equals(space.id))).write(
          SyncStatesCompanion(revokedScopesJson: Value(jsonEncode(revoked))),
        );
      });

  Future<void> requireRebuild(DataSpace space, String reason) => db.atomicWrite(
    () async {
      final current = await state(space);
      if (current == null) throw StateError('Missing sync state');
      if (current.status != 'recovery_required') {
        await _backup(space, current, reason);
      }
      await (db.update(db.syncStates)..where((t) => t.spaceId.equals(space.id)))
          .write(const SyncStatesCompanion(status: Value('recovery_required')));
    },
  );

  Future<void> stageSnapshotPage(
    DataSpace space,
    SnapshotManifest manifest,
    int index,
    List<Object?> items,
    String hash,
  ) => db.atomicWrite(() async {
    manifest.checkIdentity(space.serverInstanceId, manifest.epoch);
    manifest.checkPage(index, items, hash);
    await db
        .into(db.snapshotPages)
        .insertOnConflictUpdate(
          SnapshotPagesCompanion.insert(
            spaceId: space.id,
            snapshotId: manifest.id,
            pageIndex: index,
            itemsJson: canonicalSyncJson(items),
            sha256: hash,
          ),
        );
  });

  /// The caller rechecks live permission versions immediately before install.
  /// Recovery is an explicit user action, uses a new authenticated client ID,
  /// and never replays the old operation IDs against a restored server.
  Future<void> installSnapshot(
    DataSpace space,
    SnapshotManifest manifest, {
    required String clientId,
    required Map<String, String> permissionVersions,
    bool allowRecovery = false,
  }) => db.atomicWrite(() async {
    manifest.checkIdentity(space.serverInstanceId, manifest.epoch);
    if (canonicalSyncJson(permissionVersions) !=
        canonicalSyncJson(manifest.permissionVersions)) {
      throw StateError('Snapshot permissions changed');
    }
    final current = await state(space);
    if (current == null) throw StateError('Missing sync state');
    final recovery = current.status == 'recovery_required';
    if (recovery && (!allowRecovery || clientId == current.clientId)) {
      throw StateError(
        'Explicit recovery and a new client identity are required',
      );
    }
    if (!recovery &&
        (current.epoch != manifest.epoch || current.clientId != clientId)) {
      throw StateError('Snapshot sync identity mismatch');
    }
    final staged =
        await (db.select(db.snapshotPages)
              ..where(
                (t) =>
                    t.spaceId.equals(space.id) &
                    t.snapshotId.equals(manifest.id),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.pageIndex)]))
            .get();
    if (staged.length != manifest.pages.length) {
      throw StateError('Snapshot is incomplete');
    }
    final events = <SyncEvent>[];
    final seen = <String>{};
    for (var i = 0; i < staged.length; i++) {
      final page = staged[i];
      if (page.pageIndex != i) throw StateError('Snapshot page order changed');
      final checked = manifest.checkPage(
        i,
        jsonDecode(page.itemsJson) as List,
        page.sha256,
      );
      for (final event in checked) {
        if (!seen.add(
          '${event.scopeId}/${event.entityType}/${event.entityId}',
        )) {
          throw StateError('Duplicate snapshot entity');
        }
      }
      events.addAll(checked);
    }
    final pending = await repository.pending(space);
    final localBookScopes = <String>{};
    if (!recovery) {
      for (final operation in pending) {
        final command = _object(operation.operationJson);
        if (operation.entityType == 'book' &&
            command['action'] == 'create' &&
            command['scope_id'] == space.userId &&
            {'queued', 'sending', 'retry'}.contains(operation.state)) {
          localBookScopes.add(operation.entityId);
        }
      }
    }
    if (recovery) {
      // The full backup was committed before entering this mode. Preserve all
      // old intents in that backup and the operation journal without replay.
      await (db.update(db.pendingOperations)
            ..where((t) => t.spaceId.equals(space.id)))
          .write(const PendingOperationsCompanion(state: Value('discarded')));
      await (db.delete(db.appSettings)..where(
            (t) =>
                t.key.like('${receiptBindingsPrefix(space)}%') |
                t.key.like('${receiptAckProofPrefix(space)}%'),
          ))
          .go();
    }
    await (db.delete(
      db.serverShadows,
    )..where((t) => t.spaceId.equals(space.id))).go();
    await (db.delete(
      db.localEntities,
    )..where((t) => t.spaceId.equals(space.id))).go();
    await (db.delete(
      db.appSettings,
    )..where((t) => t.key.like('${tombstoneProofPrefix(space)}%'))).go();
    for (final event in events) {
      await _writeShadow(space, event, canonicalEpoch: manifest.epoch);
      if (event.data['projection_kind'] == 'bill_private_finance' ||
          (event.entityType == 'bill' && event.scopeId == space.userId)) {
        continue;
      }
      await db
          .into(db.localEntities)
          .insertOnConflictUpdate(
            LocalEntitiesCompanion.insert(
              spaceId: space.id,
              scopeId: Value(event.scopeId),
              entityType: event.entityType,
              entityId: event.entityId,
              dataJson: event.dataJson,
              serverRevision: Value(event.revision),
              deleted: Value(event.deleted),
              updatedAt: DateTime.now().toUtc(),
            ),
          );
    }
    if (!recovery) {
      // Preserve local intent over the newly confirmed shadow; a subsequent
      // stale revision becomes a visible conflict rather than silent rebasing.
      for (final operation in pending) {
        final command = _object(operation.operationJson);
        final scope = _destinationScope(command);
        if (_requiredScopes(command).any(
          (required) =>
              !manifest.checkpoint.containsKey(required) &&
              !localBookScopes.contains(required),
        )) {
          throw StateError('Pending scope absent from complete snapshot');
        }
        await db
            .into(db.localEntities)
            .insertOnConflictUpdate(
              LocalEntitiesCompanion.insert(
                spaceId: space.id,
                scopeId: Value(scope),
                entityType: operation.entityType,
                entityId: operation.entityId,
                dataJson: jsonEncode(command['payload']),
                serverRevision: Value(command['base_revision'] as String),
                deleted: Value(command['action'] == 'delete'),
                updatedAt: DateTime.now().toUtc(),
              ),
            );
      }
      final checked = <(String, String)>{};
      for (final operation in pending) {
        if (operation.entityType != 'bill' ||
            !checked.add((operation.entityType, operation.entityId))) {
          continue;
        }
        final canonical = await _latestPublic(
          space,
          operation.entityType,
          operation.entityId,
        );
        final command = _object(operation.operationJson);
        if (canonical != null &&
            !canonical.deleted &&
            !_requiredScopes(command).contains(canonical.scopeId)) {
          await reject(
            space,
            operation.operationId,
            'entity_moved',
            authorizedServer: _object(canonical.dataJson),
          );
        }
      }
    }
    await (db.update(
      db.syncStates,
    )..where((t) => t.spaceId.equals(space.id))).write(
      SyncStatesCompanion(
        clientId: Value(clientId),
        epoch: Value(manifest.epoch),
        status: const Value('active'),
        cursorsJson: Value(canonicalSyncJson(manifest.checkpoint)),
      ),
    );
    await (db.delete(
      db.snapshotPages,
    )..where((t) => t.spaceId.equals(space.id))).go();
    await clearGroupCache(space);
  });

  Future<void> _backup(
    DataSpace space,
    SpaceSyncState current,
    String reason,
  ) async {
    // Includes acknowledged entities and shadows, not only the outbox. This
    // is required when the server restores a backup predating an acknowledged
    // local bill. The original working data is never cleared here.
    final entities = await (db.select(
      db.localEntities,
    )..where((t) => t.spaceId.equals(space.id))).get();
    final shadows = await (db.select(
      db.serverShadows,
    )..where((t) => t.spaceId.equals(space.id))).get();
    final operations = await (db.select(
      db.pendingOperations,
    )..where((t) => t.spaceId.equals(space.id))).get();
    final drafts = await repository.drafts(space);
    final unresolved = await conflicts(space);
    final attachmentQueue = await (db.select(
      db.appSettings,
    )..where((t) => t.key.like('attachments.v1.${space.id}.queue.%'))).get();
    final ledgerPostings = await (db.select(
      db.appSettings,
    )..where((t) => t.key.like('ledger.postings.v1.${space.id}.%'))).get();
    final tombstoneProofs = await (db.select(
      db.appSettings,
    )..where((t) => t.key.like('${tombstoneProofPrefix(space)}%'))).get();
    final receiptEvidence =
        await (db.select(db.appSettings)..where(
              (t) =>
                  t.key.like('${receiptBindingsPrefix(space)}%') |
                  t.key.like('${receiptAckProofPrefix(space)}%'),
            ))
            .get();
    final assetConfiguration =
        await (db.select(db.appSettings)..where(
              (t) =>
                  t.key.like('assets.config.v1.${space.id}.%') |
                  t.key.like('assets.outbox.v1.${space.id}.%'),
            ))
            .get();
    final assetReadCache = await (db.select(
      db.appSettings,
    )..where((t) => t.key.like('assets.read.v1.${space.id}.%'))).get();
    final dataTools =
        await (db.select(db.appSettings)..where(
              (row) =>
                  row.key.like('data_tools.v1.${space.id}.batch.%') |
                  row.key.like('data_tools.local_refresh.v1.${space.id}.%'),
            ))
            .get();
    final stageSources = await (db.select(
      db.stageImportSources,
    )..where((row) => row.spaceId.equals(space.id))).get();
    final stageCommands = await (db.select(
      db.stageImportCommands,
    )..where((row) => row.spaceId.equals(space.id))).get();
    final stageChunkDescriptors = await db
        .customSelect(
          'SELECT stage_id, chunk_index, sha256, size_bytes, receipt_json '
          'FROM stage_import_chunks WHERE space_id = ? '
          'ORDER BY stage_id, chunk_index',
          variables: [Variable(space.id)],
          readsFrom: {db.stageImportChunks},
        )
        .get();
    final backupId = _uuid.v4();
    await db
        .into(db.syncRecoveryBackups)
        .insert(
          SyncRecoveryBackupsCompanion.insert(
            id: backupId,
            spaceId: space.id,
            reason: reason,
            oldEpoch: current.epoch,
            dataJson: jsonEncode({
              'version': 1,
              'space_id': space.id,
              'server_instance_id': space.serverInstanceId,
              'user_id': space.userId,
              'sync_state': current.toJson(),
              'entities': entities.map((e) => e.toJson()).toList(),
              'shadows': shadows.map((e) => e.toJson()).toList(),
              'operations': operations.map((e) => e.toJson()).toList(),
              'drafts': drafts.map((e) => e.toJson()).toList(),
              'conflicts': unresolved.map((e) => e.toJson()).toList(),
              'attachment_queue': attachmentQueue
                  .map((e) => e.toJson())
                  .toList(),
              'ledger_postings': ledgerPostings.map((e) => e.toJson()).toList(),
              'tombstone_proofs': tombstoneProofs
                  .map((e) => e.toJson())
                  .toList(),
              'receipt_evidence': receiptEvidence
                  .map((e) => e.toJson())
                  .toList(),
              'asset_configuration': assetConfiguration
                  .map((e) => e.toJson())
                  .toList(),
              'asset_read_cache': assetReadCache
                  .map((e) => e.toJson())
                  .toList(),
              // Evidence from the original epoch/client, never an instruction
              // to replay imports or adopt blobs under a replacement identity.
              'data_tools': dataTools.map((row) => row.toJson()).toList(),
              'stage_imports': {
                'sources': stageSources.map((row) => row.toJson()).toList(),
                'commands': stageCommands.map((row) => row.toJson()).toList(),
                'chunks': stageChunkDescriptors.map((row) => row.data).toList(),
                'chunk_backup_id': backupId,
              },
            }),
            createdAt: DateTime.now().toUtc(),
          ),
        );
    // SQLite copies BLOBs without allocating the entire source in Dart or JSON.
    // This joins the same outer backup transaction; failure preserves the
    // original source and rolls back the checkpoint and all copied bytes.
    await db.customStatement(
      'INSERT INTO stage_import_recovery_chunks '
      '(backup_id, stage_id, chunk_index, body, sha256, size_bytes) '
      'SELECT ?, stage_id, chunk_index, body, sha256, size_bytes '
      'FROM stage_import_chunks WHERE space_id = ?',
      [backupId, space.id],
    );
  }
}
