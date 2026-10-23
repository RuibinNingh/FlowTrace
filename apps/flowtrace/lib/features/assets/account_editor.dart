import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../../data/ledger/ledger_models.dart';
import '../../domain/assets/asset_catalog.dart';
import '../../domain/assets/asset_config.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../entry/entry_icons.dart';

class AccountEditor extends StatefulWidget {
  const AccountEditor({
    required this.app,
    required this.space,
    required this.groups,
    this.preferredCurrencies = const [],
    this.entity,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final List<AssetGroup> groups;
  final List<String> preferredCurrencies;
  final LedgerEntity? entity;
  @override
  State<AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<AccountEditor> {
  bool _revealAmounts = false;
  late bool _wasHidden;
  bool get _concealAmounts =>
      widget.app.preferences.value.hideAmounts && !_revealAmounts;

  void _privacyChanged() {
    final hidden = widget.app.preferences.value.hideAmounts;
    if (_wasHidden != hidden && mounted) {
      setState(() {
        _wasHidden = hidden;
        _revealAmounts = false;
      });
    }
  }

  final _form = GlobalKey<FormState>();
  late final String _id = widget.entity?.id ?? const Uuid().v4();
  late final Map<String, Object?> _original =
      widget.entity?.editablePayload ?? {};
  late final _name = TextEditingController(
    text: _original['name'] as String? ?? '',
  );
  late final _opening = TextEditingController(
    text: _original['opening'] == null
        ? '0.00'
        : Money.fromJson(_original['opening']).display(),
  );
  late final _note = TextEditingController(
    text: _original['note'] as String? ?? '',
  );
  late final _lastFour = TextEditingController(
    text: _original['card_last_four'] as String? ?? '',
  );
  late final _sort = TextEditingController(
    text: '${_original['sort_order'] ?? 0}',
  );
  late final Map<String, Object?> _credit =
      (_original['credit'] as Map?)?.cast<String, Object?>() ?? {};
  late final _limit = TextEditingController(
    text: _credit['limit'] == null
        ? ''
        : Money.fromJson(_credit['limit']).display(),
  );
  late final _statement = TextEditingController(
    text: '${_credit['statement_day'] ?? ''}',
  );
  late final _due = TextEditingController(
    text: '${_credit['due_day'] ?? _credit['due_days'] ?? ''}',
  );
  late String _kind = _original['kind'] as String? ?? 'cash';
  late String _currency = _original['currency'] as String? ?? 'CNY';
  late String _icon = _original['icon'] as String? ?? 'account';
  late String _dueMode = _credit['due_mode'] as String? ?? 'none';
  late String? _provider = _original['provider_id'] as String?,
      _bank = _original['bank_id'] as String?;
  late String? _group = _original['group_id'] as String?;
  late String? _openingDate = widget.entity == null
      ? DateTime.now().toIso8601String().substring(0, 10)
      : _original['opening_date'] as String?;
  late bool _include = _original['include_in_net_assets'] != false;
  late bool _hidden = _original['hidden'] == true,
      _archived = _original['archived'] == true;
  late bool _inclusive = _credit['statement_day_inclusive'] != false;
  bool _saving = false;
  String? _error;
  bool get _current =>
      widget.app.space?.id == widget.space.id && !widget.app.switchingSpace;

  @override
  void initState() {
    super.initState();
    _wasHidden = widget.app.preferences.value.hideAmounts;
    widget.app.preferences.addListener(_privacyChanged);
    if (_original['opening'] != null) {
      _currency = Money.fromJson(_original['opening']).currency;
    }
  }

  @override
  void dispose() {
    widget.app.preferences.removeListener(_privacyChanged);
    for (final controller in [
      _name,
      _opening,
      _note,
      _lastFour,
      _sort,
      _limit,
      _statement,
      _due,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  int? _number(TextEditingController field, int maximum) {
    if (field.text.trim().isEmpty) return null;
    final number = int.tryParse(field.text.trim());
    if (number == null || number < 1 || number > maximum) {
      throw const DomainError('assets.invalid_data');
    }
    return number;
  }

  Future<void> _save() async {
    if (_saving || !_current || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final opening = parseDisplay(
        _opening.text.trim(),
        _currency,
        currencyScales[_currency]!,
      );
      final sort = int.tryParse(_sort.text.trim());
      if (sort == null || sort < 0 || sort > 2147483647) {
        throw const DomainError('assets.invalid_data');
      }
      if (_openingDate != null) businessDate(_openingDate!);
      final Map<String, Object?>? credit;
      if (_kind == 'credit_card') {
        final dueMode = _dueMode == 'none' ? null : _dueMode;
        final due = dueMode == null
            ? null
            : _number(_due, dueMode == 'fixed_day' ? 31 : 120);
        if (dueMode != null && due == null) {
          throw const DomainError('assets.invalid_data');
        }
        credit = {
          'limit': _limit.text.trim().isEmpty
              ? null
              : parseDisplay(
                  _limit.text.trim(),
                  _currency,
                  currencyScales[_currency]!,
                ).toJson(),
          'statement_day': _number(_statement, 31),
          'statement_day_inclusive': _inclusive,
          'due_mode': dueMode,
          'due_day': dueMode == 'fixed_day' ? due : null,
          'due_days': dueMode == 'days_after' ? due : null,
        };
      } else {
        credit = null;
      }
      if (!_current) throw const DomainError('identity_changed');
      await widget.app.ledger.save(
        widget.space,
        entityType: 'account',
        scopeId: widget.space.userId,
        entityId: _id,
        baseRevision: widget.entity?.revision,
        payload: {
          ..._original,
          'name': _name.text.trim(),
          'kind': _kind,
          'opening': opening.toJson(),
          'include_in_net_assets': _include,
          'hidden': _hidden,
          'group_id': _group,
          'sort_order': sort,
          'archived': _archived,
          'icon': _icon,
          'note': _note.text,
          'provider_id': _provider,
          'bank_id': _bank,
          'card_last_four': _lastFour.text.trim().isEmpty
              ? null
              : _lastFour.text.trim(),
          'opening_date': _openingDate,
          'credit': credit,
        },
      );
      if (mounted && _current) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error =
              error is DomainError && error.code == 'assets.group_unconfirmed'
              ? '分组尚未确认或正在删除，请联网刷新分组后重试。输入已保留。'
              : '保存失败，请核对日期、额度、金额和账户状态。输入已保留。';
        });
      }
    }
  }

  Widget _gap(Widget child) =>
      Padding(padding: const EdgeInsets.only(bottom: 14), child: child);
  Future<void> _chooseBank() async {
    var query = '';
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: widget.app,
        builder: (context, _) => !_current
            ? const AlertDialog(content: Text('资料空间已切换，请关闭此窗口。'))
            : StatefulBuilder(
                builder: (context, update) => AlertDialog(
                  title: const Text('选择银行'),
                  content: SizedBox(
                    width: 480,
                    height: 420,
                    child: Column(
                      children: [
                        TextField(
                          key: const Key('account-bank-search'),
                          maxLength: 80,
                          decoration: const InputDecoration(
                            labelText: '搜索银行名称',
                          ),
                          onChanged: (value) =>
                              update(() => query = value.trim().toLowerCase()),
                        ),
                        Expanded(
                          child: ListView(
                            children: [
                              ListTile(
                                title: const Text('自定义银行'),
                                onTap: () => Navigator.pop(context, ''),
                              ),
                              for (final bank in assetBanks.entries.where(
                                (bank) => '${bank.key} ${bank.value}'
                                    .toLowerCase()
                                    .contains(query),
                              ))
                                ListTile(
                                  title: Text(bank.value),
                                  onTap: () => Navigator.pop(context, bank.key),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('返回'),
                    ),
                  ],
                ),
              ),
      ),
    );
    if (selected != null && mounted && _current) {
      setState(() => _bank = selected.isEmpty ? null : selected);
    }
  }

  Widget _integer(
    TextEditingController controller,
    String label,
    int maximum, {
    bool optional = true,
  }) => TextFormField(
    controller: controller,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(labelText: label),
    validator: (value) {
      if (optional && (value ?? '').trim().isEmpty) return null;
      final number = int.tryParse((value ?? '').trim());
      return number == null || number < 1 || number > maximum
          ? '请输入1至$maximum的整数'
          : null;
    },
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) {
      if (!_current) {
        return const Padding(
          padding: EdgeInsets.all(24),
          child: Text('资料空间已切换，请关闭此页面。'),
        );
      }
      final providers = assetProviders.entries.where(
        (entry) => entry.value.kind == _kind,
      );
      final groupChoices = {
        for (final group in widget.groups) group.id: group.name,
      };
      if (_group != null && !groupChoices.containsKey(_group)) {
        groupChoices[_group!] = '原分组（请联网核对）';
      }
      return Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: SingleChildScrollView(
          child: AbsorbPointer(
            absorbing: _saving,
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.entity == null ? '添加账户' : '编辑账户',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 20),
                  if (widget.app.preferences.value.hideAmounts)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        key: const Key('account-reveal-amounts'),
                        onPressed: () =>
                            setState(() => _revealAmounts = !_revealAmounts),
                        icon: Icon(
                          _revealAmounts
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        label: Text(_revealAmounts ? '隐藏本次编辑金额' : '显示本次编辑金额'),
                      ),
                    ),
                  _gap(
                    TextFormField(
                      key: const Key('account-name'),
                      controller: _name,
                      maxLength: 80,
                      decoration: const InputDecoration(labelText: '账户名称'),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? '请输入名称'
                          : null,
                    ),
                  ),
                  _gap(
                    DropdownButtonFormField<String>(
                      key: const Key('account-kind'),
                      initialValue: _kind,
                      decoration: const InputDecoration(labelText: '类型'),
                      items: [
                        for (final kind in assetKindNames.entries)
                          DropdownMenuItem(
                            value: kind.key,
                            child: Text(kind.value),
                          ),
                      ],
                      onChanged: widget.entity != null
                          ? null
                          : (value) => setState(() {
                              _kind = value!;
                              _provider = null;
                            }),
                    ),
                  ),
                  if (providers.isNotEmpty)
                    _gap(
                      DropdownButtonFormField<String>(
                        key: ValueKey('provider-$_kind'),
                        initialValue: _provider ?? '',
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '账户服务商'),
                        items: [
                          const DropdownMenuItem(value: '', child: Text('自定义')),
                          for (final entry in providers)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value.name),
                            ),
                        ],
                        onChanged: (value) => setState(
                          () => _provider = value == '' ? null : value,
                        ),
                      ),
                    ),
                  if ({'bank', 'credit_card'}.contains(_kind))
                    _gap(
                      ListTile(
                        key: const Key('account-bank'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('银行'),
                        subtitle: Text(assetBanks[_bank] ?? '自定义银行'),
                        trailing: const Icon(Icons.search),
                        onTap: _chooseBank,
                      ),
                    ),
                  if ({'bank', 'credit_card'}.contains(_kind))
                    _gap(
                      TextFormField(
                        controller: _lastFour,
                        maxLength: 4,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '卡号后四位（选填）',
                        ),
                        validator: (value) =>
                            value == null ||
                                value.trim().isEmpty ||
                                RegExp(r'^[0-9]{4}$').hasMatch(value.trim())
                            ? null
                            : '请输入四位数字',
                      ),
                    ),
                  _gap(
                    DropdownButtonFormField<String>(
                      key: const Key('account-currency'),
                      initialValue: _currency,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '币种'),
                      items: [
                        for (final currency in {
                          ...widget.preferredCurrencies.where(
                            currencyScales.containsKey,
                          ),
                          _currency,
                          ...currencyScales.keys,
                        })
                          DropdownMenuItem(
                            value: currency,
                            child: Text(
                              '$currency ${currencyNames[currency] ?? ''}${widget.preferredCurrencies.contains(currency) ? ' · 常用' : ''}',
                            ),
                          ),
                      ],
                      onChanged: widget.entity != null
                          ? null
                          : (value) => setState(() {
                              _currency = value!;
                              _opening.clear();
                              _limit.clear();
                            }),
                    ),
                  ),
                  _gap(
                    TextFormField(
                      key: const Key('account-opening'),
                      obscureText: _concealAmounts,
                      controller: _opening,
                      enabled: widget.entity == null,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                      decoration: InputDecoration(
                        labelText: '期初余额',
                        helperText:
                            _kind == 'credit_card' || _kind == 'loan_payable'
                            ? '欠款用负数表示；已有账户余额变动请使用调账。'
                            : '已有账户余额变动请使用调账。',
                      ),
                      validator: (value) {
                        try {
                          parseDisplay(
                            value?.trim(),
                            _currency,
                            currencyScales[_currency]!,
                          );
                          return null;
                        } catch (_) {
                          return '请输入符合币种精度的金额';
                        }
                      },
                    ),
                  ),
                  _gap(
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('期初日期'),
                      subtitle: Text(_openingDate ?? '原账户未记录日期，历史估值不可用'),
                      trailing: const Icon(Icons.calendar_today_outlined),
                      onTap: widget.entity != null
                          ? null
                          : () async {
                              final date = await showDatePicker(
                                context: context,
                                initialDate:
                                    DateTime.tryParse(_openingDate ?? '') ??
                                    DateTime.now(),
                                firstDate: DateTime(1),
                                lastDate: DateTime(9999, 12, 31),
                              );
                              if (date != null && mounted && _current) {
                                setState(
                                  () => _openingDate = date
                                      .toIso8601String()
                                      .substring(0, 10),
                                );
                              }
                            },
                    ),
                  ),
                  _gap(
                    DropdownButtonFormField<String>(
                      initialValue: _group ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '分组（联网确认后可用）',
                      ),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('未分组')),
                        for (final entry in groupChoices.entries)
                          DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _group = value == '' ? null : value),
                    ),
                  ),
                  _gap(
                    TextFormField(
                      controller: _sort,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '排序（较小的在前）'),
                      validator: (value) {
                        final order = int.tryParse(value ?? '');
                        return order == null || order < 0 || order > 2147483647
                            ? '请输入0至2147483647的整数'
                            : null;
                      },
                    ),
                  ),
                  _gap(
                    DropdownButtonFormField<String>(
                      initialValue: _icon,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '图标'),
                      items: [
                        for (final key in {
                          'account',
                          _icon,
                          ...EntryIcons.values.keys,
                        })
                          DropdownMenuItem(
                            value: key,
                            child: Row(
                              children: [
                                Icon(EntryIcons.of(key)),
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Text(
                                    key,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                      onChanged: (value) => setState(() => _icon = value!),
                    ),
                  ),
                  if (_kind == 'credit_card') ...[
                    const Divider(),
                    const Text('信用卡设置'),
                    const SizedBox(height: 12),
                    _gap(
                      TextFormField(
                        key: const Key('account-credit-limit'),
                        obscureText: _concealAmounts,
                        controller: _limit,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: '信用额度（可单独设置，选填）',
                        ),
                        validator: (value) {
                          if ((value ?? '').trim().isEmpty) return null;
                          try {
                            final money = parseDisplay(
                              value!.trim(),
                              _currency,
                              currencyScales[_currency]!,
                            );
                            return money.minor.isNegative ? '额度不能为负' : null;
                          } catch (_) {
                            return '请输入符合币种精度的金额';
                          }
                        },
                      ),
                    ),
                    _gap(_integer(_statement, '每月出账日（选填）', 31)),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('出账日记入本期'),
                      subtitle: const Text('关闭后，出账日记入下一期。短月日期按月末。'),
                      value: _inclusive,
                      onChanged: (value) => setState(() => _inclusive = value),
                    ),
                    _gap(
                      DropdownButtonFormField<String>(
                        initialValue: _dueMode,
                        decoration: const InputDecoration(labelText: '还款日规则'),
                        items: const [
                          DropdownMenuItem(value: 'none', child: Text('暂不设置')),
                          DropdownMenuItem(
                            value: 'fixed_day',
                            child: Text('每月固定日期'),
                          ),
                          DropdownMenuItem(
                            value: 'days_after',
                            child: Text('出账后自然日数'),
                          ),
                        ],
                        onChanged: (value) => setState(() {
                          _dueMode = value!;
                          _due.clear();
                        }),
                      ),
                    ),
                    if (_dueMode != 'none')
                      _gap(
                        _integer(
                          _due,
                          _dueMode == 'fixed_day' ? '每月还款日' : '出账后天数',
                          _dueMode == 'fixed_day' ? 31 : 120,
                          optional: false,
                        ),
                      ),
                    const Text('日期未配齐时只展示欠款与额度，不推算本期应还。'),
                  ],
                  _gap(
                    TextFormField(
                      key: const Key('account-note'),
                      controller: _note,
                      maxLength: 2000,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: '备注'),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('计入净资产'),
                    value: _include,
                    onChanged: (value) => setState(() => _include = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('隐藏账户'),
                    subtitle: const Text('仍按上面的净资产开关参与统计'),
                    value: _hidden,
                    onChanged: (value) => setState(() => _hidden = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('归档账户'),
                    subtitle: const Text('停止新增资金引用，保留历史和余额'),
                    value: _archived,
                    onChanged: (value) => setState(() => _archived = value),
                  ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  FilledButton(
                    key: const Key('save-account'),
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? '正在保存…' : '保存到本机并待同步'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
