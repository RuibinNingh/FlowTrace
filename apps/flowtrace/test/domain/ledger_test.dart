/// The fixture chooses requested projection fields; each field is compared in
/// full. The implementation never loads expected values or the fixture checker.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/domain/ledger/reference_ledger.dart';

import 'fixture_support.dart';

void main() {
  final scenarios = loadLedgerFixture('scenarios.json')['scenarios'] as List;
  for (final scenario in scenarios) {
    test('shared golden ${scenario['scenario_id']}', () {
      final ledger = ReferenceLedger(scenario['setup']);
      for (final step in scenario['steps']) {
        final before = ledger.project();
        final actual = ledger.execute(step['command']);
        final expected = step['expected'];
        expect(actual['result'], expected['result'], reason: step['step_id']);
        expect(
          actual['error_code'],
          expected['error_code'],
          reason: step['step_id'],
        );
        for (final entry in (expected['state'] as Map).entries) {
          expect(
            actual['state'][entry.key],
            entry.value,
            reason: '${step['step_id']}:${entry.key}',
          );
        }
        if (actual['result'] == 'rejected' || actual['result'] == 'replayed') {
          expect(actual['state'], before, reason: step['step_id']);
        }
      }
    });
  }

  ReferenceLedger base() {
    final ledger = ReferenceLedger(scenarios[0]['setup']);
    ledger.execute(scenarios[0]['steps'][0]['command']);
    ledger.execute(scenarios[0]['steps'][1]['command']);
    return ledger;
  }

  test('invalid edit restores the removed original expense', () {
    final ledger = base();
    final before = ledger.project();
    final result = ledger.execute({
      'action': 'update_bill',
      'bill_id': 'food_1',
      'changes': {
        'money': {'currency': 'CNY', 'currency_scale': 2, 'amount_minor': '01'},
      },
    });
    expect(result['result'], 'rejected');
    expect(result['error_code'], 'money.format');
    expect(result['state'], before);
  });
  test('schema failure after mutation rolls back and is rethrown', () {
    final ledger = base();
    final before = ledger.project();
    expect(
      () => ledger.execute({
        'action': 'update_bill',
        'bill_id': 'food_1',
        'changes': {'flags': []},
      }),
      throwsA(isA<TypeError>()),
    );
    expect(ledger.project(), before);
  });
  test('cumulative balance overflow leaves no partial entry', () {
    final setup = copyMap(scenarios[0]['setup']);
    setup['accounts'] = [setup['accounts'][0]];
    setup['accounts'][0]['opening_minor'] = '9223372036854775807';
    final ledger = ReferenceLedger(setup);
    final before = ledger.project();
    final command = copyMap(scenarios[0]['steps'][0]['command']);
    command['bill']['money']['amount_minor'] = '1';
    final result = ledger.execute(command);
    expect(result['error_code'], 'money.out_of_range');
    expect(result['state'], before);
  });
  test('target overflow does not debit a transfer source', () {
    final setup = copyMap(scenarios[0]['setup']);
    setup['accounts'] = (setup['accounts'] as List).take(2).toList();
    setup['accounts'][1]['opening_minor'] = '9223372036854775807';
    setup['accounts'][1]['include_in_net_assets'] = false;
    final ledger = ReferenceLedger(setup);
    final before = ledger.project();
    final command = copyMap(scenarios[0]['steps'][5]['command']);
    (command['bill'] as Map).remove('fee');
    command['bill']['money']['amount_minor'] = '1';
    final result = ledger.execute(command);
    expect(result['error_code'], 'money.out_of_range');
    expect(result['state'], before);
  });
  test('statistics overflow without account rejects atomically', () {
    final setup = copyMap(scenarios[7]['setup']);
    setup['budgets'] = [];
    final ledger = ReferenceLedger(setup);
    final first = copyMap(scenarios[7]['steps'][0]['command']);
    first['bill']['money']['amount_minor'] = '9223372036854775807';
    expect(ledger.execute(first)['result'], 'applied');
    final before = ledger.project();
    final second = copyMap(first);
    second['bill']['id'] = 'overflow';
    second['bill']['money']['amount_minor'] = '1';
    final result = ledger.execute(second);
    expect(result['error_code'], 'money.out_of_range');
    expect(result['state'], before);
  });
}
