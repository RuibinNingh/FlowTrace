import 'dart:convert';

import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../../domain/assets/asset_catalog.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../../domain/ledger/postings.dart';
import '../../domain/ledger/timezone_rules.dart';
import '../sync/snapshot_protocol.dart';
import 'ledger_models.dart';
import 'ledger_projection.dart';

const _bookFields = {
  'name',
  'currency',
  'timezone',
  'month_start_day',
  'template',
  'icon',
  'cover_color',
  'show_assets',
  'display_mode',
};
const _categoryFields = {
  'name',
  'kind',
  'parent_id',
  'icon',
  'sort_order',
  'archived',
};
const _tagFields = {
  'name',
  'color',
  'kind',
  'group_id',
  'archived',
  'sort_order',
};
const assetAccountOptionalFields = {
  'group_id',
  'sort_order',
  'archived',
  'icon',
  'note',
  'provider_id',
  'bank_id',
  'card_last_four',
  'opening_date',
  'credit',
};
const ordinaryFundAccountKinds = {'cash', 'bank', 'prepaid', 'investment'};
const _billFields = {
  'bill_type',
  'money',
  'book_id',
  'account_id',
  'from_account_id',
  'to_account_id',
  'target_money',
  'transfer_fx',
  'business_date',
  'business_timezone',
  'occurred_at',
  'category_id',
  'tag_ids',
  'attachment_ids',
  'source',
  'flags',
  'note',
  'reporting',
  'allocations',
  'income_component_minor',
  'target_balance_minor',
  'gross_amount_minor',
  'discount_minor',
  'fee',
  'reimbursement_tracking',
  'preserve_hidden_financial_links',
};
const _nonFinancial = {
  'note',
  'category_id',
  'tag_ids',
  'attachment_ids',
  'flags',
  'reimbursement_tracking',
};

Never _fail(String code) => throw DomainError(code);
void _closed(Map<String, Object?> payload, Set<String> fields) {
  if (payload.keys.any((key) => !fields.contains(key))) {
    _fail('ledger.unknown_field');
  }
}

String _text(Object? value, {int max = 80, bool empty = false}) {
  if (value is! String ||
      (!empty && value.isEmpty) ||
      value.length > max ||
      value.contains('\u0000')) {
    _fail('ledger.invalid_text');
  }
  return value;
}

void _boolean(Object? value) {
  if (value is! bool) _fail('ledger.invalid_bool');
}

void _order(Object? value, {int min = 0, int max = 2147483647}) {
  if (value is! int || value < min || value > max) {
    _fail('ledger.invalid_control');
  }
}

void _color(Object? value) {
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    _fail('ledger.invalid_color');
  }
}

Money _money(Object? raw, {bool positive = false, bool nonnegative = false}) {
  final value = Money.fromJson(raw, positive: positive);
  if (currencyScales[value.currency] != value.currencyScale) {
    _fail('currency.unsupported');
  }
  if (nonnegative && value.minor < BigInt.zero) {
    _fail('money.must_be_nonnegative');
  }
  return value;
}

void _flags(Object? value) {
  final flags = ledgerObject(value);
  _closed(flags, {'exclude_from_statistics', 'exclude_from_budget'});
  _boolean(flags['exclude_from_statistics']);
  _boolean(flags['exclude_from_budget']);
}

List<String> _ids(Object? raw, int limit) {
  if (raw is! List || raw.length > limit) _fail('ledger.invalid_list');
  final ids = raw.map(syncIdentifier).toList();
  if (ids.toSet().length != ids.length) _fail('ledger.duplicate_reference');
  return ids;
}

void _reporting(Object? raw, Money value, String bookCurrency) {
  if (raw == null) {
    if (value.currency != bookCurrency) _fail('fx.rate_required');
    return;
  }
  final data = ledgerObject(raw);
  _closed(data, {
    'rate',
    'rate_date',
    'rate_source',
    'report_currency',
    'report_scale',
    'report_amount_minor',
  });
  final rate = _text(data['rate'], max: 39);
  final fraction = parseRate(rate);
  businessDate(data['rate_date']);
  _text(data['rate_source']);
  if (data['report_currency'] != bookCurrency ||
      data['report_scale'] != currencyScales[bookCurrency]) {
    _fail('fx.report_currency_mismatch');
  }
  if (value.currency == bookCurrency &&
      fraction.numerator != fraction.denominator) {
    _fail('fx.same_currency_rate');
  }
  final converted = convertMoney(
    value,
    rate,
    bookCurrency,
    currencyScales[bookCurrency]!,
  );
  if (converted.minor != parseMinor(data['report_amount_minor'])) {
    _fail('fx.amount_mismatch');
  }
}

/// Checks the exact intent against one local authorization/data snapshot. The
/// server repeats authoritative checks under locks; offline knowledge may age.
void validateLedgerWrite(
  LedgerProjection p,
  String type,
  String id,
  String scope,
  String action,
  Map<String, Object?> payload,
) {
  final old = p.payloads[id];
  final live = p.local.values.where(
    (row) => !row.deleted && row.entityId != id,
  );
  Map<String, Object?> reference(
    String identifier,
    String kind, {
    bool sameBook = true,
  }) {
    final row = p.local[identifier];
    if (row == null ||
        row.deleted ||
        row.entityType != kind ||
        sameBook && row.scopeId != scope) {
      _fail('$kind.unavailable');
    }
    return p.payloads[identifier]!;
  }

  bool used() {
    if (type == 'account' &&
        p.rows.shadows.any((row) {
          if (row.scopeId != p.space.userId ||
              row.entityType != 'bill' ||
              row.deleted) {
            return false;
          }
          // Private finance remains usable after shared-book revocation, without
          // exposing that book's notes, tags or attachments.
          final data = ledgerObject(jsonDecode(row.dataJson));
          return data['projection_kind'] == 'bill_private_finance' &&
              ledgerObject(data['account_links']).values.contains(id);
        })) {
      return true;
    }
    for (final row in live) {
      final data = p.payloads[row.entityId]!;
      if (row.entityType == 'bill') {
        if (type == 'account' &&
                accountIds(p.fullBill(row.entityId) ?? data).contains(id) ||
            type == 'category' &&
                (data['category_id'] == id ||
                    (data['fee'] as Map?)?['category_id'] == id) ||
            type == 'tag' && (data['tag_ids'] as List? ?? []).contains(id) ||
            type == 'bill' &&
                (data['allocations'] as List? ?? []).any(
                  (item) => ledgerObject(item)['source_bill_id'] == id,
                )) {
          return true;
        }
      }
      if (type == 'category' &&
          (row.entityType == 'category' && data['parent_id'] == id ||
              row.entityType == 'budget' &&
                  (data['categories'] as List).any(
                    (item) => ledgerObject(item)['category_id'] == id,
                  ))) {
        return true;
      }
      if (type == 'tag' && row.entityType == 'tag' && data['group_id'] == id) {
        return true;
      }
    }
    return false;
  }

  if (action == 'delete') {
    if (payload.isNotEmpty) _fail('ledger.delete_payload');
    if (type == 'book' && live.any((row) => row.scopeId == id)) {
      _fail('book_not_empty');
    }
    if ({'category', 'tag', 'account', 'bill'}.contains(type) && used()) {
      _fail('$type.definition_in_use');
    }
    if (type == 'bill' && p.fullBill(id) == null) {
      _fail('financial_links_hidden');
    }
    return;
  }
  if (type != 'book' && type != 'account') {
    reference(scope, 'book', sameBook: false);
  }
  if (type == 'book') {
    _closed(payload, _bookFields);
    _text(payload['name']);
    if (!currencyScales.containsKey(payload['currency'])) {
      _fail('currency.unsupported');
    }
    instantBusinessDate(
      '2000-01-01T12:00:00Z',
      _text(payload['timezone'], max: 128),
    );
    _order(payload['month_start_day'], min: 1, max: 31);
    final template = _text(payload['template'], max: 64);
    if (!RegExp(r'^[a-z][a-z0-9_-]{0,63}$').hasMatch(template)) {
      _fail('book.invalid_template');
    }
    _text(payload['icon'], max: 64, empty: true);
    _color(payload['cover_color']);
    _boolean(payload['show_assets']);
    if (payload.containsKey('display_mode') &&
        !{'month', 'year', 'all'}.contains(payload['display_mode'])) {
      _fail('book.invalid_display_mode');
    }
    if (old != null &&
        old['currency'] != payload['currency'] &&
        live.any(
          (row) =>
              row.scopeId == id && {'bill', 'budget'}.contains(row.entityType),
        )) {
      _fail('book_currency_in_use');
    }
  } else if (type == 'account') {
    _closed(payload, {
      'name',
      'kind',
      'opening',
      'include_in_net_assets',
      'hidden',
      ...assetAccountOptionalFields,
    });
    if (_text(payload['name']).trim().isEmpty) _fail('ledger.invalid_text');
    if (!{
      'cash',
      'bank',
      'credit_card',
      'loan_receivable',
      'loan_payable',
      'prepaid',
      'investment',
    }.contains(payload['kind'])) {
      _fail('account.invalid_kind');
    }
    final opening = _money(payload['opening']);
    _boolean(payload['include_in_net_assets']);
    _boolean(payload['hidden']);
    _order(payload['sort_order']);
    _boolean(payload['archived']);
    _text(payload['icon'], max: 64, empty: true);
    _text(payload['note'], max: 2000, empty: true);
    for (final key in ['provider_id', 'bank_id']) {
      final value = payload[key];
      if (value != null &&
          (value is! String ||
              !RegExp(r'^[a-z][a-z0-9_-]{0,63}$').hasMatch(value))) {
        _fail('account.invalid_directory_id');
      }
    }
    final provider = payload['provider_id'];
    if (provider != null && assetProviders[provider]?.kind != payload['kind']) {
      _fail('account.invalid_provider');
    }
    if (payload['bank_id'] != null &&
        !assetBanks.containsKey(payload['bank_id'])) {
      _fail('account.invalid_bank');
    }
    final group = payload['group_id'];
    if (group != null) {
      syncIdentifier(group);
      if (scope != p.space.userId) _fail('account.private_group_required');
    }
    final lastFour = payload['card_last_four'];
    if (lastFour != null &&
        (lastFour is! String || !RegExp(r'^[0-9]{4}$').hasMatch(lastFour))) {
      _fail('account.invalid_card_last_four');
    }
    if (payload['opening_date'] != null) businessDate(payload['opening_date']);
    if (payload['credit'] != null) {
      if (payload['kind'] != 'credit_card') _fail('account.invalid_credit');
      final credit = ledgerObject(payload['credit']);
      _closed(credit, {
        'limit',
        'statement_day',
        'statement_day_inclusive',
        'due_mode',
        'due_day',
        'due_days',
      });
      if (credit['limit'] != null) {
        final limit = _money(credit['limit'], nonnegative: true);
        if (limit.currency != opening.currency ||
            limit.currencyScale != opening.currencyScale) {
          _fail('money.currency_mismatch');
        }
      }
      if (credit['statement_day'] != null) {
        _order(credit['statement_day'], min: 1, max: 31);
      }
      if (credit.containsKey('statement_day_inclusive')) {
        _boolean(credit['statement_day_inclusive']);
      }
      switch (credit['due_mode']) {
        case 'fixed_day':
          _order(credit['due_day'], min: 1, max: 31);
          if (credit['due_days'] != null) _fail('account.invalid_credit');
        case 'days_after':
          _order(credit['due_days'], min: 1, max: 120);
          if (credit['due_day'] != null) _fail('account.invalid_credit');
        case null:
          if (credit['due_day'] != null || credit['due_days'] != null) {
            _fail('account.invalid_credit');
          }
        default:
          _fail('account.invalid_credit');
      }
    }
    if (scope != p.space.userId) reference(scope, 'book', sameBook: false);
    if (old != null && used()) {
      final prior = _money(old['opening']);
      if (prior.currency != opening.currency ||
          prior.currencyScale != opening.currencyScale ||
          prior.minor != opening.minor ||
          old['kind'] != payload['kind'] ||
          old['opening_date'] != payload['opening_date']) {
        _fail('account.definition_in_use');
      }
    }
  } else if (type == 'category') {
    _closed(payload, _categoryFields);
    _text(payload['name']);
    _text(payload['icon'], max: 64, empty: true);
    _order(payload['sort_order']);
    _boolean(payload['archived']);
    if (!{'income', 'expense'}.contains(payload['kind'])) {
      _fail('category.invalid_kind');
    }
    final parent = payload['parent_id'];
    if (parent != null) {
      syncIdentifier(parent);
      final target = reference(parent as String, 'category');
      if (parent == id ||
          target['parent_id'] != null ||
          target['kind'] != payload['kind'] ||
          live.any(
            (row) =>
                row.entityType == 'category' &&
                p.payloads[row.entityId]!['parent_id'] == id,
          )) {
        _fail('category.invalid_parent');
      }
      for (final row in live.where(
        (row) => row.entityType == 'budget' && row.scopeId == scope,
      )) {
        final selected = (p.payloads[row.entityId]!['categories'] as List)
            .map((item) => ledgerObject(item)['category_id'])
            .toSet();
        if (selected.contains(id) && selected.contains(parent)) {
          _fail('category.budget_overlap');
        }
      }
    }
    if (old != null && old['kind'] != payload['kind'] && used()) {
      _fail('category.definition_in_use');
    }
  } else if (type == 'tag') {
    _closed(payload, _tagFields);
    _text(payload['name']);
    _color(payload['color']);
    _order(payload['sort_order']);
    _boolean(payload['archived']);
    if (!{'tag', 'group'}.contains(payload['kind'])) _fail('tag.invalid_kind');
    final group = payload['group_id'];
    if (group != null) {
      syncIdentifier(group);
      if (group == id ||
          payload['kind'] == 'group' ||
          reference(group as String, 'tag')['kind'] != 'group') {
        _fail('tag.invalid_group');
      }
    }
    if (old != null && old['kind'] != payload['kind'] && used()) {
      _fail('tag.definition_in_use');
    }
  } else if (type == 'bill') {
    _closed(payload, _billFields);
    final kind = payload['bill_type'];
    if (!singleAccountBillTypes.contains(kind) &&
        !twoAccountBillTypes.contains(kind)) {
      _fail('bill.unsupported_type');
    }
    if (payload.containsKey('reimbursement_tracking')) {
      if (kind != 'expense') {
        _fail('bill.reimbursement_tracking_expense_only');
      }
      _boolean(payload['reimbursement_tracking']);
    }
    final money = _money(payload['money'], positive: true);
    if (old?['bill_type'] == 'expense' && kind != 'expense' && used()) {
      _fail('bill.has_allocations');
    }
    if (payload['book_id'] != null && payload['book_id'] != scope) {
      _fail('bill.wrong_book');
    }
    businessDate(payload['business_date']);
    final zone = _text(payload['business_timezone'], max: 128);
    instantBusinessDate('2000-01-01T12:00:00Z', zone);
    if (payload['occurred_at'] != null &&
        instantBusinessDate(_text(payload['occurred_at'], max: 32), zone) !=
            payload['business_date']) {
      _fail('date.business_date_mismatch');
    }
    _text(payload['note'], max: 2000, empty: true);
    _flags(payload['flags']);
    if (!{
      'manual',
      'import',
      'recurring',
      'installment',
      'auto',
    }.contains(payload['source'])) {
      _fail('bill.invalid_source');
    }
    final tags = _ids(payload['tag_ids'], 100);
    _ids(payload['attachment_ids'], 20);
    final preserve = payload['preserve_hidden_financial_links'] ?? false;
    _boolean(preserve);
    if (preserve == true) {
      if (action != 'update' || old == null || p.fullBill(id) != null) {
        _fail('no_hidden_financial_links');
      }
      for (final field in _billFields.difference(_nonFinancial).difference({
        'preserve_hidden_financial_links',
      })) {
        if (canonicalSyncJson(payload[field]) !=
            canonicalSyncJson(old[field])) {
          _fail('hidden_financial_fields_changed');
        }
      }
    } else if (old != null && p.fullBill(id) == null) {
      _fail('financial_links_hidden');
    }
    void category(Object? value, String expected, Object? previous) {
      if (value == null) return;
      syncIdentifier(value);
      final definition = reference(value as String, 'category');
      if (definition['kind'] != expected) _fail('category.kind_mismatch');
      if (p.archived(value) && previous != value) _fail('category.archived');
    }

    category(
      payload['category_id'],
      kind == 'income' ? 'income' : 'expense',
      old?['category_id'],
    );
    for (final tag in tags) {
      if (reference(tag, 'tag')['kind'] != 'tag') {
        _fail('tag.group_not_selectable');
      }
      if (p.archived(tag) && !(old?['tag_ids'] as List? ?? []).contains(tag)) {
        _fail('tag.archived');
      }
    }
    final bookCurrency =
        reference(scope, 'book', sameBook: false)['currency'] as String;
    _reporting(payload['reporting'], money, bookCurrency);
    Map<String, Object?>? account(Object? value, Money amount) {
      if (value == null) return null;
      syncIdentifier(value);
      final target = reference(value as String, 'account', sameBook: false);
      final row = p.local[value]!;
      if (row.scopeId != p.space.userId && row.scopeId != scope ||
          !p.canWrite('account', row.scopeId)) {
        _fail('account.unavailable');
      }
      final opening = _money(target['opening']);
      if (opening.currency != amount.currency ||
          opening.currencyScale != amount.currencyScale) {
        _fail('money.currency_mismatch');
      }
      if (target['archived'] == true &&
          !accountIds(p.fullBill(id) ?? old ?? const {}).contains(value)) {
        _fail('account.archived');
      }
      if (target['opening_date'] is String &&
          (payload['business_date'] as String).compareTo(
                target['opening_date'] as String,
              ) <
              0) {
        _fail('account.before_opening');
      }
      return target;
    }

    if (twoAccountBillTypes.contains(kind)) {
      if (payload['account_id'] != null ||
          payload['from_account_id'] == payload['to_account_id'] &&
              payload['from_account_id'] != null) {
        _fail('bill.invalid_accounts');
      }
      if (preserve != true &&
          (payload['from_account_id'] == null ||
              payload['to_account_id'] == null)) {
        _fail('bill.two_accounts_required');
      }
      final first = account(payload['from_account_id'], money);
      final second = account(
        payload['to_account_id'],
        payload['target_money'] == null
            ? money
            : _money(payload['target_money'], positive: true),
      );
      final transferFx = payload['transfer_fx'];
      if (transferFx != null) {
        final target = _money(payload['target_money'], positive: true);
        if (target.currency == money.currency) _fail('fx.transfer_not_allowed');
        final fx = ledgerObject(transferFx);
        _closed(fx, {'rate', 'rate_date', 'rate_source'});
        final rate = _text(fx['rate'], max: 39);
        businessDate(fx['rate_date']);
        if (_text(fx['rate_source']).trim().isEmpty) {
          _fail('ledger.invalid_text');
        }
        if (convertMoney(
              money,
              rate,
              target.currency,
              target.currencyScale,
            ).minor !=
            target.minor) {
          _fail('fx.amount_mismatch');
        }
      }
      if (old?['transfer_fx'] != null && transferFx == null) {
        _fail('fx.frozen_rate_required');
      }
      if (kind == 'transfer' &&
          {
            first?['kind'],
            second?['kind'],
          }.intersection({'loan_payable', 'loan_receivable'}).isNotEmpty) {
        _fail('transfer.debt_account_forbidden');
      }
      final expected = switch (kind) {
        'credit_repayment' => (ordinaryFundAccountKinds, {'credit_card'}),
        'loan_borrow' => ({'loan_payable'}, ordinaryFundAccountKinds),
        'loan_lend' => (ordinaryFundAccountKinds, {'loan_receivable'}),
        'loan_collect' => ({'loan_receivable'}, ordinaryFundAccountKinds),
        'loan_repay' => (ordinaryFundAccountKinds, {'loan_payable'}),
        _ => null,
      };
      if (expected != null &&
          (first != null && !expected.$1.contains(first['kind']) ||
              second != null && !expected.$2.contains(second['kind']))) {
        _fail('account.invalid_kind');
      }
    } else {
      if ([
        'from_account_id',
        'to_account_id',
        'target_money',
        'transfer_fx',
        'fee',
      ].any((field) => payload[field] != null)) {
        _fail('bill.transfer_fields_not_allowed');
      }
      account(payload['account_id'], money);
    }
    if (kind == 'balance_adjustment') {
      if (payload['account_id'] == null ||
          payload['target_balance_minor'] == null) {
        _fail('adjustment.target_required');
      }
      parseMinor(payload['target_balance_minor']);
    } else if (payload['target_balance_minor'] != null) {
      _fail('adjustment.target_not_allowed');
    }
    if (payload['fee'] != null) {
      final fee = ledgerObject(payload['fee']);
      _closed(fee, {
        'money',
        'account_id',
        'category_id',
        'flags',
        'reporting',
      });
      final value = _money(fee['money'], positive: true);
      if (fee['account_id'] == null && preserve != true) {
        _fail('fee.account_required');
      }
      account(fee['account_id'], value);
      _flags(fee['flags']);
      _reporting(fee['reporting'], value, bookCurrency);
      category(
        fee['category_id'],
        'expense',
        (old?['fee'] as Map?)?['category_id'],
      );
    }
    final income = parseMinor(payload['income_component_minor']);
    if (income < BigInt.zero) _fail('receipt.invalid_income');
    if (kind == 'expense') {
      var allocated = BigInt.zero;
      for (final row in live.where((row) => row.entityType == 'bill')) {
        for (final raw
            in p.payloads[row.entityId]!['allocations'] as List? ?? []) {
          final allocation = ledgerObject(raw);
          if (allocation['source_bill_id'] == id) {
            allocated = checkedMinor(
              allocated + parseMinor(allocation['source_amount_minor']),
            );
          }
        }
      }
      if (allocated > money.minor) _fail('allocation.exceeds_remaining');
      if (allocated != BigInt.zero && old != null) {
        final previous = _money(old['money']);
        if (previous.currency != money.currency ||
            previous.currencyScale != money.currencyScale) {
          _fail('allocation.source_currency_changed');
        }
      }
    }
    final allocations = payload['allocations'];
    if (allocations is! List || allocations.length > 100) {
      _fail('receipt.invalid_allocations');
    }
    if (!{'refund', 'reimbursement'}.contains(kind)) {
      if (allocations.isNotEmpty || income != BigInt.zero) {
        _fail('receipt.fields_not_allowed');
      }
    } else {
      if (kind == 'reimbursement' && income != BigInt.zero) {
        _fail('receipt.invalid_income');
      }
      var received = income;
      final sources = <String>{};
      for (final raw in allocations) {
        final item = ledgerObject(raw);
        _closed(item, {
          'source_bill_id',
          'source_amount_minor',
          'receipt_amount_minor',
          'rate',
        });
        final sourceId = syncIdentifier(item['source_bill_id']);
        if (sourceId == id || !sources.add(sourceId)) {
          _fail('allocation.invalid_source');
        }
        final source = reference(sourceId, 'bill', sameBook: false);
        if (source['bill_type'] != 'expense' ||
            !p.canWrite('bill', p.local[sourceId]!.scopeId)) {
          _fail('allocation.invalid_source');
        }
        final value = _money(source['money'], positive: true);
        final allocated = parseMinor(
          item['source_amount_minor'],
          positive: true,
        );
        final amount = parseMinor(item['receipt_amount_minor'], positive: true);
        var prior = BigInt.zero;
        for (final row in live.where((row) => row.entityType == 'bill')) {
          for (final other
              in p.payloads[row.entityId]!['allocations'] as List? ?? []) {
            if (ledgerObject(other)['source_bill_id'] == sourceId) {
              prior += parseMinor(ledgerObject(other)['source_amount_minor']);
            }
          }
        }
        if (checkedMinor(prior + allocated) > value.minor) {
          _fail('allocation.exceeds_remaining');
        }
        if (value.currency == money.currency) {
          if (allocated != amount) _fail('allocation.amount_mismatch');
        } else {
          if (item['rate'] == null ||
              convertMoney(
                    Money(value.currency, value.currencyScale, allocated),
                    _text(item['rate'], max: 39),
                    money.currency,
                    money.currencyScale,
                  ).minor !=
                  amount) {
            _fail('allocation.amount_mismatch');
          }
        }
        received = checkedMinor(received + amount);
      }
      if (preserve != true && received != money.minor) {
        _fail('allocation.amount_mismatch');
      }
    }
    if (payload['gross_amount_minor'] != null ||
        payload['discount_minor'] != null) {
      if (kind != 'expense' ||
          payload['gross_amount_minor'] == null ||
          payload['discount_minor'] == null) {
        _fail('discount.fields_not_allowed');
      }
      final gross = parseMinor(payload['gross_amount_minor']),
          discount = parseMinor(payload['discount_minor']);
      if (gross < BigInt.zero ||
          discount < BigInt.zero ||
          gross - discount != money.minor) {
        _fail('discount.amount_mismatch');
      }
    }
  } else if (type == 'budget') {
    _closed(payload, {
      'period_start',
      'period_end_exclusive',
      'total',
      'categories',
      'carry_forward',
    });
    if (!businessDate(
      payload['period_start'],
    ).isBefore(businessDate(payload['period_end_exclusive']))) {
      _fail('budget.invalid_period');
    }
    _boolean(payload['carry_forward']);
    final bookCurrency = reference(scope, 'book', sameBook: false)['currency'];
    final items = payload['categories'];
    if (items is! List ||
        items.length > 100 ||
        payload['total'] == null && items.isEmpty) {
      _fail('budget.invalid_limits');
    }
    var sum = BigInt.zero;
    final selected = <String>{};
    for (final raw in items) {
      final item = ledgerObject(raw);
      _closed(item, {'category_id', 'limit'});
      final category = syncIdentifier(item['category_id']);
      if (!selected.add(category)) _fail('budget.duplicate_category');
      final definition = reference(category, 'category');
      if (definition['kind'] != 'expense') _fail('budget.category_overlap');
      if (p.archived(category) &&
          !(old?['categories'] as List? ?? []).any(
            (old) => ledgerObject(old)['category_id'] == category,
          )) {
        _fail('category.archived');
      }
      final value = _money(item['limit'], nonnegative: true);
      if (value.currency != bookCurrency) _fail('budget.currency_mismatch');
      sum = checkedMinor(sum + value.minor);
    }
    for (final category in selected) {
      if (selected.contains(p.payloads[category]!['parent_id'])) {
        _fail('budget.category_overlap');
      }
    }
    if (payload['total'] != null) {
      final total = _money(payload['total'], nonnegative: true);
      if (total.currency != bookCurrency || total.minor < sum) {
        _fail('budget.invalid_total');
      }
    }
  }
}
