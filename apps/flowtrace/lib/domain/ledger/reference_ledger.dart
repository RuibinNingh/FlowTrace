/// Deterministic in-memory reference, not persistence or resource authorization.
/// P2 supplies database transactions, current permissions and sync receipts.
library;

import 'dart:convert';

import '../../core/money/money.dart';
import 'calendar_rules.dart';
import 'postings.dart';

Map<String, dynamic> _copy(Map value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
BigInt _sum(Iterable<BigInt> values) =>
    values.fold(BigInt.zero, (sum, value) => sum + value);

class ReferenceLedger {
  ReferenceLedger(Map<String, dynamic> setup) : setup = _copy(setup) {
    _state = {
      'accounts': <String, dynamic>{
        for (final row in setup['accounts'] as List? ?? [])
          row['id']: _copy(row),
      },
      'bills': <String, dynamic>{},
      'budgets': <String, dynamic>{
        for (final row in setup['budgets'] as List? ?? [])
          row['id']: _copy(row),
      },
      'rates': <String, dynamic>{
        setup['report_currency']: '1',
        ...?setup['valuation_rates'] as Map?,
      },
      'plans': <String, dynamic>{},
      'rules': <String, dynamic>{},
      'savings': <String, dynamic>{},
      'saving_records': <String, dynamic>{},
    };
    for (final account in _accounts.values) {
      Money(
        account['currency'],
        account['currency_scale'],
        parseMinor(account['opening_minor']),
      );
    }
    for (final query in setup['period_queries'] as List? ?? []) {
      if (!businessDate(
        query['start_date'],
      ).isBefore(businessDate(query['end_date_exclusive']))) {
        throw const DomainError('date.invalid_period');
      }
    }
    for (final budget in _budgets.values) {
      _validateBudget(budget);
    }
  }

  final Map<String, dynamic> setup;
  late Map<String, dynamic> _state;
  Map<String, dynamic> get _accounts => _state['accounts'];
  Map<String, dynamic> get _bills => _state['bills'];
  Map<String, dynamic> get _budgets => _state['budgets'];
  Map<String, dynamic> get _rates => _state['rates'];
  Map<String, dynamic> get _plans => _state['plans'];
  Map<String, dynamic> get _rules => _state['rules'];
  Map<String, dynamic> get _savings => _state['savings'];
  Map<String, dynamic> get _savingRecords => _state['saving_records'];

  Map<String, dynamic> execute(Map<String, dynamic> command) {
    final previous = _copy(_state);
    try {
      final result = _apply(_copy(command));
      return {'result': result, 'state': project()};
    } on DomainError catch (error) {
      _state = previous;
      return {
        'result': 'rejected',
        'error_code': error.code,
        'state': project(),
      };
    } catch (_) {
      _state = previous;
      rethrow;
    }
  }

  String _apply(Map<String, dynamic> command) {
    switch (command['action']) {
      case 'create_bill':
        _createBill(command['bill']);
      case 'update_bill':
        final current = _bill(command['bill_id']);
        final changes = command['changes'] as Map<String, dynamic>;
        if (_allocated(current['id']) > BigInt.zero &&
            changes.keys.any(
              (key) => const {
                'money',
                'bill_type',
                'account_id',
                'business_date',
              }.contains(key),
            )) {
          throw const DomainError('bill.has_allocations');
        }
        if (changes.containsKey('id') || changes.containsKey('book_id')) {
          throw const DomainError('bill.immutable_identity');
        }
        final updated = <String, dynamic>{...current, ...changes};
        BigInt? preservedAdjustment;
        if (preservesAdjustmentDefinition(current, updated)) {
          preservedAdjustment = parseMinor(current['_adjustment_minor']);
        }
        _bills.remove(current['id']);
        _createBill(updated, preservedAdjustment: preservedAdjustment);
      case 'delete_bill':
        final bill = _bill(command['bill_id']);
        if (_allocated(bill['id']) > BigInt.zero) {
          throw const DomainError('bill.has_allocations');
        }
        _bills.remove(bill['id']);
        _savingRecords.removeWhere(
          (key, value) => value['bill_id'] == bill['id'],
        );
      case 'set_valuation_rate':
        parseRate(command['rate']);
        _rates[command['currency']] = command['rate'];
      case 'set_budget':
        final budget = <String, dynamic>{
          'id': command['budget_id'],
          'total_limit_minor': command['total_limit_minor'],
          'categories': command['categories'],
        };
        _validateBudget(budget);
        _budgets[budget['id']] = budget;
      case 'create_installment_plan':
        if (command['mode'] != 'expense_schedule') {
          throw const DomainError('schedule.unsupported_mode');
        }
        if (_plans.containsKey(command['plan_id'])) {
          throw const DomainError('schedule.id_conflict');
        }
        final money = Money.fromJson(command['money'], positive: true);
        final fee = parseMinor(command['total_fee_minor']);
        if (fee < BigInt.zero) {
          throw const DomainError('money.must_be_positive');
        }
        businessDate(command['start_date']);
        final count = command['count'] as int;
        final principal = allocateLast(money.minor.toString(), count);
        final fees = fee == BigInt.zero
            ? List.filled(count, '0')
            : allocateLast(fee.toString(), count);
        _plans[command['plan_id']] = {
          ...command,
          'principal': principal,
          'fees': fees,
          'executed': <int>[],
          'status': 'active',
        };
      case 'execute_occurrence':
        final plan = _plans[command['plan_id']];
        final index = command['occurrence_index'];
        if (index is! int || index < 1 || index > plan['count']) {
          throw const DomainError('schedule.invalid_occurrence');
        }
        if ((plan['executed'] as List).contains(index)) return 'replayed';
        if (plan['status'] != 'active') {
          throw const DomainError('schedule.cancelled_occurrence');
        }
        final date = recurrenceDates(plan['start_date'], 'monthly', index).last;
        final amount =
            parseMinor(plan['principal'][index - 1]) +
            parseMinor(plan['fees'][index - 1]);
        if (amount != BigInt.zero) {
          _generatedExpense(
            'installment:${plan['plan_id']}:$index',
            plan,
            checkedMinor(amount).toString(),
            date,
            'installment',
          );
        }
        (plan['executed'] as List).add(index);
        if ((plan['executed'] as List).length == plan['count']) {
          plan['status'] = 'completed';
        }
      case 'settle_installment':
        final plan = _plans[command['plan_id']];
        if (plan['status'] != 'active') {
          throw const DomainError('schedule.cancelled_occurrence');
        }
        final remaining = _remainingPlan(plan);
        if (parseMinor(command['remaining_principal_minor']) != remaining) {
          throw const DomainError('schedule.remaining_mismatch');
        }
        final fee = parseMinor(command['actual_fee_minor']);
        if (fee < BigInt.zero) {
          throw const DomainError('money.must_be_positive');
        }
        if (remaining + fee != BigInt.zero) {
          _generatedExpense(
            'settlement:${plan['plan_id']}',
            plan,
            checkedMinor(remaining + fee).toString(),
            command['settlement_date'],
            'installment',
          );
        }
        plan['status'] = 'settled';
      case 'create_recurring_rule':
        if (_rules.containsKey(command['rule_id'])) {
          throw const DomainError('schedule.id_conflict');
        }
        final dates = recurrenceDates(
          command['anchor_date'],
          command['frequency'],
          command['count'],
        );
        Money.fromJson(command['bill_template']['money'], positive: true);
        _rules[command['rule_id']] = {
          ...command,
          'dates': dates,
          'executed': <String>[],
        };
      case 'execute_recurring':
        final rule = _rules[command['rule_id']];
        final day = command['occurrence_date'];
        if (!(rule['dates'] as List).contains(day)) {
          throw const DomainError('schedule.invalid_occurrence');
        }
        if ((rule['executed'] as List).contains(day)) return 'replayed';
        _createBill(
          _generatedBill(
            'recurring:${rule['rule_id']}:$day',
            rule['bill_template'],
            day,
            'recurring',
          ),
        );
        (rule['executed'] as List).add(day);
      case 'create_saving_plan':
        if (_savings.containsKey(command['plan_id'])) {
          throw const DomainError('schedule.id_conflict');
        }
        Money.fromJson(command['money'], positive: true);
        _savings[command['plan_id']] = command;
      case 'record_saving':
        final plan = _savings[command['plan_id']];
        final amount = Money.fromJson(command['money'], positive: true);
        final target = Money.fromJson(plan['money']);
        if (amount.currency != target.currency ||
            amount.currencyScale != target.currencyScale) {
          throw const DomainError('money.currency_mismatch');
        }
        if (_savingRecords.containsKey(command['record_id'])) {
          throw const DomainError('saving.id_conflict');
        }
        if (command['mode'] == 'linked_transfer') {
          final day = command['business_date'];
          businessDate(day);
          _createBill(
            _generatedBill(
              command['bill_id'],
              {...command, 'bill_type': 'transfer'},
              day,
              'manual',
            ),
          );
        } else if (command['mode'] != 'progress_only') {
          throw const DomainError('saving.invalid_mode');
        }
        _savingRecords[command['record_id']] = command;
      case 'delete_saving_record':
        final record = _savingRecords.remove(command['record_id']);
        if (record['bill_id'] != null) _bills.remove(record['bill_id']);
      default:
        throw const DomainError('command.unsupported');
    }
    return 'applied';
  }

  Map<String, dynamic> _bill(String billId) {
    final bill = _bills[billId];
    if (bill == null) throw const DomainError('bill.not_found');
    return bill;
  }

  Map<String, dynamic> _generatedBill(
    String billId,
    Map<String, dynamic> template,
    String day,
    String source,
  ) => {
    ...template,
    'id': billId,
    'book_id': setup['book_id'],
    'business_date': day,
    'business_timezone': template['business_timezone'] ?? 'Asia/Shanghai',
    'source': source,
    'account_id': template['account_id'],
    'flags':
        template['flags'] ??
        {'exclude_from_statistics': false, 'exclude_from_budget': false},
    'category_id': template['category_id'] ?? 'uncategorized',
  };

  void _generatedExpense(
    String billId,
    Map<String, dynamic> plan,
    String amount,
    String day,
    String source,
  ) {
    _createBill(
      _generatedBill(
        billId,
        {
          ...plan,
          'bill_type': 'expense',
          'money': {...plan['money'] as Map, 'amount_minor': amount},
        },
        day,
        source,
      ),
    );
  }

  static BigInt _remainingPlan(Map<String, dynamic> plan) {
    if (plan['status'] == 'settled') return BigInt.zero;
    return _sum(
      (plan['principal'] as List)
          .asMap()
          .entries
          .where((entry) {
            return !(plan['executed'] as List).contains(entry.key + 1);
          })
          .map((entry) => parseMinor(entry.value)),
    );
  }

  Map<String, dynamic> _account(Object? accountId, Money money) {
    final account = _accounts[accountId];
    if (account == null) throw const DomainError('account.not_found');
    if (account['currency'] != money.currency ||
        account['currency_scale'] != money.currencyScale) {
      throw const DomainError('money.currency_mismatch');
    }
    return account;
  }

  void _createBill(Map<String, dynamic> source, {BigInt? preservedAdjustment}) {
    final bill = _copy(source);
    if (bill['id'] is! String || (bill['id'] as String).isEmpty) {
      throw const DomainError('bill.invalid_id');
    }
    if (_bills.containsKey(bill['id'])) {
      throw const DomainError('bill.id_conflict');
    }
    final money = Money.fromJson(bill['money'], positive: true);
    businessDate(bill['business_date']);
    final flags = bill['flags'] as Map? ?? {};
    for (final name in ['exclude_from_statistics', 'exclude_from_budget']) {
      if ((flags[name] ?? false) is! bool) {
        throw const DomainError('bill.invalid_flags');
      }
    }
    bill['flags'] = {
      for (final name in ['exclude_from_statistics', 'exclude_from_budget'])
        name: flags[name] ?? false,
    };
    final kind = bill['bill_type'];
    if (const {
      'income',
      'expense',
      'refund',
      'reimbursement',
      'balance_adjustment',
    }.contains(kind)) {
      if (bill['account_id'] != null) _account(bill['account_id'], money);
    } else if (const {
      'transfer',
      'credit_repayment',
      'loan_borrow',
      'loan_lend',
      'loan_collect',
      'loan_repay',
    }.contains(kind)) {
      final first = _account(bill['from_account_id'], money);
      final target = Money.fromJson(
        bill['target_money'] ?? bill['money'],
        positive: true,
      );
      final second = _account(bill['to_account_id'], target);
      if (first['id'] == second['id']) {
        throw const DomainError('transfer.same_account');
      }
      if (kind == 'transfer' &&
          [first, second].any(
            (account) => const {
              'loan_payable',
              'loan_receivable',
            }.contains(account['kind']),
          )) {
        throw const DomainError('transfer.debt_account_forbidden');
      }
    } else {
      throw const DomainError('bill.unsupported_type');
    }
    if (bill.containsKey('gross_amount_minor') ||
        bill.containsKey('discount_minor')) {
      final gross = parseMinor(bill['gross_amount_minor']);
      final discount = parseMinor(bill['discount_minor']);
      if (discount < BigInt.zero ||
          discount > gross ||
          gross - discount != money.minor) {
        throw const DomainError('bill.discount_invalid');
      }
    }
    if (bill['fee'] != null) {
      final fee = bill['fee'];
      _account(fee['account_id'], Money.fromJson(fee['money'], positive: true));
      _reportAmount({...fee as Map<String, dynamic>, 'bill_type': 'expense'});
    }
    if (kind == 'refund' || kind == 'reimbursement') {
      var allocatedReceipt = BigInt.zero;
      final perSource = <String, BigInt>{};
      for (final allocation in bill['allocations'] as List? ?? []) {
        final original = _bill(allocation['source_bill_id']);
        if (original['bill_type'] != 'expense') {
          throw const DomainError('allocation.invalid_source');
        }
        final originalMoney = Money.fromJson(original['money']);
        final sourceAmount = parseMinor(
          allocation['source_amount_minor'],
          positive: true,
        );
        final receiptAmount = parseMinor(
          allocation['receipt_amount_minor'],
          positive: true,
        );
        if (originalMoney.currency == money.currency &&
            originalMoney.currencyScale == money.currencyScale) {
          if (sourceAmount != receiptAmount) {
            throw const DomainError('allocation.amount_mismatch');
          }
        } else {
          if (allocation['rate'] == null) {
            throw const DomainError('fx.rate_required');
          }
          final converted = convertMoney(
            Money(
              originalMoney.currency,
              originalMoney.currencyScale,
              sourceAmount,
            ),
            allocation['rate'],
            money.currency,
            money.currencyScale,
          );
          if (converted.minor != receiptAmount) {
            throw const DomainError('allocation.amount_mismatch');
          }
        }
        final String originalId = original['id'];
        perSource[originalId] =
            (perSource[originalId] ?? BigInt.zero) + sourceAmount;
        if (_allocated(originalId) + perSource[originalId]! >
            originalMoney.minor) {
          throw const DomainError('allocation.exceeds_remaining');
        }
        allocatedReceipt += receiptAmount;
      }
      final income = parseMinor(bill['income_component_minor'] ?? '0');
      if (income < BigInt.zero ||
          (kind == 'reimbursement' && income != BigInt.zero) ||
          income + allocatedReceipt != money.minor) {
        throw const DomainError('allocation.amount_mismatch');
      }
    }
    _reportAmount(bill);
    if (kind == 'balance_adjustment') {
      final current = _balances()[bill['account_id']]!;
      final target = parseMinor(bill['target_balance_minor']);
      final delta = preservedAdjustment ?? checkedMinor(target - current);
      if (delta == BigInt.zero || delta.abs() != money.minor) {
        throw const DomainError('adjustment.amount_mismatch');
      }
      bill['_adjustment_minor'] = delta.toString();
    }
    _bills[bill['id']] = bill;
  }

  BigInt _reportAmount(Map<String, dynamic> bill) {
    final money = Money.fromJson(bill['money']);
    if (money.currency == setup['report_currency'] &&
        money.currencyScale == setup['report_scale']) {
      return money.minor;
    }
    final reporting = bill['reporting'];
    if (reporting == null) throw const DomainError('fx.rate_required');
    final converted = convertMoney(
      money,
      reporting['rate'],
      setup['report_currency'],
      setup['report_scale'],
    );
    if (converted.minor != parseMinor(reporting['report_amount_minor'])) {
      throw const DomainError('fx.amount_mismatch');
    }
    return converted.minor;
  }

  BigInt _allocated(String billId) => _sum(
    _bills.values.expand((bill) {
      return (bill['allocations'] as List? ?? [])
          .where((allocation) => allocation['source_bill_id'] == billId)
          .map((allocation) => parseMinor(allocation['source_amount_minor']));
    }),
  );

  Iterable<Map<String, dynamic>> _effectiveBills() sync* {
    for (final bill in _bills.values) {
      yield bill;
      if (bill['fee'] != null) {
        yield {
          ...bill as Map<String, dynamic>,
          ...bill['fee'] as Map<String, dynamic>,
          'id': '${bill['id']}:fee',
          'bill_type': 'expense',
          'fee': null,
        };
      }
    }
  }

  Map<String, BigInt> _balances() {
    final balances = <String, BigInt>{
      for (final entry in _accounts.entries)
        entry.key: parseMinor(entry.value['opening_minor']),
    };
    for (final bill in _effectiveBills()) {
      final kind = bill['bill_type'];
      final amount = Money.fromJson(bill['money']).minor;
      if (const {
        'transfer',
        'credit_repayment',
        'loan_borrow',
        'loan_lend',
        'loan_collect',
        'loan_repay',
      }.contains(kind)) {
        balances[bill['from_account_id']] =
            balances[bill['from_account_id']]! - amount;
        balances[bill['to_account_id']] =
            balances[bill['to_account_id']]! +
            Money.fromJson(bill['target_money'] ?? bill['money']).minor;
      } else if (bill['account_id'] != null) {
        final delta = kind == 'balance_adjustment'
            ? parseMinor(bill['_adjustment_minor'])
            : kind == 'expense'
            ? -amount
            : amount;
        balances[bill['account_id']] = balances[bill['account_id']]! + delta;
      }
    }
    return balances.map((key, value) => MapEntry(key, checkedMinor(value)));
  }

  static void _validateBudget(Map<String, dynamic> budget) {
    final categories = (budget['categories'] as Map).values
        .map(parseMinor)
        .toList();
    if (categories.any((value) => value < BigInt.zero)) {
      throw const DomainError('money.must_be_positive');
    }
    if (budget['total_limit_minor'] != null &&
        parseMinor(budget['total_limit_minor']) < _sum(categories)) {
      throw const DomainError('budget.total_below_categories');
    }
  }

  Map<String, dynamic> project() {
    final balances = _balances();
    var positive = BigInt.zero;
    var negative = BigInt.zero;
    for (final entry in balances.entries) {
      final account = _accounts[entry.key];
      if (!(account['include_in_net_assets'] ?? true)) continue;
      final rate = _rates[account['currency']];
      if (rate == null) throw const DomainError('fx.rate_required');
      final value = convertMoney(
        Money(account['currency'], account['currency_scale'], entry.value),
        rate,
        setup['report_currency'],
        setup['report_scale'],
      ).minor;
      if (value > BigInt.zero) positive += value;
      if (value < BigInt.zero) negative -= value;
    }
    final periods = <String, dynamic>{};
    for (final query in setup['period_queries'] as List? ?? []) {
      var income = BigInt.zero;
      final categories = <String, BigInt>{};
      final budgetCategories = <String, BigInt>{};
      for (final bill in _effectiveBills()) {
        final String day = bill['business_date'];
        if (day.compareTo(query['start_date']) < 0 ||
            day.compareTo(query['end_date_exclusive']) >= 0) {
          continue;
        }
        final flags = bill['flags'];
        final kind = bill['bill_type'];
        if (kind == 'income' && !flags['exclude_from_statistics']) {
          income += _reportAmount(bill);
        } else if (kind == 'expense') {
          final money = Money.fromJson(bill['money']);
          final report = _reportAmount(bill);
          final amount =
              report -
              roundHalfUp(report * _allocated(bill['id']), money.minor);
          final String category = bill['category_id'];
          if (amount != BigInt.zero && !flags['exclude_from_statistics']) {
            categories[category] =
                (categories[category] ?? BigInt.zero) + amount;
          }
          if (amount != BigInt.zero && !flags['exclude_from_budget']) {
            budgetCategories[category] =
                (budgetCategories[category] ?? BigInt.zero) + amount;
          }
        } else if (kind == 'refund' && !flags['exclude_from_statistics']) {
          final component = parseMinor(bill['income_component_minor'] ?? '0');
          income += roundHalfUp(
            _reportAmount(bill) * component,
            Money.fromJson(bill['money']).minor,
          );
        }
      }
      final expense = _sum(categories.values);
      final eligible = _sum(budgetCategories.values);
      periods[query['period_id']] = {
        'income_minor': checkedMinor(income).toString(),
        'expense_minor': checkedMinor(expense).toString(),
        'net_minor': checkedMinor(income - expense).toString(),
        'budget_eligible_minor': checkedMinor(eligible).toString(),
        'category_expense_minor': categories.map(
          (key, value) => MapEntry(key, checkedMinor(value).toString()),
        ),
        'budget_category_expense_minor': budgetCategories.map(
          (key, value) => MapEntry(key, checkedMinor(value).toString()),
        ),
      };
    }
    final result = <String, dynamic>{
      'account_balances_minor': balances.map(
        (key, value) => MapEntry(key, value.toString()),
      ),
      'periods': periods,
      'assets': {
        'currency': setup['report_currency'],
        'assets_minor': checkedMinor(positive).toString(),
        'liabilities_minor': checkedMinor(negative).toString(),
        'net_minor': checkedMinor(positive - negative).toString(),
      },
    };
    if (_budgets.isNotEmpty) {
      result['budgets'] = <String, dynamic>{};
      for (final entry in _budgets.entries) {
        final budget = entry.value;
        var periodId = budget['period_id'];
        if (periodId == null) {
          if (periods.length != 1) {
            throw const DomainError('budget.period_required');
          }
          periodId = periods.keys.single;
        }
        final period = periods[periodId];
        final subtotal = _sum(
          (budget['categories'] as Map).values.map(parseMinor),
        );
        final total = budget['total_limit_minor'] == null
            ? subtotal
            : parseMinor(budget['total_limit_minor']);
        final BigInt spent;
        if ((budget['categories'] as Map).isEmpty ||
            (budget['total_limit_minor'] != null && total > subtotal)) {
          spent = parseMinor(period['budget_eligible_minor']);
        } else {
          spent = _sum(
            (period['budget_category_expense_minor'] as Map).entries
                .where(
                  (entry) =>
                      (budget['categories'] as Map).containsKey(entry.key),
                )
                .map((entry) => parseMinor(entry.value)),
          );
        }
        result['budgets'][entry.key] = {
          'limit_minor': checkedMinor(total).toString(),
          'spent_minor': checkedMinor(spent).toString(),
          'remaining_minor': checkedMinor(total - spent).toString(),
        };
      }
    }
    if (_bills.values.any((bill) => bill['bill_type'] == 'expense')) {
      result['remaining_allocatable_minor'] = {
        for (final entry in _bills.entries)
          if (entry.value['bill_type'] == 'expense')
            entry.key:
                (Money.fromJson(entry.value['money']).minor -
                        _allocated(entry.key))
                    .toString(),
      };
    }
    if (_plans.isNotEmpty) {
      result['plans'] = {
        for (final entry in _plans.entries)
          entry.key: {
            'remaining_principal_minor': _remainingPlan(entry.value).toString(),
            'status': entry.value['status'],
          },
      };
    }
    if (_savings.isNotEmpty) {
      result['savings'] = {
        for (final entry in _savings.entries)
          entry.key: {
            'progress_minor': checkedMinor(
              _sum(
                _savingRecords.values
                    .where((record) => record['plan_id'] == entry.key)
                    .map((record) => Money.fromJson(record['money']).minor),
              ),
            ).toString(),
            'target_minor': entry.value['money']['amount_minor'],
          },
      };
    }
    return result;
  }
}
