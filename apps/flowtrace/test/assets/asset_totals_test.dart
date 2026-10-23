import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/domain/assets/asset_totals.dart';

AssetPosition position(
  String id,
  String amount, {
  String currency = 'CNY',
  int scale = 2,
  bool hidden = false,
  bool included = true,
}) => AssetPosition(
  id: id,
  balance: Money(currency, scale, BigInt.parse(amount)),
  hidden: hidden,
  includeInNetAssets: included,
);
AssetTotals value(
  List<AssetPosition> positions, {
  List<AssetValuationRate> rates = const [],
}) => valueAssetPositions(
  positions,
  currency: 'CNY',
  asOfDate: '2026-10-21',
  rates: rates,
  valuationPolicy: 'latest_on_or_before',
);
const usd = AssetValuationRate(
  fromCurrency: 'USD',
  toCurrency: 'CNY',
  effectiveDate: '2026-10-20',
  rate: '7.25',
);

void main() {
  test('hidden balances count while explicitly excluded balances do not', () {
    final totals = value([
      position('cash', '10000', hidden: true),
      position('credit', '-3000'),
      position('excluded', '999999', included: false),
    ]);
    expect(totals.available, isTrue);
    expect(totals.assets!.minor.toString(), '10000');
    expect(totals.liabilities!.minor.toString(), '3000');
    expect(totals.net!.minor.toString(), '7000');
  });
  test('valuation changes current totals without mutating original Money', () {
    final foreign = position('foreign', '100', currency: 'USD');
    final first = value([foreign], rates: [usd]);
    final second = value(
      [foreign],
      rates: [
        const AssetValuationRate(
          fromCurrency: 'USD',
          toCurrency: 'CNY',
          effectiveDate: '2026-10-21',
          rate: '7.3',
        ),
      ],
    );
    expect(first.net!.minor.toString(), '725');
    expect(second.net!.minor.toString(), '730');
    expect(foreign.balance!.minor.toString(), '100');
  });
  test(
    'negative conversion rounds symmetrically once and preserves currency precision',
    () {
      final totals = value(
        [position('jpy', '-1', currency: 'JPY', scale: 0)],
        rates: [
          const AssetValuationRate(
            fromCurrency: 'JPY',
            toCurrency: 'CNY',
            effectiveDate: '2026-10-01',
            rate: '0.015',
          ),
        ],
      );
      expect(totals.net!.minor.toString(), '-2');
      expect(totals.liabilities!.minor.toString(), '2');
    },
  );
  test(
    'unknown balance or missing rate leaves every grand total unavailable',
    () {
      for (final totals in [
        value([
          position('known', '500'),
          const AssetPosition(id: 'missing', balance: null),
        ]),
        value([
          position('known', '500'),
          position('foreign', '100', currency: 'USD'),
        ]),
      ]) {
        expect(totals.available, isFalse);
        expect(totals.net, isNull);
        expect(totals.assets, isNull);
        expect(totals.liabilities, isNull);
        expect(totals.convertedBalances, isEmpty);
      }
    },
  );
  test('future quotes and inverse quotes are not silently applied', () {
    final totals = value(
      [position('foreign', '100', currency: 'USD')],
      rates: [
        const AssetValuationRate(
          fromCurrency: 'USD',
          toCurrency: 'CNY',
          effectiveDate: '2026-10-22',
          rate: '99',
        ),
        const AssetValuationRate(
          fromCurrency: 'CNY',
          toCurrency: 'USD',
          effectiveDate: '2026-10-20',
          rate: '0.14',
        ),
      ],
    );
    expect(totals.available, isFalse);
    expect(totals.issues, ['assets.rate_required']);
  });
  test(
    'latest eligible direct quote is deterministic and duplicate latest dates are unavailable',
    () {
      final foreign = position('foreign', '100', currency: 'USD');
      const old = AssetValuationRate(
        fromCurrency: 'USD',
        toCurrency: 'CNY',
        effectiveDate: '2026-10-19',
        rate: '7',
      );
      expect(value([foreign], rates: [usd, old]).net!.minor.toString(), '725');
      expect(value([foreign], rates: [usd, usd]).issues, [
        'assets.ambiguous_rate',
      ]);
    },
  );
  test(
    'amounts beyond JavaScript safe integers retain exact values and overflow is unavailable',
    () {
      expect(
        value([position('large', '9007199254740993')]).net!.minor.toString(),
        '9007199254740993',
      );
      final overflow = value([
        position('a', '9223372036854775807'),
        position('b', '1'),
      ]);
      expect(overflow.available, isFalse);
      expect(overflow.issues, ['assets.out_of_range']);
    },
  );
  test('duplicate account identities and bad rates cannot return a total', () {
    expect(value([position('a', '1'), position('a', '2')]).available, isFalse);
    final invalid = value(
      [position('foreign', '1', currency: 'USD')],
      rates: [
        const AssetValuationRate(
          fromCurrency: 'USD',
          toCurrency: 'CNY',
          effectiveDate: '2026-10-20',
          rate: '1e3',
        ),
      ],
    );
    expect(invalid.issues, ['assets.rate_invalid']);
  });
  test(
    'exact-date is the default and an explicit older quote policy is distinguishable',
    () {
      final foreign = position('foreign', '100', currency: 'USD');
      final exact = valueAssetPositions(
        [foreign],
        currency: 'CNY',
        asOfDate: '2026-10-21',
        rates: [usd],
      );
      expect(exact.available, isFalse);
      expect(exact.issues, ['assets.rate_required']);
      final prior = value([foreign], rates: [usd]);
      expect(prior.available, isTrue);
      expect(prior.usedRates['USD']!.effectiveDate, '2026-10-20');
    },
  );
  test('zero foreign balance requires no quote', () {
    final result = value([position('foreign', '0', currency: 'USD')]);
    expect(result.available, isTrue);
    expect(result.net!.minor, BigInt.zero);
  });
  test(
    'borrowed and lent are descriptive subsets and do not add to net twice',
    () {
      final result = value([
        AssetPosition(
          id: 'receivable',
          balance: Money('CNY', 2, BigInt.from(500)),
          kind: 'loan_receivable',
        ),
        AssetPosition(
          id: 'payable',
          balance: Money('CNY', 2, BigInt.from(-200)),
          kind: 'loan_payable',
        ),
        position('cash', '1000'),
      ]);
      expect(result.assets!.minor.toString(), '1500');
      expect(result.liabilities!.minor.toString(), '200');
      expect(result.lent!.minor.toString(), '500');
      expect(result.borrowed!.minor.toString(), '200');
      expect(result.net!.minor.toString(), '1300');
    },
  );
  test(
    'golden account balances and dated valuation changes reproduce every fixed asset total',
    () {
      final fixtures =
          jsonDecode(
                File(
                  '../../contracts/fixtures/ledger/scenarios.json',
                ).readAsStringSync(),
              )
              as Map;
      var checkedStates = 0;
      for (final scenario in fixtures['scenarios'] as List) {
        final setup = scenario['setup'] as Map,
            rates = <String, String>{
              '${setup['report_currency']}': '1',
              ...Map<String, String>.from(
                setup['valuation_rates'] as Map? ?? {},
              ),
            };
        final accounts = {
          for (final account in setup['accounts'] as List)
            account['id']: account,
        };
        for (final step in scenario['steps'] as List) {
          if (step['command']?['action'] == 'set_valuation_rate') {
            rates[step['command']['currency']] = step['command']['rate'];
          }
          final expected = step['expected']['state'] as Map;
          if (expected['assets'] == null ||
              expected['account_balances_minor'] == null) {
            continue;
          }
          checkedStates++;
          final result = valueAssetPositions(
            [
              for (final balance
                  in (expected['account_balances_minor'] as Map).entries)
                AssetPosition(
                  id: balance.key as String,
                  balance: Money(
                    accounts[balance.key]['currency'] as String,
                    accounts[balance.key]['currency_scale'] as int,
                    BigInt.parse(balance.value as String),
                  ),
                  includeInNetAssets:
                      accounts[balance.key]['include_in_net_assets'] as bool? ??
                      true,
                ),
            ],
            currency: setup['report_currency'] as String,
            asOfDate: '2026-10-21',
            rates: [
              for (final rate in rates.entries)
                AssetValuationRate(
                  fromCurrency: rate.key,
                  toCurrency: setup['report_currency'] as String,
                  effectiveDate: '2026-10-21',
                  // The fixture rates are fixed quote facts for this chosen date.
                  rate: rate.value,
                ),
            ],
          );
          expect(
            result.available,
            isTrue,
            reason: '${scenario['scenario_id']}/${step['step_id']}',
          );
          expect(
            result.assets!.minor.toString(),
            expected['assets']['assets_minor'],
          );
          expect(
            result.liabilities!.minor.toString(),
            expected['assets']['liabilities_minor'],
          );
          expect(result.net!.minor.toString(), expected['assets']['net_minor']);
        }
      }
      expect(checkedStates, 57);
    },
  );
}
