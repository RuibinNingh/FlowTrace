import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../ledger/calendar_rules.dart';

/// Already-authorized account balances; this calculator grants no access.
final class AssetPosition {
  const AssetPosition({
    required this.id,
    required this.balance,
    this.includeInNetAssets = true,
    this.hidden = false,
    this.kind = 'cash',
  });
  final String id;
  final Money? balance;
  final bool includeInNetAssets, hidden;
  final String kind;
}

/// A direct manual quote: one source major unit equals [rate] target units.
final class AssetValuationRate {
  const AssetValuationRate({
    required this.fromCurrency,
    required this.toCurrency,
    required this.effectiveDate,
    required this.rate,
    this.source = 'manual',
  });
  final String fromCurrency, toCurrency, effectiveDate, rate, source;
}

final class AssetTotals {
  AssetTotals._({
    required this.currency,
    required this.asOfDate,
    required this.available,
    this.assets,
    this.liabilities,
    this.net,
    this.borrowed,
    this.lent,
    List<String> issues = const [],
    Map<String, Money> convertedBalances = const {},
    Map<String, AssetValuationRate> usedRates = const {},
  }) : issues = List.unmodifiable(issues),
       convertedBalances = Map.unmodifiable(convertedBalances),
       usedRates = Map.unmodifiable(usedRates);
  final String currency, asOfDate;
  final bool available;
  final Money? assets, liabilities, net, borrowed, lent;
  final List<String> issues;
  final Map<String, Money> convertedBalances;
  final Map<String, AssetValuationRate> usedRates;
}

/// Provided balances valued using the selected explicit direct-quote policy.
/// Missing balances or rates never become zero or a partial grand total.
/// Hidden accounts still contribute; explicit includeInNetAssets controls that.
AssetTotals valueAssetPositions(
  List<AssetPosition> positions, {
  required String currency,
  required String asOfDate,
  Iterable<AssetValuationRate> rates = const [],
  String valuationPolicy = 'exact_date',
}) {
  AssetTotals unavailable(Iterable<String> issues) => AssetTotals._(
    currency: currency,
    asOfDate: asOfDate,
    available: false,
    issues: issues.toSet().toList()..sort(),
  );
  try {
    businessDate(asOfDate);
    if (!{'exact_date', 'latest_on_or_before'}.contains(valuationPolicy)) {
      throw const DomainError('assets.invalid_policy');
    }
    final scale = currencyScales[currency];
    if (scale == null) throw const DomainError('currency.unsupported');
    final quotes = <String, AssetValuationRate>{};
    final requiredCurrencies = {
      for (final position in positions)
        if (position.includeInNetAssets &&
            position.balance != null &&
            position.balance!.minor != BigInt.zero &&
            position.balance!.currency != currency)
          position.balance!.currency,
    };
    final ambiguous = <String>{};
    for (final quote in rates) {
      if (quote.toCurrency != currency ||
          !requiredCurrencies.contains(quote.fromCurrency)) {
        continue;
      }
      businessDate(quote.effectiveDate);
      parseRate(quote.rate);
      if (quote.effectiveDate.compareTo(asOfDate) > 0) continue;
      if (valuationPolicy == 'exact_date' && quote.effectiveDate != asOfDate) {
        continue;
      }
      final previous = quotes[quote.fromCurrency];
      if (previous == null ||
          previous.effectiveDate.compareTo(quote.effectiveDate) < 0) {
        quotes[quote.fromCurrency] = quote;
        ambiguous.remove(quote.fromCurrency);
      } else if (previous.effectiveDate == quote.effectiveDate) {
        ambiguous.add(quote.fromCurrency);
      }
    }
    final seen = <String>{}, issues = <String>{}, converted = <String, Money>{};
    var positive = BigInt.zero,
        negative = BigInt.zero,
        borrowed = BigInt.zero,
        lent = BigInt.zero;
    for (final position in positions) {
      if (position.id.isEmpty || !seen.add(position.id)) {
        return unavailable(['assets.invalid_data']);
      }
      if (!position.includeInNetAssets) continue;
      final balance = position.balance;
      if (balance == null) {
        issues.add('assets.balance_unavailable');
        continue;
      }
      if (currencyScales[balance.currency] != balance.currencyScale) {
        issues.add('assets.currency_mismatch');
        continue;
      }
      final Money amount;
      if (balance.minor == BigInt.zero) {
        amount = Money(currency, scale, BigInt.zero);
      } else if (balance.currency == currency) {
        amount = balance;
      } else if (ambiguous.contains(balance.currency)) {
        issues.add('assets.ambiguous_rate');
        continue;
      } else {
        final quote = quotes[balance.currency];
        if (quote == null) {
          issues.add('assets.rate_required');
          continue;
        }
        amount = convertMoney(balance, quote.rate, currency, scale);
      }
      converted[position.id] = amount;
      if (amount.minor.isNegative) {
        negative -= amount.minor;
        if (position.kind == 'loan_payable') borrowed -= amount.minor;
      } else {
        positive += amount.minor;
        if (position.kind == 'loan_receivable') lent += amount.minor;
      }
    }
    if (issues.isNotEmpty) return unavailable(issues);
    return AssetTotals._(
      currency: currency,
      asOfDate: asOfDate,
      available: true,
      assets: Money(currency, scale, checkedMinor(positive)),
      liabilities: Money(currency, scale, checkedMinor(negative)),
      net: Money(currency, scale, checkedMinor(positive - negative)),
      borrowed: Money(currency, scale, checkedMinor(borrowed)),
      lent: Money(currency, scale, checkedMinor(lent)),
      convertedBalances: converted,
      usedRates: quotes,
    );
  } on DomainError catch (error) {
    return unavailable([
      switch (error.code) {
        'money.out_of_range' => 'assets.out_of_range',
        'fx.rate_invalid' => 'assets.rate_invalid',
        _ => 'assets.invalid_data',
      },
    ]);
  }
}
