import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../data/assets/asset_config_repository.dart';
import '../../data/assets/asset_config_store.dart';
import '../../data/assets/asset_repository.dart';
import '../../data/ledger/ledger_models.dart';
import '../../data/sync/sync_engine.dart';
import '../../domain/assets/asset_config.dart';
import '../currencies/currencies_page.dart';
import '../entry/entry_icons.dart';
import '../entry/entry_page.dart';
import 'account_editor.dart';
import 'asset_groups_page.dart';
import 'asset_account_page.dart';
import 'asset_history_page.dart';

class AssetsPage extends StatefulWidget {
  const AssetsPage({required this.app, required this.space, super.key});
  final AppController app;
  final DataSpace space;
  @override
  State<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends State<AssetsPage> {
  late final _config = AssetConfigStore(widget.app.repository);
  late final _assets = AssetRepository(widget.app.ledger, _config);
  late final _stream = _assets.watch(
    widget.space,
    valuationDate: DateTime.now().toIso8601String().substring(0, 10),
  );
  bool _hidden = false, _archived = false, _refreshing = false;
  bool get _amounts => !widget.app.preferences.value.hideAmounts;
  String? _message;
  bool get _current =>
      widget.app.space?.id == widget.space.id && !widget.app.switchingSpace;
  AssetConfigRepository get _configuration => AssetConfigRepository(
    _config,
    refreshPermissions: (lease) async {
      await widget.app.syncEngine.refreshScopes(lease);
    },
  );

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _message = null;
    });
    try {
      final identity = widget.app.identity;
      if (identity == null || !_current) {
        throw const DomainError('identity_changed');
      }
      final captured = SyncLease.capture(identity);
      final lease = SyncLease(
        space: captured.space,
        clientId: captured.clientId,
        epoch: captured.epoch,
        supportsGroupPull: captured.supportsGroupPull,
        request: captured.request,
        isCurrent: () => _current && captured.isCurrent(),
      );
      for (final section in AssetConfigSection.values) {
        await _configuration.refresh(lease, section);
      }
      if (mounted && _current) {
        setState(() => _message = '已刷新分组、币种与手动估值配置。账户余额按本机已同步及待同步账务计算。');
      }
    } catch (_) {
      if (mounted && _current) {
        setState(() => _message = '配置刷新未完成。保留本机资料，请联网登录后重试。');
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _edit(LocalAssetSnapshot snapshot, [LedgerEntity? entity]) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => AccountEditor(
          app: widget.app,
          space: widget.space,
          groups: snapshot.groups,
          preferredCurrencies: snapshot.preferences.enabledCodes,
          entity: entity,
        ),
      );

  Future<void> _fund(
    LocalAssetSnapshot snapshot,
    LedgerEntity account,
    String type,
  ) async {
    final books = snapshot.ledger.books
        .where(
          (book) =>
              snapshot.ledger.canCreate('bill', book.id) &&
              !book.effectiveArchived,
        )
        .toList();
    if (books.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先创建或取得可记账的账本。')));
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: widget.app,
        builder: (context, _) => !_current
            ? const AlertDialog(content: Text('资料空间已切换，请关闭此窗口。'))
            : SimpleDialog(
                title: const Text('选择记入的账本'),
                children: [
                  for (final book in books)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, book.id),
                      child: Text(book.name),
                    ),
                ],
              ),
      ),
    );
    if (!mounted || !_current || selected == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => EntryPage(
          app: widget.app,
          space: widget.space,
          bookId: selected,
          initialType: type,
          initialAccountId: account.id,
        ),
      ),
    );
  }

  String _money(Money? money) => !_amounts
      ? '••••'
      : money == null
      ? '暂不可用'
      : '${money.currency} ${widget.app.preferences.value.formatMoney(money)}';

  Future<void> _toggleAmounts() async {
    try {
      if (!widget.app.preferences.ready) {
        await widget.app.preferences.initialize();
      }
      await widget.app.preferences.update(
        widget.app.preferences.value.copyWith(hideAmounts: _amounts),
      );
    } catch (_) {
      if (mounted && _current) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('金额显示设置未能保存，请重试。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('资产'),
        actions: [
          IconButton(
            key: const Key('asset-toggle-amounts'),
            tooltip: _amounts ? '隐藏金额' : '显示金额',
            onPressed: _toggleAmounts,
            icon: Icon(
              _amounts
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '资产设置',
            onSelected: (value) async {
              if (!_current) return;
              if (value == 'hidden') {
                setState(() => _hidden = !_hidden);
                return;
              }
              if (value == 'archived') {
                setState(() => _archived = !_archived);
                return;
              }
              if (value == 'refresh') {
                await _refresh();
                return;
              }
              await Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => value == 'history'
                      ? AssetHistoryPage(app: widget.app, space: widget.space)
                      : value == 'groups'
                      ? AssetGroupsPage(app: widget.app, space: widget.space)
                      : CurrenciesPage(app: widget.app, space: widget.space),
                ),
              );
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'history', child: Text('资产趋势')),
              const PopupMenuItem(value: 'groups', child: Text('账户分组')),
              const PopupMenuItem(value: 'currencies', child: Text('币种与手动估值')),
              PopupMenuItem(
                value: 'hidden',
                child: Text(_hidden ? '收起已隐藏账户' : '显示已隐藏账户'),
              ),
              PopupMenuItem(
                value: 'archived',
                child: Text(_archived ? '收起已归档账户' : '显示已归档账户'),
              ),
              const PopupMenuItem(value: 'refresh', child: Text('联网刷新配置')),
            ],
          ),
        ],
      ),
      body: !_current
          ? const Center(child: Text('资料空间已切换，请返回当前账本。'))
          : StreamBuilder<LocalAssetSnapshot>(
              stream: _stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Text('资产资料读取失败，请返回后重试。'));
                }
                final data = snapshot.data;
                if (data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final visible = data.accounts
                    .where(
                      (account) =>
                          (_hidden || account.payload['hidden'] != true) &&
                          (_archived || !account.effectiveArchived),
                    )
                    .toList();
                final groups = {
                  for (final group in data.groups) group.id: group.name,
                };
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 880),
                    child: ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '净资产',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                    ),
                                    Text(
                                      '${data.preferences.baseCurrency} 当前余额估值',
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _money(data.totals.net),
                                  key: const Key('asset-net'),
                                  style: Theme.of(
                                    context,
                                  ).textTheme.headlineMedium,
                                ),
                                const SizedBox(height: 20),
                                Wrap(
                                  spacing: 28,
                                  runSpacing: 16,
                                  children: [
                                    for (final entry in {
                                      '总资产': data.totals.assets,
                                      '总负债': data.totals.liabilities,
                                      '借入': data.totals.borrowed,
                                      '借出': data.totals.lent,
                                    }.entries)
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(entry.key),
                                          Text(_money(entry.value)),
                                        ],
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  data.configurationConfirmed
                                      ? '已确认本机估值配置。隐藏和归档不自动排除净资产。'
                                      : '当前使用本机可用配置；外币汇率未确认时不计算合计。联网刷新可读取服务端设置。',
                                ),
                                if (!data.totals.available)
                                  const Text(
                                    '合计暂不可用：存在未确认余额、缺少当期直接汇率或金额超出范围。原币余额仍逐项展示。',
                                  ),
                                for (final quote
                                    in data.totals.usedRates.values)
                                  Text(
                                    '${quote.fromCurrency}→${quote.toCurrency} ${quote.rate} · ${quote.effectiveDate} · ${quote.source}',
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text('私人账户只属于你，共享账本不会向成员公开余额。'),
                        if (_message != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(_message!),
                          ),
                        if (_refreshing) const LinearProgressIndicator(),
                        const SizedBox(height: 16),
                        if (visible.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: Text('当前没有可见账户')),
                          ),
                        for (final account in visible)
                          Card(
                            child: ListTile(
                              leading: Icon(
                                EntryIcons.of(
                                  account.payload['icon'] == 'account'
                                      ? account.payload['kind']
                                      : account.payload['icon'] ??
                                            account.payload['kind'],
                                ),
                              ),
                              title: Text(account.name),
                              subtitle: Text(
                                [
                                  if (account.payload['hidden'] == true) '已隐藏',
                                  if (account.effectiveArchived) '已归档',
                                  if (groups[account.payload['group_id']] !=
                                      null)
                                    groups[account.payload['group_id']]!,
                                  account.pending ? '本机待同步' : '已确认',
                                  if (account
                                          .payload['include_in_net_assets'] ==
                                      false)
                                    '不计入净资产',
                                ].join(' · '),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      _money(
                                        data.ledger.balances[account.id]?.value,
                                      ),
                                    ),
                                  ),
                                  if (account.canEdit)
                                    PopupMenuButton<String>(
                                      tooltip: '${account.name}操作',
                                      onSelected: (action) async {
                                        if (!_current) return;
                                        if (action == 'edit') {
                                          await _edit(data, account);
                                        } else {
                                          await _fund(data, account, action);
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(
                                          value: 'edit',
                                          child: Text('编辑账户'),
                                        ),
                                        if (!account.effectiveArchived) ...[
                                          const PopupMenuItem(
                                            value: 'balance_adjustment',
                                            child: Text('余额调账'),
                                          ),
                                          if ({
                                            'cash',
                                            'bank',
                                            'prepaid',
                                            'investment',
                                          }.contains(account.payload['kind']))
                                            const PopupMenuItem(
                                              value: 'transfer',
                                              child: Text('转账'),
                                            ),
                                          if (account.payload['kind'] ==
                                              'credit_card')
                                            const PopupMenuItem(
                                              value: 'credit_repayment',
                                              child: Text('信用卡还款'),
                                            ),
                                          if (account.payload['kind'] ==
                                              'loan_receivable') ...[
                                            const PopupMenuItem(
                                              value: 'loan_lend',
                                              child: Text('借出本金'),
                                            ),
                                            const PopupMenuItem(
                                              value: 'loan_collect',
                                              child: Text('收回本金'),
                                            ),
                                          ],
                                          if (account.payload['kind'] ==
                                              'loan_payable') ...[
                                            const PopupMenuItem(
                                              value: 'loan_borrow',
                                              child: Text('借入本金'),
                                            ),
                                            const PopupMenuItem(
                                              value: 'loan_repay',
                                              child: Text('偿还本金'),
                                            ),
                                          ],
                                        ],
                                      ],
                                    ),
                                ],
                              ),
                              onTap: () => Navigator.push<void>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => AssetAccountPage(
                                    app: widget.app,
                                    space: widget.space,
                                    accountId: account.id,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          key: const Key('new-account'),
                          onPressed:
                              data.ledger.canCreate(
                                'account',
                                widget.space.userId,
                              )
                              ? () => _edit(data)
                              : null,
                          icon: const Icon(Icons.add),
                          label: const Text('添加资金账户'),
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
