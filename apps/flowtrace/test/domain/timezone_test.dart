import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/domain/ledger/timezone_rules.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture_support.dart';

void main() {
  final vectors = loadLedgerFixture(
    'money-time-vectors.json',
  )['timezone_vectors'];
  for (final vector in vectors) {
    test('real IANA contract $vector', () {
      if (vector['occurred_at'] != null) {
        expect(
          instantBusinessDate(vector['occurred_at'], vector['timezone']),
          vector['expected_business_date'],
        );
      } else {
        final resolved = resolveLocalTime(
          vector['local_time'],
          vector['timezone'],
        );
        if (vector['expected_resolved_local'] != null) {
          expect(formatLocalTime(resolved), vector['expected_resolved_local']);
        }
        if (vector['expected_utc'] != null) {
          expect(
            resolved.toUtc().isAtSameMomentAs(
              DateTime.parse(vector['expected_utc']),
            ),
            isTrue,
          );
        }
      }
    });
  }
  for (final value in [
    '2026-02-30T00:00:00Z',
    '2026-01-01T24:00:00Z',
    '2026-01-01T00:00:00',
    '2026-01-01T00:00:00+99:00',
  ]) {
    test('invalid instant is not normalized $value', () {
      expect(
        () => instantBusinessDate(value, 'Asia/Shanghai'),
        throwsA(
          isA<DomainError>().having((e) => e.code, 'code', 'date.invalid'),
        ),
      );
    });
  }
  test('unknown timezone does not use host fallback', () {
    expect(
      () => instantBusinessDate('2026-01-01T00:00:00Z', 'Mars/Unknown'),
      throwsA(
        isA<DomainError>().having(
          (e) => e.code,
          'code',
          'date.invalid_timezone',
        ),
      ),
    );
  });
}
