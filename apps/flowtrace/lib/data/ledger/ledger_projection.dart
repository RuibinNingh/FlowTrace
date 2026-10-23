import 'dart:convert';

import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../domain/ledger/postings.dart';
import '../local/app_database.dart';
import '../sync/snapshot_protocol.dart';
import '../sync/tombstone_proof.dart';
import 'ledger_models.dart';

const ledgerEntityTypes = {
  'book',
  'category',
  'tag',
  'account',
  'bill',
  'budget',
};
const mutableIntentStates = {
  'queued',
  'sending',
  'retry',
  'rejected',
  'blocked',
};

Map<String, Object?> normalizeLedgerPayload(
  String type,
  Map<String, Object?> data,
) {
  final payload = data['projection_kind'] == null
      ? data
      : ledgerObject(data['payload']);
  final defaults = switch (type) {
    'book' => <String, Object?>{
      'template': 'blank',
      'icon': 'book',
      'cover_color': '#2279D7',
      'show_assets': false,
      'display_mode': 'month',
    },
    'category' => <String, Object?>{'archived': false},
    'account' => <String, Object?>{
      'group_id': null,
      'sort_order': 0,
      'archived': false,
      'icon': 'account',
      'note': '',
      'provider_id': null,
      'bank_id': null,
      'card_last_four': null,
      'opening_date': null,
      'credit': null,
    },
    'tag' => <String, Object?>{
      'kind': 'tag',
      'group_id': null,
      'archived': false,
      'sort_order': 0,
    },
    'bill' => <String, Object?>{
      'account_id': null,
      'from_account_id': null,
      'to_account_id': null,
      'target_money': null,
      'occurred_at': null,
      'category_id': null,
      'tag_ids': <Object?>[],
      'attachment_ids': <Object?>[],
      'source': 'manual',
      'flags': {'exclude_from_statistics': false, 'exclude_from_budget': false},
      'note': '',
      'reporting': null,
      'allocations': <Object?>[],
      'income_component_minor': '0',
      'target_balance_minor': null,
      'gross_amount_minor': null,
      'discount_minor': null,
      'fee': null,
    },
    _ => <String, Object?>{},
  };
  return ledgerCopy({...defaults, ...payload});
}

String financialFingerprint(Map<String, Object?> payload) => canonicalSyncJson({
  for (final entry in normalizeLedgerPayload('bill', payload).entries)
    if (!{
      'note',
      'category_id',
      'tag_ids',
      'attachment_ids',
      'flags',
      'reimbursement_tracking',
      'preserve_hidden_financial_links',
    }.contains(entry.key))
      entry.key: entry.value,
});

Map<String, Object?> postingJson(FinancialPosting posting) => {
  'account_id': posting.accountId,
  'component': posting.component,
  'money': posting.money.toJson(),
};
FinancialPosting postingFromJson(Object? raw) {
  final row = ledgerObject(raw);
  return FinancialPosting(
    syncIdentifier(row['account_id']),
    row['component'] as String,
    Money.fromJson(row['money']),
  );
}

final class LedgerRows {
  LedgerRows({
    required this.entities,
    required this.shadows,
    required this.operations,
    required this.settings,
    required this.syncState,
  });
  final List<StoredEntity> entities;
  final List<ConfirmedEntity> shadows;
  final List<StoredOperation> operations;
  final Map<String, String> settings;
  final SpaceSyncState? syncState;
}

final class LedgerProjection {
  LedgerProjection(this.space, this.rows) {
    revoked = rows.syncState == null
        ? <String>{}
        : (jsonDecode(rows.syncState!.revokedScopesJson) as List)
              .cast<String>()
              .toSet();
    if (space.verified && !revoked.contains(space.userId)) {
      roles[space.userId] = 'owner';
    }
    final saved = rows.settings['sync.scope-details.${space.id}'];
    if (saved != null) {
      try {
        final details = ledgerObject(jsonDecode(saved));
        if (rows.syncState != null &&
            details['version'] == 1 &&
            details['epoch'] == rows.syncState!.epoch) {
          for (final raw in details['scopes'] as List) {
            final entry = ledgerObject(raw),
                id = syncIdentifier(ledgerObject(raw)['scope_id']);
            if (!revoked.contains(id) &&
                {'owner', 'editor', 'viewer'}.contains(entry['role'])) {
              roles[id] = entry['role'] as String;
            }
          }
        }
      } on Object {
        /* Unknown permissions remain unavailable, never infer an editor role. */
      }
    }
    for (final operation in rows.operations) {
      if (operation.entityType != 'book' ||
          !{
            'queued',
            'sending',
            'retry',
            'applied',
          }.contains(operation.state)) {
        continue;
      }
      final command = ledgerObject(jsonDecode(operation.operationJson));
      if (command['action'] == 'create' &&
          command['scope_id'] == space.userId &&
          !revoked.contains(operation.entityId)) {
        roles.putIfAbsent(operation.entityId, () => 'owner');
      }
    }
    for (final shadow in rows.shadows) {
      if (!revoked.contains(shadow.scopeId)) {
        shadowIndex['${shadow.scopeId}/${shadow.entityType}/${shadow.entityId}'] =
            shadow;
      }
    }
    for (final entity in rows.entities) {
      if (entity.scopeId.isEmpty || revoked.contains(entity.scopeId)) continue;
      try {
        final data = ledgerObject(jsonDecode(entity.dataJson));
        if (data['projection_kind'] == 'bill_private_finance') continue;
        local[entity.entityId] = entity;
        payloads[entity.entityId] = normalizeLedgerPayload(
          entity.entityType,
          data,
        );
        projections[entity.entityId] = data;
      } on Object {
        issues[entity.entityId] = 'data.invalid_projection';
      }
    }
    for (final entry in rows.settings.entries) {
      if (!entry.key.startsWith('ledger.postings.v1.${space.id}.')) continue;
      try {
        final hint = ledgerObject(jsonDecode(entry.value));
        hints[entry.key.split('.').last] = hint;
      } on Object {
        /* An unusable hint never becomes a zero movement. */
      }
    }
  }
  final DataSpace space;
  final LedgerRows rows;
  late final Set<String> revoked;
  final roles = <String, String>{};
  final shadowIndex = <String, ConfirmedEntity>{};
  final local = <String, StoredEntity>{};
  final payloads = <String, Map<String, Object?>>{};
  final projections = <String, Map<String, Object?>>{};
  final hints = <String, Map<String, Object?>>{};
  final issues = <String, String>{};
  bool get writable =>
      space.verified &&
      (rows.syncState == null || rows.syncState!.status == 'active');
  bool canWrite(String type, String scope) =>
      writable &&
      !revoked.contains(scope) &&
      (type == 'book'
          ? roles[scope] == 'owner'
          : {'owner', 'editor'}.contains(roles[scope]));
  ConfirmedEntity? shadow(String scope, String type, String id) =>
      shadowIndex['$scope/$type/$id'];
  List<StoredOperation> operations(String id) => rows.operations
      .where((op) => op.entityId == id && op.state != 'discarded')
      .toList();
  bool archived(String id) {
    final payload = payloads[id];
    if (payload == null) return true;
    if (payload['archived'] == true) return true;
    // Account groups live in private REST configuration, outside the ledger
    // entity set. Only category/tag parents can propagate ledger archiving.
    final parent = switch (local[id]?.entityType) {
      'category' => payload['parent_id'],
      'tag' => payload['group_id'],
      _ => null,
    };
    return parent != null &&
        (payloads[parent]?['archived'] == true ||
            !payloads.containsKey(parent));
  }

  Map<String, Object?>? fullBill(String id, {bool confirmed = false}) {
    try {
      return _fullBill(id, confirmed: confirmed);
    } on Object {
      issues[id] = 'data.invalid_projection';
      return null;
    }
  }

  Map<String, Object?>? _fullBill(String id, {bool confirmed = false}) {
    final row = local[id];
    if (row == null || row.entityType != 'bill' || row.deleted && !confirmed) {
      return null;
    }
    final source = confirmed ? shadow(row.scopeId, 'bill', id) : null;
    if (confirmed && (source == null || source.deleted)) return null;
    final data = confirmed
        ? ledgerObject(jsonDecode(source!.dataJson))
        : projections[id]!;
    if (confirmed && data['projection_kind'] != 'bill_public') return null;
    final payload = normalizeLedgerPayload('bill', data);
    final visibility =
        !confirmed &&
            data['projection_kind'] == null &&
            payload['preserve_hidden_financial_links'] == true
        ? _publicVisibility(id)
        : data;
    if (visibility == null) return null;
    final hidden = (visibility['hidden_account_fields'] as List? ?? [])
        .cast<String>();
    if ((visibility['hidden_allocation_count'] as int? ?? 0) != 0) return null;
    final finance = shadow(space.userId, 'bill', id);
    final financeData = finance == null || finance.deleted
        ? null
        : ledgerObject(jsonDecode(finance.dataJson));
    for (final field in hidden) {
      final key = field == 'fee.account_id' ? 'fee_account_id' : field;
      final value = financeData?['projection_kind'] == 'bill_private_finance'
          ? ledgerObject(financeData!['account_links'])[key]
          : null;
      if (value == null) return null;
      final account = local[value];
      if (account == null ||
          account.scopeId != space.userId ||
          account.deleted) {
        return null;
      }
      if (field == 'fee.account_id') {
        payload['fee'] = {...ledgerObject(payload['fee']), 'account_id': value};
      } else {
        payload[field] = value;
      }
    }
    for (final accountId in accountIds(payload)) {
      final account = local[accountId];
      if (account == null ||
          account.deleted ||
          !canWrite('account', account.scopeId)) {
        return null;
      }
    }
    for (final allocation in payload['allocations'] as List) {
      final original = local[ledgerObject(allocation)['source_bill_id']];
      if (original == null ||
          original.deleted ||
          !canWrite('bill', original.scopeId)) {
        return null;
      }
    }
    return payload;
  }

  Map<String, Object?>? _publicVisibility(String id) {
    for (final operation in operations(id).reversed) {
      if (operation.baseDataJson == null) continue;
      final data = ledgerObject(jsonDecode(operation.baseDataJson!));
      if (data['projection_kind'] == 'bill_public') return data;
    }
    final row = local[id];
    final current = row == null ? null : shadow(row.scopeId, 'bill', id);
    if (current == null || current.deleted) return null;
    final data = ledgerObject(jsonDecode(current.dataJson));
    return data['projection_kind'] == 'bill_public' ? data : null;
  }

  List<FinancialPosting>? confirmedPostings(String id) {
    try {
      return _confirmedPostings(id);
    } on Object {
      issues[id] = 'data.invalid_projection';
      return null;
    }
  }

  List<FinancialPosting>? _confirmedPostings(String id) {
    final row = local[id];
    if (row == null) return null;
    final current = shadow(row.scopeId, 'bill', id);
    final moving = _pendingMoveBaseline(id);
    if (moving != null) return moving.postings;
    if (current == null) {
      return operations(id).any(
            (op) =>
                ledgerObject(jsonDecode(op.operationJson))['action'] ==
                'create',
          )
          ? []
          : null;
    }
    if (current.deleted) {
      if (operations(id).any(
        (operation) =>
            mutableIntentStates.contains(operation.state) &&
            ledgerObject(jsonDecode(operation.operationJson))['move'] is Map,
      )) {
        return null;
      }
      return [];
    }
    final data = ledgerObject(jsonDecode(current.dataJson));
    if (data['projection_kind'] != 'bill_public') return null;
    final payload = normalizeLedgerPayload('bill', data);
    final private = shadow(space.userId, 'bill', id);
    final privateData = private == null || private.deleted
        ? null
        : ledgerObject(jsonDecode(private.dataJson));
    final entries = <FinancialPosting>[];
    if (privateData?['projection_kind'] == 'bill_private_finance') {
      entries.addAll((privateData!['entries'] as List).map(postingFromJson));
    }
    if (payload['bill_type'] == 'balance_adjustment' &&
        payload['account_id'] != null) {
      // A shared historical adjustment has no direction in its public payload.
      // Only an exact matching local posting hint can supplement that evidence.
      final full = fullBill(id, confirmed: true);
      final hint = full == null ? null : _hintFor(id, full);
      if (hint == null) return null;
      entries.addAll((hint['new_entries'] as List).map(postingFromJson));
    } else {
      entries.addAll(financialPostings(payload, allowHiddenLinks: true));
    }
    return _uniquePostings(entries);
  }

  /// A queued move changes the local book before the target canonical arrives.
  /// Reuse only the exact still-authorized source cut captured by that move;
  /// a newer target canonical or raw ACK takes precedence over this proof.
  _MoveBaseline? _pendingMoveBaseline(String id) {
    try {
      final row = local[id];
      if (row == null || row.deleted) {
        return null;
      }
      final candidates = operations(id).where(
        (operation) =>
            {'queued', 'sending', 'retry'}.contains(operation.state) &&
            ledgerObject(jsonDecode(operation.operationJson))['move'] is Map,
      );
      if (candidates.length != 1) return null;
      final operation = candidates.single;
      final command = ledgerObject(jsonDecode(operation.operationJson));
      final move = ledgerObject(command['move']);
      final sourceScope = command['scope_id'];
      final target = ledgerObject(command['payload']);
      final hint = hints[operation.operationId];
      if (command['entity_type'] != 'bill' ||
          command['entity_id'] != id ||
          command['action'] != 'update' ||
          sourceScope is! String ||
          sourceScope == row.scopeId ||
          move['target_scope_id'] != row.scopeId ||
          target['book_id'] != row.scopeId ||
          hint == null ||
          hint['version'] != 1 ||
          hint['bill_id'] != id ||
          hint['move_source_scope_id'] != sourceScope ||
          hint['move_source_revision'] != command['base_revision'] ||
          hint['fingerprint'] != financialFingerprint(target) ||
          financialFingerprint(payloads[id]!) != financialFingerprint(target) ||
          !{'owner', 'editor', 'viewer'}.contains(roles[sourceScope]) ||
          !{'owner', 'editor', 'viewer'}.contains(roles[row.scopeId]) ||
          revoked.contains(sourceScope) ||
          revoked.contains(row.scopeId)) {
        return null;
      }
      final source = shadow(sourceScope, 'bill', id);
      if (source == null ||
          source.deleted ||
          source.revision != command['base_revision']) {
        return null;
      }
      final targetShadow = shadow(row.scopeId, 'bill', id);
      if (targetShadow != null) {
        final compared = BigInt.parse(
          targetShadow.revision,
        ).compareTo(BigInt.parse(source.revision));
        // A previous move out leaves a tomb with the source live revision.
        // That tomb and older target data cannot erase the proven source cut.
        if (compared > 0 || compared == 0 && !targetShadow.deleted) return null;
      }
      final data = ledgerObject(jsonDecode(source.dataJson));
      if (data['projection_kind'] != 'bill_public' ||
          hint['move_source_projection_hash'] != syncContentHash(data) ||
          (data['hidden_allocation_count'] as int? ?? 0) != 0) {
        return null;
      }
      final before = (hint['old_entries'] as List)
          .map(postingFromJson)
          .toList();
      final after = (hint['new_entries'] as List).map(postingFromJson).toList();
      if (_postingSignature(before) != _postingSignature(after)) return null;
      final private = shadow(space.userId, 'bill', id);
      final finance = private == null || private.deleted
          ? null
          : ledgerObject(jsonDecode(private.dataJson));
      if (before.isNotEmpty &&
          (private == null ||
              private.revision != source.revision ||
              finance?['projection_kind'] != 'bill_private_finance' ||
              finance?['book_id'] != sourceScope ||
              _postingSignature(
                    (finance!['entries'] as List).map(postingFromJson).toList(),
                  ) !=
                  _postingSignature(before))) {
        return null;
      }
      final original = normalizeLedgerPayload('bill', data);
      for (final field
          in (data['hidden_account_fields'] as List? ?? []).cast<String>()) {
        final key = field == 'fee.account_id' ? 'fee_account_id' : field;
        final value = finance == null
            ? null
            : ledgerObject(finance['account_links'])[key];
        if (value == null) return null;
        if (field == 'fee.account_id') {
          original['fee'] = {
            ...ledgerObject(original['fee']),
            'account_id': value,
          };
        } else {
          original[field] = value;
        }
      }
      original['book_id'] = row.scopeId;
      if (original['fee'] != null && target['fee'] != null) {
        original['fee'] = {
          ...ledgerObject(original['fee']),
          'category_id': ledgerObject(target['fee'])['category_id'],
        };
      }
      if (financialFingerprint(original) != financialFingerprint(target) ||
          (original['allocations'] as List).isNotEmpty ||
          {'refund', 'reimbursement'}.contains(original['bill_type'])) {
        return null;
      }
      for (final accountId in accountIds(target)) {
        final account = local[accountId];
        if (account == null ||
            account.deleted ||
            account.scopeId != space.userId ||
            !canWrite('account', account.scopeId)) {
          return null;
        }
      }
      if (target['bill_type'] != 'balance_adjustment' &&
          _postingSignature(financialPostings(target)) !=
              _postingSignature(before)) {
        return null;
      }
      if (target['bill_type'] == 'balance_adjustment') {
        final money = Money.fromJson(target['money'], positive: true);
        if (before.length != 1 ||
            before.single.component != 'principal' ||
            before.single.accountId != target['account_id'] ||
            before.single.money.currency != money.currency ||
            before.single.money.currencyScale != money.currencyScale ||
            before.single.money.minor.abs() != money.minor) {
          return null;
        }
      }
      return _MoveBaseline(source, before);
    } on Object {
      return null;
    }
  }

  Map<String, Object?>? _hintFor(String id, Map<String, Object?> payload) {
    for (final op in operations(id).reversed) {
      final hint = hints[op.operationId];
      if (hint?['fingerprint'] == financialFingerprint(payload)) return hint;
    }
    return null;
  }

  List<FinancialPosting>? currentPostings(String id) {
    final row = local[id];
    if (row == null || row.entityType != 'bill') return null;
    if (row.deleted) return [];
    final payload = fullBill(id);
    if (payload == null) return null;
    final hint = _hintFor(id, payload);
    if (hint != null) {
      return (hint['new_entries'] as List).map(postingFromJson).toList();
    }
    if (payload['bill_type'] == 'balance_adjustment') {
      return confirmedPostings(id);
    }
    return financialPostings(payload);
  }

  Map<String, LedgerBalance> balances() {
    final values = <String, Money>{},
        confirmed = <String, Money>{},
        status = <String, String>{},
        errors = <String, String>{};
    for (final row in local.values.where(
      (row) => row.entityType == 'account' && !row.deleted,
    )) {
      try {
        final source = shadow(row.scopeId, 'account', row.entityId);
        final data = source == null
            ? null
            : ledgerObject(jsonDecode(source.dataJson));
        final canonical =
            data?['projection_kind'] == 'account' && data?['balance'] != null;
        if (canonical) {
          final balance = Money.fromJson(data!['balance']);
          confirmed[row.entityId] = balance;
          values[row.entityId] = balance;
          status[row.entityId] = 'confirmed';
          final accountOps = operations(
            row.entityId,
          ).where((op) => mutableIntentStates.contains(op.state));
          if (accountOps.isNotEmpty) {
            final opening = Money.fromJson(payloads[row.entityId]!['opening']);
            final baseOpening = Money.fromJson(
              ledgerObject(data['payload'])['opening'],
            );
            values[row.entityId] = Money(
              opening.currency,
              opening.currencyScale,
              checkedMinor(balance.minor + opening.minor - baseOpening.minor),
            );
            status[row.entityId] = 'pending';
          }
        } else if (source == null &&
            operations(row.entityId).any(
              (op) =>
                  mutableIntentStates.contains(op.state) &&
                  ledgerObject(jsonDecode(op.operationJson))['action'] ==
                      'create',
            )) {
          values[row.entityId] = Money.fromJson(
            payloads[row.entityId]!['opening'],
          );
          status[row.entityId] = 'pending';
        } else {
          errors[row.entityId] = 'awaiting_server_projection';
        }
        if (operations(
          row.entityId,
        ).any((op) => {'rejected', 'blocked'}.contains(op.state))) {
          errors[row.entityId] = 'conflicted';
        }
      } on Object {
        errors[row.entityId] = 'balance.unavailable';
      }
    }
    for (final row in local.values.where((row) => row.entityType == 'bill')) {
      try {
        final ops = operations(row.entityId),
            pending = ops
                .where((op) => mutableIntentStates.contains(op.state))
                .toList();
        final source =
            _pendingMoveBaseline(row.entityId)?.source ??
            shadow(row.scopeId, 'bill', row.entityId);
        final data = source == null
            ? null
            : ledgerObject(jsonDecode(source.dataJson));
        final canonical =
            data?['projection_kind'] == 'bill_public' ||
            source != null &&
                isCanonicalBillTombstone(
                  space,
                  rows.syncState?.epoch,
                  source,
                  rows.settings,
                );
        final missingAck = ops.any(
          (op) =>
              op.state == 'applied' &&
              op.appliedRevision != null &&
              (!canonical ||
                  BigInt.parse(op.appliedRevision!) >
                      BigInt.parse(source!.revision)),
        );
        if (pending.isEmpty && !missingAck) continue;
        // An authorized redacted edit changes display metadata only. It neither
        // needs nor guesses another person's original private movements.
        if (!missingAck &&
            payloads[row.entityId]!['preserve_hidden_financial_links'] ==
                true &&
            !pending.any((op) => {'rejected', 'blocked'}.contains(op.state))) {
          continue;
        }
        final payload = fullBill(row.entityId);
        final affected = <String>{...accountIds(payloads[row.entityId]!)};
        final before = confirmedPostings(row.entityId);
        if (before != null) {
          affected.addAll(before.map((entry) => entry.accountId));
        }
        for (final op in ops) {
          final hint = hints[op.operationId];
          if (hint != null) {
            for (final raw in [
              ...hint['old_entries'] as List,
              ...hint['new_entries'] as List,
            ]) {
              affected.add(postingFromJson(raw).accountId);
            }
          }
        }
        if (missingAck ||
            before == null ||
            pending.any((op) => {'rejected', 'blocked'}.contains(op.state))) {
          for (final id in affected) {
            errors[id] = missingAck
                ? 'awaiting_server_projection'
                : 'conflicted';
          }
          continue;
        }
        if (payloads[row.entityId]!['preserve_hidden_financial_links'] ==
            true) {
          continue;
        }
        try {
          final List<FinancialPosting> after;
          if (row.deleted) {
            after = [];
          } else if (payload == null) {
            throw const DomainError('financial_links_hidden');
          } else if (payload['bill_type'] == 'balance_adjustment') {
            final hint = _hintFor(row.entityId, payload);
            if (hint == null) throw const DomainError('adjustment.unavailable');
            after = (hint['new_entries'] as List).map(postingFromJson).toList();
          } else {
            after = financialPostings(payload);
          }
          final deltas = <String, BigInt>{};
          for (final posting in [
            ...before.map(
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
            ...after,
          ]) {
            final value = values[posting.accountId];
            if (value == null) {
              errors[posting.accountId] = 'balance.unavailable';
              continue;
            }
            if (value.currency != posting.money.currency ||
                value.currencyScale != posting.money.currencyScale) {
              throw const DomainError('money.currency_mismatch');
            }
            deltas.update(
              posting.accountId,
              (sum) => sum + posting.money.minor,
              ifAbsent: () => posting.money.minor,
            );
          }
          for (final entry in deltas.entries) {
            final value = values[entry.key]!;
            values[entry.key] = Money(
              value.currency,
              value.currencyScale,
              checkedMinor(value.minor + entry.value),
            );
            status[entry.key] = 'pending';
          }
        } on Object {
          for (final id in affected) {
            errors[id] = 'balance.unavailable';
          }
        }
      } on Object {
        issues[row.entityId] = 'data.invalid_projection';
        for (final id in values.keys) {
          errors[id] = 'balance.unavailable';
        }
      }
    }
    return {
      for (final row in local.values.where(
        (row) => row.entityType == 'account' && !row.deleted,
      ))
        row.entityId: LedgerBalance(
          status: errors[row.entityId] ?? status[row.entityId] ?? 'unavailable',
          value: errors.containsKey(row.entityId) ? null : values[row.entityId],
          confirmed: confirmed[row.entityId],
          issue: errors[row.entityId],
        ),
    };
  }

  LedgerView view(LedgerQuery query) {
    final entities = <LedgerEntity>[];
    for (final row in local.values) {
      final payload = payloads[row.entityId]!, ops = operations(row.entityId);
      var displayPayload = payload;
      var displayProjection = projections[row.entityId]!;
      if (row.entityType == 'bill' &&
          displayProjection['projection_kind'] == null) {
        displayPayload = ledgerCopy(payload);
        final visibility = payload['preserve_hidden_financial_links'] == true
            ? _publicVisibility(row.entityId)
            : null;
        final hidden = <String>[
          ...(visibility?['hidden_account_fields'] as List? ?? [])
              .cast<String>(),
        ];
        for (final field in [
          'account_id',
          'from_account_id',
          'to_account_id',
          'fee.account_id',
        ]) {
          final value = field == 'fee.account_id'
              ? ((displayPayload['fee'] as Map?)?['account_id'])
              : displayPayload[field];
          if (value == null) continue;
          final linked = local[value];
          if (linked == null ||
              linked.scopeId == space.userId ||
              revoked.contains(linked.scopeId)) {
            if (!hidden.contains(field)) hidden.add(field);
            if (field == 'fee.account_id') {
              displayPayload['fee'] = {
                ...ledgerObject(displayPayload['fee']),
                'account_id': null,
              };
            } else {
              displayPayload[field] = null;
            }
          }
        }
        final allocations = displayPayload['allocations'] as List;
        final visible = allocations
            .where(
              (raw) =>
                  local[ledgerObject(raw)['source_bill_id']]?.scopeId ==
                  row.scopeId,
            )
            .toList();
        displayPayload['allocations'] = visible;
        displayProjection = {
          'projection_kind': 'bill_public',
          'payload': displayPayload,
          'hidden_account_fields': hidden,
          'hidden_allocation_count': allocations.length - visible.length,
          if (visibility != null)
            'hidden_allocation_count':
                (visibility['hidden_allocation_count'] as int? ?? 0) +
                allocations.length -
                visible.length,
        };
      }
      final pending = ops.any((op) => mutableIntentStates.contains(op.state));
      final conflicted = ops.any(
        (op) => {'rejected', 'blocked'}.contains(op.state),
      );
      final full = row.entityType == 'bill' ? fullBill(row.entityId) : payload;
      final allowed =
          canWrite(row.entityType, row.scopeId) && !row.deleted && !conflicted;
      final hidden = row.entityType == 'bill' && full == null;
      final unavailable =
          row.entityType == 'bill' &&
          payload['bill_type'] == 'balance_adjustment' &&
          !hidden &&
          currentPostings(row.entityId) == null;
      entities.add(
        LedgerEntity(
          id: row.entityId,
          type: row.entityType,
          scopeId: row.entityType == 'book' ? row.entityId : row.scopeId,
          revision: row.serverRevision,
          payload: displayPayload,
          projection: displayProjection,
          pending: pending,
          conflicted: conflicted,
          deleted: row.deleted,
          canEdit: allowed && !hidden && !unavailable,
          editMode: !allowed || unavailable
              ? 'readonly'
              : hidden
              ? 'metadata'
              : 'full',
          effectiveArchived: archived(row.entityId),
          issue: !writable
              ? 'recovery_required'
              : conflicted
              ? 'conflicted'
              : !canWrite(row.entityType, row.scopeId)
              ? 'scope.readonly'
              : hidden
              ? 'financial_links_hidden'
              : unavailable
              ? 'balance.unavailable'
              : null,
          editablePayload: allowed && !hidden && !unavailable ? full : null,
        ),
      );
    }
    List<LedgerEntity> filtered(String type) {
      final result = entities
          .where(
            (entry) =>
                entry.type == type &&
                (query.includeDeleted || !entry.deleted) &&
                (query.includeArchived ||
                    !{'category', 'tag'}.contains(type) ||
                    !entry.effectiveArchived) &&
                (query.bookId == null ||
                    type == 'book' ||
                    entry.scopeId == query.bookId ||
                    type == 'account' && entry.scopeId == space.userId),
          )
          .toList();
      result.sort((a, b) {
        final order = ((a.payload['sort_order'] as int?) ?? 0).compareTo(
          (b.payload['sort_order'] as int?) ?? 0,
        );
        return order != 0 ? order : a.id.compareTo(b.id);
      });
      return result;
    }

    return LedgerView(
      epoch: rows.syncState?.epoch,
      syncStatus: rows.syncState?.status ?? 'uninitialized',
      pendingCount: rows.operations
          .where((op) => mutableIntentStates.contains(op.state))
          .length,
      writable: writable,
      entities: entities,
      books: filtered('book'),
      categories: filtered('category'),
      tags: filtered('tag'),
      accounts: filtered('account'),
      bills: filtered('bill'),
      balances: balances(),
      scopeRoles: roles,
      issue: issues.isNotEmpty ? 'data.unavailable' : null,
    );
  }
}

Set<String> accountIds(Map<String, Object?> payload) => {
  for (final key in ['account_id', 'from_account_id', 'to_account_id'])
    if (payload[key] is String) payload[key] as String,
  if (payload['fee'] is Map<String, Object?> &&
      ledgerObject(payload['fee'])['account_id'] is String)
    ledgerObject(payload['fee'])['account_id'] as String,
};

List<FinancialPosting> _uniquePostings(List<FinancialPosting> values) {
  final entries = <String, FinancialPosting>{};
  for (final value in values) {
    entries['${value.accountId}/${value.component}'] = value;
  }
  return entries.values.toList();
}

final class _MoveBaseline {
  const _MoveBaseline(this.source, this.postings);
  final ConfirmedEntity source;
  final List<FinancialPosting> postings;
}

String _postingSignature(List<FinancialPosting> entries) {
  final keyed = <String, FinancialPosting>{};
  for (final entry in entries) {
    final key = '${entry.accountId}/${entry.component}';
    if (keyed.containsKey(key)) throw const DomainError('posting.duplicate');
    keyed[key] = entry;
  }
  return canonicalSyncJson([
    for (final key in keyed.keys.toList()..sort()) postingJson(keyed[key]!),
  ]);
}
