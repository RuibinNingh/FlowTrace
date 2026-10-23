import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../../data/ledger/ledger_models.dart';
import '../../data/ledger/ledger_query.dart';
import '../../data/ledger/ledger_reporting.dart';
import '../../data/preferences/app_preferences.dart';
import '../../data/preferences/preferences_scope.dart';
import '../../data/preferences/preferences_controller.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../../domain/ledger/timezone_rules.dart';
import '../../domain/reporting/reporting.dart' show uncategorizedReportCategory;
import '../budgets/budget_view.dart';
import '../calendar/calendar_view.dart';
import '../entry/entry_page.dart';
import '../search/search_page.dart';
import 'report_widgets.dart';

class StatisticsPage extends StatefulWidget {
  const StatisticsPage({
    required this.app,
    required this.space,
    required this.bookId,
    this.initialDate,
    this.initialTab = 0,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final String bookId;
  final String? initialDate;
  final int initialTab;
  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  late final _ledgerStream = widget.app.ledger.watch(
    widget.space,
    query: const LedgerQuery(includeArchived: true),
  );
  late final _reports = LedgerReportingService(widget.app.repository);
  Stream<ReportResult>? _stream, _previousStream;
  ReportQuery? _query;
  String? _signature;
  late int _tab = widget.initialTab;
  String _mode = 'month';
  String? _anchor, _customStart, _customEnd;
  bool _incomeCategories = false;
  bool get _current =>
      mounted &&
      widget.app.space?.id == widget.space.id &&
      !widget.app.switchingSpace;

  @override
  void initState() {
    super.initState();
    _loadCalendarPreference();
  }

  Future<void> _loadCalendarPreference() async {
    try {
      if (!widget.app.preferences.ready) {
        await widget.app.preferences.initialize();
      }
      final legacy = await widget.app.repository.readSetting(
        'calendar.week-start.${widget.space.id}',
      );
      final saved = await widget.app.repository.readSetting(
        PreferencesController.settingKey,
      );
      if (_current && saved == null && legacy != null) {
        try {
          await widget.app.preferences.update(
            widget.app.preferences.value.copyWith(
              weekStartsMonday: legacy != 'sunday',
            ),
          );
        } catch (_) {
          // A concurrent preferences writer is authoritative; no stale migration.
        }
      }
    } catch (_) {
      if (mounted && _current) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('周首设置暂不能读取，当前使用已有显示设置。')));
      }
    }
  }

  Future<void> _setCalendarPreference(bool monday) async {
    if (!_current) return;
    try {
      await widget.app.preferences.update(
        widget.app.preferences.value.copyWith(weekStartsMonday: monday),
      );
    } catch (_) {
      if (mounted && _current) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('日历周首设置未能保存，请重试。')));
      }
    }
  }

  void _configure(LedgerEntity book) {
    _anchor ??=
        widget.initialDate ??
        instantBusinessDate(
          DateTime.now().toUtc().toIso8601String(),
          book.payload['timezone'] as String,
        );
    final day = businessDate(_anchor!);
    final currency = book.payload['currency'] as String;
    final monthStart = book.payload['month_start_day'] as int? ?? 1;
    final (start, end) = switch (_mode) {
      'year' => (
        '${day.year.toString().padLeft(4, '0')}-01-01',
        '${(day.year + 1).toString().padLeft(4, '0')}-01-01',
      ),
      'custom' => (_customStart!, _customEnd!),
      _ => periodBounds(_anchor!, monthStart),
    };
    final signature = '${book.id}:$currency:$start:$end';
    if (_signature == signature) return;
    _signature = signature;
    _query = ReportQuery(
      bookId: book.id,
      reportCurrency: currency,
      reportScale: currencyScales[currency]!,
      startDate: start,
      endDateExclusive: end,
    );
    _stream = _reports.watch(widget.space, _query!);
    final (previousStart, previousEnd) = _mode == 'month'
        ? periodBounds(
            isoBusinessDate(
              businessDate(start).subtract(const Duration(days: 1)),
            ),
            monthStart,
          )
        : _mode == 'year'
        ? ('${(day.year - 1).toString().padLeft(4, '0')}-01-01', start)
        : (
            isoBusinessDate(
              businessDate(
                start,
              ).subtract(businessDate(end).difference(businessDate(start))),
            ),
            start,
          );
    _previousStream = _reports.watch(
      widget.space,
      ReportQuery(
        bookId: book.id,
        reportCurrency: currency,
        reportScale: currencyScales[currency]!,
        startDate: previousStart,
        endDateExclusive: previousEnd,
      ),
    );
  }

  Future<void> _selectMode(String mode) async {
    if (mode == 'custom') {
      final q = _query!;
      final result = await showDateRangePicker(
        context: context,
        firstDate: DateTime(1900),
        lastDate: DateTime(2100, 12, 31),
        initialDateRange: DateTimeRange(
          start: businessDate(q.startDate),
          end: businessDate(
            q.endDateExclusive,
          ).subtract(const Duration(days: 1)),
        ),
      );
      if (result == null || !_current) return;
      setState(() {
        _mode = mode;
        _customStart = isoBusinessDate(result.start);
        _customEnd = isoBusinessDate(result.end.add(const Duration(days: 1)));
        _signature = null;
      });
    } else {
      setState(() {
        _mode = mode;
        _signature = null;
      });
    }
  }

  void _shift(bool forward) {
    final q = _query!;
    setState(() {
      if (_mode == 'month') {
        _anchor = forward
            ? q.endDateExclusive
            : isoBusinessDate(
                businessDate(q.startDate).subtract(const Duration(days: 1)),
              );
      } else if (_mode == 'year') {
        _anchor = '${businessDate(_anchor!).year + (forward ? 1 : -1)}-01-01';
      } else {
        final delta =
            businessDate(
              q.endDateExclusive,
            ).difference(businessDate(q.startDate)) *
            (forward ? 1 : -1);
        _customStart = isoBusinessDate(businessDate(q.startDate).add(delta));
        _customEnd = isoBusinessDate(
          businessDate(q.endDateExclusive).add(delta),
        );
      }
      _signature = null;
    });
  }

  Future<void> _openBills({String? day, String? category}) async {
    final q = _query!;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SearchPage(
          app: widget.app,
          space: widget.space,
          initialBookId: widget.bookId,
          initialFilter: BillFilter(
            bookIds: {widget.bookId},
            fromDate: day ?? q.startDate,
            endDateExclusive: day == null
                ? q.endDateExclusive
                : isoBusinessDate(
                    businessDate(day).add(const Duration(days: 1)),
                  ),
            categoryIds: category == null ? null : {category},
            includeDescendants: true,
          ),
        ),
      ),
    );
  }

  Future<void> _addDay(String day) => Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => EntryPage(
        app: widget.app,
        space: widget.space,
        bookId: widget.bookId,
        initialBusinessDate: day,
      ),
    ),
  );

  Widget _summary(LedgerView view, ReportResult report) {
    final totals = report.totals!;
    final preferences = widget.app.preferences.value;
    final q = _query!;
    final days = businessDate(
      q.endDateExclusive,
    ).difference(businessDate(q.startDate)).inDays;
    final average = Money(
      q.reportCurrency,
      q.reportScale,
      roundHalfUp(totals.expense.minor, BigInt.from(days)),
    );
    final count = view.bills
        .where(
          (b) =>
              b.scopeId == widget.bookId &&
              (b.payload['business_date'] as String).compareTo(q.startDate) >=
                  0 &&
              (b.payload['business_date'] as String).compareTo(
                    q.endDateExclusive,
                  ) <
                  0,
        )
        .length;
    return ReportSection(
      title: '期间概览 · ${q.reportCurrency}',
      action: TextButton(
        onPressed: () => _openBills(),
        child: const Text('原始流水'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            children: [
              ReportMetric(
                '收入',
                preferences.formatMoney(totals.income),
                color: preferences.incomeColor,
              ),
              ReportMetric(
                '支出',
                preferences.formatMoney(totals.expense),
                color: preferences.expenseColor,
              ),
              ReportMetric('结余', preferences.formatMoney(totals.net)),
              ReportMetric('日均支出 · $days天', preferences.formatMoney(average)),
              ReportMetric('可见原始记录', '$count笔'),
              ReportMetric(
                '退款冲减',
                totals.refund == null
                    ? '明细不可用'
                    : preferences.formatMoney(totals.refund!),
              ),
              ReportMetric(
                '报销冲减',
                totals.reimbursement == null
                    ? '明细不可用'
                    : preferences.formatMoney(totals.reimbursement!),
              ),
            ],
          ),
          StreamBuilder<ReportResult>(
            key: ValueKey('previous-$_signature'),
            stream: _previousStream,
            builder: (context, snapshot) {
              if (preferences.hideAmounts) return const Text('上期比较金额已隐藏。');
              final previous = snapshot.data?.totals;
              if (previous == null || snapshot.hasError) {
                return const Text('上期比较待核对');
              }
              final delta = totals.expense.minor - previous.expense.minor;
              return Text(
                previous.expense.minor == BigInt.zero
                    ? '上期支出为0，环比不适用。'
                    : '支出较上期 ${delta.isNegative ? '减少' : '增加'} ${reportPercent(delta.abs(), previous.expense.minor)}',
              );
            },
          ),
          if (!report.allocationBreakdownAvailable)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('净收支已按可证剩余额计算；部分退款/报销明细不在当前权限内，拆分暂不可用。'),
            ),
        ],
      ),
    );
  }

  Widget _categories(LedgerView view, ReportResult report) {
    final preferences = widget.app.preferences.value;
    final values = (_incomeCategories
        ? report.categoryIncomeMinor
        : report.categoryExpenseMinor)!;
    final sorted = values.entries.toList()
      ..sort((a, b) => parseMinor(b.value).compareTo(parseMinor(a.value)));
    final sum = values.values.fold(BigInt.zero, (s, v) => s + parseMinor(v));
    return ReportSection(
      title: '分类占比',
      action: SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('支出')),
          ButtonSegment(value: true, label: Text('收入')),
        ],
        selected: {_incomeCategories},
        onSelectionChanged: (v) => setState(() => _incomeCategories = v.single),
      ),
      child: sorted.isEmpty
          ? const Text('这期没有可统计的分类收支。')
          : Column(
              children: [
                for (final entry in sorted)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      entry.key == uncategorizedReportCategory
                          ? '未分类 / 手续费'
                          : view.find('category', entry.key)?.name ?? '历史分类',
                    ),
                    subtitle: preferences.hideAmounts
                        ? null
                        : Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 8),
                            child: LinearProgressIndicator(
                              value: reportRatio(parseMinor(entry.value), sum),
                            ),
                          ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          preferences.formatMoney(
                            Money(
                              _query!.reportCurrency,
                              _query!.reportScale,
                              parseMinor(entry.value),
                            ),
                          ),
                        ),
                        if (!preferences.hideAmounts)
                          Text(
                            reportPercent(parseMinor(entry.value), sum),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                    onTap: entry.key == uncategorizedReportCategory
                        ? null
                        : () => _openBills(category: entry.key),
                  ),
                const Text('分类按直接归属分列；父分类和子分类不会重复求和。点分类查看本期原始流水。'),
              ],
            ),
    );
  }

  Widget _unavailable(ReportResult report) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('汇总待核对', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(
            report.issues.contains('fx.report_unavailable')
                ? '部分外币记录缺少已冻结汇率，请编辑补齐后重试。'
                : '当前资料不足以证明完整收支。请同步并检查冲突、退款或报销关联，原始账单已保留。',
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => Navigator.pushNamed(context, '/sync'),
            child: const Text('查看同步与恢复'),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('统计、日历与预算')),
      body: !_current
          ? const Center(child: Text('资料空间已切换。'))
          : StreamBuilder<LedgerView>(
              stream: _ledgerStream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Text('账本资料读取失败。'));
                }
                final view = snapshot.data;
                if (view == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final book = view.find('book', widget.bookId);
                if (book == null) {
                  return const Center(child: Text('当前无权访问此账本。'));
                }
                _configure(book);
                final q = _query!;
                return StreamBuilder<ReportResult>(
                  key: ValueKey(_signature),
                  stream: _stream,
                  builder: (context, reportSnapshot) {
                    final report = reportSnapshot.data;
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1000),
                        child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            Text(
                              book.name,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SegmentedButton<String>(
                                  segments: const [
                                    ButtonSegment(
                                      value: 'month',
                                      label: Text('月'),
                                    ),
                                    ButtonSegment(
                                      value: 'year',
                                      label: Text('年'),
                                    ),
                                    ButtonSegment(
                                      value: 'custom',
                                      label: Text('自定义'),
                                    ),
                                  ],
                                  selected: {_mode},
                                  onSelectionChanged: (v) =>
                                      _selectMode(v.single),
                                ),
                                IconButton(
                                  tooltip: '上一期',
                                  onPressed:
                                      businessDate(q.startDate).year > 1900
                                      ? () => _shift(false)
                                      : null,
                                  icon: const Icon(Icons.chevron_left),
                                ),
                                Text(
                                  '${q.startDate} 至 ${isoBusinessDate(businessDate(q.endDateExclusive).subtract(const Duration(days: 1)))}',
                                ),
                                IconButton(
                                  tooltip: '下一期',
                                  onPressed:
                                      businessDate(q.endDateExclusive).year <
                                          2101
                                      ? () => _shift(true)
                                      : null,
                                  icon: const Icon(Icons.chevron_right),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (view.pendingCount > 0)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  '有${view.pendingCount}项本机变更待处理；汇总包含可证明的本机变更。',
                                ),
                              ),
                            SegmentedButton<int>(
                              segments: const [
                                ButtonSegment(
                                  value: 0,
                                  label: Text('统计'),
                                  icon: Icon(Icons.bar_chart),
                                ),
                                ButtonSegment(
                                  value: 1,
                                  label: Text('日历'),
                                  icon: Icon(Icons.calendar_month),
                                ),
                                ButtonSegment(
                                  value: 2,
                                  label: Text('预算'),
                                  icon: Icon(Icons.savings_outlined),
                                ),
                              ],
                              selected: {_tab},
                              onSelectionChanged: (v) =>
                                  setState(() => _tab = v.single),
                            ),
                            const SizedBox(height: 18),
                            if (reportSnapshot.hasError)
                              const Text('报表读取失败，请返回重试。')
                            else if (report == null)
                              const Padding(
                                padding: EdgeInsets.all(40),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else ...[
                              if (!report.available) _unavailable(report),
                              if (_tab == 0 && report.available) ...[
                                _summary(view, report),
                                const SizedBox(height: 12),
                                ReportSection(
                                  title: '每日收支',
                                  action: IconButton(
                                    tooltip: '全屏趋势',
                                    onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute<void>(
                                        builder: (_) => _ReportChartPage(
                                          app: widget.app,
                                          space: widget.space,
                                          query: q,
                                        ),
                                      ),
                                    ),
                                    icon: const Icon(Icons.fullscreen),
                                  ),
                                  child: ReportDailyChart(
                                    report: report,
                                    query: q,
                                    preferences: widget.app.preferences.value,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                _categories(view, report),
                              ],
                              if (_tab == 1 && report.available)
                                LedgerCalendar(
                                  query: q,
                                  report: report,
                                  canAdd: view.canCreate('bill', widget.bookId),
                                  weekStartsMonday: widget
                                      .app
                                      .preferences
                                      .value
                                      .weekStartsMonday,
                                  preferences: widget.app.preferences.value,
                                  onWeekStartChanged: _setCalendarPreference,
                                  onOpenDay: (day) => _openBills(day: day),
                                  onAddDay: _addDay,
                                ),
                              if (_tab == 2 &&
                                  widget.app.preferences.value.hideAmounts)
                                const ReportSection(
                                  title: '预算金额已隐藏',
                                  child: Text('请在设置中关闭“隐藏金额”后查看或编辑预算。'),
                                ),
                              if (_tab == 2 &&
                                  !widget.app.preferences.value.hideAmounts)
                                _mode != 'month'
                                    ? const Padding(
                                        padding: EdgeInsets.all(20),
                                        child: Text(
                                          '切换到“月”查看或设置账本预算；月份遵循账本起始日。',
                                        ),
                                      )
                                    : BudgetView(
                                        app: widget.app,
                                        space: widget.space,
                                        book: book,
                                        view: view,
                                        query: q,
                                        report: report,
                                      ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    ),
  );
}

class _ReportChartPage extends StatefulWidget {
  const _ReportChartPage({
    required this.app,
    required this.space,
    required this.query,
  });
  final AppController app;
  final DataSpace space;
  final ReportQuery query;
  @override
  State<_ReportChartPage> createState() => _ReportChartPageState();
}

class _ReportChartPageState extends State<_ReportChartPage> {
  late final _stream = LedgerReportingService(
    widget.app.repository,
  ).watch(widget.space, widget.query);
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('收支趋势')),
      body: widget.app.space?.id != widget.space.id || widget.app.switchingSpace
          ? const Center(child: Text('资料空间已切换。'))
          : StreamBuilder<ReportResult>(
              stream: _stream,
              builder: (context, snapshot) {
                final report = snapshot.data;
                if (snapshot.hasError) {
                  return const Center(child: Text('报表读取失败。'));
                }
                if (report == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!report.available) {
                  return const Center(child: Text('当前汇总不可用，请核对权限与同步状态。'));
                }
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: ReportDailyChart(
                    report: report,
                    query: widget.query,
                    preferences: widget.app.preferences.value,
                  ),
                );
              },
            ),
    ),
  );
}

class ReportDailyChart extends StatefulWidget {
  const ReportDailyChart({
    required this.report,
    required this.query,
    this.preferences,
    super.key,
  });
  final ReportResult report;
  final ReportQuery query;
  final AppPreferences? preferences;
  @override
  State<ReportDailyChart> createState() => _ReportDailyChartState();
}

class _ReportDailyChartState extends State<ReportDailyChart> {
  bool _line = false;
  ReportResult get report => widget.report;
  ReportQuery get query => widget.query;
  @override
  Widget build(BuildContext context) {
    final preferences = widget.preferences ?? AppPreferencesScope.of(context);
    if (preferences.hideAmounts) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text('金额已隐藏，数值趋势图暂不展示。'),
      );
    }
    final days = report.calendar ?? {};
    final start = businessDate(query.startDate),
        end = businessDate(query.endDateExclusive);
    final monthly = end.difference(start).inDays > 366;
    final points = <String, (BigInt, BigInt)>{};
    for (
      var date = start;
      date.isBefore(end);
      date = monthly
          ? DateTime.utc(date.year, date.month + 1)
          : date.add(const Duration(days: 1))
    ) {
      points[isoBusinessDate(date).substring(0, monthly ? 7 : 10)] = (
        BigInt.zero,
        BigInt.zero,
      );
    }
    for (final entry in days.entries) {
      final key = entry.key.substring(0, monthly ? 7 : 10);
      final old = points[key] ?? (BigInt.zero, BigInt.zero);
      points[key] = (
        old.$1 + entry.value.income.minor,
        old.$2 + entry.value.expense.minor,
      );
    }
    final max = points.values.fold(BigInt.zero, (m, v) {
      final n = v.$1 > v.$2 ? v.$1 : v.$2;
      return n > m ? n : m;
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${query.reportCurrency}  ·  ${preferences.incomeExpenseColors == IncomeExpenseColors.expenseRed ? '绿色收入 / 红色支出' : '红色收入 / 绿色支出'}${monthly ? ' · 长期间按月汇集' : ''}',
        ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('柱状图')),
            ButtonSegment(value: true, label: Text('折线图')),
          ],
          selected: {_line},
          onSelectionChanged: (v) => setState(() => _line = v.single),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 240,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Stack(
              alignment: Alignment.bottomLeft,
              children: [
                if (_line)
                  Positioned(
                    left: 0,
                    bottom: 36,
                    child: CustomPaint(
                      size: Size(points.length * (monthly ? 72.0 : 56.0), 180),
                      painter: _ReportLinePainter(
                        [
                          for (final value in points.values)
                            (
                              reportRatio(value.$1, max),
                              reportRatio(value.$2, max),
                            ),
                        ],
                        preferences.incomeColor,
                        preferences.expenseColor,
                      ),
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final entry in points.entries)
                      Tooltip(
                        message:
                            '${entry.key}\n收入 ${preferences.formatMoney(Money(query.reportCurrency, query.reportScale, checkedMinor(entry.value.$1)))}\n支出 ${preferences.formatMoney(Money(query.reportCurrency, query.reportScale, checkedMinor(entry.value.$2)))}',
                        child: SizedBox(
                          width: monthly ? 72 : 56,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              SizedBox(
                                height: 180,
                                child: _line
                                    ? null
                                    : Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Container(
                                            width: 12,
                                            height:
                                                reportRatio(
                                                  entry.value.$1,
                                                  max,
                                                ) *
                                                180,
                                            decoration: BoxDecoration(
                                              color: preferences.incomeColor,
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                          ),
                                          const SizedBox(width: 3),
                                          Container(
                                            width: 12,
                                            height:
                                                reportRatio(
                                                  entry.value.$2,
                                                  max,
                                                ) *
                                                180,
                                            decoration: BoxDecoration(
                                              color: preferences.expenseColor,
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                height: 26,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    entry.key.substring(monthly ? 2 : 5),
                                    maxLines: 1,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelSmall,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text('可横向滚动，长按日期查看金额。图形比例不参与金额计算。'),
      ],
    );
  }
}

class _ReportLinePainter extends CustomPainter {
  _ReportLinePainter(this.values, this.incomeColor, this.expenseColor);
  final List<(double, double)> values;
  final Color incomeColor, expenseColor;
  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final step = size.width / values.length;
    for (final income in [true, false]) {
      final paint = Paint()
        ..color = income ? incomeColor : expenseColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (var i = 0; i < values.length; i++) {
        final value = income ? values[i].$1 : values[i].$2;
        final point = Offset((i + .5) * step, size.height * (1 - value));
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawCircle(point, 2, Paint()..color = paint.color);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_ReportLinePainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.incomeColor != incomeColor ||
      oldDelegate.expenseColor != expenseColor;
}
