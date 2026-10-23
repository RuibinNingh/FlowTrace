import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/domain/ledger/calendar_rules.dart';

import 'fixture_support.dart';

void main() {
  final vectors = loadLedgerFixture('money-time-vectors.json');
  for (final vector in vectors['money_vectors']) {
    test('money contract ${vector['input']}', () {
      if (vector['accepted']) {
        expect(
          Money.fromJson(vector['input']).toJson()['amount_minor'],
          vector['canonical_minor'],
        );
      } else {
        expect(
          () => Money.fromJson(vector['input']),
          throwsA(
            isA<DomainError>().having(
              (e) => e.code,
              'code',
              vector['error_code'],
            ),
          ),
        );
      }
    });
  }
  for (final vector in vectors['display_vectors']) {
    test('display contract ${vector['input']}', () {
      if (vector['error_code'] != null) {
        expect(
          () => parseDisplay(
            vector['input'],
            vector['currency'],
            vector['scale'],
          ),
          throwsA(
            isA<DomainError>().having(
              (e) => e.code,
              'code',
              vector['error_code'],
            ),
          ),
        );
      } else {
        final money = parseDisplay(
          vector['input'],
          vector['currency'],
          vector['scale'],
        );
        expect(money.minor.toString(), vector['expected_minor']);
        expect(
          parseDisplay(
            money.display(),
            money.currency,
            money.currencyScale,
          ).toJson(),
          money.toJson(),
        );
      }
    });
  }
  for (final vector in vectors['allocation_vectors']) {
    test('allocation contract ${vector['total_minor']}/${vector['count']}', () {
      expect(
        allocateLast(vector['total_minor'], vector['count']),
        vector['expected_minor'],
      );
    });
  }
  for (final vector in vectors['fx_vectors']) {
    test('FX contract ${vector['source']}', () {
      expect(
        convertMoney(
          Money.fromJson(vector['source']),
          vector['rate'],
          vector['report_currency'],
          vector['report_scale'],
        ).minor.toString(),
        vector['expected_minor'],
      );
    });
  }
  for (final vector in vectors['period_vectors']) {
    test('business period ${vector['date']}/${vector['month_start_day']}', () {
      expect(periodBounds(vector['date'], vector['month_start_day']), (
        vector['expected_start'],
        vector['expected_end_exclusive'],
      ));
    });
  }
  for (final vector in vectors['recurrence_vectors']) {
    test('recurrence ${vector['frequency']}/${vector['anchor_date']}', () {
      expect(
        recurrenceDates(
          vector['anchor_date'],
          vector['frequency'],
          vector['count'],
        ),
        vector['expected_dates'],
      );
    });
  }
  for (final vector in vectors['saving_vectors']) {
    test('saving mode ${vector['mode']}', () {
      final values = savingSchedule(
        vector['mode'],
        vector['base_minor'],
        vector['count'],
      );
      expect(
        values
            .map(BigInt.parse)
            .fold(BigInt.zero, (sum, v) => sum + v)
            .toString(),
        vector['expected_total_minor'],
      );
      if (vector['first_minor'] != null) {
        expect(values.first, vector['first_minor']);
        expect(values.last, vector['last_minor']);
      }
    });
  }
  for (final value in [
    '-9223372036854775808',
    '9223372036854775807',
    '9007199254740993',
  ]) {
    test('signed int64 JSON round trip $value', () {
      final source = {
        'currency': 'CNY',
        'currency_scale': 2,
        'amount_minor': value,
      };
      expect(Money.fromJson(jsonDecode(jsonEncode(source))).toJson(), source);
    });
  }
  for (final value in <Object?>[
    '+1',
    '-0',
    '1e3',
    ' 1',
    '1\n',
    '١',
    true,
    1,
    1.0,
    null,
  ]) {
    test('minor rejects noncanonical ${jsonEncode(value)}', () {
      expect(
        () => parseMinor(value),
        throwsA(
          isA<DomainError>().having((e) => e.code, 'code', 'money.format'),
        ),
      );
    });
  }
  for (final value in [
    '-9223372036854775809',
    '9223372036854775808',
    '9' * 10000,
  ]) {
    test('minor rejects overflow length=${value.length}', () {
      expect(
        () => parseMinor(value),
        throwsA(
          isA<DomainError>().having(
            (e) => e.code,
            'code',
            'money.out_of_range',
          ),
        ),
      );
    });
  }
  for (final tuple in [
    (1, 2, 1),
    (-1, 2, -1),
    (1, 3, 0),
    (-1, 3, 0),
    (5, 2, 3),
    (-5, 2, -3),
  ]) {
    test('symmetric half up $tuple', () {
      expect(
        roundHalfUp(BigInt.from(tuple.$1), BigInt.from(tuple.$2)),
        BigInt.from(tuple.$3),
      );
    });
  }
  test('partial allocation exactly clears frozen reporting total', () {
    final first = cumulativeAllocationDelta('7207', '1001', '0', '400');
    final last = cumulativeAllocationDelta('7207', '1001', '400', '1001');
    expect(first, '2880');
    expect(last, '4327');
    expect(BigInt.parse(first) + BigInt.parse(last), BigInt.from(7207));
  });
  for (final rate in <Object>[
    '0',
    '-1',
    '1e1',
    '01',
    '1.0000000000000000001',
    '100000000000000000000',
    1.2,
  ]) {
    test('rate rejects ${jsonEncode(rate)}', () {
      expect(
        () => parseRate(rate),
        throwsA(
          isA<DomainError>().having((e) => e.code, 'code', 'fx.rate_invalid'),
        ),
      );
    });
  }
  test('positive amount and currency precision remain independent', () {
    expect(Money('CNY', 2, BigInt.zero).display(), '0.00');
    expect(
      () => Money.fromJson({
        'currency': 'CNY',
        'currency_scale': 2,
        'amount_minor': '0',
      }, positive: true),
      throwsA(isA<DomainError>()),
    );
    expect(
      () => Money.fromJson({
        'currency': 'CNY',
        'currency_scale': true,
        'amount_minor': '1',
      }),
      throwsA(isA<DomainError>()),
    );
    expect(
      () => Money('CNY', 2, BigInt.one).plus(Money('JPY', 0, BigInt.one)),
      throwsA(isA<DomainError>()),
    );
  });
  for (final value in ['2026-02-29', '2026-13-01', '2026-2-01', '0000-01-01']) {
    test('invalid business date $value', () {
      expect(() => businessDate(value), throwsA(isA<DomainError>()));
    });
  }
  test('bounded occurrences and real workday requirement', () {
    expect(() => allocateLast('1', 10001), throwsA(isA<DomainError>()));
    expect(
      () => recurrenceDates('2026-01-01', 'monthly', 10001),
      throwsA(isA<DomainError>()),
    );
    expect(
      () => recurrenceDates('2026-01-01', 'statutory_workday', 1),
      throwsA(
        isA<DomainError>().having(
          (e) => e.code,
          'code',
          'schedule.calendar_unavailable',
        ),
      ),
    );
  });
}
