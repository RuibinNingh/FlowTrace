import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/data/ledger/ledger_models.dart';
import 'package:flowtrace/features/home/book_summary.dart';

LedgerEntity bill(
  String type,
  String amount, {
  Map<String, Object?>? extra,
}) => LedgerEntity(
  id: 'synthetic-$type-$amount',
  type: 'bill',
  scopeId: 'synthetic-book',
  revision: '1',
  payload: {
    'bill_type': type,
    'money': {'currency': 'CNY', 'currency_scale': 2, 'amount_minor': amount},
    'flags': {'exclude_from_statistics': false, 'exclude_from_budget': false},
    ...?extra,
  },
  projection: {},
  pending: false,
  conflicted: false,
  deleted: false,
  canEdit: true,
  effectiveArchived: false,
);

void main() {
  test('income, expense and transfer fee use separate statistics flags', () {
    final summary = BookSummary.calculate(
      [
        bill('expense', '9007199254740993'),
        bill('income', '100'),
        bill(
          'expense',
          '8',
          extra: {
            'flags': {
              'exclude_from_statistics': true,
              'exclude_from_budget': false,
            },
          },
        ),
        bill(
          'transfer',
          '5000',
          extra: {
            'flags': {
              'exclude_from_statistics': true,
              'exclude_from_budget': true,
            },
            'fee': {
              'money': {
                'currency': 'CNY',
                'currency_scale': 2,
                'amount_minor': '2',
              },
              'flags': {
                'exclude_from_statistics': false,
                'exclude_from_budget': true,
              },
            },
          },
        ),
      ],
      'CNY',
      2,
    );
    expect(summary.expense!.minor.toString(), '9007199254740995');
    expect(summary.income!.minor.toString(), '100');
  });

  test(
    'missing exchange and not-yet-supported allocation show unavailable',
    () {
      final foreign = bill(
        'expense',
        '1',
        extra: {
          'money': {
            'currency': 'USD',
            'currency_scale': 2,
            'amount_minor': '1',
          },
        },
      );
      expect(BookSummary.calculate([foreign], 'CNY', 2).expense, isNull);
      expect(
        BookSummary.calculate([bill('refund', '1')], 'CNY', 2).expense,
        isNull,
      );
    },
  );
}
