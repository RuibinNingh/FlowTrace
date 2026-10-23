import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../data/assets/asset_read_repository.dart';
import '../../data/ledger/ledger_models.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../transactions/bill_detail_page.dart';
import 'asset_history_page.dart';
import 'asset_read_view.dart';
import 'credit_calendar_page.dart';

class AssetAccountPage extends StatefulWidget {
  const AssetAccountPage({
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
  State<AssetAccountPage> createState() => _AssetAccountPageState();
}

class _AssetAccountPageState extends State<AssetAccountPage> {
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
  int _offset = 0;
  bool get _current =>
      widget.app.space?.id == widget.space.id && !widget.app.switchingSpace;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('账户明细')),
      body: !_current
          ? const Center(child: Text('资料空间已变化，请返回。'))
          : StreamBuilder<LedgerView>(
              stream: _stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Text('账户资料暂不可读。'));
                }
                final view = snapshot.data;
                if (view == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final account = view.find('account', widget.accountId);
                if (account == null || account.deleted) {
                  return const Center(child: Text('当前账户不存在或无权读取。'));
                }
                final opening = Money.fromJson(account.payload['opening']);
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      account.name,
                      key: const Key('asset-account-name'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    Text(
                      '本机原币余额 ${_money(view.balances[account.id]?.value)}',
                      key: const Key('asset-account-local-balance'),
                    ),
                    Text(
                      '期初 ${_money(opening)} · 启用日期 ${account.payload['opening_date'] ?? '未记录'}',
                    ),
                    if (account.pending)
                      const Text('此账户有尚未同步的修改，以下服务器分录不包含本机待同步记录。'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('asset-account-history'),
                          icon: const Icon(Icons.show_chart),
                          label: const Text('此资产范围趋势'),
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => AssetHistoryPage(
                                app: widget.app,
                                space: widget.space,
                                scopeId: account.scopeId,
                                initialDate: _date,
                              ),
                            ),
                          ),
                        ),
                        if (account.payload['kind'] == 'credit_card')
                          OutlinedButton.icon(
                            key: const Key('asset-account-credit'),
                            icon: const Icon(Icons.credit_card),
                            label: const Text('信用卡账期'),
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => CreditCalendarPage(
                                  app: widget.app,
                                  space: widget.space,
                                  accountId: account.id,
                                  initialDate: _date,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    AssetDateRange(
                      start: _start,
                      endExclusive: _end,
                      onChanged: (start, end) {
                        if (_current) {
                          setState(() {
                            _start = start;
                            _end = end;
                            _offset = 0;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    AssetReadView(
                      app: widget.app,
                      space: widget.space,
                      repository: _repository,
                      query: AssetReadQuery.entries(
                        scopeId: account.scopeId,
                        accountId: account.id,
                        startDate: _start,
                        endDateExclusive: _end,
                        offset: _offset,
                      ),
                      builder: (context, result) {
                        final entries = result.data as AssetAccountEntries;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '服务器期间期初 ${_money(entries.openingBalance)}',
                              key: const Key('asset-entry-opening'),
                            ),
                            Text(
                              '服务器期间期末 ${_money(entries.closingBalance)}',
                              key: const Key('asset-entry-closing'),
                            ),
                            for (final issue in entries.issues)
                              Text(assetReadIssue(issue)),
                            const SizedBox(height: 8),
                            Text(
                              '共 ${entries.totalCount} 条分录 · 当前第 ${entries.offset + 1}–${entries.offset + entries.entries.length} 条',
                            ),
                            if (entries.entries.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(16),
                                child: Text('此期间没有已同步分录。'),
                              ),
                            for (final entry in entries.entries)
                              _entry(view, entry),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              children: [
                                OutlinedButton(
                                  key: const Key('asset-entries-previous'),
                                  onPressed: _offset == 0
                                      ? null
                                      : () => setState(
                                          () => _offset =
                                              (_offset - entries.limit).clamp(
                                                0,
                                                50000,
                                              ),
                                        ),
                                  child: const Text('上一页'),
                                ),
                                OutlinedButton(
                                  key: const Key('asset-entries-next'),
                                  onPressed: !entries.hasNext
                                      ? null
                                      : () => setState(
                                          () =>
                                              _offset += entries.entries.length,
                                        ),
                                  child: const Text('下一页'),
                                ),
                              ],
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

  Widget _entry(LedgerView view, AssetEntry entry) {
    final bill = entry.billId == null ? null : view.find('bill', entry.billId!);
    final canOpen =
        entry.detailAvailable &&
        bill != null &&
        !bill.deleted &&
        bill.scopeId == entry.bookId;
    final category = entry.categoryId == null
        ? null
        : view.find('category', entry.categoryId!);
    final tags = [
      for (final id in entry.tagIds) view.find('tag', id)?.name ?? '标签待同步',
    ];
    return Card(
      child: ListTile(
        key: Key('asset-entry-${entry.id}'),
        isThreeLine: true,
        title: Text(
          '${entry.businessDate} · ${entry.component == 'fee' ? '手续费' : '本金'} · ${_money(entry.money)}',
        ),
        subtitle: Text(
          entry.detailAvailable
              ? '${entry.note!.isEmpty ? '无备注' : entry.note}\n${category?.name ?? (entry.categoryId == null ? '未分类' : '分类待同步')}${tags.isEmpty ? '' : ' · ${tags.join('、')}'}${canOpen ? '' : ' · 账单正文待同步后可打开'}'
              : '原账本当前不可访问，仅保留本人分录金额和业务日期。\n不显示原账本、备注、分类、标签或图片。',
        ),
        trailing: canOpen ? const Icon(Icons.chevron_right) : null,
        onTap: !canOpen
            ? null
            : () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => BillDetailPage(
                    app: widget.app,
                    space: widget.space,
                    entityId: entry.billId!,
                  ),
                ),
              ),
      ),
    );
  }
}
