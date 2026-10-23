import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/money/money.dart';
import '../ledger/ledger_projection.dart' show normalizeLedgerPayload;
import '../ledger/ledger_repository.dart';
import '../local/app_database.dart';
import '../sync/snapshot_protocol.dart';
import 'receipt_preview.dart';
import 'receipt_read_repository.dart';

final class ReceiptCreateResult {
  const ReceiptCreateResult({
    required this.entityId,
    required this.operationId,
    required this.alreadySaved,
  });

  final String entityId, operationId;

  /// Finds the original local create; it does not reconfirm its allocations.
  final bool alreadySaved;
}

/// Confirms one new receipt in one local transaction using existing ledger I/O.
/// This does not implement receipt editing, lifecycle commands or remote batches.
final class ReceiptCommandRepository {
  ReceiptCommandRepository({required this.reader, required this.ledger}) {
    if (!identical(reader.repository.database, ledger.repository.database)) {
      throw ArgumentError('回款读取和写入必须使用同一个本地数据库。');
    }
  }

  final ReceiptReadRepository reader;
  final LedgerRepository ledger;
  AppDatabase get _db => ledger.repository.database;

  Future<ReceiptCreateResult> create(
    ReceiptReadLease lease, {
    required ReceiptPreview preview,
    required String entityId,
    required String receiptScopeId,
    required Map<String, Object?> payload,
  }) async {
    syncIdentifier(entityId);
    syncIdentifier(receiptScopeId);
    // Capture caller-owned mutable maps before any await. Exact JSON excludes
    // floating point money and unsupported values without mutating the input.
    final frozen = syncObject(jsonDecode(canonicalSyncJson(payload)));
    _checkLease(lease);
    final result = await _db.atomicWrite(() async {
      _checkLease(lease);
      _checkPayload(preview, receiptScopeId, frozen);
      if (preview.allocations.any((allocation) {
        final source = allocation.source;
        return source.spaceId != lease.space.id ||
            source.instanceId != lease.space.serverInstanceId ||
            source.userId != lease.space.userId ||
            source.clientId != lease.clientId ||
            source.epoch != lease.epoch;
      })) {
        throw const DomainError('receipt.preview_changed');
      }
      await _requireContext(lease, {
        receiptScopeId,
        for (final allocation in preview.allocations) allocation.source.scopeId,
      });
      final entities =
          await (_db.select(_db.localEntities)..where(
                (row) =>
                    row.spaceId.equals(lease.space.id) &
                    row.entityId.equals(entityId),
              ))
              .get();
      final operations =
          await (_db.select(_db.pendingOperations)
                ..where(
                  (row) =>
                      row.spaceId.equals(lease.space.id) &
                      row.entityId.equals(entityId),
                )
                ..orderBy([(row) => OrderingTerm.asc(row.sequence)]))
              .get();
      final shadows =
          await (_db.select(_db.serverShadows)..where(
                (row) =>
                    row.spaceId.equals(lease.space.id) &
                    row.entityId.equals(entityId),
              ))
              .get();
      _checkLease(lease);
      if (entities.isNotEmpty || operations.isNotEmpty || shadows.isNotEmpty) {
        return _recoverExisting(
          lease,
          preview,
          receiptScopeId,
          entityId,
          frozen,
          entities,
          operations,
        );
      }

      final selections = <ReceiptPreviewSelection>[];
      for (final allocation in preview.allocations) {
        final query = ReceiptSourceQuery(
          scopeId: allocation.source.scopeId,
          sourceId: allocation.source.sourceId,
        );
        final read = await reader.read(lease, query);
        _checkLease(lease);
        if (read.hasPending || read.hasConflict) {
          throw const DomainError('receipt.pending_source');
        }
        if (!allocation.source.matchesCurrentRead(lease, query, read)) {
          throw const DomainError('receipt.preview_changed');
        }
        selections.add(
          ReceiptPreviewSelection(
            lease: lease,
            query: query,
            read: read,
            sourceMoney: allocation.sourceMoney,
            receiptMoney: allocation.receiptMoney,
            rate: allocation.rate,
          ),
        );
      }
      final recomputed = ReceiptPreview.create(
        kind: preview.kind,
        receiptMoney: preview.receiptMoney,
        incomeComponent: preview.incomeComponent,
        selections: selections,
      );
      _checkPayload(recomputed, receiptScopeId, frozen);
      final operationId = await ledger.save(
        lease.space,
        entityType: 'bill',
        scopeId: receiptScopeId,
        entityId: entityId,
        baseRevision: '0',
        payload: frozen,
      );
      _checkLease(lease);
      return ReceiptCreateResult(
        entityId: entityId,
        operationId: operationId,
        alreadySaved: false,
      );
    });
    // A generation may change after SQLite has committed but before its future
    // returns. Preserve that old-space write and suppress a late UI success;
    // this check cannot and does not claim to roll an existing commit back.
    _checkLease(lease);
    return result;
  }

  static void _checkLease(ReceiptReadLease lease) {
    if (!lease.space.verified || !lease.isCurrent()) {
      throw const DomainError('receipt.identity_changed');
    }
  }

  static void _checkPayload(
    ReceiptPreview preview,
    String scopeId,
    Map<String, Object?> payload,
  ) {
    if (canonicalSyncJson(normalizeLedgerPayload('bill', payload)) !=
        canonicalSyncJson(payload)) {
      throw const DomainError('receipt.incomplete_payload');
    }
    if (payload['book_id'] != scopeId ||
        payload['bill_type'] != preview.kind.name ||
        canonicalSyncJson(payload['money']) !=
            canonicalSyncJson(preview.receiptMoney.toJson()) ||
        payload['income_component_minor'] !=
            preview.incomeComponent.minor.toString() ||
        canonicalSyncJson(payload['allocations']) !=
            canonicalSyncJson(preview.allocationPayloads)) {
      throw const DomainError('receipt.payload_preview_mismatch');
    }
  }

  Future<void> _requireContext(
    ReceiptReadLease lease,
    Set<String> scopes,
  ) async {
    final state = await (_db.select(
      _db.syncStates,
    )..where((row) => row.spaceId.equals(lease.space.id))).getSingleOrNull();
    _checkLease(lease);
    if (state == null ||
        state.status != 'active' ||
        state.clientId != lease.clientId ||
        state.epoch != lease.epoch) {
      throw const DomainError('receipt.identity_changed');
    }
    try {
      final revoked = (jsonDecode(state.revokedScopesJson) as List)
          .cast<String>();
      if (revoked.contains(lease.space.userId) ||
          scopes.any(revoked.contains)) {
        throw const DomainError('receipt.scope_unavailable');
      }
      final permissionsRaw = await ledger.repository.readSetting(
        'sync.scopes.${lease.space.id}',
      );
      final detailsRaw = await ledger.repository.readSetting(
        'sync.scope-details.${lease.space.id}',
      );
      final permissions = syncVector(jsonDecode(permissionsRaw ?? '{}'));
      final details = syncObject(jsonDecode(detailsRaw ?? '{}'));
      if (details['version'] != 1 ||
          details['epoch'] != state.epoch ||
          details['scopes'] is! List) {
        throw const DomainError('receipt.scope_unavailable');
      }
      for (final id in scopes) {
        final matches = (details['scopes'] as List)
            .whereType<Map>()
            .where((row) => row['scope_id'] == id)
            .toList();
        if (matches.length != 1 || !permissions.containsKey(id)) {
          throw const DomainError('receipt.scope_unavailable');
        }
        final scope = matches.single;
        if (scope['kind'] != 'book' ||
            !{'owner', 'editor'}.contains(scope['role']) ||
            scope['permission_version'] != permissions[id]) {
          throw const DomainError('receipt.scope_unavailable');
        }
      }
    } on DomainError {
      rethrow;
    } on Object {
      throw const DomainError('receipt.scope_unavailable');
    }
    _checkLease(lease);
  }

  Future<ReceiptCreateResult> _recoverExisting(
    ReceiptReadLease lease,
    ReceiptPreview preview,
    String scopeId,
    String entityId,
    Map<String, Object?> payload,
    List<StoredEntity> entities,
    List<StoredOperation> operations,
  ) async {
    if (entities.length != 1 ||
        entities.single.entityType != 'bill' ||
        entities.single.scopeId != scopeId ||
        entities.single.deleted ||
        operations.length != 1) {
      throw const DomainError('receipt.entity_in_use');
    }
    final operation = operations.single;
    if (operation.entityType != 'bill' ||
        !{'queued', 'sending', 'retry', 'applied'}.contains(operation.state)) {
      throw const DomainError('receipt.entity_in_use');
    }
    if (operation.state == 'applied'
        ? operation.appliedRevision == null ||
              entities.single.serverRevision != operation.appliedRevision
        : entities.single.serverRevision != '0') {
      throw const DomainError('receipt.entity_in_use');
    }
    final original = syncObject(jsonDecode(operation.operationJson));
    if (original['action'] != 'create' ||
        original['scope_id'] != scopeId ||
        original['entity_id'] != entityId ||
        original['base_revision'] != '0' ||
        original['move'] != null ||
        canonicalSyncJson(original['payload']) != canonicalSyncJson(payload)) {
      throw const DomainError('receipt.entity_in_use');
    }
    final body = operation.frozenRequestJson;
    if (body != null) {
      final request = syncObject(jsonDecode(body));
      final command = syncObject((request['operations'] as List).single);
      if (request['client_id'] != lease.clientId ||
          request['sync_epoch'] != lease.epoch ||
          command['operation_id'] != operation.operationId ||
          command['scope_id'] != scopeId ||
          command['entity_id'] != entityId ||
          command['action'] != 'create' ||
          canonicalSyncJson(command['payload']) != canonicalSyncJson(payload)) {
        throw const DomainError('receipt.entity_in_use');
      }
    } else if (operation.state == 'applied') {
      throw const DomainError('receipt.entity_in_use');
    }
    final view = await ledger.read(
      lease.space,
      query: const LedgerQuery(includeDeleted: true),
    );
    final existing = view.find('bill', entityId);
    if (existing?.editablePayload == null ||
        canonicalSyncJson(existing!.editablePayload) !=
            canonicalSyncJson(payload)) {
      throw const DomainError('receipt.entity_in_use');
    }
    for (final allocation in preview.allocations) {
      final read = await reader.read(
        lease,
        ReceiptSourceQuery(
          scopeId: allocation.source.scopeId,
          sourceId: allocation.source.sourceId,
        ),
      );
      _checkLease(lease);
      if (read.disposition == ReceiptReadDisposition.unavailable ||
          read.hasConflict ||
          read.intents.any(
            (intent) =>
                intent.operationId != operation.operationId ||
                intent.kind != ReceiptIntentKind.linkedReceipt,
          )) {
        throw const DomainError('receipt.source_unavailable');
      }
    }
    _checkLease(lease);
    return ReceiptCreateResult(
      entityId: entityId,
      operationId: operation.operationId,
      alreadySaved: true,
    );
  }
}
