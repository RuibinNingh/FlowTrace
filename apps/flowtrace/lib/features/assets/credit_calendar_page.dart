import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../data/assets/asset_read_repository.dart';
import '../../data/ledger/ledger_models.dart';
import '../../domain/ledger/calendar_rules.dart';
import 'asset_read_view.dart';

class CreditCalendarPage extends StatefulWidget {
  const CreditCalendarPage({
    required this.app,
    required this.space,
    required this.accountId,
    this.initialDate,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final String accountId;
  final DateTime? initialDate;
  @override
  State<CreditCalendarPage> createState() => _CreditCalendarPageState();
}

class _CreditCalendarPageState extends State<CreditCalendarPage> {
  String _money(Money? value) =>
      assetMoney(value, widget.app.preferences.value);
  late final _repository = assetReads(widget.app);
  late final _stream = widget.app.ledger.watch(
    widget.space,
    query: const LedgerQuery(includeArchived: true),
  );
  late final _date = widget.initialDate ?? DateTime.now();
  late String _start = isoBusinessDate(DateTime.utc(_date.year, _date.month));
  late String _end = isoBusinessDate(DateTime.utc(_date.year, _date.month + 1));
  bool get _current =>
      widget.app.space?.id == widget.space.id && !widget.app.switchingSpace;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('信用卡账期')),
      body: !_current
          ? const Center(child: Text('资料空间已变化，请返回。'))
          : StreamBuilder<LedgerView>(
              stream: _stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Text('信用卡资料暂不可读。'));
                }
                final view = snapshot.data;
                if (view == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final account = view.find('account', widget.accountId);
                if (account == null ||
                    account.deleted ||
                    account.payload['kind'] != 'credit_card') {
                  return const Center(child: Text('此账户当前不可读取信用卡账期。'));
                }
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      account.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const Text(
                      '以下为服务器已同步账务按所配日历与先进先出抵扣重构的结果。免息日数是日期差，请与银行账单核对。',
                    ),
                    const SizedBox(height: 12),
                    AssetDateRange(
                      start: _start,
                      endExclusive: _end,
                      onChanged: (start, end) {
                        if (_current) {
                          setState(() {
                            _start = start;
                            _end = end;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    AssetReadView(
                      app: widget.app,
                      space: widget.space,
                      repository: _repository,
                      query: AssetReadQuery.creditCalendar(
                        scopeId: account.scopeId,
                        accountId: account.id,
                        startDate: _start,
                        endDateExclusive: _end,
                      ),
                      builder: (context, result) {
                        final calendar = result.data as AssetCreditCalendar;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '服务器已同步总欠款 ${_money(calendar.totalDebt)}',
                                      key: const Key('credit-total-debt'),
                                    ),
                                    Text('溢缴 ${_money(calendar.overpayment)}'),
                                    Text(
                                      '可用额度 ${_money(calendar.availableCredit)}',
                                    ),
                                    Text('超额 ${_money(calendar.overLimit)}'),
                                    Text(
                                      '期初未归属账期欠款 ${_money(calendar.openingCarry)}',
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (!calendar.repaymentAvailable)
                              const Text('部分或全部账期缺少完整证据，不能据此得出完整应还金额。'),
                            for (final issue in calendar.issues)
                              Text(assetReadIssue(issue)),
                            if (calendar.cycles.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(16),
                                child: Text('此范围内没有可展示的出账日；请核对信用卡配置或调整范围。'),
                              ),
                            for (final cycle in calendar.cycles)
                              Card(
                                key: Key('credit-cycle-${cycle.statementDate}'),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '出账日 ${cycle.statementDate}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                      Text(
                                        '账期 ${cycle.startDate} 至 ${isoBusinessDate(businessDate(cycle.endDateExclusive).subtract(const Duration(days: 1)))}',
                                      ),
                                      Text('还款日 ${cycle.dueDate}'),
                                      Text('期间消费 ${_money(cycle.charges)}'),
                                      Text(
                                        '出账时应还 ${_money(cycle.statementDue)}',
                                      ),
                                      Text(
                                        '服务器已同步剩余应还 ${_money(cycle.remainingDue)}',
                                      ),
                                      Text(
                                        '所配日历免息日数 ${cycle.minInterestFreeDays}–${cycle.maxInterestFreeDays} 天',
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                );
              },
            ),
    ),
  );
}
