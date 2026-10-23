import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../../data/ledger/ledger_models.dart';
import '../../data/ledger/ledger_query.dart';
import '../../data/preferences/app_preferences.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../entry/entry_icons.dart';
import '../transactions/bill_detail_page.dart';
import '../transactions/bill_batch_page.dart';
import '../transactions/bill_image_export_page.dart';
import '../transactions/bill_book_move_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    required this.app,
    required this.space,
    this.initialBookId,
    this.initialFilter,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final String? initialBookId;
  final BillFilter? initialFilter;
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  AppPreferences get _preferences => widget.app.preferences.value;
  late final _stream = widget.app.ledger.watch(
    widget.space,
    query: const LedgerQuery(includeArchived: true),
  );
  final _keyword = TextEditingController();
  late BillFilter _filter =
      widget.initialFilter ??
      BillFilter(
        bookIds: widget.initialBookId == null ? null : {widget.initialBookId!},
      );
  final Set<String> _selected = {};
  bool get _current =>
      mounted &&
      widget.app.space?.id == widget.space.id &&
      !widget.app.switchingSpace;

  @override
  void initState() {
    super.initState();
    _keyword.text = _filter.keyword;
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _filters(LedgerView view) async {
    final value = await showModalBottomSheet<BillFilter>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _FilterEditor(
        app: widget.app,
        space: widget.space,
        view: view,
        initial: _filter,
      ),
    );
    if (value != null && _current) {
      setState(() {
        _filter = value;
        _keyword.text = value.keyword;
        _selected.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('搜索账单')),
      body: !_current
          ? const Center(child: Text('资料空间已切换，请返回当前账本。'))
          : StreamBuilder<LedgerView>(
              stream: _stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Text('账单读取失败，请重试。'));
                }
                final view = snapshot.data;
                if (view == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final result = queryBills(view, filter: _filter);
                _selected.retainAll(result.idSet);
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  key: const Key('bill-search-keyword'),
                                  controller: _keyword,
                                  decoration: const InputDecoration(
                                    prefixIcon: Icon(Icons.search),
                                    labelText: '备注、分类、标签或金额',
                                  ),
                                  onChanged: (value) => setState(() {
                                    _filter = BillFilter(
                                      fromDate: _filter.fromDate,
                                      endDateExclusive:
                                          _filter.endDateExclusive,
                                      bookIds: _filter.bookIds,
                                      keyword: value,
                                      categoryIds: _filter.categoryIds,
                                      includeDescendants:
                                          _filter.includeDescendants,
                                      tagIds: _filter.tagIds,
                                      allTags: _filter.allTags,
                                      currency: _filter.currency,
                                      minAmount: _filter.minAmount,
                                      maxAmount: _filter.maxAmount,
                                      hasAttachments: _filter.hasAttachments,
                                      hasTags: _filter.hasTags,
                                      hasAccount: _filter.hasAccount,
                                      sources: _filter.sources,
                                      types: _filter.types,
                                      excludeFromStatistics:
                                          _filter.excludeFromStatistics,
                                      excludeFromBudget:
                                          _filter.excludeFromBudget,
                                    );
                                    _selected.clear();
                                  }),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: '组合筛选',
                                onPressed: () => _filters(view),
                                icon: const Icon(Icons.filter_alt_outlined),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '${result.bills.length}笔匹配 · 本机可访问范围',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ),
                        if (result.issues.isNotEmpty)
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text('部分记录资料不完整，已单独标记，未当作零金额。'),
                          ),
                        for (final entry in result.totalsByCurrency.entries)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 4,
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '${entry.key} 名义金额合计 ${_preferences.hideAmounts
                                    ? '••••'
                                    : entry.value.nominalAmount == null
                                    ? '不可用'
                                    : _preferences.formatMoney(entry.value.nominalAmount!)} · 包含转账，不代表净收支',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        if (_selected.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Wrap(
                              spacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text('已选${_selected.length}笔'),
                                TextButton(
                                  onPressed: () => setState(
                                    () => _selected.addAll(result.ids),
                                  ),
                                  child: const Text('选择全部匹配'),
                                ),
                                TextButton(
                                  onPressed: () => setState(_selected.clear),
                                  child: const Text('取消选择'),
                                ),
                                FilledButton(
                                  onPressed: () async {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute<bool>(
                                        builder: (_) => BillBatchPage(
                                          app: widget.app,
                                          space: widget.space,
                                          ids: Set.unmodifiable(_selected),
                                        ),
                                      ),
                                    );
                                    if (_current) setState(_selected.clear);
                                  },
                                  child: const Text('批量维护'),
                                ),
                                OutlinedButton.icon(
                                  key: const Key('move-selected-bills'),
                                  onPressed: () async {
                                    final saved = await Navigator.push<bool>(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => BillBookMovePage(
                                          app: widget.app,
                                          space: widget.space,
                                          ids: Set.unmodifiable(_selected),
                                        ),
                                      ),
                                    );
                                    if (_current && saved == true) {
                                      setState(_selected.clear);
                                    }
                                  },
                                  icon: const Icon(
                                    Icons.drive_file_move_outlined,
                                  ),
                                  label: const Text('移动到账本'),
                                ),
                                OutlinedButton.icon(
                                  key: const Key('export-selected-images'),
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => BillImageExportPage(
                                        app: widget.app,
                                        space: widget.space,
                                        ids: Set.unmodifiable(_selected),
                                      ),
                                    ),
                                  ),
                                  icon: const Icon(Icons.download_outlined),
                                  label: const Text('导出图片'),
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: ListView.builder(
                            itemCount: result.bills.length,
                            itemBuilder: (context, index) {
                              final bill = result.bills[index],
                                  payload = bill.payload;
                              final amount = Money.fromJson(payload['money']);
                              final category = payload['category_id'] == null
                                  ? null
                                  : view.find(
                                      'category',
                                      payload['category_id'] as String,
                                    );
                              final presentation = BillPresentation.create(
                                preferences: _preferences,
                                category:
                                    category?.name ?? '${payload['bill_type']}',
                                note: payload['note'] as String? ?? '',
                                parentCategory:
                                    category?.payload['parent_id'] is String
                                    ? view
                                          .find(
                                            'category',
                                            category!.payload['parent_id']
                                                as String,
                                          )
                                          ?.name
                                    : null,
                              );
                              final amountText = Text(
                                '${amount.currency} ${_preferences.formatMoney(amount)}',
                                style: TextStyle(
                                  color: payload['bill_type'] == 'expense'
                                      ? _preferences.expenseColor
                                      : payload['bill_type'] == 'income'
                                      ? _preferences.incomeColor
                                      : null,
                                ),
                              );
                              final stackedAmount =
                                  MediaQuery.sizeOf(context).width < 600 ||
                                  MediaQuery.textScalerOf(context).scale(14) >
                                      20;
                              return ListTile(
                                leading: _selected.isEmpty
                                    ? !_preferences.showCategoryIcons
                                          ? null
                                          : Icon(
                                              EntryIcons.of(
                                                category?.payload['icon'],
                                              ),
                                            )
                                    : Checkbox(
                                        value: _selected.contains(bill.id),
                                        onChanged: (yes) => setState(() {
                                          yes == true
                                              ? _selected.add(bill.id)
                                              : _selected.remove(bill.id);
                                        }),
                                      ),
                                onLongPress: () =>
                                    setState(() => _selected.add(bill.id)),
                                key: ValueKey('search-bill-${bill.id}'),
                                title: Text(presentation.title),
                                subtitle: stackedAmount
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '${payload['business_date']}${presentation.subtitle == null ? '' : ' · ${presentation.subtitle}'}',
                                          ),
                                          amountText,
                                        ],
                                      )
                                    : Text(
                                        '${payload['business_date']}${presentation.subtitle == null ? '' : ' · ${presentation.subtitle}'}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                trailing: stackedAmount ? null : amountText,
                                onTap: () {
                                  if (_selected.isNotEmpty) {
                                    setState(() {
                                      _selected.contains(bill.id)
                                          ? _selected.remove(bill.id)
                                          : _selected.add(bill.id);
                                    });
                                    return;
                                  }
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => BillDetailPage(
                                        app: widget.app,
                                        space: widget.space,
                                        entityId: bill.id,
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                        if (result.bills.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('没有匹配的账单，试试调整筛选条件。'),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    ),
  );
}

class _FilterEditor extends StatefulWidget {
  const _FilterEditor({
    required this.app,
    required this.space,
    required this.view,
    required this.initial,
  });
  final AppController app;
  final DataSpace space;
  final LedgerView view;
  final BillFilter initial;
  @override
  State<_FilterEditor> createState() => _FilterEditorState();
}

class _FilterEditorState extends State<_FilterEditor> {
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

  late final TextEditingController _minimum, _maximum;
  late String? _from, _end, _currency;
  late Set<String> _books, _categories, _tags, _types, _sources;
  late bool? _pictures, _hasTags, _hasAccount, _statistics, _budget;
  late bool _allTags, _descendants;
  String? _error;
  @override
  void initState() {
    super.initState();
    final f = widget.initial;
    _wasHidden = widget.app.preferences.value.hideAmounts;
    widget.app.preferences.addListener(_privacyChanged);
    _minimum = TextEditingController(text: f.minAmount?.display() ?? '');
    _maximum = TextEditingController(text: f.maxAmount?.display() ?? '');
    _from = f.fromDate;
    _end = f.endDateExclusive;
    _currency = f.currency ?? f.amountCurrency;
    _books = {...?f.bookIds};
    _categories = {...?f.categoryIds};
    _tags = {...?f.tagIds};
    _types = {...?f.types};
    _sources = {...?f.sources};
    _pictures = f.hasAttachments;
    _hasTags = f.hasTags;
    _hasAccount = f.hasAccount;
    _statistics = f.excludeFromStatistics;
    _budget = f.excludeFromBudget;
    _allTags = f.allTags;
    _descendants = f.includeDescendants;
  }

  @override
  void dispose() {
    widget.app.preferences.removeListener(_privacyChanged);
    _minimum.dispose();
    _maximum.dispose();
    super.dispose();
  }

  Widget _tri(String label, bool? value, void Function(bool?) changed) =>
      DropdownButtonFormField<String>(
        key: ValueKey('$label:$value'),
        initialValue: value == null
            ? 'any'
            : value
            ? 'yes'
            : 'no',
        decoration: InputDecoration(labelText: label),
        items: const [
          DropdownMenuItem(value: 'any', child: Text('不限')),
          DropdownMenuItem(value: 'yes', child: Text('是')),
          DropdownMenuItem(value: 'no', child: Text('否')),
        ],
        onChanged: (v) =>
            setState(() => changed(v == 'any' ? null : v == 'yes')),
      );
  Widget _chips(
    String title,
    Map<String, String> values,
    Set<String> selected,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        children: [
          for (final e in values.entries)
            FilterChip(
              label: Text(e.value),
              selected: selected.contains(e.key),
              onSelected: (yes) => setState(() {
                yes ? selected.add(e.key) : selected.remove(e.key);
              }),
            ),
        ],
      ),
      const SizedBox(height: 16),
    ],
  );

  Future<void> _date(bool end) async {
    final current = end ? _end : _from;
    final picked = await showDatePicker(
      context: context,
      initialDate: current == null
          ? DateTime.now()
          : end
          ? businessDate(current).subtract(const Duration(days: 1))
          : businessDate(current),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100, 12, 31),
    );
    if (picked != null && mounted) {
      setState(() {
        if (end) {
          _end = isoBusinessDate(picked.add(const Duration(days: 1)));
        } else {
          _from = isoBusinessDate(picked);
        }
      });
    }
  }

  void _apply() {
    try {
      Money? amount(TextEditingController c) {
        if (c.text.trim().isEmpty) return null;
        if (_currency == null) {
          throw const DomainError('query.currency_required');
        }
        return parseDisplay(
          c.text.trim(),
          _currency!,
          currencyScales[_currency]!,
        );
      }

      final filter = BillFilter(
        fromDate: _from,
        endDateExclusive: _end,
        keyword: widget.initial.keyword,
        bookIds: _books.isEmpty ? null : _books,
        categoryIds: _categories.isEmpty ? null : _categories,
        includeDescendants: _descendants,
        tagIds: _tags.isEmpty ? null : _tags,
        allTags: _allTags,
        currency: _currency,
        minAmount: amount(_minimum),
        maxAmount: amount(_maximum),
        hasAttachments: _pictures,
        hasTags: _hasTags,
        hasAccount: _hasAccount,
        sources: _sources.isEmpty ? null : _sources,
        types: _types.isEmpty ? null : _types,
        excludeFromStatistics: _statistics,
        excludeFromBudget: _budget,
      );
      Navigator.pop(context, filter);
    } catch (_) {
      setState(() => _error = '请核对日期范围、金额上下限和币种精度。');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) {
      if (widget.app.space?.id != widget.space.id ||
          widget.app.switchingSpace) {
        return const Padding(
          padding: EdgeInsets.all(24),
          child: Text('资料空间已切换。'),
        );
      }
      return Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .8,
          child: Column(
            children: [
              Row(
                children: [
                  Text('组合筛选', style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context, BillFilter()),
                    child: const Text('重置'),
                  ),
                ],
              ),
              Expanded(
                child: ListView(
                  children: [
                    Wrap(
                      spacing: 8,
                      children: [
                        ActionChip(
                          label: Text(_from ?? '开始日期'),
                          onPressed: () => _date(false),
                        ),
                        ActionChip(
                          label: Text(
                            _end == null
                                ? '截止日期'
                                : isoBusinessDate(
                                    businessDate(
                                      _end!,
                                    ).subtract(const Duration(days: 1)),
                                  ),
                          ),
                          onPressed: () => _date(true),
                        ),
                        if (_from != null || _end != null)
                          ActionChip(
                            label: const Text('清除日期'),
                            onPressed: () => setState(() {
                              _from = _end = null;
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _chips('账本', {
                      for (final b in widget.view.books) b.id: b.name,
                    }, _books),
                    _chips('类型', const {
                      'expense': '支出',
                      'income': '收入',
                      'transfer': '转账',
                      'credit_repayment': '信用卡还款',
                      'loan_borrow': '借入',
                      'loan_lend': '借出',
                      'loan_collect': '收回',
                      'loan_repay': '还款',
                      'refund': '退款',
                      'reimbursement': '报销',
                      'balance_adjustment': '余额调整',
                    }, _types),
                    _chips('分类', {
                      for (final c in widget.view.categories) c.id: c.name,
                    }, _categories),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('分类包含二级分类'),
                      value: _descendants,
                      onChanged: (v) => setState(() => _descendants = v),
                    ),
                    _chips('标签', {
                      for (final t in widget.view.tags.where(
                        (t) => t.payload['kind'] != 'group',
                      ))
                        t.id: t.name,
                    }, _tags),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('必须同时具有所选标签'),
                      value: _allTags,
                      onChanged: (v) => setState(() => _allTags = v),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: _currency ?? '',
                      decoration: const InputDecoration(labelText: '金额币种'),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('不限币种')),
                        for (final c in currencyScales.keys)
                          DropdownMenuItem(value: c, child: Text(c)),
                      ],
                      onChanged: (v) =>
                          setState(() => _currency = v == '' ? null : v),
                    ),
                    const SizedBox(height: 12),
                    if (widget.app.preferences.value.hideAmounts)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          key: const Key('filter-reveal-amounts'),
                          onPressed: () =>
                              setState(() => _revealAmounts = !_revealAmounts),
                          icon: Icon(
                            _revealAmounts
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                          label: Text(_revealAmounts ? '隐藏本次筛选金额' : '显示本次筛选金额'),
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _minimum,
                            key: const Key('filter-minimum'),
                            obscureText: _concealAmounts,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: '最小金额',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _maximum,
                            key: const Key('filter-maximum'),
                            obscureText: _concealAmounts,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: '最大金额',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _tri('有图片', _pictures, (v) => _pictures = v),
                    const SizedBox(height: 12),
                    _tri('有标签', _hasTags, (v) => _hasTags = v),
                    const SizedBox(height: 12),
                    _tri('关联账户', _hasAccount, (v) => _hasAccount = v),
                    const SizedBox(height: 12),
                    _tri('不计入收支统计', _statistics, (v) => _statistics = v),
                    const SizedBox(height: 12),
                    _tri('不计入预算', _budget, (v) => _budget = v),
                    const SizedBox(height: 16),
                    _chips('来源', const {
                      'manual': '手动',
                      'import': '导入',
                      'recurring': '周期',
                      'installment': '分期',
                      'auto': '自动',
                    }, _sources),
                  ],
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _apply,
                  child: const Text('应用筛选'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
