import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/config/data_space.dart';
import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../../domain/reporting/reporting.dart';
import '../local/app_database.dart';
import '../local/local_repository.dart';
import '../sync/tombstone_proof.dart';
import 'ledger_models.dart';
import 'ledger_projection.dart';

export '../../domain/reporting/reporting.dart'
    show ReportQuery, ReportResult, ReportTotals;

const _receiptTypes = {'refund', 'reimbursement'};

/// Reports the current authorized local intent, without fetching or valuing FX.
final class LedgerReportingService {
  LedgerReportingService(this.repository);
  final LocalRepository repository;
  AppDatabase get _db => repository.database;

  Future<ReportResult> read(
    DataSpace space,
    ReportQuery query, {
    String? budgetId,
  }) => _db.readSnapshot(() async {
    try {
      final projection = await _load(space);
      return _LocalReport(projection, query, budgetId).build();
    } on DomainError catch (error) {
      return ReportResult.unavailable(query, [error.code]);
    } on FormatException {
      return ReportResult.unavailable(query, ['report.invalid_data']);
    } on TypeError {
      return ReportResult.unavailable(query, ['report.invalid_data']);
    }
  });

  Stream<ReportResult> watch(
    DataSpace space,
    ReportQuery query, {
    String? budgetId,
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
      .asyncMap((_) => read(space, query, budgetId: budgetId));

  Future<LedgerProjection> _load(DataSpace space) async {
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
        settings: {for (final row in settings) row.key: row.value},
      ),
    );
  }
}

final class _LocalReport {
  _LocalReport(this.projection, this.query, this.budgetId);
  final LedgerProjection projection;
  final ReportQuery query;
  final String? budgetId;
  late final LedgerView view;
  late final Map<String, LedgerEntity> bills;
  late final Set<String> sources;

  bool _inPeriod(Map<String, Object?> payload) {
    final day = payload['business_date'];
    if (day is! String) throw const DomainError('report.invalid_data');
    return day.compareTo(query.startDate) >= 0 &&
        day.compareTo(query.endDateExclusive) < 0;
  }

  bool _needsRemaining(Map<String, Object?> payload) {
    final flags = ledgerObject(payload['flags']);
    return payload['bill_type'] == 'expense' &&
        _inPeriod(payload) &&
        !(flags['exclude_from_statistics'] == true &&
            flags['exclude_from_budget'] == true);
  }

  ReportResult build() {
    if (!projection.space.verified ||
        projection.rows.syncState == null ||
        projection.rows.syncState!.status != 'active') {
      throw const DomainError('report.sync_unavailable');
    }
    final book = projection.local[query.bookId];
    if (book == null ||
        book.entityType != 'book' ||
        book.deleted ||
        projection.revoked.contains(query.bookId) ||
        !{
          'owner',
          'editor',
          'viewer',
        }.contains(projection.roles[query.bookId])) {
      throw const DomainError('report.scope_unavailable');
    }
    final bookPayload = projection.payloads[query.bookId]!;
    if (bookPayload['currency'] != query.reportCurrency ||
        currencyScales[query.reportCurrency] != query.reportScale) {
      throw const DomainError('money.currency_mismatch');
    }
    for (final row in projection.rows.entities) {
      if (row.scopeId == query.bookId &&
          !row.deleted &&
          {'bill', 'category', 'budget'}.contains(row.entityType) &&
          !projection.local.containsKey(row.entityId)) {
        throw const DomainError('report.invalid_data');
      }
    }
    for (final row in projection.local.values) {
      if ((row.scopeId == query.bookId || row.entityId == query.bookId) &&
          {'book', 'category', 'bill', 'budget'}.contains(row.entityType) &&
          projection
              .operations(row.entityId)
              .any((op) => {'rejected', 'blocked'}.contains(op.state))) {
        throw const DomainError('report.local_conflict');
      }
    }
    view = projection.view(
      const LedgerQuery(includeArchived: true, includeDeleted: true),
    );
    bills = {
      for (final entity in view.bills)
        if (entity.scopeId == query.bookId && !entity.deleted)
          entity.id: entity,
    };
    sources = {
      for (final bill in bills.values)
        if (_needsRemaining(bill.payload)) bill.id,
    };
    final deltas = _allocationDeltas();
    final reports = <ReportBill>[];
    for (final bill in bills.values) {
      final payload = bill.payload;
      String? remaining;
      if (sources.contains(bill.id)) {
        remaining = _remaining(bill, deltas[bill.id] ?? BigInt.zero);
      }
      reports.add(
        ReportBill(
          id: bill.id,
          payload: payload,
          remainingAllocatableMinor: remaining,
          // Canonical remaining plus proven local deltas also supports hidden
          // foreign receipts. It does not prove their detailed split.
          hiddenAllocationCount:
              bill.projection['hidden_allocation_count'] as int? ?? 0,
        ),
      );
    }
    return buildReport(
      reports,
      query,
      categoryParents: _parents(),
      budget: _budget(),
    );
  }

  Map<String, String?> _parents() {
    final categories = {
      for (final entity in view.categories)
        if (entity.scopeId == query.bookId && !entity.deleted)
          entity.id: entity,
    };
    final result = <String, String?>{};
    for (final category in categories.values) {
      final parent = category.payload['parent_id'] as String?;
      if (parent != null && !categories.containsKey(parent)) {
        throw const DomainError('report.invalid_data');
      }
      result[category.id] = parent;
    }
    void check(Object? id) {
      if (id != null && (id is! String || !categories.containsKey(id))) {
        throw const DomainError('report.invalid_data');
      }
    }

    for (final bill in bills.values) {
      final payload = bill.payload;
      check(payload['category_id']);
      if (payload['fee'] != null) {
        check(ledgerObject(payload['fee'])['category_id']);
      }
    }
    return result;
  }

  ReportBudget? _budget() {
    final candidates = view.budgets.where((entity) {
      if (entity.scopeId != query.bookId) return false;
      if (budgetId != null) return entity.id == budgetId;
      final data = entity.payload;
      return data['period_start'] == query.startDate &&
          data['period_end_exclusive'] == query.endDateExclusive;
    }).toList();
    if (budgetId != null && candidates.isEmpty) {
      throw const DomainError('report.budget_unavailable');
    }
    if (candidates.length > 1) {
      throw const DomainError('report.budget_ambiguous');
    }
    if (candidates.isEmpty) return null;
    final selected = candidates.single;
    if (selected.conflicted) {
      throw const DomainError('report.local_conflict');
    }
    final payload = selected.payload;
    String amount(Object? raw) {
      final money = Money.fromJson(raw);
      if (money.minor.isNegative ||
          money.currency != query.reportCurrency ||
          money.currencyScale != query.reportScale) {
        throw const DomainError('budget.currency_mismatch');
      }
      return money.minor.toString();
    }

    final categories = <String, String>{};
    for (final raw in payload['categories'] as List) {
      final row = ledgerObject(raw), id = row['category_id'] as String;
      if (categories.containsKey(id) ||
          !view.categories.any(
            (entity) =>
                entity.id == id &&
                entity.scopeId == query.bookId &&
                !entity.deleted &&
                entity.payload['kind'] == 'expense',
          )) {
        throw const DomainError('report.invalid_data');
      }
      categories[id] = amount(row['limit']);
    }
    return ReportBudget(
      startDate: payload['period_start'] as String,
      endDateExclusive: payload['period_end_exclusive'] as String,
      totalLimitMinor: payload['total'] == null
          ? null
          : amount(payload['total']),
      categoryLimits: categories,
    );
  }

  Map<String, Object?>? _canonical(StoredEntity row) {
    final shadow = projection.shadow(row.scopeId, 'bill', row.entityId);
    if (shadow == null || shadow.deleted) return null;
    final data = ledgerObject(jsonDecode(shadow.dataJson));
    return data['projection_kind'] == 'bill_public' ? data : null;
  }

  Map<String, BigInt> _allocations(Map<String, Object?>? payload) {
    if (payload == null || !_receiptTypes.contains(payload['bill_type'])) {
      return {};
    }
    final values = <String, BigInt>{};
    for (final raw in payload['allocations'] as List? ?? []) {
      final row = ledgerObject(raw), source = row['source_bill_id'] as String;
      if (!sources.contains(source)) continue;
      if (values.containsKey(source)) {
        throw const DomainError('report.duplicate_allocation');
      }
      values[source] = parseMinor(row['source_amount_minor'], positive: true);
    }
    return values;
  }

  Map<String, BigInt> _allocationDeltas() {
    if (sources.isEmpty) return {};
    final deltas = <String, BigInt>{};
    for (final row in projection.local.values) {
      if (row.entityType != 'bill' ||
          !{
            'owner',
            'editor',
            'viewer',
          }.contains(projection.roles[row.scopeId])) {
        continue;
      }
      final operations = projection.operations(row.entityId);
      final pending = operations.any(
        (op) => mutableIntentStates.contains(op.state),
      );
      final current = row.deleted ? null : projection.payloads[row.entityId];
      final canonical = _canonical(row);
      final before = canonical == null
          ? <String, BigInt>{}
          : _allocations(normalizeLedgerPayload('bill', canonical));
      final after = _allocations(current);
      final shadow = projection.shadow(row.scopeId, 'bill', row.entityId);
      final bases = <Map<String, Object?>>[
        for (final op in operations)
          if (op.baseDataJson != null)
            ledgerObject(jsonDecode(op.baseDataJson!)),
      ];
      final baseAffected = bases.any(
        (base) => _allocations(normalizeLedgerPayload('bill', base)).isNotEmpty,
      );
      final foreignHidden =
          row.scopeId != query.bookId &&
          [
            ?canonical,
            ...bases,
          ].any((data) => (data['hidden_allocation_count'] as int? ?? 0) > 0);
      final hiddenPreserved =
          current?['preserve_hidden_financial_links'] == true;
      if (pending && foreignHidden && !hiddenPreserved) {
        throw const DomainError('report.allocations_incomplete');
      }
      if (before.isEmpty && after.isEmpty && !baseAffected) continue;
      if (operations.any((op) => {'rejected', 'blocked'}.contains(op.state)) ||
          pending && projection.roles[row.scopeId] == 'viewer') {
        throw const DomainError('report.local_conflict');
      }
      if (canonical == null && shadow != null && !shadow.deleted) {
        // An ACK freezes the submitted body but lacks derived source remaining.
        // Until canonical changes arrive there is no shared financial cut.
        throw const DomainError('report.allocation_stale');
      }
      if (canonical == null && shadow == null && !_newCreate(operations)) {
        throw const DomainError('report.allocations_incomplete');
      }
      for (final id in {...before.keys, ...after.keys}) {
        deltas[id] =
            (deltas[id] ?? BigInt.zero) +
            (after[id] ?? BigInt.zero) -
            (before[id] ?? BigInt.zero);
      }
    }
    return deltas;
  }

  bool _newCreate(List<StoredOperation> operations) => operations.any((op) {
    if (!{'queued', 'sending', 'retry'}.contains(op.state)) return false;
    final body = ledgerObject(jsonDecode(op.operationJson));
    return body['action'] == 'create' && body['base_revision'] == '0';
  });

  String _remaining(LedgerEntity bill, BigInt delta) {
    final row = projection.local[bill.id]!,
        current = Money.fromJson(bill.payload['money'], positive: true),
        canonical = _canonical(row),
        shadow = projection.shadow(row.scopeId, 'bill', row.entityId);
    BigInt allocated;
    if (canonical != null) {
      final payload = normalizeLedgerPayload('bill', canonical);
      if (payload['bill_type'] != 'expense') {
        allocated = BigInt.zero;
      } else {
        final old = Money.fromJson(payload['money'], positive: true),
            raw = canonical['remaining_allocatable_minor'];
        if (raw == null) {
          throw const DomainError('report.allocations_incomplete');
        }
        final remaining = parseMinor(raw);
        if (remaining.isNegative || remaining > old.minor) {
          throw const DomainError('report.allocation_stale');
        }
        allocated = old.minor - remaining;
        if (allocated != BigInt.zero &&
            (old.currency != current.currency ||
                old.currencyScale != current.currencyScale)) {
          throw const DomainError('money.currency_mismatch');
        }
      }
    } else if (shadow == null &&
        bill.revision == '0' &&
        _newCreate(projection.operations(bill.id))) {
      allocated = BigInt.zero;
    } else {
      throw const DomainError('report.allocations_incomplete');
    }
    allocated += delta;
    if (allocated.isNegative || allocated > current.minor) {
      throw const DomainError('report.allocation_stale');
    }
    return checkedMinor(current.minor - allocated).toString();
  }
}
