import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../../domain/ledger/postings.dart';
import '../../domain/ledger/timezone_rules.dart';
import 'ledger_models.dart';

/// An immutable local query. Dates are business-date half-open bounds, and
/// monetary bounds always name one currency through Money or [currency].
final class BillFilter {
  BillFilter({
    this.fromDate,
    this.endDateExclusive,
    Set<String>? bookIds,
    this.keyword = '',
    Set<String>? categoryIds,
    this.includeDescendants = true,
    Set<String>? tagIds,
    this.allTags = false,
    this.currency,
    this.minAmount,
    this.maxAmount,
    this.hasAttachments,
    this.hasTags,
    this.hasAccount,
    Set<String>? sources,
    Set<String>? types,
    this.excludeFromStatistics,
    this.excludeFromBudget,
  }) : bookIds = bookIds == null ? null : Set.unmodifiable(bookIds),
       categoryIds = categoryIds == null ? null : Set.unmodifiable(categoryIds),
       tagIds = tagIds == null ? null : Set.unmodifiable(tagIds),
       sources = sources == null ? null : Set.unmodifiable(sources),
       types = types == null ? null : Set.unmodifiable(types) {
    final start = fromDate == null ? null : businessDate(fromDate);
    final end = endDateExclusive == null
        ? null
        : businessDate(endDateExclusive);
    if (start != null && end != null && !start.isBefore(end)) {
      throw const DomainError('query.invalid_dates');
    }
    final currencies = <String?>{
      currency,
      minAmount?.currency,
      maxAmount?.currency,
    }..remove(null);
    if (currencies.length > 1) {
      throw const DomainError('query.mixed_amount_currencies');
    }
    for (final value in [minAmount, maxAmount]) {
      if (value != null &&
          (value.minor < BigInt.zero ||
              currencyScales[value.currency] != value.currencyScale)) {
        throw const DomainError('query.invalid_amount');
      }
    }
    if (currency != null && !currencyScales.containsKey(currency)) {
      throw const DomainError('currency.unsupported');
    }
    if (minAmount != null &&
        maxAmount != null &&
        minAmount!.minor > maxAmount!.minor) {
      throw const DomainError('query.invalid_amount_range');
    }
    if (sources != null &&
        sources.any(
          (value) => !{
            'manual',
            'import',
            'recurring',
            'installment',
            'auto',
          }.contains(value),
        )) {
      throw const DomainError('query.invalid_source');
    }
    if (types != null &&
        types.any(
          (value) =>
              !singleAccountBillTypes.contains(value) &&
              !twoAccountBillTypes.contains(value),
        )) {
      throw const DomainError('query.invalid_type');
    }
  }
  final String? fromDate, endDateExclusive, currency;
  final String keyword;
  final Set<String>? bookIds, categoryIds, tagIds, sources, types;
  final bool includeDescendants, allTags;
  final Money? minAmount, maxAmount;
  final bool? hasAttachments,
      hasTags,
      hasAccount,
      excludeFromStatistics,
      excludeFromBudget;
  String? get amountCurrency =>
      currency ?? minAmount?.currency ?? maxAmount?.currency;
}

/// Nominal selected amounts, including transfers and receipts. This is
/// intentionally distinct from net spending, budget use or account cashflow.
final class BillQueryCurrencyTotals {
  BillQueryCurrencyTotals({
    required this.count,
    required this.nominalAmount,
    required Map<String, Money?> byType,
    this.issue,
  }) : byType = Map.unmodifiable(byType);
  final int count;
  final Money? nominalAmount;
  final Map<String, Money?> byType;
  final String? issue;
}

final class BillQueryResult {
  BillQueryResult({
    required List<LedgerEntity> bills,
    required Map<String, BillQueryCurrencyTotals> totalsByCurrency,
    required Map<String, String> issues,
  }) : bills = List.unmodifiable(bills),
       ids = List.unmodifiable(bills.map((bill) => bill.id)),
       totalsByCurrency = Map.unmodifiable(totalsByCurrency),
       issues = Map.unmodifiable(issues);
  final List<LedgerEntity> bills;
  final List<String> ids;
  Set<String> get idSet => Set.unmodifiable(ids);
  final Map<String, BillQueryCurrencyTotals> totalsByCurrency;
  final Map<String, String> issues;
  Set<String> get unavailableIds => Set.unmodifiable(issues.keys);
}

BillQueryResult queryBills(LedgerView view, {BillFilter? filter}) {
  final query = filter ?? BillFilter();
  final matches = <LedgerEntity>[], issues = <String, String>{};
  bool selected(LedgerEntity bill, Money amount) {
    final data = bill.payload;
    final date = data['business_date'];
    businessDate(date);
    if (query.bookIds != null && !query.bookIds!.contains(bill.scopeId)) {
      return false;
    }
    if (query.fromDate != null &&
            (date as String).compareTo(query.fromDate!) < 0 ||
        query.endDateExclusive != null &&
            (date as String).compareTo(query.endDateExclusive!) >= 0) {
      return false;
    }
    if (query.types != null && !query.types!.contains(data['bill_type'])) {
      return false;
    }
    if (query.sources != null && !query.sources!.contains(data['source'])) {
      return false;
    }
    if (!singleAccountBillTypes.contains(data['bill_type']) &&
        !twoAccountBillTypes.contains(data['bill_type'])) {
      throw const DomainError('query.invalid_type');
    }
    if (data['occurred_at'] != null &&
        instantBusinessDate(
              data['occurred_at'] as String,
              data['business_timezone'] as String,
            ) !=
            date) {
      throw const DomainError('query.invalid_time');
    }
    if (query.amountCurrency != null &&
        amount.currency != query.amountCurrency) {
      return false;
    }
    if (query.minAmount != null && amount.minor < query.minAmount!.minor ||
        query.maxAmount != null && amount.minor > query.maxAmount!.minor) {
      return false;
    }
    final tags = (data['tag_ids'] as List).cast<String>();
    if (query.hasTags != null && tags.isNotEmpty != query.hasTags) return false;
    if (query.tagIds != null &&
        (query.tagIds!.isEmpty ||
            (query.allTags
                ? !query.tagIds!.every(tags.contains)
                : !tags.any(query.tagIds!.contains)))) {
      return false;
    }
    final pictures = (data['attachment_ids'] as List).isNotEmpty;
    if (query.hasAttachments != null && pictures != query.hasAttachments) {
      return false;
    }
    final hasAccount =
        [
          'account_id',
          'from_account_id',
          'to_account_id',
        ].any((field) => data[field] != null) ||
        (bill.projection['hidden_account_fields'] as List? ?? []).isNotEmpty;
    if (query.hasAccount != null && hasAccount != query.hasAccount) {
      return false;
    }
    final flags = ledgerObject(data['flags']);
    if (flags['exclude_from_statistics'] is! bool ||
        flags['exclude_from_budget'] is! bool) {
      throw const DomainError('query.invalid_flags');
    }
    if (query.excludeFromStatistics != null &&
            flags['exclude_from_statistics'] != query.excludeFromStatistics ||
        query.excludeFromBudget != null &&
            flags['exclude_from_budget'] != query.excludeFromBudget) {
      return false;
    }
    if (query.categoryIds != null) {
      String? cursor = data['category_id'] as String?;
      var found = false;
      final seen = <String>{};
      while (cursor != null && seen.add(cursor)) {
        if (query.categoryIds!.contains(cursor)) {
          found = true;
          break;
        }
        if (!query.includeDescendants) break;
        final definition = view.find('category', cursor);
        if (definition == null) {
          throw const DomainError('query.category_unavailable');
        }
        cursor = definition.payload['parent_id'] as String?;
      }
      if (!found) return false;
    }
    final keyword = query.keyword.trim().toLowerCase();
    if (keyword.isNotEmpty) {
      final text = <String>[
        data['note'] as String? ?? '',
        amount.display(),
        amount.currency,
      ];
      var missing = false;
      String? category = data['category_id'] as String?;
      final seen = <String>{};
      while (category != null && seen.add(category)) {
        final definition = view.find('category', category);
        if (definition == null) {
          missing = true;
          break;
        }
        text.add(definition.name);
        category = definition.payload['parent_id'] as String?;
      }
      for (final id in tags) {
        final tag = view.find('tag', id);
        if (tag == null) {
          missing = true;
        } else {
          text.add(tag.name);
        }
      }
      if (!text.any((value) => value.toLowerCase().contains(keyword))) {
        if (missing) {
          throw const DomainError('query.search_metadata_unavailable');
        }
        return false;
      }
    }
    return true;
  }

  for (final bill in view.bills.where((bill) => !bill.deleted)) {
    try {
      final amount = Money.fromJson(bill.payload['money'], positive: true);
      if (currencyScales[amount.currency] != amount.currencyScale) {
        throw const DomainError('currency.unsupported');
      }
      if (selected(bill, amount)) matches.add(bill);
    } on DomainError catch (error) {
      issues[bill.id] = error.code;
    } on Object {
      issues[bill.id] = 'query.invalid_bill';
    }
  }
  matches.sort((a, b) {
    var order = (b.payload['business_date'] as String).compareTo(
      a.payload['business_date'] as String,
    );
    if (order != 0) return order;
    final left = a.payload['occurred_at'] as String?,
        right = b.payload['occurred_at'] as String?;
    if (left != null && right != null) {
      order = DateTime.parse(right).compareTo(DateTime.parse(left));
    } else if (left != null || right != null) {
      order = left == null ? 1 : -1;
    }
    return order != 0 ? order : a.id.compareTo(b.id);
  });
  final sums = <String, BigInt>{},
      counts = <String, int>{},
      kinds = <String, Map<String, BigInt>>{};
  for (final bill in matches) {
    final amount = Money.fromJson(bill.payload['money']);
    sums.update(
      amount.currency,
      (sum) => sum + amount.minor,
      ifAbsent: () => amount.minor,
    );
    counts.update(amount.currency, (count) => count + 1, ifAbsent: () => 1);
    kinds
        .putIfAbsent(amount.currency, () => {})
        .update(
          bill.payload['bill_type'] as String,
          (sum) => sum + amount.minor,
          ifAbsent: () => amount.minor,
        );
  }
  final totals = <String, BillQueryCurrencyTotals>{};
  for (final currency in sums.keys.toList()..sort()) {
    Money? exact(BigInt sum) {
      try {
        return Money(currency, currencyScales[currency]!, sum);
      } on DomainError {
        return null;
      }
    }

    final total = exact(sums[currency]!);
    totals[currency] = BillQueryCurrencyTotals(
      count: counts[currency]!,
      nominalAmount: total,
      byType: {
        for (final entry in kinds[currency]!.entries)
          entry.key: exact(entry.value),
      },
      issue: total == null ? 'query.total_overflow' : null,
    );
  }
  return BillQueryResult(
    bills: matches,
    totalsByCurrency: totals,
    issues: issues,
  );
}
