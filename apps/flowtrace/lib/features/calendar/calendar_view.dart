import 'package:flutter/material.dart';

import '../../core/money/money.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../../domain/reporting/reporting.dart';
import '../../data/preferences/app_preferences.dart';
import '../../data/preferences/preferences_scope.dart';

class LedgerCalendar extends StatefulWidget {
  const LedgerCalendar({
    required this.query,
    required this.report,
    required this.onOpenDay,
    required this.onAddDay,
    required this.canAdd,
    this.weekStartsMonday = true,
    this.onWeekStartChanged,
    this.preferences,
    super.key,
  });
  final ReportQuery query;
  final ReportResult report;
  final ValueChanged<String> onOpenDay, onAddDay;
  final bool canAdd;
  final bool weekStartsMonday;
  final ValueChanged<bool>? onWeekStartChanged;
  final AppPreferences? preferences;
  @override
  State<LedgerCalendar> createState() => _LedgerCalendarState();
}

class _LedgerCalendarState extends State<LedgerCalendar> {
  late DateTime _month;
  String? _selected;
  late bool _monday = widget.weekStartsMonday;
  String _mode = 'both';
  @override
  void initState() {
    super.initState();
    final first = businessDate(widget.query.startDate);
    _month = DateTime.utc(first.year, first.month);
  }

  @override
  void didUpdateWidget(LedgerCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.weekStartsMonday != widget.weekStartsMonday) {
      _monday = widget.weekStartsMonday;
    }
    if (oldWidget.query.startDate != widget.query.startDate ||
        oldWidget.query.endDateExclusive != widget.query.endDateExclusive) {
      final first = businessDate(widget.query.startDate);
      _month = DateTime.utc(first.year, first.month);
      _selected = null;
    }
  }

  AppPreferences get _preferences =>
      widget.preferences ?? AppPreferencesScope.of(context);
  String _money(Money? value) => _preferences.formatMoney(
    value ??
        Money(
          widget.query.reportCurrency,
          widget.query.reportScale,
          BigInt.zero,
        ),
  );
  @override
  Widget build(BuildContext context) {
    final start = businessDate(widget.query.startDate),
        end = businessDate(widget.query.endDateExclusive);
    final days = DateTime.utc(_month.year, _month.month + 1, 0).day;
    final offset = (_month.weekday - (_monday ? 1 : 0)) % 7;
    final previous = DateTime.utc(_month.year, _month.month - 1);
    final next = DateTime.utc(_month.year, _month.month + 1);
    final labels = _monday
        ? ['一', '二', '三', '四', '五', '六', '日']
        : ['日', '一', '二', '三', '四', '五', '六'];
    final calendar = widget.report.calendar ?? {};
    final selected = _selected == null ? null : calendar[_selected];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              tooltip: '上一个日历月',
              onPressed: _month.isAfter(DateTime.utc(start.year, start.month))
                  ? () => setState(() {
                      _month = previous;
                      _selected = null;
                    })
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Text(
              '${_month.year}年${_month.month}月',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            IconButton(
              tooltip: '下一个日历月',
              onPressed: next.isBefore(end)
                  ? () => setState(() {
                      _month = next;
                      _selected = null;
                    })
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
            DropdownButton<String>(
              value: _mode,
              items: const [
                DropdownMenuItem(value: 'both', child: Text('收支')),
                DropdownMenuItem(value: 'net', child: Text('结余')),
                DropdownMenuItem(value: 'income', child: Text('收入')),
                DropdownMenuItem(value: 'expense', child: Text('支出')),
              ],
              onChanged: (v) => setState(() => _mode = v!),
            ),
            FilterChip(
              label: const Text('周一开始'),
              selected: _monday,
              onSelected: (v) {
                if (widget.onWeekStartChanged == null) {
                  setState(() => _monday = v);
                } else {
                  widget.onWeekStartChanged!(v);
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          key: const Key('calendar-weekday-labels'),
          children: [
            for (final label in labels)
              Expanded(child: Center(child: Text(label))),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) => GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: ((offset + days + 6) ~/ 7) * 7,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisExtent: constraints.maxWidth < 450 ? 92 : 106,
              mainAxisSpacing: 3,
              crossAxisSpacing: 3,
            ),
            itemBuilder: (context, index) {
              final number = index - offset + 1;
              if (number < 1 || number > days) return const SizedBox.shrink();
              final date = DateTime.utc(_month.year, _month.month, number);
              final iso = isoBusinessDate(date);
              final enabled = !date.isBefore(start) && date.isBefore(end);
              final totals = calendar[iso];
              return Material(
                color: _selected == iso
                    ? Theme.of(context).colorScheme.primaryContainer
                    : enabled
                    ? Theme.of(context).colorScheme.surfaceContainerLow
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  key: ValueKey('calendar-$iso'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: enabled ? () => setState(() => _selected = iso) : null,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      children: [
                        Text(
                          '$number',
                          style: TextStyle(
                            color: enabled
                                ? null
                                : Theme.of(context).disabledColor,
                          ),
                        ),
                        const SizedBox(height: 5),
                        if (enabled && totals != null) ...[
                          if (_mode == 'both' || _mode == 'income')
                            Text(
                              '+${_money(totals.income)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: _preferences.incomeColor,
                              ),
                            ),
                          if (_mode == 'both' || _mode == 'expense')
                            Text(
                              '−${_money(totals.expense)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: _preferences.expenseColor,
                              ),
                            ),
                          if (_mode == 'net')
                            Text(
                              _money(totals.net),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        if (_selected != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _selected!,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '收入 ${_money(selected?.income)}  ·  支出 ${_money(selected?.expense)}  ·  结余 ${_money(selected?.net)}',
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 12,
                    children: [
                      OutlinedButton(
                        onPressed: () => widget.onOpenDay(_selected!),
                        child: const Text('查看当天流水'),
                      ),
                      FilledButton.icon(
                        key: const Key('calendar-add-entry'),
                        onPressed: widget.canAdd
                            ? () => widget.onAddDay(_selected!)
                            : null,
                        icon: const Icon(Icons.add),
                        label: const Text('补记一笔'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        const Text('收支按账本业务日归属。退款、报销冲减原单日期；转账和借贷本金不计入收支。'),
      ],
    );
  }
}
