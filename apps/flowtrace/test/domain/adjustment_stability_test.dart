import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/domain/ledger/reference_ledger.dart';

void main() {
  for (final changes in <Map<String, Object?>>[
    {'note': '只改合成备注'},
    {'business_date': '2026-10-22'},
    {
      'flags': {'exclude_from_statistics': true, 'exclude_from_budget': false},
    },
  ]) {
    test(
      'reference retains signed adjustment after later income ${changes.keys.single}',
      () {
        final ledger = ReferenceLedger({
          'principal': 'alice',
          'book_id': 'test',
          'report_currency': 'CNY',
          'report_scale': 2,
          'accounts': [
            {
              'id': 'cash',
              'currency': 'CNY',
              'currency_scale': 2,
              'kind': 'cash',
              'owner_user_id': 'alice',
              'opening_minor': '10000',
              'include_in_net_assets': true,
            },
          ],
          'period_queries': [],
          'budgets': [],
        });
        Map<String, Object?> bill(String id, String kind, String amount) => {
          'id': id,
          'book_id': 'test',
          'bill_type': kind,
          'account_id': 'cash',
          'business_date': '2026-10-21',
          'business_timezone': 'Asia/Shanghai',
          'money': {
            'currency': 'CNY',
            'currency_scale': 2,
            'amount_minor': amount,
          },
          if (kind == 'balance_adjustment') 'target_balance_minor': '9500',
        };
        for (final value in [
          bill('expense', 'expense', '1000'),
          bill('adjust', 'balance_adjustment', '500'),
          bill('income', 'income', '1000'),
        ]) {
          expect(
            ledger.execute({'action': 'create_bill', 'bill': value})['result'],
            'applied',
          );
        }
        final result = ledger.execute({
          'action': 'update_bill',
          'bill_id': 'adjust',
          'changes': changes,
        });
        expect(result['result'], 'applied');
        expect(
          (result['state'] as Map)['account_balances_minor']['cash'],
          '10500',
        );
        expect(
          (ledger.execute({
                'action': 'delete_bill',
                'bill_id': 'adjust',
              })['state']
              as Map)['account_balances_minor']['cash'],
          '10000',
        );
      },
    );
  }
}
