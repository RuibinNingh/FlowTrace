import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../domain/ledger/postings.dart';
import '../assets/asset_config_store.dart';
import '../local/app_database.dart';
import '../local/local_repository.dart';
import '../sync/snapshot_protocol.dart';
import '../sync/tombstone_proof.dart';
import 'ledger_models.dart';
import 'ledger_projection.dart';
import 'ledger_validation.dart';

export 'ledger_models.dart';

/// A data-space scoped, transactional facade. It never sends network requests.
final class LedgerRepository {
  LedgerRepository(this.repository);
  final LocalRepository repository;
  AppDatabase get _db => repository.database;
  static const _uuid = Uuid();
  static const maxDraftBytes = 1024 * 1024;

  Future<LedgerProjection> _load(DataSpace space) => _db.readSnapshot(() async {
    final entities = await (_db.select(
      _db.localEntities,
    )..where((t) => t.spaceId.equals(space.id))).get();
    final shadows = await (_db.select(
      _db.serverShadows,
    )..where((t) => t.spaceId.equals(space.id))).get();
    final operations =
        await (_db.select(_db.pendingOperations)
              ..where((t) => t.spaceId.equals(space.id))
              ..orderBy([(t) => OrderingTerm.asc(t.sequence)]))
            .get();
    final state = await (_db.select(
      _db.syncStates,
    )..where((t) => t.spaceId.equals(space.id))).getSingleOrNull();
    final settings =
        await (_db.select(_db.appSettings)..where(
              (t) =>
                  t.key.equals('sync.scope-details.${space.id}') |
                  t.key.like('ledger.postings.v1.${space.id}.%') |
                  t.key.like('${tombstoneProofPrefix(space)}%'),
            ))
            .get();
    return LedgerProjection(
      space,
      LedgerRows(
        entities: entities,
        shadows: shadows,
        operations: operations,
        syncState: state,
        settings: {for (final setting in settings) setting.key: setting.value},
      ),
    );
  });

  Future<LedgerView> read(
    DataSpace space, {
    LedgerQuery query = const LedgerQuery(),
  }) async => (await _load(space)).view(query);

  Stream<LedgerView> watch(
    DataSpace space, {
    LedgerQuery query = const LedgerQuery(),
  }) => _db
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
      .asyncMap((_) => read(space, query: query));

  Future<String> save(
    DataSpace space, {
    required String entityType,
    required String scopeId,
    required Map<String, Object?> payload,
    String? entityId,
    String? baseRevision,
    String? dependsOn,
  }) async => (await saveBatch(space, [
    LedgerWrite(
      entityType: entityType,
      scopeId: scopeId,
      payload: payload,
      entityId: entityId,
      baseRevision: baseRevision,
      dependsOn: dependsOn,
    ),
  ])).single;

  Future<void> delete(DataSpace space, LedgerEntity entity) async {
    await saveBatch(space, [
      LedgerWrite(
        entityType: entity.type,
        scopeId: entity.scopeId,
        entityId: entity.id,
        baseRevision: entity.revision,
        payload: const {},
        action: 'delete',
      ),
    ]);
  }

  /// Computes a proposed adjustment after removing the edited bill's original
  /// signed movement. save() independently verifies the amount against its own
  /// write snapshot, so a concurrent balance change requires a fresh preview.
  Future<Money> adjustmentAmount(
    DataSpace space, {
    required String accountId,
    required String targetBalanceMinor,
    String? existingBillId,
  }) => _db.readSnapshot(() async {
    final projection = await _load(space);
    final account = projection.local[accountId];
    if (!projection.writable ||
        account == null ||
        account.deleted ||
        account.entityType != 'account' ||
        !projection.canWrite('account', account.scopeId)) {
      throw const DomainError('account.unavailable');
    }
    final balance = projection.balances()[accountId]?.value;
    if (balance == null) throw const DomainError('balance.unavailable');
    var baseline = balance.minor;
    if (existingBillId != null) {
      final old = projection.fullBill(existingBillId);
      final postings = projection.currentPostings(existingBillId);
      if (old == null ||
          old['bill_type'] != 'balance_adjustment' ||
          postings == null) {
        throw const DomainError('balance.unavailable');
      }
      for (final posting in postings) {
        if (posting.accountId == accountId) baseline -= posting.money.minor;
      }
    }
    final delta = checkedMinor(parseMinor(targetBalanceMinor) - baseline);
    if (delta == BigInt.zero) throw const DomainError('adjustment.no_change');
    return Money(balance.currency, balance.currencyScale, delta.abs());
  });

  /// All local writes and journal entries commit together. Network results are
  /// deliberately per operation; the server does not promise a batch rollback.
  Future<List<String>> saveBatch(
    DataSpace space,
    List<LedgerWrite> writes,
  ) async {
    if (writes.isEmpty || writes.length > 1000) {
      throw const DomainError('ledger.batch_size');
    }
    return _db.atomicWrite(() async {
      final result = <String>[];
      for (final write in writes) {
        result.add(await _save(space, write));
      }
      return result;
    });
  }

  Future<String> _save(DataSpace space, LedgerWrite write) async {
    final projection = await _load(space);
    if (!projection.writable) throw const DomainError('ledger.read_only');
    if (!ledgerEntityTypes.contains(write.entityType)) {
      throw const DomainError('ledger.unsupported_type');
    }
    final id = write.entityId ?? _uuid.v4();
    syncIdentifier(id);
    final existing = projection.local[id];
    if (existing != null && existing.entityType != write.entityType) {
      throw const DomainError('ledger.id_in_use');
    }
    final action = write.action ?? (existing == null ? 'create' : 'update');
    if (!{'create', 'update', 'delete'}.contains(action) ||
        (action == 'create') != (existing == null) ||
        existing?.deleted == true) {
      throw const DomainError('ledger.invalid_action');
    }
    // A newly created book is first queued in user scope; every later edit is
    // addressed to the new book's own scope, even before that create is ACKed.
    final scope = write.entityType == 'book' && existing != null
        ? id
        : write.scopeId;
    syncIdentifier(scope);
    if (!projection.canWrite(write.entityType, scope) ||
        existing != null &&
            existing.entityType != 'book' &&
            existing.scopeId != scope ||
        action == 'create' &&
            write.entityType == 'book' &&
            scope != space.userId) {
      throw const DomainError('scope.readonly');
    }
    if (projection
        .operations(id)
        .any((op) => {'rejected', 'blocked'}.contains(op.state))) {
      throw const DomainError('ledger.conflicted');
    }
    final input = write.payload;
    if (action == 'delete' && input.isNotEmpty) {
      throw const DomainError('ledger.delete_payload');
    }
    final previous = projection.payloads[id];
    var payload = <String, Object?>{};
    if (action != 'delete') {
      payload = normalizeLedgerPayload(write.entityType, input);
      // Preserve new management fields that an older form did not submit.
      final additions = switch (write.entityType) {
        'book' => {
          'template',
          'icon',
          'cover_color',
          'show_assets',
          'display_mode',
        },
        'category' => {'archived'},
        'tag' => {'kind', 'group_id', 'archived', 'sort_order'},
        'account' => assetAccountOptionalFields,
        'bill' => {'transfer_fx'},
        _ => <String>{},
      };
      for (final key in additions) {
        if (!input.containsKey(key) && previous?.containsKey(key) == true) {
          payload[key] = previous![key];
        }
      }
      // Old complete forms may omit tracking. Preserve its exact presence only
      // while both versions are expenses; never default legacy rows or inherit
      // the field into a different bill type.
      if (write.entityType == 'bill' &&
          previous?['bill_type'] == 'expense' &&
          payload['bill_type'] == 'expense' &&
          !input.containsKey('reimbursement_tracking') &&
          previous!.containsKey('reimbursement_tracking')) {
        payload['reimbursement_tracking'] = previous['reimbursement_tracking'];
      }
    }
    final ops = projection.operations(id);
    if (action != 'delete' &&
        existing != null &&
        canonicalSyncJson(payload) == canonicalSyncJson(previous)) {
      if (ops.isNotEmpty) return ops.last.operationId;
    }
    if (write.baseRevision != null &&
        existing != null &&
        write.baseRevision != existing.serverRevision) {
      throw const DomainError('ledger.local_revision_changed');
    }
    validateLedgerWrite(
      projection,
      write.entityType,
      id,
      scope,
      action,
      payload,
    );
    if (write.entityType == 'account' && payload['group_id'] is String) {
      await AssetConfigStore(
        repository,
      ).requireConfirmedGroup(space, payload['group_id'] as String);
    }

    List<FinancialPosting>? before, after;
    if (write.entityType == 'bill' &&
        payload['preserve_hidden_financial_links'] != true) {
      before = existing == null ? [] : projection.currentPostings(id);
      if (before == null) throw const DomainError('balance.unavailable');
      final balances = projection.balances();
      if (action == 'delete') {
        after = [];
      } else {
        final base = <String, BigInt>{};
        for (final entry in balances.entries) {
          if (entry.value.value != null) {
            base[entry.key] = entry.value.value!.minor;
          }
        }
        for (final posting in before) {
          if (base.containsKey(posting.accountId)) {
            base[posting.accountId] =
                base[posting.accountId]! - posting.money.minor;
          }
        }
        after = editedFinancialPostings(
          payload,
          previousBill: existing == null ? null : projection.fullBill(id),
          previousPostings: before,
          balances: base,
        );
      }
      final deltas = <String, BigInt>{};
      for (final entry in before) {
        deltas.update(
          entry.accountId,
          (sum) => sum - entry.money.minor,
          ifAbsent: () => -entry.money.minor,
        );
      }
      for (final entry in after) {
        deltas.update(
          entry.accountId,
          (sum) => sum + entry.money.minor,
          ifAbsent: () => entry.money.minor,
        );
      }
      for (final entry in deltas.entries) {
        final current = balances[entry.key]?.value;
        if (current != null) checkedMinor(current.minor + entry.value);
      }
    }
    String? dependency = write.dependsOn;
    // Same-entity predecessors are maintained by LocalRepository. Otherwise
    // select the latest already queued referenced definition as a dependency.
    final ownPending = ops.where(
      (op) => mutableIntentStates.contains(op.state),
    );
    if (ownPending.isNotEmpty) {
      dependency = ownPending.last.operationId;
    } else if (dependency == null) {
      final references = <String>{
        scope,
        if (payload['parent_id'] is String) payload['parent_id'] as String,
        if (write.entityType != 'account' && payload['group_id'] is String)
          payload['group_id'] as String,
        ...accountIds(payload),
        if (payload['category_id'] is String) payload['category_id'] as String,
        ...(payload['tag_ids'] as List? ?? []).cast<String>(),
        for (final allocation in payload['allocations'] as List? ?? [])
          ledgerObject(allocation)['source_bill_id'] as String,
      };
      final candidates = projection.rows.operations.where(
        (op) =>
            references.contains(op.entityId) &&
            mutableIntentStates.contains(op.state),
      );
      if (candidates.isNotEmpty) dependency = candidates.last.operationId;
    }
    final operation = _uuid.v4();
    await repository.saveEntityAndQueue(
      space,
      QueuedCommand(
        operationId: operation,
        scopeId: scope,
        entityType: write.entityType,
        entityId: id,
        action: action,
        baseRevision: existing?.serverRevision ?? '0',
        dependsOn: dependency,
        payload: payload,
      ),
    );
    if (before != null && after != null) {
      await repository.writeSetting(
        'ledger.postings.v1.${space.id}.$operation',
        jsonEncode({
          'version': 1,
          'bill_id': id,
          'fingerprint': financialFingerprint(payload),
          'old_entries': before.map(postingJson).toList(),
          'new_entries': after.map(postingJson).toList(),
        }),
      );
    }
    return operation;
  }

  Future<String> copyBookConfiguration(
    DataSpace space,
    String sourceBookId, {
    required String name,
  }) async => _db.atomicWrite(() async {
    final projection = await _load(space);
    final source = projection.local[sourceBookId];
    if (source == null || source.entityType != 'book' || source.deleted) {
      throw const DomainError('book.unavailable');
    }
    final bookId = _uuid.v4();
    final definitions = projection.local.values
        .where(
          (row) =>
              !row.deleted &&
              row.scopeId == sourceBookId &&
              {'category', 'tag'}.contains(row.entityType),
        )
        .toList();
    final ids = {for (final row in definitions) row.entityId: _uuid.v4()};
    definitions.sort((a, b) {
      int depth(StoredEntity row) =>
          projection.payloads[row.entityId]!['parent_id'] != null ||
              projection.payloads[row.entityId]!['group_id'] != null
          ? 1
          : 0;
      return depth(a).compareTo(depth(b));
    });
    final writes = [
      LedgerWrite(
        entityType: 'book',
        scopeId: space.userId,
        entityId: bookId,
        payload: {...projection.payloads[sourceBookId]!, 'name': name},
      ),
    ];
    for (final row in definitions) {
      final payload = ledgerCopy(projection.payloads[row.entityId]!);
      for (final field in ['parent_id', 'group_id']) {
        if (payload[field] != null) {
          if (!ids.containsKey(payload[field])) {
            throw const DomainError('configuration.reference_unavailable');
          }
          payload[field] = ids[payload[field]];
        }
      }
      writes.add(
        LedgerWrite(
          entityType: row.entityType,
          scopeId: bookId,
          entityId: ids[row.entityId],
          payload: payload,
        ),
      );
    }
    await saveBatch(space, writes);
    return bookId;
  });

  Future<String> saveDraft(
    DataSpace space, {
    required String? bookId,
    required Map<String, Object?> payload,
    Map<String, Object?> ui = const {},
    String? draftId,
  }) async {
    if (bookId != null) syncIdentifier(bookId);
    final id = draftId ?? _uuid.v4();
    syncIdentifier(id);
    final body = jsonEncode({
      'kind': 'ledger_draft',
      'version': 1,
      'book_id': bookId,
      'payload': payload,
      'ui': ui,
    });
    if (utf8.encode(body).length > maxDraftBytes) {
      throw const DomainError('draft.too_large');
    }
    // Partial form values intentionally need not satisfy a formal bill schema.
    // JSON encoding rejects unsupported objects; no string truncation is used.
    await _db.atomicWrite(() async {
      await repository.registerSpace(space);
      final old =
          await (_db.select(_db.localDrafts)
                ..where((t) => t.spaceId.equals(space.id) & t.id.equals(id)))
              .getSingleOrNull();
      final now = DateTime.now().toUtc();
      await _db
          .into(_db.localDrafts)
          .insertOnConflictUpdate(
            LocalDraftsCompanion.insert(
              id: id,
              spaceId: space.id,
              body: body,
              createdAt: old?.createdAt ?? now,
              updatedAt: now,
            ),
          );
    });
    return id;
  }

  LedgerDraft? _draft(StoredDraft row) {
    try {
      final envelope = ledgerObject(jsonDecode(row.body));
      if (envelope['kind'] != 'ledger_draft' || envelope['version'] != 1) {
        return null;
      }
      return LedgerDraft(
        id: row.id,
        bookId: envelope['book_id'] as String?,
        payload: ledgerObject(envelope['payload']),
        ui: ledgerObject(envelope['ui']),
        updatedAt: row.updatedAt,
      );
    } on Object {
      return null;
    }
  }

  Future<LedgerDraft?> readDraft(DataSpace space, String id) async {
    final row =
        await (_db.select(_db.localDrafts)
              ..where((t) => t.spaceId.equals(space.id) & t.id.equals(id)))
            .getSingleOrNull();
    return row == null ? null : _draft(row);
  }

  Stream<List<LedgerDraft>> watchDrafts(DataSpace space, {String? bookId}) =>
      (_db.select(_db.localDrafts)
            ..where((t) => t.spaceId.equals(space.id))
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
          .watch()
          .map(
            (rows) => rows
                .map(_draft)
                .whereType<LedgerDraft>()
                .where((draft) => bookId == null || draft.bookId == bookId)
                .toList(),
          );
  Future<void> deleteDraft(DataSpace space, String id) =>
      repository.deleteDraft(space, id);
}
