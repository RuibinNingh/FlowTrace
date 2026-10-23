/// Date-only business rules. IANA conversion lives in timezone_rules.dart;
/// these functions never read DateTime.now or the host timezone.
library;

import '../../core/money/money.dart';

DateTime businessDate(Object? value) {
  if (value is! String ||
      !RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(value)) {
    throw const DomainError('date.invalid');
  }
  final parts = value.split('-').map(int.parse).toList();
  if (parts[0] < 1 || parts[0] > 9999) throw const DomainError('date.invalid');
  final date = DateTime.utc(parts[0], parts[1], parts[2]);
  if (date.year != parts[0] || date.month != parts[1] || date.day != parts[2]) {
    throw const DomainError('date.invalid');
  }
  return date;
}

String isoBusinessDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

(int, int) _month(int year, int month, int delta) {
  final ordinal = year * 12 + month - 1 + delta;
  final resultYear = ordinal ~/ 12;
  if (resultYear < 1 || resultYear > 9999) {
    throw const DomainError('date.out_of_range');
  }
  return (resultYear, ordinal % 12 + 1);
}

DateTime _clamped(int year, int month, int day) {
  final last = DateTime.utc(year, month + 1, 0).day;
  return DateTime.utc(year, month, day > last ? last : day);
}

(String, String) periodBounds(String value, int monthStartDay) {
  final day = businessDate(value);
  if (monthStartDay < 1 || monthStartDay > 31) {
    throw const DomainError('date.invalid_month_start');
  }
  var start = _clamped(day.year, day.month, monthStartDay);
  if (day.isBefore(start)) {
    final (year, month) = _month(day.year, day.month, -1);
    start = _clamped(year, month, monthStartDay);
  }
  final (year, month) = _month(start.year, start.month, 1);
  final end = _clamped(year, month, monthStartDay);
  return (isoBusinessDate(start), isoBusinessDate(end));
}

List<String> recurrenceDates(String anchor, String frequency, int count) {
  final day = businessDate(anchor);
  if (count <= 0 || count > maxReferenceOccurrences) {
    throw const DomainError('schedule.invalid_count');
  }
  final values = <String>[];
  for (var index = 0; index < count; index++) {
    DateTime occurrence;
    if (frequency == 'monthly') {
      final (year, month) = _month(day.year, day.month, index);
      occurrence = _clamped(year, month, day.day);
    } else if (frequency == 'yearly') {
      if (day.year + index > 9999) {
        throw const DomainError('date.out_of_range');
      }
      occurrence = _clamped(day.year + index, day.month, day.day);
    } else if (frequency == 'daily' || frequency == 'weekly') {
      occurrence = day.add(
        Duration(days: index * (frequency == 'weekly' ? 7 : 1)),
      );
      if (occurrence.year > 9999) {
        throw const DomainError('date.out_of_range');
      }
    } else if (frequency == 'statutory_workday') {
      throw const DomainError('schedule.calendar_unavailable');
    } else {
      throw const DomainError('schedule.unsupported_frequency');
    }
    values.add(isoBusinessDate(occurrence));
  }
  return values;
}

List<String> savingSchedule(String mode, String baseMinor, int count) {
  final base = parseMinor(baseMinor, positive: true);
  if (count < 0 || count > maxReferenceOccurrences) {
    throw const DomainError('schedule.invalid_count');
  }
  if (mode == 'flexible') {
    if (count != 0) throw const DomainError('schedule.invalid_count');
    return [];
  }
  const fixedCounts = {
    '365': 365,
    '52_week': 52,
    '52_week_reverse': 52,
    '12_deposit': 12,
    '36_deposit': 36,
  };
  if (fixedCounts.containsKey(mode) && fixedCounts[mode] != count) {
    throw const DomainError('schedule.invalid_count');
  }
  if (count <= 0 || (!fixedCounts.containsKey(mode) && mode != 'fixed')) {
    throw const DomainError('schedule.unsupported_mode');
  }
  final values = List.generate(count, (index) {
    final multiplier = mode == '365' || mode == '52_week'
        ? index + 1
        : mode == '52_week_reverse'
        ? count - index
        : 1;
    return checkedMinor(base * BigInt.from(multiplier));
  });
  checkedMinor(values.fold(BigInt.zero, (sum, value) => sum + value));
  return values.map((value) => value.toString()).toList();
}
