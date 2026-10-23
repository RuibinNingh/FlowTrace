import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../../domain/assets/asset_config.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../assets/asset_configuration_controller.dart';

class CurrenciesPage extends StatefulWidget {
  const CurrenciesPage({required this.app, required this.space, super.key});
  final AppController app;
  final DataSpace space;
  @override
  State<CurrenciesPage> createState() => _CurrenciesPageState();
}

class _CurrenciesPageState extends State<CurrenciesPage> {
  late final _controller = AssetConfigurationController(
    widget.app,
    widget.space,
  );
  CurrencyPreferences? _draft;
  CurrencyPreferences get _preferences =>
      _draft ??
      _controller.sections[AssetConfigSection.preferences]?.preferences ??
      CurrencyPreferences(baseCurrency: 'CNY', enabledCodes: ['CNY']);
  @override
  void initState() {
    super.initState();
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _update({String? base, Iterable<String>? enabled, String? policy}) {
    final current = _preferences;
    setState(
      () => _draft = CurrencyPreferences(
        baseCurrency: base ?? current.baseCurrency,
        enabledCodes: enabled ?? {...current.enabledCodes, ?base},
        valuationPolicy: policy ?? current.valuationPolicy,
      ),
    );
  }

  Future<void> _chooseEnabled() async {
    final enabled = _preferences.enabledCodes.toSet(),
        base = _preferences.baseCurrency;
    var query = '';
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('常用币种'),
          content: SizedBox(
            width: 480,
            height: 440,
            child: Column(
              children: [
                TextField(
                  decoration: const InputDecoration(labelText: '搜索币种代码或名称'),
                  onChanged: (value) =>
                      update(() => query = value.trim().toLowerCase()),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final code in currencyScales.keys.where(
                        (code) => '$code ${currencyNames[code]}'
                            .toLowerCase()
                            .contains(query),
                      ))
                        CheckboxListTile(
                          title: Text('$code ${currencyNames[code]}'),
                          subtitle: code == base
                              ? const Text('本位币须保持启用')
                              : null,
                          value: enabled.contains(code),
                          onChanged: code == base
                              ? null
                              : (selected) => update(() {
                                  if (selected == true) {
                                    enabled.add(code);
                                  } else {
                                    enabled.remove(code);
                                  }
                                }),
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
            FilledButton(
              onPressed: () => Navigator.pop(context, enabled),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (selected != null && mounted && _controller.current) {
      _update(enabled: selected);
    }
  }

  Future<void> _newRate() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _RateEditor(
        baseCurrency: _preferences.baseCurrency,
        controller: _controller,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('币种与手动估值'),
        actions: [
          IconButton(
            tooltip: '联网刷新',
            onPressed: _controller.busy ? null : _controller.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !_controller.current
          ? const Center(child: Text('资料空间已切换。'))
          : _controller.loading
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    const Text('本位币和手动汇率只用于资产估值，不会重算历史账单的原币金额、转账目标金额或记账汇率。'),
                    const SizedBox(height: 16),
                    if (_controller.message != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Semantics(
                          container: true,
                          liveRegion: true,
                          child: Text(_controller.message!),
                        ),
                      ),
                    if (_controller.busy) const LinearProgressIndicator(),
                    PendingAssetOperations(_controller),
                    DropdownButtonFormField<String>(
                      key: ValueKey('base-${_preferences.baseCurrency}'),
                      initialValue: _preferences.baseCurrency,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '本位币'),
                      items: [
                        for (final code in currencyScales.keys)
                          DropdownMenuItem(
                            value: code,
                            child: Text('$code ${currencyNames[code]}'),
                          ),
                      ],
                      onChanged: _controller.busy
                          ? null
                          : (value) => _update(base: value!),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _controller.busy ? null : _chooseEnabled,
                      child: Text(
                        '常用币种：${_preferences.enabledCodes.join('、')}',
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey('policy-${_preferences.valuationPolicy}'),
                      initialValue: _preferences.valuationPolicy,
                      decoration: const InputDecoration(labelText: '估值汇率日期规则'),
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(
                          value: 'exact_date',
                          child: Text('仅使用估值日当日报价'),
                        ),
                        DropdownMenuItem(
                          value: 'latest_on_or_before',
                          child: Text('使用估值日或之前最新报价'),
                        ),
                      ],
                      onChanged: _controller.busy
                          ? null
                          : (value) => _update(policy: value!),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _controller.busy
                          ? null
                          : () async {
                              final saved = await _controller.perform((
                                lease,
                              ) async {
                                await _controller.repository.savePreferences(
                                  lease,
                                  _preferences,
                                );
                              });
                              if (saved && mounted && _controller.current) {
                                setState(() => _draft = null);
                              }
                            },
                      child: const Text('保存币种与估值偏好'),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      '手动估值汇率',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '每条报价表示1单位来源币等于多少目标币。不会自动联网、反向推算或跨币种换算。修改已有报价请删除后重新添加。',
                    ),
                    for (final rate
                        in _controller
                                .sections[AssetConfigSection.rates]
                                ?.rates ??
                            <AssetRate>[])
                      Card(
                        child: ListTile(
                          title: Text(
                            '${rate.fromCurrency} → ${rate.toCurrency}  ${rate.rate}',
                          ),
                          subtitle: Text(
                            '${rate.effectiveDate} · ${rate.source}',
                          ),
                          trailing: IconButton(
                            tooltip: '删除报价',
                            onPressed: _controller.busy
                                ? null
                                : () async {
                                    final remove = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AssetConfigConfirmation(
                                        controller: _controller,
                                        title: '删除此估值报价？',
                                        content:
                                            '${rate.fromCurrency}→${rate.toCurrency} · ${rate.effectiveDate}\n删除后可能无法计算该日资产估值，历史账单金额保持不变。',
                                      ),
                                    );
                                    if (remove == true) {
                                      await _controller.perform((lease) async {
                                        await _controller.repository.deleteRate(
                                          lease,
                                          rate.id,
                                        );
                                      });
                                    }
                                  },
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _controller.busy ? null : _newRate,
                      icon: const Icon(Icons.add),
                      label: const Text('添加手动估值报价'),
                    ),
                    const SizedBox(height: 24),
                    Text('币种目录截至 $currencyCatalogDate，保留官方已知小数位；未启用的历史币种仍可读取。'),
                  ],
                ),
              ),
            ),
    ),
  );
}

class _RateEditor extends StatefulWidget {
  const _RateEditor({required this.baseCurrency, required this.controller});
  final String baseCurrency;
  final AssetConfigurationController controller;
  @override
  State<_RateEditor> createState() => _RateEditorState();
}

class _RateEditorState extends State<_RateEditor> {
  final _form = GlobalKey<FormState>();
  final _id = const Uuid().v4();
  final _rate = TextEditingController(),
      _source = TextEditingController(text: '手动');
  final _date = TextEditingController(
    text: DateTime.now().toIso8601String().substring(0, 10),
  );
  late String _from = widget.baseCurrency == 'USD' ? 'CNY' : 'USD',
      _to = widget.baseCurrency;
  @override
  void dispose() {
    _rate.dispose();
    _source.dispose();
    _date.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => !widget.controller.current
        ? const AlertDialog(content: Text('资料空间已切换，请关闭此窗口。'))
        : AlertDialog(
            scrollable: true,
            title: const Text('添加手动估值报价'),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Form(
                  key: _form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final source in [true, false])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: DropdownButtonFormField<String>(
                            initialValue: source ? _from : _to,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: source ? '来源币种' : '目标币种',
                            ),
                            items: [
                              for (final code in currencyScales.keys)
                                DropdownMenuItem(
                                  value: code,
                                  child: Text('$code ${currencyNames[code]}'),
                                ),
                            ],
                            onChanged: (value) => setState(() {
                              if (source) {
                                _from = value!;
                              } else {
                                _to = value!;
                              }
                            }),
                            validator: (_) => _from == _to ? '请选择不同币种' : null,
                          ),
                        ),
                      TextFormField(
                        controller: _rate,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: '1来源币 = 目标币金额',
                        ),
                        validator: (value) {
                          try {
                            parseRate(value?.trim());
                            return null;
                          } catch (_) {
                            return '请输入正数，最多18位小数';
                          }
                        },
                      ),
                      TextFormField(
                        controller: _date,
                        decoration: const InputDecoration(
                          labelText: '生效日期（YYYY-MM-DD）',
                        ),
                        validator: (value) {
                          try {
                            businessDate(value?.trim() ?? '');
                            return null;
                          } catch (_) {
                            return '请输入有效日期';
                          }
                        },
                      ),
                      TextFormField(
                        controller: _source,
                        maxLength: 80,
                        decoration: const InputDecoration(labelText: '来源或备注'),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? '请填写来源'
                            : null,
                      ),
                      if (widget.controller.message != null)
                        Text(widget.controller.message!),
                      PendingAssetOperations(widget.controller),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('返回'),
              ),
              FilledButton(
                onPressed: widget.controller.busy
                    ? null
                    : () async {
                        if (!_form.currentState!.validate() ||
                            !widget.controller.current) {
                          return;
                        }
                        final rate = AssetRate(
                          id: _id,
                          fromCurrency: _from,
                          toCurrency: _to,
                          effectiveDate: _date.text.trim(),
                          rate: _rate.text.trim(),
                          source: _source.text.trim(),
                          revision: '0',
                        );
                        final saved = await widget.controller.perform((
                          lease,
                        ) async {
                          await widget.controller.repository.createRate(
                            lease,
                            rate,
                          );
                        });
                        if (saved &&
                            context.mounted &&
                            widget.controller.current) {
                          Navigator.pop(context);
                        }
                      },
                child: const Text('保存并确认'),
              ),
            ],
          ),
  );
}
