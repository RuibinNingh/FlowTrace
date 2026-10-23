import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../../data/ledger/ledger_models.dart';
import '../../domain/ledger/calendar_rules.dart';

class BudgetEditor extends StatefulWidget {
  const BudgetEditor({
    required this.app,
    required this.space,
    required this.book,
    required this.periodStart,
    required this.periodEndExclusive,
    this.existing,
    this.copyFrom,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final LedgerEntity book;
  final String periodStart, periodEndExclusive;
  final LedgerEntity? existing;
  final Map<String, Object?>? copyFrom;
  @override
  State<BudgetEditor> createState() => _BudgetEditorState();
}

class _BudgetEditorState extends State<BudgetEditor> {
  late final String _entityId = widget.existing?.id ?? const Uuid().v4();
  late final _stream = widget.app.ledger.watch(
    widget.space,
    query: const LedgerQuery(includeArchived: true),
  );
  late final TextEditingController _total;
  final Map<String, TextEditingController> _limits = {};
  late String _mode;
  bool _busy = false;
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

  String? _error;
  bool get _current =>
      mounted &&
      widget.app.space?.id == widget.space.id &&
      !widget.app.switchingSpace;
  String get _currency => widget.book.payload['currency'] as String;
  int get _scale => currencyScales[_currency]!;

  @override
  void initState() {
    super.initState();
    _wasHidden = widget.app.preferences.value.hideAmounts;
    widget.app.preferences.addListener(_privacyChanged);
    final data =
        widget.existing?.editablePayload ??
        widget.copyFrom ??
        <String, Object?>{};
    _total = TextEditingController(
      text: data['total'] == null
          ? ''
          : Money.fromJson(data['total']).display(),
    );
    for (final raw in data['categories'] as List? ?? []) {
      final row = raw as Map;
      _limits[row['category_id'] as String] = TextEditingController(
        text: Money.fromJson(row['limit']).display(),
      );
    }
    _mode = data['total'] == null && _limits.isNotEmpty
        ? 'categories'
        : _limits.isEmpty
        ? 'total'
        : 'mixed';
  }

  @override
  void dispose() {
    widget.app.preferences.removeListener(_privacyChanged);
    _total.dispose();
    for (final c in _limits.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_current) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final categories = <Map<String, Object?>>[];
      if (_mode != 'total') {
        for (final e in _limits.entries) {
          final amount = parseDisplay(e.value.text.trim(), _currency, _scale);
          if (amount.minor < BigInt.zero) {
            throw const DomainError('budget.negative');
          }
          categories.add({'category_id': e.key, 'limit': amount.toJson()});
        }
      }
      final total = _mode == 'categories'
          ? null
          : parseDisplay(_total.text.trim(), _currency, _scale);
      if (total != null && total.minor < BigInt.zero) {
        throw const DomainError('budget.negative');
      }
      if (!_current) return;
      await widget.app.ledger.save(
        widget.space,
        entityType: 'budget',
        scopeId: widget.book.id,
        entityId: _entityId,
        baseRevision: widget.existing?.revision,
        payload: {
          'period_start': widget.periodStart,
          'period_end_exclusive': widget.periodEndExclusive,
          'total': total?.toJson(),
          'categories': categories,
          'carry_forward': widget.existing?.payload['carry_forward'] ?? false,
        },
      );
      if (mounted && _current) Navigator.pop(context, true);
    } on DomainError catch (e) {
      if (_current) {
        setState(
          () => _error = switch (e.code) {
            'budget.total_below_categories' => '总预算不能低于分类预算之和。',
            'budget.overlapping_categories' => '不能同时给父分类和子分类设置预算。',
            'budget.negative' => '预算金额不能为负。',
            _ => '请核对预算金额、分类与权限；输入已保留。',
          },
        );
      }
    } catch (_) {
      if (_current) setState(() => _error = '预算未能保存，输入已保留，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? '设置预算' : '编辑预算')),
      body: !_current
          ? const Center(child: Text('资料空间已切换。'))
          : StreamBuilder<LedgerView>(
              stream: _stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Text('预算资料读取失败。'));
                }
                final view = snapshot.data;
                if (view == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (view.find('book', widget.book.id) == null) {
                  return const Center(child: Text('当前无权访问此账本。'));
                }
                final allowed = widget.existing == null
                    ? view.canCreate('budget', widget.book.id)
                    : view.find('budget', widget.existing!.id)?.canEdit == true;
                final categories = view.categories
                    .where(
                      (c) =>
                          c.scopeId == widget.book.id &&
                          c.payload['kind'] == 'expense' &&
                          (!c.effectiveArchived || _limits.containsKey(c.id)),
                    )
                    .toList();
                return AbsorbPointer(
                  absorbing: _busy,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          Text(
                            widget.book.name,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${widget.periodStart} 至 ${isoBusinessDate(businessDate(widget.periodEndExclusive).subtract(const Duration(days: 1)))} · $_currency',
                          ),
                          const SizedBox(height: 20),
                          if (widget.app.preferences.value.hideAmounts)
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                key: const Key('budget-reveal-amounts'),
                                onPressed: () => setState(
                                  () => _revealAmounts = !_revealAmounts,
                                ),
                                icon: Icon(
                                  _revealAmounts
                                      ? Icons.visibility
                                      : Icons.visibility_off,
                                ),
                                label: Text(
                                  _revealAmounts ? '隐藏本次编辑金额' : '显示本次编辑金额',
                                ),
                              ),
                            ),
                          DropdownButtonFormField<String>(
                            initialValue: _mode,
                            decoration: const InputDecoration(
                              labelText: '预算方式',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'total',
                                child: Text('仅设置总预算'),
                              ),
                              DropdownMenuItem(
                                value: 'categories',
                                child: Text('仅设置分类预算'),
                              ),
                              DropdownMenuItem(
                                value: 'mixed',
                                child: Text('总预算与分类预算'),
                              ),
                            ],
                            onChanged: (v) => setState(() => _mode = v!),
                          ),
                          if (_mode != 'categories') ...[
                            const SizedBox(height: 16),
                            TextField(
                              key: const Key('budget-total'),
                              controller: _total,
                              obscureText: _concealAmounts,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: InputDecoration(
                                labelText: '总预算 ($_currency)',
                              ),
                            ),
                          ],
                          if (_mode != 'total') ...[
                            const SizedBox(height: 20),
                            const Text('选择分类并填写限额。父类包含子类，不能重复选择父子。'),
                            const SizedBox(height: 12),
                            for (final category in categories) ...[
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  '${category.payload['parent_id'] == null ? '' : '↳ '}${category.name}',
                                ),
                                value: _limits.containsKey(category.id),
                                onChanged: (selected) => setState(() {
                                  if (selected == true) {
                                    _limits[category.id] =
                                        TextEditingController();
                                  } else {
                                    final controller = _limits.remove(
                                      category.id,
                                    );
                                    if (controller != null) {
                                      WidgetsBinding.instance
                                          .addPostFrameCallback(
                                            (_) => controller.dispose(),
                                          );
                                    }
                                  }
                                }),
                              ),
                              if (_limits.containsKey(category.id))
                                TextField(
                                  key: ValueKey(
                                    'budget-category-${category.id}',
                                  ),
                                  controller: _limits[category.id],
                                  obscureText: _concealAmounts,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  decoration: InputDecoration(
                                    labelText:
                                        '${category.name}限额 ($_currency)',
                                  ),
                                ),
                            ],
                          ],
                          const SizedBox(height: 20),
                          const Text(
                            '不计入预算的账单不占用限额。分类与总额相等时仅统计所设分类；总额大于分类和时还包含其他分类。',
                          ),
                          const SizedBox(height: 20),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          if (!allowed) const Text('当前权限只允许查看预算。'),
                          FilledButton(
                            key: const Key('save-budget'),
                            onPressed: !allowed || _busy ? null : _save,
                            child: Text(_busy ? '正在保存…' : '保存到本机并待同步'),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    ),
  );
}
