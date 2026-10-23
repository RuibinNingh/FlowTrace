import '../../core/money/money.dart';

/// One exact account movement. Report/budget flags never change account money.
final class FinancialPosting {
  const FinancialPosting(this.accountId, this.component, this.money);
  final String accountId;
  final String component;
  final Money money;
}

const twoAccountBillTypes = {
  'transfer',
  'credit_repayment',
  'loan_borrow',
  'loan_lend',
  'loan_collect',
  'loan_repay',
};
const singleAccountBillTypes = {
  'income',
  'expense',
  'refund',
  'reimbursement',
  'balance_adjustment',
};

/// Existing adjustment metadata never reinterprets its historical target.
bool preservesAdjustmentDefinition(
  Map<String, Object?> previous,
  Map<String, Object?> current,
) {
  if (previous['bill_type'] != 'balance_adjustment' ||
      current['bill_type'] != 'balance_adjustment' ||
      previous['account_id'] != current['account_id'] ||
      previous['target_balance_minor'] != current['target_balance_minor']) {
    return false;
  }
  final before = Money.fromJson(previous['money']),
      after = Money.fromJson(current['money']);
  return before.currency == after.currency &&
      before.currencyScale == after.currencyScale &&
      before.minor == after.minor;
}

List<FinancialPosting> editedFinancialPostings(
  Map<String, Object?> bill, {
  Map<String, Object?>? previousBill,
  List<FinancialPosting>? previousPostings,
  Map<String, BigInt> balances = const {},
}) {
  if (previousBill != null &&
      preservesAdjustmentDefinition(previousBill, bill)) {
    final amount = Money.fromJson(bill['money'], positive: true);
    if (previousPostings == null) {
      throw const DomainError('balance.unavailable');
    }
    if (previousPostings.length != 1 ||
        previousPostings.single.accountId != bill['account_id'] ||
        previousPostings.single.component != 'principal' ||
        previousPostings.single.money.currency != amount.currency ||
        previousPostings.single.money.currencyScale != amount.currencyScale ||
        previousPostings.single.money.minor.abs() != amount.minor) {
      throw const DomainError('adjustment.amount_mismatch');
    }
    return List.unmodifiable(previousPostings);
  }
  return financialPostings(bill, balances: balances);
}

/// Produces movements for a visible bill without mutating caller state. A
/// redacted projection can contain only one side of a transfer; that mode is
/// for reading, and must not authorize a new financial edit.
List<FinancialPosting> financialPostings(
  Map<String, Object?> bill, {
  Map<String, BigInt> balances = const {},
  bool allowHiddenLinks = false,
}) {
  final kind = bill['bill_type'];
  if (!twoAccountBillTypes.contains(kind) &&
      !singleAccountBillTypes.contains(kind)) {
    throw const DomainError('bill.unsupported_type');
  }
  final amount = Money.fromJson(bill['money'], positive: true);
  final result = <FinancialPosting>[];
  String? id(Object? value) {
    if (value == null) return null;
    if (value is! String || value.isEmpty) {
      throw const DomainError('account.id_invalid');
    }
    return value;
  }

  void add(String? account, String component, Money money, bool negative) {
    if (account == null) return;
    result.add(
      FinancialPosting(
        account,
        component,
        Money(
          money.currency,
          money.currencyScale,
          negative ? -money.minor : money.minor,
        ),
      ),
    );
  }

  if (twoAccountBillTypes.contains(kind)) {
    final from = id(bill['from_account_id']);
    final to = id(bill['to_account_id']);
    if (!allowHiddenLinks && (from == null || to == null)) {
      throw const DomainError('bill.two_accounts_required');
    }
    if (from != null && from == to) {
      throw const DomainError('bill.same_account');
    }
    final target = bill['target_money'] == null
        ? amount
        : Money.fromJson(bill['target_money'], positive: true);
    add(from, 'principal', amount, true);
    add(to, 'principal', target, false);
  } else {
    final account = id(bill['account_id']);
    if (kind == 'balance_adjustment') {
      if (account == null) {
        if (!allowHiddenLinks) {
          throw const DomainError('adjustment.account_required');
        }
      } else {
        final before = balances[account];
        if (before == null) {
          throw const DomainError('adjustment.balance_required');
        }
        final target = parseMinor(bill['target_balance_minor']);
        final delta = checkedMinor(target - before);
        if (delta == BigInt.zero || delta.abs() != amount.minor) {
          throw const DomainError('adjustment.amount_mismatch');
        }
        result.add(
          FinancialPosting(
            account,
            'principal',
            Money(amount.currency, amount.currencyScale, delta),
          ),
        );
      }
    } else {
      add(account, 'principal', amount, kind == 'expense');
    }
  }
  final fee = bill['fee'];
  if (fee != null) {
    if (!twoAccountBillTypes.contains(kind) || fee is! Map<String, Object?>) {
      throw const DomainError('bill.fee_invalid');
    }
    final account = id(fee['account_id']);
    if (account == null && !allowHiddenLinks) {
      throw const DomainError('fee.account_required');
    }
    add(account, 'fee', Money.fromJson(fee['money'], positive: true), true);
  }
  return List.unmodifiable(result);
}
