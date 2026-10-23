/// IANA rules use the bundled, locked package database and never the host zone.
library;

import 'package:timezone/data/latest_all.dart' as database;
import 'package:timezone/timezone.dart' as tz;

import '../../core/money/money.dart';
import 'calendar_rules.dart';

bool _initialized = false;

tz.Location _location(String name) {
  if (!_initialized) {
    database.initializeTimeZones();
    _initialized = true;
  }
  try {
    return tz.getLocation(name);
  } on tz.LocationNotFoundException {
    throw const DomainError('date.invalid_timezone');
  }
}

DateTime _wall(String value) {
  final match = RegExp(
    r'^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,6}))?$',
  ).firstMatch(value);
  if (match == null || match.end != value.length) {
    throw const DomainError('date.invalid');
  }
  businessDate(match.group(1));
  if (int.parse(match.group(2)!) > 23 ||
      int.parse(match.group(3)!) > 59 ||
      int.parse(match.group(4)!) > 59) {
    throw const DomainError('date.invalid');
  }
  return DateTime.parse('${value}Z');
}

bool _sameWall(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day &&
    left.hour == right.hour &&
    left.minute == right.minute &&
    left.second == right.second &&
    left.millisecond == right.millisecond &&
    left.microsecond == right.microsecond;

List<tz.TZDateTime> _candidates(DateTime wall, tz.Location location) {
  final values = <int, tz.TZDateTime>{};
  for (final offset in location.zones.map((zone) => zone.offset).toSet()) {
    final utc = wall.subtract(offset);
    final candidate = tz.TZDateTime.from(utc, location);
    if (_sameWall(candidate, wall)) {
      values[utc.microsecondsSinceEpoch] = candidate;
    }
  }
  final keys = values.keys.toList()..sort();
  return keys.map((key) => values[key]!).toList();
}

String instantBusinessDate(String occurredAt, String timezoneName) {
  final match = RegExp(
    r'^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?)(Z|[+-][0-9]{2}:[0-9]{2})$',
  ).firstMatch(occurredAt);
  if (match == null || match.end != occurredAt.length) {
    throw const DomainError('date.invalid');
  }
  _wall(match.group(1)!);
  final offset = match.group(2)!;
  if (offset != 'Z' &&
      (int.parse(offset.substring(1, 3)) > 23 ||
          int.parse(offset.substring(4, 6)) > 59)) {
    throw const DomainError('date.invalid');
  }
  final instant = DateTime.parse(occurredAt);
  return isoBusinessDate(tz.TZDateTime.from(instant, _location(timezoneName)));
}

tz.TZDateTime resolveLocalTime(String localTime, String timezoneName) {
  final wall = _wall(localTime);
  final location = _location(timezoneName);
  var candidates = _candidates(wall, location);
  if (candidates.isNotEmpty) return candidates.first;
  var cursor = DateTime.utc(
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
  );
  for (var minute = 0; minute < 48 * 60; minute++) {
    cursor = cursor.add(const Duration(minutes: 1));
    if (cursor.year > 9999) throw const DomainError('date.out_of_range');
    if (_candidates(cursor, location).isNotEmpty) {
      final start = cursor.subtract(const Duration(minutes: 1));
      for (var second = 0; second <= 60; second++) {
        final probe = start.add(Duration(seconds: second));
        if (!probe.isBefore(wall)) {
          candidates = _candidates(probe, location);
          if (candidates.isNotEmpty) return candidates.first;
        }
      }
    }
  }
  throw const DomainError('date.unresolvable_local');
}

String formatLocalTime(tz.TZDateTime value) {
  String pair(int number) => number.toString().padLeft(2, '0');
  final offset = value.timeZoneOffset.inSeconds;
  final absolute = offset.abs();
  final hours = absolute ~/ 3600;
  final minutes = (absolute % 3600) ~/ 60;
  final seconds = absolute % 60;
  final fraction = value.millisecond * 1000 + value.microsecond;
  final subsecond = fraction == 0
      ? ''
      : '.${fraction.toString().padLeft(6, '0')}';
  final zone =
      '${offset < 0 ? '-' : '+'}${pair(hours)}:${pair(minutes)}'
      '${seconds == 0 ? '' : ':${pair(seconds)}'}';
  return '${isoBusinessDate(value)}T${pair(value.hour)}:${pair(value.minute)}:'
      '${pair(value.second)}$subsecond$zone';
}
