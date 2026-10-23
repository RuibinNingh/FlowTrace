import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../data/ledger/ledger_models.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../../domain/reporting/reporting.dart';
import '../statistics/report_widgets.dart';
import 'budget_editor.dart';

class BudgetView extends StatefulWidget {
  const BudgetView({
    required this.app,
    required this.space,
    required this.book,
    required this.view,
    required this.query,
    required this.report,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final LedgerEntity book;
  final LedgerView view;
  final ReportQuery query;
  final ReportResult report;
  @override
  State<BudgetView> createState() => _BudgetViewState();
}

class _BudgetViewState extends State<BudgetView> {
  bool _busy = false;
  bool get _current =>
      mounted &&
      widget.app.space?.id == widget.space.id &&
      !widget.app.switchingSpace;
  List<LedgerEntity> get _matching => widget.view.budgets
      .where(
        (b) =>
            b.scopeId == widget.book.id &&
            b.payload['period_start'] == widget.query.startDate &&
            b.payload['period_end_exclusive'] == widget.query.endDateExclusive,
      )
      .toList();

  Future<void> _edit({
    LedgerEntity? existing,
    Map<String, Object?>? copy,
  }) async {
    if (!_current) return;
    await Navigator.push(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => BudgetEditor(
          app: widget.app,
          space: widget.space,
          book: widget.book,
          periodStart: widget.query.startDate,
          periodEndExclusive: widget.query.endDateExclusive,
          existing: existing,
          copyFrom: copy,
        ),
      ),
    );
  }

  Future<void> _delete(LedgerEntity entity) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除这期预算？'),
        content: const Text('账单和其他期间预算会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !_current || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.app.ledger.delete(widget.space, entity);
    } catch (_) {
      if (mounted && _current) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('预算未删除，请核对权限后重试。')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _limit(String name, Object? limit, Object? spent, Object? remaining) {
    final ceiling = parseMinor(limit),
        used = parseMinor(spent),
        left = parseMinor(remaining);
    String amount(Object? value) => widget.app.preferences.value.formatMoney(
      Money(
        widget.query.reportCurrency,
        widget.query.reportScale,
        parseMinor(value),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              Text(name, style: Theme.of(context).textTheme.titleSmall),
              Text('限额 ${amount(limit)}'),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: reportRatio(used, ceiling),
            color: left.isNegative ? Theme.of(context).colorScheme.error : null,
          ),
          const SizedBox(height: 8),
          Text(
            '已用 ${amount(spent)}  ·  ${left.isNegative ? '超出' : '剩余'} ${amount(left.abs().toString())}',
            style: TextStyle(
              color: left.isNegative
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => widget.app.preferences.value.hideAmounts
        ? const ReportSection(title: '预算金额已隐藏', child: Text('关闭隐藏金额后查看预算。'))
        : _content(context),
  );

  Widget _content(BuildContext context) {
    final matching = _matching;
    final (previousStart, previousEnd) = periodBounds(
      isoBusinessDate(
        businessDate(widget.query.startDate).subtract(const Duration(days: 1)),
      ),
      widget.book.payload['month_start_day'] as int? ?? 1,
    );
    final previous = widget.view.budgets
        .where(
          (b) =>
              b.scopeId == widget.book.id &&
              b.payload['period_start'] == previousStart &&
              b.payload['period_end_exclusive'] == previousEnd,
        )
        .toList();
    final data = widget.report.budget;
    final canCreate = widget.view.canCreate('budget', widget.book.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (matching.length > 1) ...[
          const Text('这期有多份预算，汇总暂停。请核对并保留一份。'),
          for (final budget in matching)
            ListTile(
              title: const Text('重复预算'),
              subtitle: Text(budget.pending ? '待同步' : '已同步'),
              trailing: budget.canEdit
                  ? IconButton(
                      tooltip: '删除重复预算',
                      onPressed: _busy ? null : () => _delete(budget),
                      icon: const Icon(Icons.delete_outline),
                    )
                  : null,
            ),
        ] else if (matching.isEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('这期还没有预算。可设置总预算、分类预算，或同时设置。'),
          ),
          FilledButton.icon(
            key: const Key('create-budget'),
            onPressed: canCreate ? () => _edit() : null,
            icon: const Icon(Icons.add),
            label: const Text('设置本期预算'),
          ),
          if (previous.length == 1) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              key: const Key('copy-previous-budget'),
              onPressed: canCreate
                  ? () => _edit(copy: previous.single.payload)
                  : null,
              child: const Text('沿用上期金额与分类'),
            ),
          ],
        ] else ...[
          if (matching.single.pending) const Text('本期预算已保存在本机，待同步。'),
          if (data == null || !widget.report.available)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('预算占用暂不可用，请同步并核对账单关联。'),
            )
          else ...[
            ReportSection(
              title: '${widget.query.reportCurrency} · 本期预算',
              child: _limit(
                '总计',
                data['limit_minor'],
                data['spent_minor'],
                data['remaining_minor'],
              ),
            ),
            const SizedBox(height: 12),
            for (final entry in (data['categories'] as Map).entries) ...[
              _limit(
                widget.view.find('category', entry.key as String)?.name ??
                    '历史分类',
                (entry.value as Map)['limit_minor'],
                (entry.value as Map)['spent_minor'],
                (entry.value as Map)['remaining_minor'],
              ),
            ],
            if (data['other_limit_minor'] != null)
              _limit(
                '其他分类',
                data['other_limit_minor'],
                data['other_spent_minor'],
                (parseMinor(data['other_limit_minor']) -
                        parseMinor(data['other_spent_minor']))
                    .toString(),
              ),
            Text(
              data['includes_other_categories'] == true
                  ? '包含全部分类的预算支出。'
                  : '只统计已设置预算的分类及其子分类。',
            ),
          ],
          const SizedBox(height: 20),
          if (matching.single.canEdit)
            Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  key: const Key('edit-budget'),
                  onPressed: _busy
                      ? null
                      : () => _edit(existing: matching.single),
                  child: const Text('编辑预算'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _delete(matching.single),
                  child: const Text('删除预算'),
                ),
              ],
            ),
        ],
        const SizedBox(height: 20),
        const Text('“不计入预算”和“不计入收支”独立生效。退款、报销按原单期间减少预算占用。'),
      ],
    );
  }
}
