/// Deterministic projections over a caller-authorized complete visible dataset.
/// No database, clock, exchange-rate lookup or permission decision lives here.
library;

import 'dart:convert';

import '../../core/money/money.dart';
import '../ledger/calendar_rules.dart';

const uncategorizedReportCategory = 'uncategorized';
const _billTypes = {
  'income',
  'expense',
  'transfer',
  'credit_repayment',
  'loan_borrow',
  'loan_lend',
  'loan_collect',
  'loan_repay',
  'refund',
  'reimbursement',
  'balance_adjustment',
};

Map<String, Object?> _object(Object? value) {
  if (value is! Map) throw const DomainError('report.invalid_data');
  return value.cast<String, Object?>();
}

final class ReportBill {
  ReportBill({
    required this.id,
    required Map<String, Object?> payload,
    this.remainingAllocatableMinor,
    this.allocationsComplete = false,
    this.hiddenAllocationCount = 0,
  }) : _payload = jsonEncode(payload);
  final String id;
  final String? remainingAllocatableMinor;
  final bool allocationsComplete;
  final int hiddenAllocationCount;
  final String _payload;
  Map<String, Object?> get payload => _object(jsonDecode(_payload));
}

final class ReportQuery {
  ReportQuery({
    required this.bookId,
    required this.reportCurrency,
    required this.reportScale,
    required this.startDate,
    required this.endDateExclusive,
  }) {
    Money(reportCurrency, reportScale, BigInt.zero);
    if (!businessDate(startDate).isBefore(businessDate(endDateExclusive))) {
      throw const DomainError('date.invalid_period');
    }
  }
  factory ReportQuery.monthAt({
    required String bookId,
    required String currency,
    required int scale,
    required String day,
    int monthStartDay = 1,
  }) {
    final (start, end) = periodBounds(day, monthStartDay);
    return ReportQuery(
      bookId: bookId,
      reportCurrency: currency,
      reportScale: scale,
      startDate: start,
      endDateExclusive: end,
    );
  }
  final String bookId, reportCurrency, startDate, endDateExclusive;
  final int reportScale;
}

final class ReportBudget {
  ReportBudget({
    required this.startDate,
    required this.endDateExclusive,
    this.totalLimitMinor,
    Map<String, String> categoryLimits = const {},
  }) : categoryLimits = Map.unmodifiable(categoryLimits);
  final String startDate, endDateExclusive;
  final String? totalLimitMinor;
  final Map<String, String> categoryLimits;
}

final class ReportTotals {
  ReportTotals._(Map<String, Object?> values, String currency, int scale)
    : income = Money(currency, scale, parseMinor(values['income_minor'])),
      expense = Money(currency, scale, parseMinor(values['expense_minor'])),
      net = Money(currency, scale, parseMinor(values['net_minor'])),
      budgetEligible = Money(
        currency,
        scale,
        parseMinor(values['budget_eligible_minor']),
      ),
      grossExpense = Money(
        currency,
        scale,
        parseMinor(values['gross_expense_minor']),
      ),
      allocatedExpense = Money(
        currency,
        scale,
        parseMinor(values['allocated_expense_minor']),
      ),
      refund = values['refund_minor'] == null
          ? null
          : Money(currency, scale, parseMinor(values['refund_minor'])),
      reimbursement = values['reimbursement_minor'] == null
          ? null
          : Money(currency, scale, parseMinor(values['reimbursement_minor']));
  final Money income,
      expense,
      net,
      budgetEligible,
      grossExpense,
      allocatedExpense;
  final Money? refund, reimbursement;
}

final class ReportResult {
  ReportResult._(Map<String, Object?> data) : _encoded = jsonEncode(data);
  factory ReportResult.unavailable(ReportQuery query, Iterable<String> issues) {
    const allowed = {
      'report.scope_unavailable',
      'report.sync_unavailable',
      'report.local_conflict',
      'report.budget_unavailable',
      'report.allocations_incomplete',
      'report.source_unavailable',
      'report.allocation_stale',
      'report.category_cycle',
      'report.invalid_data',
      'report.duplicate_or_invalid_bill',
      'report.duplicate_allocation',
      'report.invalid_source',
      'report.invalid_allocation',
      'report.allocation_detail_unavailable',
      'report.budget_ambiguous',
      'allocation.exceeds_remaining',
      'fx.report_unavailable',
      'fx.amount_mismatch',
      'fx.rate_invalid',
      'money.out_of_range',
      'money.format',
      'money.must_be_positive',
      'money.currency_mismatch',
      'money.precision',
      'date.invalid',
      'date.out_of_range',
      'budget.period_mismatch',
      'budget.currency_mismatch',
      'budget.limit_required',
      'budget.overlapping_categories',
      'budget.total_below_categories',
    };
    final projected =
        issues
            .map(
              (code) => allowed.contains(code) ? code : 'report.invalid_data',
            )
            .toSet()
            .toList()
          ..sort();
    final data = _emptyReport(query);
    data['issues'] = projected.isEmpty ? ['report.invalid_data'] : projected;
    return ReportResult._(data);
  }
  final String _encoded;
  Map<String, Object?> toJson() => _object(jsonDecode(_encoded));
  bool get available => toJson()['available'] == true;
  bool get allocationBreakdownAvailable =>
      toJson()['allocation_breakdown_available'] == true;
  List<String> get issues =>
      List.unmodifiable((toJson()['issues'] as List).cast<String>());
  ReportTotals? get totals {
    final data = toJson(), values = data['totals'];
    return values == null
        ? null
        : ReportTotals._(
            _object(values),
            data['report_currency'] as String,
            data['report_scale'] as int,
          );
  }

  Map<String, String>? _categories(String key) {
    final value = toJson()[key];
    return value == null
        ? null
        : Map.unmodifiable((value as Map).cast<String, String>());
  }

  Map<String, String>? get categoryIncomeMinor =>
      _categories('category_income_minor');
  Map<String, String>? get categoryExpenseMinor =>
      _categories('category_expense_minor');
  Map<String, String>? get budgetCategoryExpenseMinor =>
      _categories('budget_category_expense_minor');
  Map<String, String>? get categoryExpenseRollupMinor =>
      _categories('category_expense_rollup_minor');
  Map<String, ReportTotals>? get calendar {
    final data = toJson(), days = data['calendar'];
    if (days == null) return null;
    return Map.unmodifiable(
      _object(days).map(
        (day, values) => MapEntry(
          day,
          ReportTotals._(
            _object(values),
            data['report_currency'] as String,
            data['report_scale'] as int,
          ),
        ),
      ),
    );
  }

  Map<String, Object?>? get budget {
    final value = toJson()['budget'];
    return value == null ? null : _object(value);
  }
}

BigInt _amount(Map<String, Object?> payload, ReportQuery query) {
  final source = Money.fromJson(payload['money'], positive: true);
  if (source.currency == query.reportCurrency &&
      source.currencyScale == query.reportScale) {
    return source.minor;
  }
  final raw = payload['reporting'];
  if (raw is! Map ||
      (raw['report_currency'] ?? query.reportCurrency) !=
          query.reportCurrency ||
      (raw['report_scale'] ?? query.reportScale) != query.reportScale) {
    throw const DomainError('fx.report_unavailable');
  }
  final value = parseMinor(raw['report_amount_minor']);
  final rate = raw['rate'];
  if (rate is! String) throw const DomainError('fx.rate_invalid');
  if (convertMoney(
        source,
        rate,
        query.reportCurrency,
        query.reportScale,
      ).minor !=
      value) {
    throw const DomainError('fx.amount_mismatch');
  }
  if (value.isNegative) throw const DomainError('money.must_be_positive');
  return value;
}

(bool, bool) _flags(
  Map<String, Object?> payload, [
  Map<String, Object?>? fallback,
]) {
  final value = _object(
    payload.containsKey('flags')
        ? payload['flags']
        : fallback ?? <String, Object?>{},
  );
  final statistics = value['exclude_from_statistics'] ?? false,
      budget = value['exclude_from_budget'] ?? false;
  if (statistics is! bool || budget is! bool) {
    throw const DomainError('report.invalid_data');
  }
  return (statistics, budget);
}

String _category(Object? value) {
  if (value == null) return uncategorizedReportCategory;
  if (value is! String || value.isEmpty) {
    throw const DomainError('report.invalid_data');
  }
  return value;
}

List<String> _ancestors(String category, Map<String, String?> parents) {
  final values = <String>[], seen = <String>{};
  String? current = category;
  while (current != null) {
    if (seen.contains(current) || values.length >= 100) {
      throw const DomainError('report.category_cycle');
    }
    seen.add(current);
    values.add(current);
    final parent = parents[current];
    if (parent != null && parent.isEmpty) {
      throw const DomainError('report.invalid_data');
    }
    current = parent;
  }
  return values;
}

void _add(Map<String, BigInt> values, String key, BigInt amount) {
  if (amount != BigInt.zero) {
    values[key] = (values[key] ?? BigInt.zero) + amount;
  }
}

Map<String, String> _strings(Map<String, BigInt> values) => {
  for (final key in values.keys.toList()..sort())
    if (values[key] != BigInt.zero) key: checkedMinor(values[key]!).toString(),
};

Map<String, BigInt> _totals() => {
  for (final key in [
    'income_minor',
    'expense_minor',
    'net_minor',
    'budget_eligible_minor',
    'gross_expense_minor',
    'allocated_expense_minor',
    'refund_minor',
    'reimbursement_minor',
  ])
    key: BigInt.zero,
};

Map<String, String?> _serializeTotals(
  Map<String, BigInt> values,
  bool breakdown,
) => {
  for (final entry in values.entries)
    entry.key:
        !breakdown &&
            {'refund_minor', 'reimbursement_minor'}.contains(entry.key)
        ? null
        : checkedMinor(entry.value).toString(),
};

BigInt _sum(Iterable<BigInt> values) =>
    values.fold(BigInt.zero, (sum, value) => sum + value);

Map<String, Object?> _budgetResult(
  ReportBudget config,
  ReportQuery query,
  Map<String, BigInt> categories,
  Map<String, String?> parents,
) {
  if (config.startDate != query.startDate ||
      config.endDateExclusive != query.endDateExclusive) {
    throw const DomainError('budget.period_mismatch');
  }
  final limits = config.categoryLimits.map(
    (key, value) => MapEntry(key, parseMinor(value)),
  );
  final total = config.totalLimitMinor == null
      ? null
      : parseMinor(config.totalLimitMinor);
  if (limits.values.any((value) => value.isNegative) ||
      (total?.isNegative ?? false)) {
    throw const DomainError('money.must_be_positive');
  }
  if (total == null && limits.isEmpty) {
    throw const DomainError('budget.limit_required');
  }
  for (final category in limits.keys) {
    if (_ancestors(category, parents).skip(1).any(limits.containsKey)) {
      throw const DomainError('budget.overlapping_categories');
    }
  }
  final subtotal = checkedMinor(_sum(limits.values));
  if (total != null && total < subtotal) {
    throw const DomainError('budget.total_below_categories');
  }
  final ceiling = total ?? subtotal;
  final allCategories = limits.isEmpty || (total != null && total > subtotal);
  final grouped = {for (final category in limits.keys) category: BigInt.zero};
  var other = BigInt.zero;
  for (final entry in categories.entries) {
    String? group;
    for (final parent in _ancestors(entry.key, parents)) {
      if (limits.containsKey(parent)) {
        group = parent;
        break;
      }
    }
    if (group == null) {
      other += entry.value;
    } else {
      grouped[group] = grouped[group]! + entry.value;
    }
  }
  final spent = checkedMinor(
    _sum(allCategories ? categories.values : grouped.values),
  );
  return {
    'limit_minor': ceiling.toString(),
    'spent_minor': spent.toString(),
    'remaining_minor': checkedMinor(ceiling - spent).toString(),
    'includes_other_categories': allCategories,
    'other_limit_minor': total != null && limits.isNotEmpty && total > subtotal
        ? (ceiling - subtotal).toString()
        : null,
    'other_spent_minor': allCategories ? checkedMinor(other).toString() : null,
    'categories': {
      for (final category in limits.keys.toList()..sort())
        category: {
          'limit_minor': limits[category].toString(),
          'spent_minor': checkedMinor(grouped[category]!).toString(),
          'remaining_minor': checkedMinor(
            limits[category]! - grouped[category]!,
          ).toString(),
        },
    },
  };
}

final class _Allocation {
  _Allocation(this.date, this.id, this.kind, this.amount);
  final String date, id, kind;
  final BigInt amount;
}

/// No partial numbers are published when an amount or its provenance is missing.
/// An authoritative remaining value must already reflect any local allocation
/// edits/deletions. An old server projection is not such evidence.
ReportResult buildReport(
  Iterable<ReportBill> bills,
  ReportQuery query, {
  Map<String, String?> categoryParents = const {},
  ReportBudget? budget,
}) {
  final result = _emptyReport(query);
  try {
    _build(bills.toList(), query, Map.of(categoryParents), budget, result);
  } on DomainError catch (error) {
    result['issues'] = [error.code];
  } on TypeError {
    result['issues'] = ['report.invalid_data'];
  } on FormatException {
    result['issues'] = ['report.invalid_data'];
  }
  return ReportResult._(result);
}

Map<String, Object?> _emptyReport(ReportQuery query) => <String, Object?>{
  'version': 1,
  'book_id': query.bookId,
  'report_currency': query.reportCurrency,
  'report_scale': query.reportScale,
  'start_date': query.startDate,
  'end_date_exclusive': query.endDateExclusive,
  'available': false,
  'issues': <String>[],
  'allocation_breakdown_available': false,
  'totals': null,
  'category_income_minor': null,
  'category_expense_minor': null,
  'budget_category_expense_minor': null,
  'category_income_rollup_minor': null,
  'category_expense_rollup_minor': null,
  'budget_category_rollup_minor': null,
  'calendar': null,
  'budget': null,
};

void _build(
  List<ReportBill> bills,
  ReportQuery query,
  Map<String, String?> parents,
  ReportBudget? budget,
  Map<String, Object?> result,
) {
  final rows = <String, ReportBill>{};
  for (final row in bills) {
    if (row.id.isEmpty || rows.containsKey(row.id)) {
      throw const DomainError('report.duplicate_or_invalid_bill');
    }
    if (row.hiddenAllocationCount < 0) {
      throw const DomainError('report.invalid_data');
    }
    rows[row.id] = row;
  }
  for (final category in parents.keys) {
    _ancestors(category, parents);
  }
  final allocations = <String, List<_Allocation>>{};
  var breakdown = true;
  for (final row in rows.values) {
    final payload = row.payload;
    if (!_billTypes.contains(payload['bill_type'])) {
      throw const DomainError('report.invalid_data');
    }
    businessDate(payload['business_date']);
    Money.fromJson(payload['money'], positive: true);
    if (!{'refund', 'reimbursement'}.contains(payload['bill_type'])) continue;
    if (row.hiddenAllocationCount > 0) breakdown = false;
    final seen = <String>{};
    var received = BigInt.zero;
    final allocationRows = payload.containsKey('allocations')
        ? payload['allocations'] as List
        : <Object?>[];
    for (final raw in allocationRows) {
      final allocation = _object(raw),
          sourceId = allocation['source_bill_id'] as String;
      if (!seen.add(sourceId)) {
        throw const DomainError('report.duplicate_allocation');
      }
      final source = rows[sourceId];
      if (source == null) throw const DomainError('report.source_unavailable');
      if (source.payload['bill_type'] != 'expense') {
        throw const DomainError('report.invalid_source');
      }
      final amount = parseMinor(
        allocation['source_amount_minor'],
        positive: true,
      );
      received += parseMinor(
        allocation['receipt_amount_minor'],
        positive: true,
      );
      allocations
          .putIfAbsent(sourceId, () => [])
          .add(
            _Allocation(
              payload['business_date'] as String,
              row.id,
              payload['bill_type'] as String,
              amount,
            ),
          );
    }
    final component = parseMinor(payload['income_component_minor'] ?? '0');
    final receiptAmount = Money.fromJson(
      payload['money'],
      positive: true,
    ).minor;
    if (component.isNegative ||
        (payload['bill_type'] == 'reimbursement' && component != BigInt.zero) ||
        received + component > receiptAmount ||
        (row.hiddenAllocationCount == 0 &&
            received + component != receiptAmount)) {
      throw const DomainError('report.invalid_allocation');
    }
  }

  final totals = _totals(), days = <String, Map<String, BigInt>>{};
  final incomeCategories = <String, BigInt>{},
      expenseCategories = <String, BigInt>{},
      budgetCategories = <String, BigInt>{};
  for (final row in rows.values) {
    final payload = row.payload, day = payload['business_date'] as String;
    if (payload['book_id'] != query.bookId ||
        day.compareTo(query.startDate) < 0 ||
        day.compareTo(query.endDateExclusive) >= 0) {
      continue;
    }
    final kind = payload['bill_type'];
    final (statisticsExcluded, budgetExcluded) = _flags(payload);
    final contributions = _totals(),
        category = _category(payload['category_id']);
    if (kind == 'income' && !statisticsExcluded) {
      contributions['income_minor'] = _amount(payload, query);
    } else if (kind == 'refund' && !statisticsExcluded) {
      final component = parseMinor(payload['income_component_minor'] ?? '0');
      final original = Money.fromJson(payload['money'], positive: true).minor;
      if (component.isNegative || component > original) {
        throw const DomainError('allocation.exceeds_remaining');
      }
      if (component > BigInt.zero) {
        contributions['income_minor'] = roundHalfUp(
          _amount(payload, query) * component,
          original,
        );
      }
    } else if (kind == 'expense' && !(statisticsExcluded && budgetExcluded)) {
      final original = Money.fromJson(payload['money'], positive: true).minor;
      final report = _amount(payload, query);
      final linked = List<_Allocation>.from(allocations[row.id] ?? [])
        ..sort((a, b) {
          final date = a.date.compareTo(b.date);
          return date == 0 ? a.id.compareTo(b.id) : date;
        });
      final visible = _sum(linked.map((item) => item.amount));
      BigInt allocated;
      if (row.remainingAllocatableMinor != null) {
        final remaining = parseMinor(row.remainingAllocatableMinor);
        if (remaining.isNegative || remaining > original) {
          throw const DomainError('allocation.exceeds_remaining');
        }
        allocated = original - remaining;
        if (visible > allocated ||
            (row.allocationsComplete && visible != allocated)) {
          throw const DomainError('report.allocation_stale');
        }
      } else if (row.allocationsComplete) {
        allocated = visible;
      } else {
        throw const DomainError('report.allocations_incomplete');
      }
      if (allocated.isNegative || allocated > original) {
        throw const DomainError('allocation.exceeds_remaining');
      }
      final reduction = roundHalfUp(report * allocated, original),
          net = report - reduction;
      var refund = BigInt.zero,
          reimbursement = BigInt.zero,
          prefix = BigInt.zero;
      for (final item in linked) {
        final delta =
            roundHalfUp(report * (prefix + item.amount), original) -
            roundHalfUp(report * prefix, original);
        if (item.kind == 'refund') {
          refund += delta;
        } else {
          reimbursement += delta;
        }
        prefix += item.amount;
      }
      if (visible != allocated) breakdown = false;
      if (!statisticsExcluded) {
        contributions.addAll({
          'expense_minor': net,
          'gross_expense_minor': report,
          'allocated_expense_minor': reduction,
          'refund_minor': refund,
          'reimbursement_minor': reimbursement,
        });
        _add(expenseCategories, category, net);
      }
      if (!budgetExcluded) {
        contributions['budget_eligible_minor'] = net;
        _add(budgetCategories, category, net);
      }
    }
    if (contributions['income_minor'] != BigInt.zero) {
      _add(incomeCategories, category, contributions['income_minor']!);
    }
    final feeRaw = payload['fee'];
    if (feeRaw != null) {
      final fee = _object(feeRaw);
      final (feeStatistics, feeBudget) = _flags(
        fee,
        payload['flags'] == null ? null : _object(payload['flags']),
      );
      if (!(feeStatistics && feeBudget)) {
        final amount = _amount(fee, query),
            feeCategory = _category(fee['category_id']);
        if (!feeStatistics) {
          contributions['expense_minor'] =
              contributions['expense_minor']! + amount;
          contributions['gross_expense_minor'] =
              contributions['gross_expense_minor']! + amount;
          _add(expenseCategories, feeCategory, amount);
        }
        if (!feeBudget) {
          contributions['budget_eligible_minor'] =
              contributions['budget_eligible_minor']! + amount;
          _add(budgetCategories, feeCategory, amount);
        }
      }
    }
    contributions['net_minor'] =
        contributions['income_minor']! - contributions['expense_minor']!;
    if (contributions.values.any((value) => value != BigInt.zero)) {
      final daily = days.putIfAbsent(day, _totals);
      for (final entry in contributions.entries) {
        totals[entry.key] = totals[entry.key]! + entry.value;
        daily[entry.key] = daily[entry.key]! + entry.value;
      }
    }
  }
  Map<String, String> rollup(Map<String, BigInt> values) {
    final rolled = <String, BigInt>{};
    for (final entry in values.entries) {
      for (final parent in _ancestors(entry.key, parents)) {
        _add(rolled, parent, entry.value);
      }
    }
    return _strings(rolled);
  }

  final prepared = <String, Object?>{
    'totals': _serializeTotals(totals, breakdown),
    'category_income_minor': _strings(incomeCategories),
    'category_expense_minor': _strings(expenseCategories),
    'budget_category_expense_minor': _strings(budgetCategories),
    'category_income_rollup_minor': rollup(incomeCategories),
    'category_expense_rollup_minor': rollup(expenseCategories),
    'budget_category_rollup_minor': rollup(budgetCategories),
    'calendar': {
      for (final day in days.keys.toList()..sort())
        day: _serializeTotals(days[day]!, breakdown),
    },
    'budget': budget == null
        ? null
        : _budgetResult(budget, query, budgetCategories, parents),
  };
  result.addAll(prepared);
  result.addAll({
    'available': true,
    'allocation_breakdown_available': breakdown,
    'issues': breakdown ? <String>[] : ['report.allocation_detail_unavailable'],
  });
}
