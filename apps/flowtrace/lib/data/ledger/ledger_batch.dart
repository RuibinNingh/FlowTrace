import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../../domain/ledger/postings.dart';
import '../../domain/ledger/timezone_rules.dart';
import '../local/app_database.dart';
import '../sync/snapshot_protocol.dart';
import '../sync/tombstone_proof.dart';
import 'ledger_projection.dart';
import 'ledger_repository.dart';
import 'ledger_validation.dart';

enum BillBatchAction { update, delete, copy }

enum BillChangeMode { unchanged, set, clear }

final class BillChange<T> {
  const BillChange.unchanged() : mode = BillChangeMode.unchanged, value = null;
  const BillChange.set(T this.value) : mode = BillChangeMode.set;
  const BillChange.clear() : mode = BillChangeMode.clear, value = null;
  final BillChangeMode mode;
  final T? value;
  bool get changed => mode != BillChangeMode.unchanged;
}

/// No timezone override: each selected bill retains its original IANA zone.
/// Unchanged fields never round-trip through DateTime or lose subsecond data.
final class BillTimeEdit {
  const BillTimeEdit({this.date, this.time, this.clearTime = false});
  final String? date, time;
  final bool clearTime;
}

final class BillBatchPatch {
  const BillBatchPatch({
    this.bookId = const BillChange.unchanged(),
    this.categoryId = const BillChange.unchanged(),
    this.note = const BillChange.unchanged(),
    this.tagIds = const BillChange.unchanged(),
    this.time = const BillChange.unchanged(),
    this.excludeFromStatistics = const BillChange.unchanged(),
    this.excludeFromBudget = const BillChange.unchanged(),
    this.removeAttachments = false,
  });
  final BillChange<String> bookId, categoryId, note;
  final BillChange<List<String>> tagIds;
  final BillChange<BillTimeEdit> time;
  final BillChange<bool> excludeFromStatistics, excludeFromBudget;
  final bool removeAttachments;
}

final class BillBatchItem {
  BillBatchItem({
    required this.billId,
    required this.targetId,
    required this.action,
    required Map<String, Object?> before,
    required Map<String, Object?> after,
    required Set<String> changedFields,
    this.issue,
  }) : _before = jsonEncode(before),
       _after = jsonEncode(after),
       changedFields = Set.unmodifiable(changedFields);
  final String billId, targetId;
  final BillBatchAction action;
  final String? issue;
  final Set<String> changedFields;
  final String _before, _after;
  Map<String, Object?> get before => ledgerObject(jsonDecode(_before));
  Map<String, Object?> get after => ledgerObject(jsonDecode(_after));
}

final class BillBatchPreview {
  BillBatchPreview._({
    required this.spaceId,
    required this.epoch,
    required this.permissionHash,
    required List<BillBatchItem> items,
    required Map<String, String> fingerprints,
    required List<LedgerWrite> writes,
    required Map<String, String> sourceForTarget,
    required Set<String> unchanged,
  }) : items = List.unmodifiable(items),
       _fingerprints = Map.unmodifiable(fingerprints),
       _writes = List.unmodifiable(writes),
       _sourceForTarget = Map.unmodifiable(sourceForTarget),
       unchangedIds = Set.unmodifiable(unchanged);
  final String spaceId;
  final String? epoch;
  final String permissionHash;
  final List<BillBatchItem> items;
  final Map<String, String> _fingerprints, _sourceForTarget;
  final List<LedgerWrite> _writes;
  final Set<String> unchangedIds;
  Map<String, String> get issues => Map.unmodifiable({
    for (final item in items)
      if (item.issue != null) item.billId: item.issue!,
  });
  bool get canConfirm => issues.isEmpty && _writes.isNotEmpty;
}

final class BillBatchResult {
  BillBatchResult(Map<String, String> operationIds, Set<String> unchangedIds)
    : operationIds = Map.unmodifiable(operationIds),
      unchangedIds = Set.unmodifiable(unchangedIds);

  /// Keys are affected entity IDs; a copied row therefore uses its new UUID.
  final Map<String, String> operationIds;
  final Set<String> unchangedIds;
}

final class BillBatchException implements Exception {
  BillBatchException(Map<String, String> issues)
    : issues = Map.unmodifiable(issues);
  final Map<String, String> issues;
  @override
  String toString() =>
      'BillBatchException(${issues.values.toSet().join(', ')})';
}

final class LedgerBatchService {
  LedgerBatchService(this.repository);
  final LedgerRepository repository;
  static const _uuid = Uuid();
  AppDatabase get _db => repository.repository.database;

  String _permissionHash(LedgerProjection p) => syncContentHash({
    'epoch': p.rows.syncState?.epoch,
    'status': p.rows.syncState?.status,
    'revoked': p.rows.syncState?.revokedScopesJson,
    'permissions': p.rows.settings['sync.scope-details.${p.space.id}'],
  });

  Future<LedgerProjection> _projection(DataSpace space) =>
      _db.readSnapshot(() async {
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
            settings: {for (final item in settings) item.key: item.value},
          ),
        );
      });
  String _fingerprint(LedgerEntity entity, LedgerView view) => syncContentHash({
    'id': entity.id,
    'scope_id': entity.scopeId,
    'revision': entity.revision,
    'deleted': entity.deleted,
    'payload': entity.payload,
    'projection': entity.projection,
    'editable': entity.editablePayload,
    'can_edit': entity.canEdit,
    'edit_mode': entity.editMode,
    'role': view.roleFor(entity.scopeId),
    'writable': view.writable,
  });

  Future<BillBatchPreview> preview(
    DataSpace space, {
    required Iterable<String> ids,
    BillBatchAction action = BillBatchAction.update,
    BillBatchPatch patch = const BillBatchPatch(),
  }) => _db.readSnapshot(() async {
    final provided = ids.take(1001).toList();
    if (provided.length > 1000) {
      throw BillBatchException({'selection': 'batch.invalid_size'});
    }
    final selected = provided.toSet().toList()..sort();
    if (selected.isEmpty || selected.length > 1000) {
      throw BillBatchException({'selection': 'batch.invalid_size'});
    }
    final p = await _projection(space),
        view = p.view(
          const LedgerQuery(includeArchived: true, includeDeleted: true),
        );
    final fingerprints = <String, String>{},
        items = <BillBatchItem>[],
        writes = <LedgerWrite>[],
        sourceForTarget = <String, String>{},
        unchanged = <String>{};
    final workingBalances = {
      for (final entry in p.balances().entries) entry.key: entry.value.value,
    };
    void project(List<FinancialPosting> entries, {bool reverse = false}) {
      final deltas = <String, BigInt>{};
      for (final entry in entries) {
        deltas.update(
          entry.accountId,
          (sum) => sum + (reverse ? -entry.money.minor : entry.money.minor),
          ifAbsent: () => reverse ? -entry.money.minor : entry.money.minor,
        );
      }
      for (final entry in deltas.entries) {
        final balance = workingBalances[entry.key];
        if (balance != null) {
          workingBalances[entry.key] = Money(
            balance.currency,
            balance.currencyScale,
            checkedMinor(balance.minor + entry.value),
          );
        }
      }
    }

    // An explicitly selected receipt is deleted before its selected source.
    // Unselected relations continue to reject deletion; none are auto-cleared.
    if (action == BillBatchAction.delete) {
      selected.sort((a, b) {
        int rank(String id) =>
            {
              'refund',
              'reimbursement',
            }.contains(view.find('bill', id)?.payload['bill_type'])
            ? 0
            : 1;
        final order = rank(a).compareTo(rank(b));
        return order != 0 ? order : a.compareTo(b);
      });
    }
    for (final id in selected) {
      final entity = view.find('bill', id);
      var target = id, after = <String, Object?>{}, changed = <String>{};
      String? issue;
      try {
        syncIdentifier(id);
        if (entity == null || entity.deleted) {
          throw const DomainError('bill.unavailable');
        }
        if (patch.removeAttachments && action != BillBatchAction.update) {
          throw const DomainError('batch.attachment_removal_update_only');
        }
        fingerprints[id] = _fingerprint(entity, view);
        if (!view.writable ||
            !{'owner', 'editor'}.contains(view.roleFor(entity.scopeId))) {
          throw const DomainError('scope.readonly');
        }
        if (entity.conflicted) throw const DomainError('ledger.conflicted');
        if (action == BillBatchAction.delete) {
          if (!entity.canEdit || entity.editablePayload == null) {
            throw DomainError(entity.issue ?? 'financial_links_hidden');
          }
          validateLedgerWrite(p, 'bill', id, entity.scopeId, 'delete', {});
          final entries = p.currentPostings(id);
          if (entries == null) throw const DomainError('balance.unavailable');
          project(entries, reverse: true);
          writes.add(
            LedgerWrite(
              entityType: 'bill',
              scopeId: entity.scopeId,
              entityId: id,
              baseRevision: entity.revision,
              action: 'delete',
              payload: const {},
            ),
          );
          p.local[id] = p.local[id]!.copyWith(deleted: true);
          changed = {'deleted'};
        } else {
          final full = entity.editablePayload;
          final hidden = full == null;
          if (action == BillBatchAction.copy) {
            if (hidden || !entity.canEdit) {
              throw DomainError(entity.issue ?? 'financial_links_hidden');
            }
            if ({
              'refund',
              'reimbursement',
              'balance_adjustment',
            }.contains(full['bill_type'])) {
              throw const DomainError('copy.requires_explicit_financial_flow');
            }
            target = _uuid.v4();
            after = ledgerCopy(full);
            changed = {'identity'};
          } else {
            after = ledgerCopy(full ?? entity.payload);
          }
          final fields = _applyPatch(after, patch, entity.scopeId);
          changed.addAll(fields);
          if (hidden) {
            if (action != BillBatchAction.update ||
                entity.editMode != 'metadata' ||
                fields.any(
                  (field) => !{
                    'category_id',
                    'note',
                    'tag_ids',
                    'attachment_ids',
                    'flags.exclude_from_statistics',
                    'flags.exclude_from_budget',
                  }.contains(field),
                )) {
              throw const DomainError('financial_links_hidden');
            }
            after['preserve_hidden_financial_links'] = true;
          }
          if (action == BillBatchAction.update && changed.isEmpty) {
            unchanged.add(id);
          } else {
            validateLedgerWrite(
              p,
              'bill',
              target,
              entity.scopeId,
              action == BillBatchAction.copy ? 'create' : 'update',
              normalizeLedgerPayload('bill', after),
            );
            if (action == BillBatchAction.copy) {
              project(financialPostings(after));
            } else if (after['bill_type'] == 'balance_adjustment') {
              final old = p.currentPostings(id);
              if (old == null) throw const DomainError('balance.unavailable');
              final base = {
                for (final entry in workingBalances.entries)
                  if (entry.value != null) entry.key: entry.value!.minor,
              };
              for (final entry in old) {
                if (base.containsKey(entry.accountId)) {
                  base[entry.accountId] =
                      base[entry.accountId]! - entry.money.minor;
                }
              }
              final revised = editedFinancialPostings(
                after,
                previousBill: full,
                previousPostings: old,
                balances: base,
              );
              project([
                ...old.map(
                  (entry) => FinancialPosting(
                    entry.accountId,
                    entry.component,
                    Money(
                      entry.money.currency,
                      entry.money.currencyScale,
                      -entry.money.minor,
                    ),
                  ),
                ),
                ...revised,
              ]);
            }
            writes.add(
              LedgerWrite(
                entityType: 'bill',
                scopeId: entity.scopeId,
                entityId: target,
                baseRevision: action == BillBatchAction.copy
                    ? null
                    : entity.revision,
                action: action == BillBatchAction.copy ? 'create' : null,
                payload: after,
              ),
            );
          }
        }
        sourceForTarget[target] = id;
      } on DomainError catch (error) {
        issue = error.code;
      } on Object {
        issue = 'batch.invalid_input';
      }
      // Only public data is exposed to a confirmation page. Private financial
      // links stay inside immutable commands and cannot leak via preview text.
      final display = entity == null
          ? <String, Object?>{}
          : ledgerCopy(entity.payload);
      for (final field in changed) {
        if (field.startsWith('flags.')) {
          display['flags'] = after['flags'];
        } else if (!{'identity', 'deleted'}.contains(field)) {
          display[field] = after[field];
        }
      }
      items.add(
        BillBatchItem(
          billId: id,
          targetId: target,
          action: action,
          before: entity?.payload ?? {},
          after: action == BillBatchAction.delete ? {} : display,
          changedFields: changed,
          issue: issue,
        ),
      );
    }
    return BillBatchPreview._(
      spaceId: space.id,
      epoch: view.epoch,
      permissionHash: _permissionHash(p),
      items: items,
      fingerprints: fingerprints,
      writes: writes,
      sourceForTarget: sourceForTarget,
      unchanged: unchanged,
    );
  });

  Future<BillBatchResult> confirm(
    DataSpace space,
    BillBatchPreview preview,
  ) => _db.atomicWrite(() async {
    if (preview.spaceId != space.id || !preview.canConfirm) {
      throw BillBatchException(
        preview.issues.isEmpty
            ? {'selection': 'batch.not_confirmable'}
            : preview.issues,
      );
    }
    final projection = await _projection(space);
    final view = projection.view(
      const LedgerQuery(includeArchived: true, includeDeleted: true),
    );
    final issues = <String, String>{};
    for (final item in preview.items) {
      final entity = view.find('bill', item.billId);
      if (view.epoch != preview.epoch ||
          !view.writable ||
          _permissionHash(projection) != preview.permissionHash) {
        issues[item.billId] = 'batch.context_changed';
      } else if (entity == null ||
          _fingerprint(entity, view) != preview._fingerprints[item.billId]) {
        issues[item.billId] = 'batch.selection_changed';
      }
    }
    if (issues.isNotEmpty) throw BillBatchException(issues);
    final operations = <String, String>{};
    // One outer transaction also rolls back earlier writes if the last row
    // fails. The reported ID remains the original selection, including copies.
    for (final write in preview._writes) {
      try {
        final operation = (await repository.saveBatch(space, [write])).single;
        operations[write.entityId!] = operation;
      } on Object catch (error) {
        final source =
            preview._sourceForTarget[write.entityId] ?? write.entityId!;
        throw BillBatchException({
          source: error is DomainError ? error.code : 'batch.storage_failed',
        });
      }
    }
    return BillBatchResult(operations, preview.unchangedIds);
  });
}

Set<String> _applyPatch(
  Map<String, Object?> payload,
  BillBatchPatch patch,
  String scope,
) {
  final changed = <String>{};
  void apply<T>(String field, BillChange<T> change, Object? clearValue) {
    if (!change.changed) return;
    final value = change.mode == BillChangeMode.clear
        ? clearValue
        : change.value;
    if (canonicalSyncJson(value) != canonicalSyncJson(payload[field])) {
      payload[field] = value;
      changed.add(field);
    }
  }

  if (patch.bookId.changed) {
    if (patch.bookId.mode == BillChangeMode.clear ||
        patch.bookId.value != scope) {
      throw const DomainError('book_move_requires_server');
    }
  }
  apply('category_id', patch.categoryId, null);
  apply('note', patch.note, '');
  apply('tag_ids', patch.tagIds, <String>[]);
  if (patch.removeAttachments &&
      (payload['attachment_ids'] as List).isNotEmpty) {
    payload['attachment_ids'] = <String>[];
    changed.add('attachment_ids');
  }
  final flags = ledgerCopy(ledgerObject(payload['flags']));
  for (final entry in {
    'exclude_from_statistics': patch.excludeFromStatistics,
    'exclude_from_budget': patch.excludeFromBudget,
  }.entries) {
    if (entry.value.mode == BillChangeMode.clear) {
      throw const DomainError('batch.invalid_flag_change');
    }
    if (entry.value.changed && flags[entry.key] != entry.value.value) {
      flags[entry.key] = entry.value.value;
      changed.add('flags.${entry.key}');
    }
  }
  payload['flags'] = flags;
  if (patch.time.changed) {
    final old = ledgerCopy(payload);
    if (patch.time.mode == BillChangeMode.clear) {
      payload['occurred_at'] = null;
    } else {
      _editTime(payload, patch.time.value!);
    }
    for (final field in ['business_date', 'business_timezone', 'occurred_at']) {
      if (payload[field] != old[field]) changed.add(field);
    }
  }
  return changed;
}

void _editTime(Map<String, Object?> payload, BillTimeEdit edit) {
  if (edit.clearTime && edit.time != null) {
    throw const DomainError('batch.invalid_time_change');
  }
  final zone = payload['business_timezone'] as String;
  final date = edit.date ?? payload['business_date'] as String;
  businessDate(date);
  if (edit.time == null &&
      !edit.clearTime &&
      date == payload['business_date']) {
    return;
  }
  if (edit.date == null && edit.time == null && !edit.clearTime) return;
  payload['business_date'] = date;
  if (edit.clearTime) {
    payload['occurred_at'] = null;
    return;
  }
  String? time = edit.time;
  final old = payload['occurred_at'] as String?;
  if (time == null && old != null) {
    final location = resolveLocalTime('2000-01-01T00:00:00', zone).location;
    final local = tz.TZDateTime.from(DateTime.parse(old), location);
    String pair(int value) => value.toString().padLeft(2, '0');
    final micros = local.millisecond * 1000 + local.microsecond;
    time =
        '${pair(local.hour)}:${pair(local.minute)}:${pair(local.second)}${micros == 0 ? '' : '.${micros.toString().padLeft(6, '0')}'}';
  }
  if (time == null) {
    payload['occurred_at'] = null;
    return;
  }
  if (RegExp(r'^[0-9]{2}:[0-9]{2}$').hasMatch(time)) time = '$time:00';
  final resolved = resolveLocalTime('${date}T$time', zone);
  payload['business_date'] = isoBusinessDate(resolved);
  payload['occurred_at'] = resolved.toUtc().toIso8601String();
}
