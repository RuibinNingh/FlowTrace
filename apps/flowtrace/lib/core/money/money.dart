/// Exact money primitives shared by native and browser clients.
/// Monetary values never pass through double or JavaScript Number.
library;

final BigInt int64Min = BigInt.parse('-9223372036854775808');
final BigInt int64Max = BigInt.parse('9223372036854775807');
const maxReferenceOccurrences = 10000;
final _minorPattern = RegExp(r'^(?:0|-?[1-9][0-9]*)$');
final _displayPattern = RegExp(r'^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?$');
final _ratePattern = RegExp(r'^(?:0|[1-9][0-9]*)(?:\.[0-9]{1,18})?$');

class DomainError implements Exception {
  const DomainError(this.code);
  final String code;
  @override
  String toString() => code;
}

BigInt checkedMinor(BigInt value) {
  if (value < int64Min || value > int64Max) {
    throw const DomainError('money.out_of_range');
  }
  return value;
}

BigInt parseMinor(Object? value, {bool positive = false}) {
  if (value is! String || !_minorPattern.hasMatch(value)) {
    throw const DomainError('money.format');
  }
  if (value.replaceFirst('-', '').length > 19) {
    throw const DomainError('money.out_of_range');
  }
  final amount = checkedMinor(BigInt.parse(value));
  if (positive && amount <= BigInt.zero) {
    throw const DomainError('money.must_be_positive');
  }
  return amount;
}

int validateScale(Object? value) {
  if (value is! int || value < 0 || value > 6) {
    throw const DomainError('money.precision');
  }
  return value;
}

class Money {
  Money(this.currency, this.currencyScale, BigInt minor)
    : minor = checkedMinor(minor) {
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      throw const DomainError('money.currency_mismatch');
    }
    validateScale(currencyScale);
  }

  factory Money.fromJson(Object? value, {bool positive = false}) {
    if (value is! Map ||
        value.length != 3 ||
        !value.containsKey('currency') ||
        !value.containsKey('currency_scale') ||
        !value.containsKey('amount_minor')) {
      throw const DomainError('money.format');
    }
    final currency = value['currency'];
    if (currency is! String) {
      throw const DomainError('money.currency_mismatch');
    }
    return Money(
      currency,
      validateScale(value['currency_scale']),
      parseMinor(value['amount_minor'], positive: positive),
    );
  }

  final String currency;
  final int currencyScale;
  final BigInt minor;

  Map<String, Object> toJson() => {
    'currency': currency,
    'currency_scale': currencyScale,
    'amount_minor': minor.toString(),
  };

  Money plus(Money other) {
    if (currency != other.currency || currencyScale != other.currencyScale) {
      throw const DomainError('money.currency_mismatch');
    }
    return Money(currency, currencyScale, checkedMinor(minor + other.minor));
  }

  String display() {
    final sign = minor.isNegative ? '-' : '';
    final digits = minor.abs().toString().padLeft(currencyScale + 1, '0');
    if (currencyScale == 0) return '$sign$digits';
    final split = digits.length - currencyScale;
    return '$sign${digits.substring(0, split)}.${digits.substring(split)}';
  }
}

Money parseDisplay(Object? value, String currency, int scale) {
  validateScale(scale);
  final match = value is String ? _displayPattern.firstMatch(value) : null;
  if (match == null) throw const DomainError('money.format');
  final fraction = match.group(3) ?? '';
  if (fraction.length > scale &&
      fraction.substring(scale).contains(RegExp('[1-9]'))) {
    throw const DomainError('money.precision');
  }
  final kept = fraction.length > scale
      ? fraction.substring(0, scale)
      : fraction;
  final digits = '${match.group(2)}${kept.padRight(scale, '0')}';
  var canonical = digits.replaceFirst(RegExp('^0+'), '');
  if (canonical.isEmpty) canonical = '0';
  if (match.group(1) == '-' && canonical != '0') canonical = '-$canonical';
  return Money(currency, scale, parseMinor(canonical));
}

class ExactRate {
  const ExactRate(this.numerator, this.denominator);
  final BigInt numerator;
  final BigInt denominator;
}

ExactRate parseRate(Object? value) {
  if (value is! String || !_ratePattern.hasMatch(value)) {
    throw const DomainError('fx.rate_invalid');
  }
  final parts = value.split('.');
  if (parts[0].length > 20) throw const DomainError('fx.rate_invalid');
  final decimals = parts.length == 2 ? parts[1] : '';
  final numerator = BigInt.parse('${parts[0]}$decimals');
  final denominator = BigInt.from(10).pow(decimals.length);
  if (numerator <= BigInt.zero ||
      numerator >= BigInt.from(10).pow(20) * denominator) {
    throw const DomainError('fx.rate_invalid');
  }
  return ExactRate(numerator, denominator);
}

BigInt roundHalfUp(BigInt numerator, BigInt denominator) {
  if (denominator <= BigInt.zero) throw const DomainError('money.format');
  final magnitude =
      (numerator.abs() * BigInt.two + denominator) ~/
      (BigInt.two * denominator);
  return numerator.isNegative ? -magnitude : magnitude;
}

Money convertMoney(
  Money source,
  String rate,
  String reportCurrency,
  int reportScale,
) {
  validateScale(reportScale);
  final fraction = parseRate(rate);
  final numerator =
      source.minor * fraction.numerator * BigInt.from(10).pow(reportScale);
  final denominator =
      fraction.denominator * BigInt.from(10).pow(source.currencyScale);
  return Money(
    reportCurrency,
    reportScale,
    checkedMinor(roundHalfUp(numerator, denominator)),
  );
}

List<String> allocateLast(String totalMinor, int count) {
  final total = parseMinor(totalMinor, positive: true);
  if (count <= 0 || count > maxReferenceOccurrences) {
    throw const DomainError('schedule.invalid_count');
  }
  final base = total ~/ BigInt.from(count);
  return [
    ...List.filled(count - 1, base.toString()),
    (total - BigInt.from(count - 1) * base).toString(),
  ];
}

String cumulativeAllocationDelta(
  String reportTotal,
  String originalTotal,
  String previous,
  String current,
) {
  final report = parseMinor(reportTotal);
  final original = parseMinor(originalTotal, positive: true);
  final before = parseMinor(previous);
  final after = parseMinor(current);
  if (before < BigInt.zero || before > after || after > original) {
    throw const DomainError('allocation.exceeds_remaining');
  }
  return checkedMinor(
    roundHalfUp(report * after, original) -
        roundHalfUp(report * before, original),
  ).toString();
}
