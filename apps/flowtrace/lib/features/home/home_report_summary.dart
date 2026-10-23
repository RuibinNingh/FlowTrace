import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../data/ledger/ledger_reporting.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../statistics/report_widgets.dart';
import '../statistics/statistics_page.dart';

class HomeReportSummary extends StatefulWidget {
  const HomeReportSummary({
    required this.app,
    required this.space,
    required this.query,
    required this.bookName,
    required this.mode,
    required this.cover,
    required this.onOpen,
    this.onOpenTab,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final ReportQuery? query;
  final String bookName, mode;
  final Color cover;
  final VoidCallback onOpen;
  final ValueChanged<int>? onOpenTab;
  @override
  State<HomeReportSummary> createState() => _HomeReportSummaryState();
}

class _HomeReportSummaryState extends State<HomeReportSummary> {
  late final _stream = widget.query == null
      ? null
      : LedgerReportingService(
          widget.app.repository,
        ).watch(widget.space, widget.query!);
  @override
  Widget build(BuildContext context) => StreamBuilder<ReportResult>(
    stream: _stream,
    builder: (context, snapshot) {
      final valid =
          !snapshot.hasError &&
          widget.app.space?.id == widget.space.id &&
          !widget.app.switchingSpace;
      final report = valid ? snapshot.data : null;
      final totals = report?.totals;
      final preferences = widget.app.preferences.value;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (preferences.showHomeSummary)
            Container(
              key: const Key('home-summary-card'),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: LinearGradient(
                  colors: [
                    widget.cover,
                    Color.lerp(widget.cover, Colors.black, .35)!,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: widget.onOpen,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.bookName,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            const Icon(Icons.bar_chart, color: Colors.white70),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Text(switch (widget.mode) {
                          'all' => '累计支出',
                          'year' => '年支出',
                          _ => '月支出',
                        }, style: const TextStyle(color: Colors.white70)),
                        const SizedBox(height: 4),
                        Text(
                          totals == null
                              ? '待核对'
                              : '${widget.query!.reportCurrency} ${preferences.formatMoney(totals.expense)}',
                          key: const Key('home-expense'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (widget.mode == 'month' && widget.query != null)
                          Text(
                            '${widget.query!.startDate} – ${isoBusinessDate(businessDate(widget.query!.endDateExclusive).subtract(const Duration(days: 1)))}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 22,
                          runSpacing: 8,
                          children: [
                            Text(
                              '收入 ${totals == null ? '待核对' : preferences.formatMoney(totals.income)}',
                              style: const TextStyle(color: Colors.white),
                            ),
                            Text(
                              '结余 ${totals == null ? '待核对' : preferences.formatMoney(totals.net)}',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                        if (report?.available == false ||
                            snapshot.hasError ||
                            widget.query == null)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: Text(
                              '汇总资料待核对，请检查同步、汇率与账单关联。',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (preferences.showHomeBudget) ...[
            if (preferences.showHomeSummary) const SizedBox(height: 12),
            _budget(report),
          ],
          if (preferences.showHomeTrend) ...[
            if (preferences.showHomeSummary || preferences.showHomeBudget)
              const SizedBox(height: 12),
            ReportSection(
              key: const Key('home-trend-card'),
              title: '收支趋势',
              action: TextButton(
                onPressed: widget.onOpen,
                child: const Text('全部统计'),
              ),
              child: report?.available == true && widget.query != null
                  ? ReportDailyChart(
                      report: report!,
                      query: widget.query!,
                      preferences: preferences,
                    )
                  : const Text('趋势资料待核对。'),
            ),
          ],
        ],
      );
    },
  );

  Widget _budget(ReportResult? report) {
    final data = report?.budget;
    final preferences = widget.app.preferences.value;
    String amount(Object? minor) => preferences.formatMoney(
      Money(
        widget.query!.reportCurrency,
        widget.query!.reportScale,
        parseMinor(minor),
      ),
    );
    return ReportSection(
      key: const Key('home-budget-card'),
      title: '本期预算',
      action: TextButton(
        onPressed: () {
          if (widget.onOpenTab != null) {
            widget.onOpenTab!(2);
          } else {
            widget.onOpen();
          }
        },
        child: const Text('管理预算'),
      ),
      child: widget.mode != 'month'
          ? const Text('切换到月期间查看账本预算。')
          : report == null || !report.available
          ? const Text('预算资料待核对。')
          : data == null
          ? const Text('本期尚未设置预算。')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '限额 ${amount(data['limit_minor'])} ${widget.query!.reportCurrency}',
                ),
                const SizedBox(height: 8),
                if (!preferences.hideAmounts) ...[
                  LinearProgressIndicator(
                    value: reportRatio(
                      parseMinor(data['spent_minor']),
                      parseMinor(data['limit_minor']),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  '已用 ${amount(data['spent_minor'])} · 剩余 ${amount(data['remaining_minor'])}',
                ),
              ],
            ),
    );
  }
}
