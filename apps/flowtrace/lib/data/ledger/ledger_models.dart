import 'dart:convert';

import '../../core/money/money.dart';

Map<String, Object?> ledgerObject(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const DomainError('ledger.invalid_object');
  }
  return value;
}

Map<String, Object?> ledgerCopy(Map<String, Object?> value) =>
    ledgerObject(jsonDecode(jsonEncode(value)));

final class LedgerQuery {
  const LedgerQuery({
    this.bookId,
    this.includeArchived = false,
    this.includeDeleted = false,
  });
  final String? bookId;
  final bool includeArchived;
  final bool includeDeleted;
}

/// Public display data stays separate from a caller-authorized editing payload.
final class LedgerEntity {
  LedgerEntity({
    required this.id,
    required this.type,
    required this.scopeId,
    required this.revision,
    required Map<String, Object?> payload,
    required Map<String, Object?> projection,
    required this.pending,
    required this.conflicted,
    required this.deleted,
    required this.canEdit,
    required this.effectiveArchived,
    this.editMode = 'full',
    this.issue,
    Map<String, Object?>? editablePayload,
  }) : _payload = jsonEncode(payload),
       _projection = jsonEncode(projection),
       _editable = editablePayload == null ? null : jsonEncode(editablePayload);

  final String id;
  final String type;
  final String scopeId;
  final String revision;
  final bool pending;
  final bool conflicted;
  final bool deleted;
  final bool canEdit;
  final bool effectiveArchived;
  final String? issue;
  final String editMode;
  final String _payload;
  final String _projection;
  final String? _editable;
  Map<String, Object?> get payload => ledgerObject(jsonDecode(_payload));
  Map<String, Object?> get projection => ledgerObject(jsonDecode(_projection));
  Map<String, Object?>? get editablePayload =>
      _editable == null ? null : ledgerObject(jsonDecode(_editable));
  String get name => payload['name'] is String ? payload['name'] as String : '';
}

final class LedgerBalance {
  const LedgerBalance({
    required this.status,
    this.value,
    this.confirmed,
    this.issue,
  });
  final String status;
  final Money? value;
  final Money? confirmed;
  final String? issue;
  bool get available => value != null;
}

final class LedgerView {
  LedgerView({
    required this.epoch,
    required this.syncStatus,
    required this.pendingCount,
    required this.writable,
    required List<LedgerEntity> entities,
    required List<LedgerEntity> books,
    required List<LedgerEntity> categories,
    required List<LedgerEntity> tags,
    required List<LedgerEntity> accounts,
    required List<LedgerEntity> bills,
    required Map<String, LedgerBalance> balances,
    required Map<String, String> scopeRoles,
    this.issue,
  }) : _entities = List.unmodifiable(entities),
       books = List.unmodifiable(books),
       categories = List.unmodifiable(categories),
       tags = List.unmodifiable(tags),
       accounts = List.unmodifiable(accounts),
       bills = List.unmodifiable(bills),
       balances = Map.unmodifiable(balances),
       scopeRoles = Map.unmodifiable(scopeRoles);
  final String? epoch;
  final String syncStatus;
  final int pendingCount;
  final bool writable;
  final String? issue;
  final List<LedgerEntity> _entities;
  final List<LedgerEntity> books;
  final List<LedgerEntity> categories;
  final List<LedgerEntity> tags;
  final List<LedgerEntity> accounts;
  final List<LedgerEntity> bills;
  List<LedgerEntity> get budgets => List.unmodifiable(
    _entities.where((entity) => entity.type == 'budget' && !entity.deleted),
  );
  final Map<String, LedgerBalance> balances;
  final Map<String, String> scopeRoles;
  String? roleFor(String scopeId) => scopeRoles[scopeId];
  bool canCreate(String entityType, String scopeId) =>
      writable &&
      (entityType == 'book'
          ? scopeRoles[scopeId] == 'owner'
          : {'owner', 'editor'}.contains(scopeRoles[scopeId]));

  LedgerEntity? find(String type, String id) {
    for (final entity in _entities) {
      if (entity.type == type && entity.id == id) return entity;
    }
    return null;
  }
}

final class LedgerWrite {
  LedgerWrite({
    required this.entityType,
    required this.scopeId,
    required Map<String, Object?> payload,
    this.entityId,
    this.baseRevision,
    this.dependsOn,
    this.action,
  }) : _payload = jsonEncode(payload);
  final String entityType;
  final String scopeId;
  final String? entityId;
  final String? baseRevision;
  final String? dependsOn;
  final String? action;
  final String _payload;
  Map<String, Object?> get payload => ledgerObject(jsonDecode(_payload));
}

final class LedgerDraft {
  LedgerDraft({
    required this.id,
    required this.bookId,
    required Map<String, Object?> payload,
    required Map<String, Object?> ui,
    required this.updatedAt,
  }) : _payload = jsonEncode(payload),
       _ui = jsonEncode(ui);
  final String id;
  final String? bookId;
  final DateTime updatedAt;
  final String _payload;
  final String _ui;
  Map<String, Object?> get payload => ledgerObject(jsonDecode(_payload));
  Map<String, Object?> get ui => ledgerObject(jsonDecode(_ui));
}
