import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../../data/ledger/ledger_models.dart';
import '../../data/preferences/app_preferences.dart';
import '../../data/assets/asset_config_store.dart';
import '../../data/ledger/ledger_validation.dart' show ordinaryFundAccountKinds;
import '../../data/attachments/attachment_transfer.dart';
import '../../data/sync/snapshot_protocol.dart' show canonicalSyncJson;
import '../../domain/ledger/calendar_rules.dart';
import '../../domain/ledger/postings.dart';
import '../../domain/assets/asset_config.dart';
import '../../domain/ledger/timezone_rules.dart';
import '../assets/assets_page.dart';
import '../attachments/attachment_panel.dart';
import '../management/management_page.dart';
import 'entry_icons.dart';
import 'exact_calculator.dart';

class EntryPage extends StatefulWidget {
  const EntryPage({
    required this.app,
    required this.space,
    required this.bookId,
    this.existing,
    this.draft,
    this.initialBusinessDate,
    this.initialType = 'expense',
    this.initialAccountId,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final String bookId;
  final LedgerEntity? existing;
  final LedgerDraft? draft;
  final String? initialBusinessDate;
  final String initialType;
  final String? initialAccountId;
  @override
  State<EntryPage> createState() => _EntryPageState();
}

class _EntryPageState extends State<EntryPage> with WidgetsBindingObserver {
  late final Stream<LedgerView> _stream;
  late final TextEditingController _note,
      _fee,
      _discount,
      _target,
      _rate,
      _feeRate,
      _transferRate,
      _adjustmentTarget;
  late ExactCalculator _calculator;
  late String _type, _currency, _day;
  late String _feeCurrency;
  String? _category, _account, _from, _to, _feeAccount, _draftId, _parent;
  TimeOfDay? _time;
  Set<String> _tags = {};
  List<String> _attachments = [];
  bool _excludeStats = false,
      _excludeBudget = false,
      _busy = false,
      _dirty = false,
      _allowPop = false;
  String? _error;
  late String _entityId;
  String? _editingBaseRevision;
  late bool _isEditing;
  String? _entryTimezone;
  Map<String, Object?>? _originalTemporal;
  late final Map<String, Object?> _originalPayload;
  bool _dateTimeEdited = false, _attachmentBusy = false, _finished = false;
  bool _revealAmounts = false;
  late bool _wasHidden;
  final _retainedFields = <String>{};
  AppPreferences get _preferences => widget.app.preferences.value;
  bool get _concealAmounts => _preferences.hideAmounts && !_revealAmounts;
  bool _showField(String key, bool enabled, bool populated) =>
      enabled || populated || _retainedFields.contains(key);

  void _privacyChanged() {
    final hidden = _preferences.hideAmounts;
    if (_wasHidden != hidden && mounted) {
      setState(() {
        _wasHidden = hidden;
        _revealAmounts = false;
      });
    }
  }

  Timer? _draftTimer;
  Future<void> _draftQueue = Future.value();
  int _editVersion = 0;
  LedgerView? _latest;
  List<String> _preferredCurrencies = const ['CNY'];
  bool get _current =>
      mounted &&
      !_finished &&
      widget.app.space?.id == widget.space.id &&
      !widget.app.switchingSpace;
  String get _timezone =>
      _entryTimezone ??
      _latest?.find('book', widget.bookId)?.payload['timezone'] as String? ??
      'Asia/Shanghai';
  bool get _showAssets =>
      (_preferences.assetsEnabled &&
          _latest?.find('book', widget.bookId)?.payload['show_assets'] ==
              true) ||
      _retainedFields.contains('assets') ||
      _account != null ||
      _from != null ||
      _to != null ||
      _feeAccount != null ||
      _twoAccounts ||
      _type == 'balance_adjustment';
  bool get _twoAccounts => twoAccountBillTypes.contains(_type);
  static const _supportedTypes = {
    'income',
    'expense',
    ...twoAccountBillTypes,
    'balance_adjustment',
  };
  static const _typeLabels = {
    'income': '收入',
    'expense': '支出',
    'transfer': '转账',
    'credit_repayment': '信用卡还款',
    'loan_borrow': '借入',
    'loan_lend': '借出',
    'loan_collect': '收回借款',
    'loan_repay': '归还借款',
    'balance_adjustment': '余额调整',
  };

  @override
  void initState() {
    super.initState();
    _wasHidden = _preferences.hideAmounts;
    widget.app.preferences.addListener(_privacyChanged);
    WidgetsBinding.instance.addObserver(this);
    _stream = widget.app.ledger
        .watch(widget.space, query: LedgerQuery(bookId: widget.bookId))
        .asyncMap((view) async {
          try {
            final snapshot = await AssetConfigStore(
              widget.app.repository,
            ).readSection(widget.space, AssetConfigSection.preferences);
            _preferredCurrencies =
                snapshot?.preferences?.enabledCodes ?? const ['CNY'];
          } on DomainError {
            // A new local-only or recovering space still retains its original
            // currency choices. Preferences never authorize or reinterpret money.
            _preferredCurrencies = const ['CNY'];
          }
          return view;
        });
    final payload =
        widget.draft?.payload ??
        widget.existing?.editablePayload ??
        widget.existing?.payload ??
        <String, Object?>{};
    final ui = widget.draft?.ui ?? <String, Object?>{};
    _originalPayload = ledgerCopy(
      ui['original_payload'] is Map<String, Object?>
          ? ledgerObject(ui['original_payload'])
          : payload,
    );
    _entryTimezone = payload['business_timezone'] as String?;
    if (payload['business_date'] is String &&
        payload['business_timezone'] is String) {
      _originalTemporal = {
        for (final key in ['business_date', 'business_timezone', 'occurred_at'])
          key: payload[key],
      };
    }
    _dateTimeEdited = ui['time_edited'] == true;
    _entityId =
        widget.existing?.id ??
        ui['entry_entity_id'] as String? ??
        const Uuid().v4();
    _isEditing = widget.existing != null || ui['editing_entity_id'] is String;
    _editingBaseRevision =
        ui['editing_base_revision'] as String? ?? widget.existing?.revision;
    final money = payload['money'] == null
        ? null
        : Money.fromJson(payload['money']);
    _currency = money?.currency ?? 'CNY';
    _calculator = ExactCalculator(
      currency: _currency,
      scale: currencyScales[_currency]!,
      initial: ui['expression'] as String? ?? money?.display() ?? '',
    );
    _type = payload['bill_type'] as String? ?? widget.initialType;
    _day =
        ui['day'] as String? ??
        payload['business_date'] as String? ??
        widget.initialBusinessDate ??
        '';
    _category = payload['category_id'] as String?;
    _account = payload['account_id'] as String?;
    _from = payload['from_account_id'] as String?;
    _to = payload['to_account_id'] as String?;
    if (widget.existing == null &&
        widget.draft == null &&
        widget.initialAccountId != null) {
      switch (_type) {
        case 'credit_repayment' || 'loan_lend' || 'loan_repay':
          _to = widget.initialAccountId;
        case 'transfer' || 'loan_borrow' || 'loan_collect':
          _from = widget.initialAccountId;
        default:
          _account = widget.initialAccountId;
      }
    }
    _tags = (payload['tag_ids'] as List? ?? []).cast<String>().toSet();
    _attachments = (payload['attachment_ids'] as List? ?? [])
        .cast<String>()
        .toList();
    final flags = payload['flags'] as Map? ?? {};
    _excludeStats = flags['exclude_from_statistics'] == true;
    _excludeBudget = flags['exclude_from_budget'] == true;
    final fee = payload['fee'] as Map?;
    _feeCurrency =
        ui['fee_currency'] as String? ??
        (fee == null ? _currency : Money.fromJson(fee['money']).currency);
    _feeAccount = fee?['account_id'] as String?;
    _note = TextEditingController(text: payload['note'] as String? ?? '');
    _fee = TextEditingController(
      text:
          ui['fee'] as String? ??
          (fee == null ? '' : Money.fromJson(fee['money']).display()),
    );
    _discount = TextEditingController(
      text:
          ui['discount'] as String? ??
          (payload['discount_minor'] == null
              ? ''
              : Money(
                  _currency,
                  currencyScales[_currency]!,
                  parseMinor(payload['discount_minor']),
                ).display()),
    );
    _target = TextEditingController(
      text:
          ui['target'] as String? ??
          (payload['target_money'] == null
              ? ''
              : Money.fromJson(payload['target_money']).display()),
    );
    _rate = TextEditingController(
      text:
          ui['rate'] as String? ??
          (payload['reporting'] as Map?)?['rate'] as String? ??
          '',
    );
    _feeRate = TextEditingController(
      text:
          ui['fee_rate'] as String? ??
          (fee?['reporting'] as Map?)?['rate'] as String? ??
          '',
    );
    _transferRate = TextEditingController(
      text:
          ui['transfer_rate'] as String? ??
          (payload['transfer_fx'] as Map?)?['rate'] as String? ??
          '',
    );
    _adjustmentTarget = TextEditingController(
      text:
          ui['adjustment_target'] as String? ??
          (payload['target_balance_minor'] == null
              ? ''
              : Money(
                  _currency,
                  currencyScales[_currency]!,
                  parseMinor(payload['target_balance_minor']),
                ).display()),
    );
    _draftId = widget.draft?.id;
    final time = (ui['time'] as String?)?.split(':');
    if (time != null && time.length == 2) {
      _time = TimeOfDay(hour: int.parse(time[0]), minute: int.parse(time[1]));
    } else if (payload['occurred_at'] is String) {
      final zone = payload['business_timezone'] as String;
      instantBusinessDate(payload['occurred_at'] as String, zone);
      final wall = tz.TZDateTime.from(
        DateTime.parse(payload['occurred_at'] as String),
        tz.getLocation(zone),
      );
      _time = TimeOfDay(hour: wall.hour, minute: wall.minute);
    }
    _retainedFields.addAll({
      if (_time != null) 'time',
      if (_discount.text.isNotEmpty) 'discount',
      if (_tags.isNotEmpty) 'tags',
      if (_attachments.isNotEmpty) 'images',
      if (_excludeStats || _excludeBudget) 'flags',
      if (_account != null ||
          _from != null ||
          _to != null ||
          _feeAccount != null)
        'assets',
      if (money != null) 'currency',
    });
    for (final field in [
      _note,
      _fee,
      _discount,
      _target,
      _rate,
      _feeRate,
      _transferRate,
      _adjustmentTarget,
    ]) {
      field.addListener(_changed);
    }
  }

  void _changed() {
    _dirty = true;
    ++_editVersion;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 350), _autoSave);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.app.registerUpdateParticipant(
      this,
      route: ModalRoute.of(context),
      prepare: _prepareUpdate,
    );
  }

  Future<bool> _prepareUpdate() async {
    _draftTimer?.cancel();
    if (_busy || _attachmentBusy || !_current) return false;
    await _draftQueue;
    if (_dirty) {
      if (_latest == null) return false;
      await _saveDraft();
    }
    return _current && !_dirty && !_busy && !_attachmentBusy;
  }

  void _autoSave() {
    if (!_dirty || _busy || !_current || _latest == null) return;
    unawaited(
      _saveDraft().catchError((Object _) {
        if (mounted && _current) setState(() => _error = '自动保存草稿失败，请保留输入并重试。');
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted && _revealAmounts) {
      setState(() => _revealAmounts = false);
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _draftTimer?.cancel();
      _autoSave();
    }
  }

  @override
  void dispose() {
    widget.app.preferences.removeListener(_privacyChanged);
    widget.app.unregisterUpdateParticipant(this);
    _draftTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final field in [
      _note,
      _fee,
      _discount,
      _target,
      _rate,
      _feeRate,
      _transferRate,
      _adjustmentTarget,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Map<String, Object?> _payload({required bool validate}) {
    Money amount;
    try {
      amount = _type == 'balance_adjustment'
          ? (_originalPayload['money'] == null
                ? Money(_currency, currencyScales[_currency]!, BigInt.one)
                : Money.fromJson(_originalPayload['money']))
          : _calculator.evaluate(positive: validate);
    } on DomainError {
      if (validate) rethrow;
      amount = Money(_currency, currencyScales[_currency]!, BigInt.one);
    }
    final book = _latest?.find('book', widget.bookId);
    if (validate && (book == null || !_latest!.writable)) {
      throw const DomainError('ledger.read_only');
    }
    final reportCurrency = book?.payload['currency'] as String? ?? _currency;
    Map<String, Object?>? reporting(
      Money value, {
      Map? previous,
      bool fee = false,
    }) {
      final original = fee ? previous : _originalPayload['reporting'] as Map?;
      if (value.currency == reportCurrency && original == null) return null;
      if (!validate && _rate.text.trim().isEmpty) return null;
      final rate = fee
          ? (_feeRate.text.trim().isNotEmpty
                ? _feeRate.text.trim()
                : (value.currency == _currency ? _rate.text.trim() : ''))
          : _rate.text.trim();
      final converted = convertMoney(
        value,
        rate,
        reportCurrency,
        currencyScales[reportCurrency]!,
      );
      final keepSource = original?['rate'] == rate;
      return {
        'rate': rate,
        'rate_date': keepSource ? original!['rate_date'] : _day,
        'rate_source': keepSource ? original!['rate_source'] : 'manual',
        'report_currency': reportCurrency,
        'report_scale': converted.currencyScale,
        'report_amount_minor': converted.minor.toString(),
      };
    }

    final result = <String, Object?>{
      'bill_type': _type,
      'money': amount.toJson(),
      'book_id': widget.bookId,
      'business_date': _day,
      'business_timezone': _timezone,
      'occurred_at': null,
      'category_id': _twoAccounts || _type == 'balance_adjustment'
          ? null
          : _category,
      'tag_ids': _tags.toList(),
      'attachment_ids': _attachments,
      'source':
          widget.draft?.payload['source'] ??
          widget.existing?.payload['source'] ??
          'manual',
      'flags': {
        'exclude_from_statistics': _excludeStats,
        'exclude_from_budget': _excludeBudget,
      },
      'note': _note.text,
      'reporting': validate ? reporting(amount) : null,
    };
    if (!_dateTimeEdited && _originalTemporal != null) {
      result.addAll(_originalTemporal!);
    } else if (_time != null) {
      final wall =
          '${_day}T${_time!.hour.toString().padLeft(2, '0')}:${_time!.minute.toString().padLeft(2, '0')}:00';
      final resolved = resolveLocalTime(wall, _timezone);
      // DST gap resolution can move the business date; store the resolved pair.
      result['occurred_at'] = resolved.toUtc().toIso8601String();
      result['business_date'] = isoBusinessDate(resolved);
    }
    if (!validate) {
      result['account_id'] = _account;
      result['from_account_id'] = _from;
      result['to_account_id'] = _to;
      for (final field in [
        'reporting',
        'transfer_fx',
        'target_money',
        'target_balance_minor',
      ]) {
        if (_originalPayload.containsKey(field)) {
          result[field] = _originalPayload[field];
        }
      }
      if (_fee.text.isNotEmpty) {
        result['fee'] = {
          'account_id': _feeAccount,
          'money': Money(
            _feeCurrency,
            currencyScales[_feeCurrency]!,
            BigInt.one,
          ).toJson(),
        };
      }
      return result;
    }
    if (_twoAccounts) {
      if (validate && (_from == null || _to == null || _from == _to)) {
        throw const DomainError('bill.two_accounts_required');
      }
      result['from_account_id'] = _from;
      result['to_account_id'] = _to;
      final targetAccount = _to == null ? null : _latest?.find('account', _to!);
      final targetMoney = targetAccount == null
          ? amount
          : Money.fromJson(targetAccount.payload['opening']);
      if (targetMoney.currency != amount.currency) {
        final target = parseDisplay(
          _target.text.trim(),
          targetMoney.currency,
          targetMoney.currencyScale,
        );
        result['target_money'] = target.toJson();
        final original = _originalPayload['transfer_fx'] as Map?;
        if (_transferRate.text.trim().isNotEmpty) {
          final keepSource = original?['rate'] == _transferRate.text.trim();
          result['transfer_fx'] = {
            'rate': _transferRate.text.trim(),
            'rate_date': keepSource ? original!['rate_date'] : _day,
            'rate_source': keepSource ? original!['rate_source'] : 'manual',
          };
        } else if (!_isEditing ||
            original != null ||
            _originalPayload['from_account_id'] != _from ||
            _originalPayload['to_account_id'] != _to ||
            canonicalSyncJson(_originalPayload['money']) !=
                canonicalSyncJson(amount.toJson()) ||
            canonicalSyncJson(_originalPayload['target_money']) !=
                canonicalSyncJson(target.toJson())) {
          throw const DomainError('fx.transfer_rate_required');
        }
      }
      if (_fee.text.trim().isNotEmpty) {
        final fee = parseDisplay(
          _fee.text.trim(),
          _feeCurrency,
          currencyScales[_feeCurrency]!,
        );
        if (fee.minor < BigInt.zero) {
          throw const DomainError('money.must_be_positive');
        }
        if (fee.minor > BigInt.zero) {
          final originalFee = _originalPayload['fee'] as Map?;
          result['fee'] = {
            'money': fee.toJson(),
            'account_id': _feeAccount ?? _from,
            'category_id': originalFee?['category_id'],
            'flags':
                originalFee?['flags'] ??
                {
                  'exclude_from_statistics': _excludeStats,
                  'exclude_from_budget': _excludeBudget,
                },
            'reporting': reporting(
              fee,
              previous: originalFee?['reporting'] as Map?,
              fee: true,
            ),
          };
        }
      }
    } else {
      result['account_id'] = _account;
      if (_type == 'balance_adjustment') {
        if (_account == null) {
          throw const DomainError('adjustment.target_required');
        }
        result['target_balance_minor'] = parseDisplay(
          _adjustmentTarget.text.trim(),
          _currency,
          currencyScales[_currency]!,
        ).minor.toString();
      }
      if (_type == 'expense' && _discount.text.trim().isNotEmpty) {
        final discount = parseDisplay(
          _discount.text.trim(),
          _currency,
          currencyScales[_currency]!,
        );
        if (discount.minor < BigInt.zero) {
          throw const DomainError('money.must_be_positive');
        }
        result['discount_minor'] = discount.minor.toString();
        result['gross_amount_minor'] = checkedMinor(
          amount.minor + discount.minor,
        ).toString();
      }
    }
    if (validate && _note.text.length > 2000) {
      throw const DomainError('bill.note_too_long');
    }
    return result;
  }

  Future<void> _saveDraft({List<String>? attachments}) {
    final next = _draftQueue.then((_) => _persistDraft(attachments));
    _draftQueue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _persistDraft(List<String>? attachments) async {
    if (!_current) throw const DomainError('identity_changed');
    final previous = _attachments;
    if (attachments != null) _attachments = List.of(attachments);
    final version = _editVersion;
    try {
      _draftId = await widget.app.ledger.saveDraft(
        widget.space,
        bookId: widget.bookId,
        draftId: _draftId,
        payload: _payload(validate: false),
        ui: {
          'expression': _calculator.expression,
          'fee': _fee.text,
          'fee_currency': _feeCurrency,
          'fee_rate': _feeRate.text,
          'discount': _discount.text,
          'target': _target.text,
          'rate': _rate.text,
          'day': _day,
          'time_edited': _dateTimeEdited,
          'transfer_rate': _transferRate.text,
          'adjustment_target': _adjustmentTarget.text,
          if (_isEditing) 'original_payload': _originalPayload,
          if (_time != null) 'time': '${_time!.hour}:${_time!.minute}',
          if (_isEditing) 'editing_entity_id': _entityId,
          if (_editingBaseRevision != null)
            'editing_base_revision': _editingBaseRevision,
          'entry_entity_id': _entityId,
        },
      );
      if (!_current) throw const DomainError('identity_changed');
      _dirty = _editVersion != version;
    } catch (_) {
      _attachments = previous;
      rethrow;
    }
  }

  Future<void> _leave() async {
    if (_busy) return;
    try {
      if (_dirty && _current) await _saveDraft();
      if (mounted) {
        _finished = true;
        setState(() => _allowPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '草稿未能保存，请重试或保留输入。');
    }
  }

  Future<void> _save(bool again) async {
    if (_busy || _attachmentBusy || !_current) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // A failed formal write always has a complete, recoverable draft.
      await _saveDraft();
      final payload = _payload(validate: true);
      if (_type == 'balance_adjustment' &&
          (!_isEditing ||
              _originalPayload['account_id'] != payload['account_id'] ||
              _originalPayload['target_balance_minor'] !=
                  payload['target_balance_minor'])) {
        payload['money'] = (await widget.app.ledger.adjustmentAmount(
          widget.space,
          accountId: payload['account_id'] as String,
          targetBalanceMinor: payload['target_balance_minor'] as String,
          existingBillId: _isEditing ? _entityId : null,
        )).toJson();
        if (!_current) throw const DomainError('identity_changed');
        if (payload['reporting'] is Map<String, Object?>) {
          final frozen = ledgerObject(payload['reporting']);
          final converted = convertMoney(
            Money.fromJson(payload['money']),
            frozen['rate'] as String,
            frozen['report_currency'] as String,
            frozen['report_scale'] as int,
          );
          payload['reporting'] = {
            ...frozen,
            'report_amount_minor': converted.minor.toString(),
          };
        }
      }
      if (_isEditing && _editingBaseRevision == null) {
        throw const DomainError('draft.missing_revision');
      }
      await widget.app.ledger.save(
        widget.space,
        entityType: 'bill',
        scopeId: widget.bookId,
        entityId: _entityId,
        baseRevision: _editingBaseRevision,
        payload: payload,
      );
      final savedDraft = _draftId;
      if (savedDraft != null) {
        await widget.app.ledger.deleteDraft(widget.space, savedDraft);
      }
      if (!mounted || !_current) return;
      _dirty = false;
      if (again && !_isEditing) {
        setState(() {
          _entityId = const Uuid().v4();
          _draftId = null;
          _calculator.expression = '';
          _note.clear();
          _fee.clear();
          _discount.clear();
          _attachments = [];
          _dirty = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已保存到本机，继续记下一笔。')));
      } else {
        _finished = true;
        setState(() => _allowPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, true);
        });
      }
    } on DomainError catch (e) {
      if (mounted && _current) {
        setState(
          () => _error = switch (e.code) {
            'money.must_be_positive' => '金额必须大于零。',
            'bill.two_accounts_required' => '请选择两个不同的资金账户。',
            'fx.rate_invalid' || 'fx.rate_required' => '请填写本笔折算到账本币种的有效汇率。',
            'fx.transfer_rate_required' => '请填写本次转出到转入币种的冻结汇率。',
            'fx.amount_mismatch' => '到账金额与填写的汇率不一致，请核对后保存。',
            'adjustment.no_change' => '目标余额与当前余额相同，无须调整。',
            'calculator.incomplete' => '请完成金额计算。',
            _ => '请核对金额、分类、账户和权限；完整输入已保存为草稿。',
          },
        );
      }
    } catch (_) {
      if (mounted && _current) setState(() => _error = '未能完成入账，输入已保留，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _changeType(String value) {
    if (value == _type) return;
    setState(() {
      _type = value;
      _category = null;
      _parent = null;
      _account = null;
      _from = null;
      _to = null;
      _feeAccount = null;
      _fee.clear();
      _feeCurrency = _currency;
      _feeRate.clear();
      _discount.clear();
      _target.clear();
      _transferRate.clear();
      _adjustmentTarget.clear();
      _changed();
    });
  }

  void _setCurrency(String currency) {
    _currency = currency;
    _calculator = ExactCalculator(
      currency: currency,
      scale: currencyScales[currency]!,
    );
    _account = _from = _to = _feeAccount = null;
    _fee.clear();
    _feeCurrency = _currency;
    _discount.clear();
    _target.clear();
    _rate.clear();
    _feeRate.clear();
    _transferRate.clear();
    _adjustmentTarget.clear();
    _changed();
  }

  void _swapAccounts() {
    final from = _from;
    final next = _to == null ? null : _latest?.find('account', _to!);
    if (next != null) {
      final money = Money.fromJson(next.payload['opening']);
      if (money.currency != _currency) {
        final oldAmount = _calculator.preview ?? '';
        _calculator = ExactCalculator(
          currency: money.currency,
          scale: money.currencyScale,
          initial: _target.text.trim(),
        );
        _currency = money.currency;
        _target.text = oldAmount;
        _rate.clear();
        _feeRate.clear();
        _transferRate.clear();
        _fee.clear();
        _feeCurrency = _currency;
      }
    }
    _from = _to;
    _to = from;
    _feeAccount = null;
    _changed();
  }

  Future<void> _date() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: businessDate(_day),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100, 12, 31),
    );
    if (selected != null && mounted && _current) {
      setState(() {
        _day = isoBusinessDate(selected);
        _dateTimeEdited = true;
        _changed();
      });
    }
  }

  Widget _accountField(
    String label,
    String? value,
    void Function(String?) change, {
    bool nullable = true,
    bool matching = true,
    Set<String>? kinds,
  }) {
    final accounts = _latest!.accounts
        .where(
          (a) =>
              (a.payload['hidden'] != true || a.id == value) &&
              (a.payload['archived'] != true || _isEditing && a.id == value) &&
              (kinds == null || kinds.contains(a.payload['kind'])) &&
              (!matching ||
                  Money.fromJson(a.payload['opening']).currency == _currency),
        )
        .toList();
    return DropdownButtonFormField<String>(
      key: ValueKey('$label:$value:${accounts.map((a) => a.id).join()}'),
      initialValue: accounts.any((a) => a.id == value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        if (nullable) const DropdownMenuItem(value: '', child: Text('不关联账户')),
        for (final a in accounts)
          DropdownMenuItem(
            value: a.id,
            child: Text(a.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _busy
          ? null
          : (v) => setState(() {
              change(v == '' ? null : v);
              _changed();
            }),
    );
  }

  Widget _categories(LedgerView view) {
    if (_twoAccounts || _type == 'balance_adjustment') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            Icon(
              _type == 'balance_adjustment'
                  ? Icons.balance
                  : Icons.swap_horiz_rounded,
              size: 64,
            ),
            const SizedBox(height: 12),
            Text(
              _type == 'balance_adjustment'
                  ? '调整会新增有记录的余额差额，不计入收支。'
                  : '转账、还款和借贷本金不计入收支，手续费单独计支出。',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    final categories = view.categories
        .where((c) => c.payload['kind'] == _type && !c.effectiveArchived)
        .toList();
    final roots = categories
        .where((c) => c.payload['parent_id'] == null)
        .toList();
    final children = categories
        .where((c) => c.payload['parent_id'] == _parent)
        .toList();
    Widget grid(List<LedgerEntity> list) => Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final c in list)
          SizedBox(
            width: 76,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _busy
                  ? null
                  : () => setState(() {
                      _category = c.id;
                      if (c.payload['parent_id'] == null) _parent = c.id;
                      _changed();
                    }),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 4,
                ),
                child: Column(
                  children: [
                    if (_preferences.showCategoryIcons)
                      Icon(
                        EntryIcons.of(c.payload['icon']),
                        size: 29,
                        color: _category == c.id
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    if (_preferences.showCategoryIcons)
                      const SizedBox(height: 8),
                    Text(
                      _preferences.showFullCategory &&
                              c.payload['parent_id'] is String
                          ? '${view.find('category', c.payload['parent_id'] as String)?.name ?? '分类'} / ${c.name}'
                          : c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _category == c.id
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (roots.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('此账本还没有分类，可从右上角管理入口添加。', textAlign: TextAlign.center),
          ),
        grid(roots),
        if (_parent != null && children.isNotEmpty) ...[
          const Divider(),
          grid(children),
        ],
      ],
    );
  }

  Widget _details(LedgerView view) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('entry-note'),
              controller: _note,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: '备注',
                counterText: '',
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (_showField(
            'currency',
            _preferences.multiCurrencyEnabled,
            _currency != view.find('book', widget.bookId)?.payload['currency'],
          ))
            DropdownButton<String>(
              key: const Key('entry-currency'),
              value: _currency,
              items: [
                ..._preferredCurrencies,
                ...currencyScales.keys.where(
                  (code) => !_preferredCurrencies.contains(code),
                ),
              ].map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _setCurrency(v!);
                    }),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ActionChip(
            avatar: const Icon(Icons.calendar_today_outlined, size: 16),
            label: Text(_day),
            onPressed: _date,
          ),
          if (_showField('time', _preferences.billTimeEnabled, _time != null))
            ActionChip(
              key: const Key('entry-time'),
              avatar: const Icon(Icons.schedule_outlined, size: 16),
              label: Text(_time == null ? '不指定时间' : _time!.format(context)),
              onPressed: () async {
                final t = await showTimePicker(
                  context: context,
                  initialTime: _time ?? TimeOfDay.now(),
                );
                if (t != null && mounted && _current) {
                  setState(() {
                    _time = t;
                    _dateTimeEdited = true;
                    _changed();
                  });
                }
              },
            ),
          if (_time != null)
            ActionChip(
              label: const Text('清除时间'),
              onPressed: () => setState(() {
                _time = null;
                _dateTimeEdited = true;
                _changed();
              }),
            ),
          if (_showAssets)
            ActionChip(
              avatar: const Icon(
                Icons.account_balance_wallet_outlined,
                size: 16,
              ),
              label: const Text('管理账户'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      AssetsPage(app: widget.app, space: widget.space),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      if (_twoAccounts) ...[
        _accountField(
          '转出账户',
          _from,
          (v) => _from = v,
          nullable: false,
          kinds: switch (_type) {
            'loan_borrow' => {'loan_payable'},
            'loan_collect' => {'loan_receivable'},
            'transfer' => {...ordinaryFundAccountKinds, 'credit_card'},
            _ => ordinaryFundAccountKinds,
          },
        ),
        IconButton(
          tooltip: '交换账户',
          onPressed: _busy || _type != 'transfer'
              ? null
              : () => setState(_swapAccounts),
          icon: const Icon(Icons.swap_vert),
        ),
        _accountField(
          '转入账户',
          _to,
          (v) => _to = v,
          nullable: false,
          matching: false,
          kinds: switch (_type) {
            'credit_repayment' => {'credit_card'},
            'loan_lend' => {'loan_receivable'},
            'loan_repay' => {'loan_payable'},
            'transfer' => {...ordinaryFundAccountKinds, 'credit_card'},
            _ => ordinaryFundAccountKinds,
          },
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('entry-target-money'),
          controller: _target,
          obscureText: _concealAmounts,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: '跨币种到账金额（同币种留空）'),
        ),
        if (_to != null &&
            view.find('account', _to!) != null &&
            Money.fromJson(
                  view.find('account', _to!)!.payload['opening'],
                ).currency !=
                _currency) ...[
          const SizedBox(height: 12),
          TextField(
            key: const Key('entry-transfer-rate'),
            controller: _transferRate,
            obscureText: _concealAmounts,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText:
                  '1 $_currency 折合多少 ${Money.fromJson(view.find('account', _to!)!.payload['opening']).currency}',
              helperText: '保存本次转账汇率及日期，不使用资产估值替换。',
            ),
          ),
          if ((_originalPayload['transfer_fx'] as Map?)?['rate'] ==
              _transferRate.text.trim())
            Text(
              '保留原汇率日期 ${(_originalPayload['transfer_fx'] as Map)['rate_date']} · '
              '${(_originalPayload['transfer_fx'] as Map)['rate_source']}',
            ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _fee,
          obscureText: _concealAmounts,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: '手续费 ($_feeCurrency)'),
        ),
        const SizedBox(height: 12),
        _accountField('手续费账户（默认转出账户）', _feeAccount, (v) {
          _feeAccount = v;
          final currency = v == null
              ? _currency
              : Money.fromJson(
                  view.find('account', v)!.payload['opening'],
                ).currency;
          if (_feeCurrency != currency) {
            _feeCurrency = currency;
            _fee.clear();
            _feeRate.clear();
          }
        }, matching: false),
        if (_feeCurrency !=
            view.find('book', widget.bookId)?.payload['currency']) ...[
          const SizedBox(height: 12),
          TextField(
            key: const Key('entry-fee-rate'),
            controller: _feeRate,
            obscureText: _concealAmounts,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText:
                  '手续费：1 $_feeCurrency 折合多少 ${view.find('book', widget.bookId)?.payload['currency']}',
              helperText: _feeCurrency == _currency
                  ? '留空沿用本笔账本折算汇率，单独填写可固定手续费折算。'
                  : '手续费币种不同，请单独填写折算到账本币种的汇率。',
            ),
          ),
        ],
      ] else if (_showAssets)
        _accountField(
          '资金账户',
          _account,
          (v) {
            _account = v;
            if (_type == 'balance_adjustment' && v != null) {
              final currency = Money.fromJson(
                view.find('account', v)!.payload['opening'],
              );
              if (_currency != currency.currency) {
                _currency = currency.currency;
                _adjustmentTarget.clear();
              }
            }
          },
          nullable: _type != 'balance_adjustment',
          matching: _type != 'balance_adjustment',
        ),
      if (_type == 'balance_adjustment') ...[
        const SizedBox(height: 12),
        TextField(
          key: const Key('entry-adjustment-target'),
          controller: _adjustmentTarget,
          obscureText: _concealAmounts,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            labelText: '目标余额 ($_currency)',
            helperText: '欠款填负数；保存时核对当前余额并记录差额。',
          ),
        ),
      ],
      if (_type == 'expense' &&
          _showField(
            'discount',
            _preferences.discountEnabled,
            _discount.text.isNotEmpty,
          )) ...[
        const SizedBox(height: 12),
        TextField(
          key: const Key('entry-discount'),
          controller: _discount,
          obscureText: _concealAmounts,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: '优惠金额',
            helperText: '主金额填写实付，原价 = 实付 + 优惠。',
          ),
        ),
      ],
      if (_currency !=
          view.find('book', widget.bookId)?.payload['currency']) ...[
        const SizedBox(height: 12),
        TextField(
          controller: _rate,
          obscureText: _concealAmounts,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText:
                '1 $_currency 折合多少 ${view.find('book', widget.bookId)?.payload['currency']}',
            helperText: '保存时固定此笔折算，不自动猜测汇率。',
          ),
        ),
      ],
      const SizedBox(height: 12),
      if (_showField('tags', _preferences.tagsEnabled, _tags.isNotEmpty))
        Wrap(
          key: const Key('entry-tags'),
          spacing: 6,
          children: [
            for (final tag in view.tags.where(
              (t) =>
                  (!t.effectiveArchived || _tags.contains(t.id)) &&
                  t.payload['kind'] != 'group',
            ))
              FilterChip(
                label: Text(tag.name),
                selected: _tags.contains(tag.id),
                onSelected: (selected) => setState(() {
                  selected ? _tags.add(tag.id) : _tags.remove(tag.id);
                  _changed();
                }),
              ),
            for (final id in _tags.where((id) => view.find('tag', id) == null))
              InputChip(
                label: const Text('原标签（待同步）'),
                onDeleted: () => setState(() {
                  _tags.remove(id);
                  _changed();
                }),
              ),
          ],
        ),
      if (_showField(
        'flags',
        _preferences.billFlagsEnabled,
        _excludeStats || _excludeBudget,
      ))
        CheckboxListTile(
          key: const Key('entry-statistics-flag'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('不计入收支统计'),
          value: _excludeStats,
          onChanged: (v) => setState(() {
            _excludeStats = v!;
            _changed();
          }),
        ),
      if (_showField(
        'flags',
        _preferences.billFlagsEnabled,
        _excludeStats || _excludeBudget,
      ))
        CheckboxListTile(
          key: const Key('entry-budget-flag'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('不计入预算'),
          value: _excludeBudget,
          onChanged: (v) => setState(() {
            _excludeBudget = v!;
            _changed();
          }),
        ),
      if (view.epoch != null &&
          _showField(
            'images',
            _preferences.billImagesEnabled,
            _attachments.isNotEmpty,
          ))
        FutureBuilder(
          future: widget.app.attachments(),
          builder: (context, snapshot) {
            if (snapshot.hasError) return const Text('图片存储未就绪，已有附件引用保留。');
            final transfer = snapshot.data;
            if (transfer == null) return const LinearProgressIndicator();
            return AttachmentPanel(
              repository: transfer.repository,
              space: widget.space,
              epoch: view.epoch!,
              scopeId: widget.bookId,
              transfer: transfer,
              lease: widget.app.identity == null
                  ? null
                  : () => AttachmentLease.capture(widget.app.identity!),
              attachmentIds: _attachments,
              isCurrent: () => _current,
              contextChanges: widget.app,
              readOnly: _busy,
              onBusyChanged: (value) {
                if (mounted) setState(() => _attachmentBusy = value);
              },
              onChanged: (ids) async {
                await _saveDraft(attachments: ids);
                if (mounted && _current) setState(() {});
              },
            );
          },
        ),
    ],
  );

  Widget _keypad() => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              _concealAmounts
                  ? '••••'
                  : _calculator.expression.isEmpty
                  ? '0'
                  : _calculator.expression,
              key: const Key('entry-expression'),
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const SizedBox(width: 12),
          if (_preferences.hideAmounts)
            IconButton(
              key: const Key('entry-reveal-amounts'),
              tooltip: _revealAmounts ? '隐藏本次输入金额' : '显示本次输入金额',
              onPressed: () => setState(() => _revealAmounts = !_revealAmounts),
              icon: Icon(
                _revealAmounts ? Icons.visibility : Icons.visibility_off,
              ),
            ),
          Text(_currency),
        ],
      ),
      if (_calculator.expression.contains(RegExp('[+-]')))
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '= ${_concealAmounts
                ? '••••'
                : _calculator.preview == null
                ? '…'
                : _preferences.formatMoney(_calculator.evaluate(), reveal: _revealAmounts)}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      const SizedBox(height: 10),
      for (final row in [
        ['1', '2', '3', '⌫'],
        ['4', '5', '6', '-'],
        ['7', '8', '9', '+'],
        ['再记', '0', '.', '保存'],
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              for (final key in row)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: FilledButton.tonal(
                      key: Key('entry-key-$key'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 46),
                        padding: EdgeInsets.zero,
                        backgroundColor: key == '保存'
                            ? (_type == 'income'
                                  ? _preferences.incomeColor
                                  : _type == 'transfer'
                                  ? Theme.of(context).colorScheme.primary
                                  : _preferences.expenseColor)
                            : null,
                        foregroundColor: key == '保存' ? Colors.white : null,
                      ),
                      onPressed:
                          _busy ||
                              _attachmentBusy ||
                              ((key == '保存' || key == '再记') &&
                                  !(_latest?.canCreate('bill', widget.bookId) ??
                                      false))
                          ? null
                          : key == '保存'
                          ? () => _save(false)
                          : key == '再记'
                          ? (!_isEditing ? () => _save(true) : null)
                          : () => setState(() {
                              _calculator.input(key);
                              _changed();
                            }),
                      child: key == '⌫'
                          ? const Icon(Icons.backspace_outlined, size: 20)
                          : Text(
                              key,
                              style: TextStyle(
                                fontSize: key.length == 1 ? 21 : 15,
                              ),
                            ),
                    ),
                  ),
                ),
            ],
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _leave();
    },
    child: AnimatedBuilder(
      animation: widget.app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '返回并保留草稿',
            onPressed: _leave,
            icon: const Icon(Icons.close),
          ),
          title: const Text('记一笔'),
          actions: [
            if (_current)
              IconButton(
                tooltip: '分类与标签管理',
                onPressed: _busy
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ManagementPage(
                            repository: widget.app.ledger,
                            space: widget.space,
                            initialBookId: widget.bookId,
                            isCurrent: () => _current,
                            sessionChanges: widget.app,
                          ),
                        ),
                      ),
                icon: const Icon(Icons.category_outlined),
              ),
            IconButton(
              tooltip: '保存草稿',
              onPressed: !_current || _busy
                  ? null
                  : () async {
                      try {
                        await _saveDraft();
                        if (context.mounted && _current) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('完整草稿已保存到本机。')),
                          );
                        }
                      } catch (_) {
                        if (mounted && _current) {
                          setState(() => _error = '草稿保存失败，请保留输入。');
                        }
                      }
                    },
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: _finished
            ? const SizedBox.shrink()
            : !_current
            ? const Center(child: Text('资料空间已切换，请关闭此编辑器。'))
            : StreamBuilder<LedgerView>(
                stream: _stream,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(child: Text('账本读取失败，请返回后重试。'));
                  }
                  final view = snapshot.data;
                  if (view == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  _latest = view;
                  _entryTimezone ??=
                      view.find('book', widget.bookId)?.payload['timezone']
                          as String?;
                  final book = view.find('book', widget.bookId);
                  if (book == null) {
                    return const Center(child: Text('此账本当前不可访问，已保存的草稿保留在本机。'));
                  }
                  if (_day.isEmpty) {
                    _day = instantBusinessDate(
                      DateTime.now().toUtc().toIso8601String(),
                      _timezone,
                    );
                    if (widget.existing == null && widget.draft == null) {
                      final source = _from ?? _account;
                      _currency =
                          source != null && view.find('account', source) != null
                          ? Money.fromJson(
                              view.find('account', source)!.payload['opening'],
                            ).currency
                          : book.payload['currency'] as String;
                      _calculator = ExactCalculator(
                        currency: _currency,
                        scale: currencyScales[_currency]!,
                      );
                    }
                  }
                  if (!_supportedTypes.contains(_type) ||
                      _isEditing &&
                          view.find('bill', _entityId)?.editablePayload ==
                              null) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('此账单包含受限资金关联或尚未接入的关联账务，请保留原记录。'),
                      ),
                    );
                  }
                  return AbsorbPointer(
                    absorbing: _busy,
                    child: SafeArea(
                      top: false,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 6,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child:
                                          !{
                                            'income',
                                            'expense',
                                            'transfer',
                                          }.contains(_type)
                                          ? Text(
                                              _typeLabels[_type]!,
                                              textAlign: TextAlign.center,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.titleLarge,
                                            )
                                          : SegmentedButton<String>(
                                              showSelectedIcon: false,
                                              segments: [
                                                const ButtonSegment(
                                                  value: 'expense',
                                                  label: Text('支出'),
                                                ),
                                                const ButtonSegment(
                                                  value: 'income',
                                                  label: Text('收入'),
                                                ),
                                                if (_showAssets)
                                                  const ButtonSegment(
                                                    value: 'transfer',
                                                    label: Text('转账'),
                                                  ),
                                              ],
                                              selected: {_type},
                                              onSelectionChanged:
                                                  _busy || _isEditing
                                                  ? null
                                                  : (v) =>
                                                        _changeType(v.single),
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    children: [
                                      _categories(view),
                                      const SizedBox(height: 16),
                                      _details(view),
                                    ],
                                  ),
                                ),
                              ),
                              if (!view.writable)
                                const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Text('资料需先完成同步或恢复，仍可保存草稿。'),
                                ),
                              if (_error != null)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 6,
                                  ),
                                  child: Text(
                                    _error!,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  8,
                                  12,
                                  6,
                                ),
                                child: _type == 'balance_adjustment'
                                    ? FilledButton(
                                        key: const Key('entry-key-保存'),
                                        onPressed:
                                            _busy ||
                                                _attachmentBusy ||
                                                !view.canCreate(
                                                  'bill',
                                                  widget.bookId,
                                                )
                                            ? null
                                            : () => _save(false),
                                        child: const Text('保存余额调整'),
                                      )
                                    : _keypad(),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    ),
  );
}
