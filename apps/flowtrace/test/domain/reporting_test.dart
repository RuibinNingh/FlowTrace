import 'package:flowtrace/domain/reporting/reporting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture_support.dart';

void main() {
  final scenarios = loadLedgerFixture('scenarios.json')['scenarios'] as List;
  for (final raw in [...scenarios.take(4), scenarios[7]]) {
    final scenario = raw as Map;
    test('golden ${scenario['scenario_id']} reports every accepted step', () {
      final setup = scenario['setup'] as Map;
      final bills = <String, Map<String, Object?>>{};
      for (final rawStep in scenario['steps'] as List) {
        final step = rawStep as Map,
            command = step['command'] as Map,
            expected = step['expected'] as Map;
        if (expected['result'] == 'applied') {
          if (command['action'] == 'create_bill') {
            final payload = copyMap(command['bill'] as Map);
            bills[payload.remove('id') as String] = payload;
          } else if (command['action'] == 'update_bill') {
            bills[command['bill_id']]!.addAll(
              copyMap(command['changes'] as Map),
            );
          } else if (command['action'] == 'delete_bill') {
            bills.remove(command['bill_id']);
          }
        }
        for (final rawPeriod in setup['period_queries'] as List) {
          final period = rawPeriod as Map;
          final query = ReportQuery(
            bookId: setup['book_id'] as String,
            reportCurrency: setup['report_currency'] as String,
            reportScale: setup['report_scale'] as int,
            startDate: period['start_date'] as String,
            endDateExclusive: period['end_date_exclusive'] as String,
          );
          final rows = bills.entries
              .map(
                (entry) => ReportBill(
                  id: entry.key,
                  payload: entry.value,
                  allocationsComplete: true,
                ),
              )
              .toList();
          final actual = buildReport(rows, query);
          expect(
            actual.available,
            isTrue,
            reason: '${step['step_id']}: ${actual.issues}',
          );
          final data = actual.toJson(), totals = data['totals'] as Map;
          final expectedPeriod =
              (expected['state'] as Map)['periods'][period['period_id']] as Map;
          for (final entry in expectedPeriod.entries) {
            expect(
              totals.containsKey(entry.key)
                  ? totals[entry.key]
                  : data[entry.key],
              entry.value,
              reason: '${step['step_id']}: ${entry.key}',
            );
          }
          for (final rawConfig in setup['budgets'] as List? ?? []) {
            final config = rawConfig as Map;
            final measured = buildReport(
              rows,
              query,
              budget: ReportBudget(
                startDate: query.startDate,
                endDateExclusive: query.endDateExclusive,
                totalLimitMinor: config['total_limit_minor'] as String?,
                categoryLimits: (config['categories'] as Map)
                    .cast<String, String>(),
              ),
            );
            expect(measured.available, isTrue, reason: '${measured.issues}');
            final expectedBudget =
                (expected['state'] as Map)['budgets'][config['id']] as Map;
            for (final entry in expectedBudget.entries) {
              expect(
                measured.budget![entry.key],
                entry.value,
                reason: '${step['step_id']}: ${config['id']}: ${entry.key}',
              );
            }
          }
        }
      }
    });
  }

  final query = ReportQuery(
    bookId: 'book',
    reportCurrency: 'CNY',
    reportScale: 2,
    startDate: '2026-10-01',
    endDateExclusive: '2026-11-01',
  );

  ReportBill expense({
    String id = 'source',
    String amount = '1001',
    Map<String, Object?> changes = const {},
  }) => ReportBill(
    id: id,
    allocationsComplete: true,
    payload: {
      'book_id': 'book',
      'bill_type': 'expense',
      'business_date': '2026-10-21',
      'money': {'currency': 'CNY', 'currency_scale': 2, 'amount_minor': amount},
      'category_id': 'food',
      'flags': {'exclude_from_statistics': false, 'exclude_from_budget': false},
      ...changes,
    },
  );
  ReportBill receipt({
    String id = 'refund',
    String source = 'source',
    String amount = '400',
    String kind = 'refund',
    Map<String, Object?> changes = const {},
  }) => ReportBill(
    id: id,
    allocationsComplete: true,
    payload: {
      'book_id': 'book',
      'bill_type': kind,
      'business_date': '2026-11-03',
      'money': {'currency': 'CNY', 'currency_scale': 2, 'amount_minor': amount},
      'allocations': [
        {
          'source_bill_id': source,
          'source_amount_minor': amount,
          'receipt_amount_minor': amount,
        },
      ],
      'income_component_minor': '0',
      ...changes,
    },
  );

  test(
    'hierarchy, calendar and parent budget count each child expense once',
    () {
      final result = buildReport(
        [
          expense(changes: {'category_id': 'coffee'}),
          receipt(),
        ],
        query,
        categoryParents: {'coffee': 'food', 'food': null},
        budget: ReportBudget(
          startDate: query.startDate,
          endDateExclusive: query.endDateExclusive,
          categoryLimits: {'food': '1000'},
        ),
      );
      expect(result.totals!.expense.minor.toString(), '601');
      expect(result.categoryExpenseMinor, {'coffee': '601'});
      expect(result.categoryExpenseRollupMinor, {
        'coffee': '601',
        'food': '601',
      });
      expect(result.calendar!['2026-10-21']!.expense.minor.toString(), '601');
      expect(result.calendar!.containsKey('2026-11-03'), isFalse);
      expect(result.budget!['spent_minor'], '601');
      expect(result.budget!['remaining_minor'], '399');
    },
  );

  test(
    'public remaining proves net but hides the unavailable allocation breakdown',
    () {
      final result = buildReport([
        ReportBill(
          id: 'source',
          payload: expense().payload,
          remainingAllocatableMinor: '601',
        ),
      ], query);
      expect(result.available, isTrue);
      expect(result.totals!.expense.minor.toString(), '601');
      expect(result.totals!.allocatedExpense.minor.toString(), '400');
      expect(result.totals!.refund, isNull);
      expect(result.totals!.reimbursement, isNull);
      expect(result.allocationBreakdownAvailable, isFalse);
      expect(result.toJson().toString(), isNot(contains('source_bill_id')));
    },
  );

  test('missing source or remaining returns no fabricated partial zeros', () {
    var result = buildReport([
      ReportBill(id: 'source', payload: expense().payload),
    ], query);
    expect(result.available, isFalse);
    expect(result.issues, ['report.allocations_incomplete']);
    expect(result.totals, isNull);
    result = buildReport([receipt(source: 'private-secret-identifier')], query);
    expect(result.issues, ['report.source_unavailable']);
    expect(
      result.toJson().toString(),
      isNot(contains('private-secret-identifier')),
    );
  });

  test('stale remaining cannot silently ignore a pending local refund', () {
    final result = buildReport([
      ReportBill(
        id: 'source',
        payload: expense().payload,
        remainingAllocatableMinor: '1001',
      ),
      receipt(),
    ], query);
    expect(result.available, isFalse);
    expect(result.issues, ['report.allocation_stale']);
  });

  for (final entry in [
    ({'food': '1000', 'coffee': '100'}, null, 'budget.overlapping_categories'),
    ({'food': '1000'}, '999', 'budget.total_below_categories'),
  ]) {
    test('invalid budget ${entry.$3} keeps all values unavailable', () {
      final original = expense();
      final before = original.payload;
      final result = buildReport(
        [original],
        query,
        categoryParents: {'coffee': 'food'},
        budget: ReportBudget(
          startDate: query.startDate,
          endDateExclusive: query.endDateExclusive,
          totalLimitMinor: entry.$2,
          categoryLimits: entry.$1,
        ),
      );
      expect(result.issues, [entry.$3]);
      expect(result.totals, isNull);
      expect(original.payload, before);
    });
  }

  test('cycle and overflow never publish partial categories or totals', () {
    var result = buildReport(
      [expense()],
      query,
      categoryParents: {'food': 'coffee', 'coffee': 'food'},
    );
    expect(result.issues, ['report.category_cycle']);
    result = buildReport([
      expense(amount: '9223372036854775807'),
      expense(id: 'other', amount: '1'),
    ], query);
    expect(result.issues, ['money.out_of_range']);
    expect(result.totals, isNull);
  });

  test('missing FX only blocks an actual contributing component', () {
    final foreign = expense(
      changes: {
        'money': {
          'currency': 'USD',
          'currency_scale': 2,
          'amount_minor': '100',
        },
      },
    );
    expect(buildReport([foreign], query).issues, ['fx.report_unavailable']);
    final excluded = expense(
      changes: {
        'money': foreign.payload['money'],
        'flags': {'exclude_from_statistics': true, 'exclude_from_budget': true},
      },
    );
    expect(buildReport([excluded], query).available, isTrue);
  });

  test('custom period follows original month-end anchor', () {
    final first = ReportQuery.monthAt(
      bookId: 'book',
      currency: 'CNY',
      scale: 2,
      day: '2026-02-10',
      monthStartDay: 31,
    );
    expect(
      (first.startDate, first.endDateExclusive),
      ('2026-01-31', '2026-02-28'),
    );
    final next = ReportQuery.monthAt(
      bookId: 'book',
      currency: 'CNY',
      scale: 2,
      day: '2026-02-28',
      monthStartDay: 31,
    );
    expect(
      (next.startDate, next.endDateExclusive),
      ('2026-02-28', '2026-03-31'),
    );
  });

  test(
    'stable cumulative receipt rounding closes exactly and ignores input order',
    () {
      final source = expense(
        changes: {
          'money': {
            'currency': 'USD',
            'currency_scale': 2,
            'amount_minor': '3',
          },
          'reporting': {
            'rate': '0.5',
            'report_currency': 'CNY',
            'report_scale': 2,
            'report_amount_minor': '2',
          },
        },
      );
      final refund = receipt(id: 'a', amount: '1'),
          reimbursement = receipt(id: 'b', amount: '2', kind: 'reimbursement');
      final one = buildReport([reimbursement, source, refund], query);
      final two = buildReport([source, refund, reimbursement], query);
      expect(one.toJson(), two.toJson());
      expect(one.totals!.grossExpense.minor.toString(), '2');
      expect(one.totals!.refund!.minor.toString(), '1');
      expect(one.totals!.reimbursement!.minor.toString(), '1');
      expect(one.totals!.expense.minor.toString(), '0');
    },
  );

  test(
    'large report amounts survive JSON above the JavaScript exact integer range',
    () {
      final result = buildReport([expense(amount: '9007199254740993')], query);
      expect(result.totals!.expense.minor.toString(), '9007199254740993');
      expect(
        (result.toJson()['totals'] as Map)['expense_minor'],
        '9007199254740993',
      );
    },
  );
  test('invalid receipt conservation cannot reduce the source expense', () {
    final broken = receipt(
      kind: 'reimbursement',
      changes: {'income_component_minor': '1'},
    );
    final data = buildReport([expense(), broken], query);
    expect(data.available, isFalse);
    expect(data.issues, ['report.invalid_allocation']);
    expect(data.totals, isNull);
  });
  test(
    'unavailable factory accepts only fixed codes and publishes no monetary projection',
    () {
      final result = ReportResult.unavailable(query, [
        'report.scope_unavailable',
        'secret-user-identifier',
        'report.scope_unavailable',
      ]);
      expect(result.available, isFalse);
      expect(result.issues, [
        'report.invalid_data',
        'report.scope_unavailable',
      ]);
      expect(result.totals, isNull);
      expect(result.calendar, isNull);
      expect(result.categoryExpenseMinor, isNull);
      expect(result.budget, isNull);
      expect(
        result.toJson().toString(),
        isNot(contains('secret-user-identifier')),
      );
      expect(ReportResult.unavailable(query, const []).issues, [
        'report.invalid_data',
      ]);
    },
  );
}
