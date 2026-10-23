import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../data/preferences/app_preferences.dart';
import '../entry/entry_icons.dart';
import '../../data/attachments/attachment_transfer.dart';
import '../../data/ledger/ledger_batch.dart';
import '../../data/ledger/ledger_models.dart';
import '../attachments/attachment_panel.dart';
import '../entry/entry_page.dart';
import 'bill_batch_page.dart';

class BillDetailPage extends StatefulWidget {
  const BillDetailPage({
    required this.app,
    required this.space,
    required this.entityId,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final String entityId;
  @override
  State<BillDetailPage> createState() => _BillDetailPageState();
}

class _BillDetailPageState extends State<BillDetailPage> {
  late final _stream = widget.app.ledger.watch(
    widget.space,
    query: const LedgerQuery(includeArchived: true),
  );
  bool _busy = false;
  bool get _current =>
      mounted &&
      widget.app.space?.id == widget.space.id &&
      !widget.app.switchingSpace;

  Future<void> _action(BillBatchAction action) async {
    if (_busy || !_current) return;
    setState(() => _busy = true);
    try {
      final service = LedgerBatchService(widget.app.ledger);
      final preview = await service.preview(
        widget.space,
        ids: [widget.entityId],
        action: action,
      );
      if (!mounted || !_current) return;
      if (!preview.canConfirm) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前权限、引用或账单状态不允许此操作，原记录保留。')),
        );
        return;
      }
      final copied = action == BillBatchAction.copy;
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AnimatedBuilder(
          animation: widget.app,
          builder: (context, _) => AlertDialog(
            title: Text(copied ? '复制这笔账单？' : '删除这笔账单？'),
            content: Text(
              !_current
                  ? '资料空间已变化，请关闭。'
                  : copied
                  ? '在原账本按原金额、时间和可用关联新增一笔，会影响余额。'
                  : '本机标记删除，联网同步后其他设备同步删除。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: !_current ? null : () => Navigator.pop(c, true),
                child: Text(copied ? '确认复制' : '确认删除'),
              ),
            ],
          ),
        ),
      );
      if (yes != true || !_current) return;
      await service.confirm(widget.space, preview);
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(copied ? '已在本机复制，待同步。' : '已在本机标记删除，待同步。')),
        );
        if (!copied) Navigator.pop(context);
      }
    } catch (_) {
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('记录或权限已变化，请重新核对后操作；未写入半批结果。')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('账单详情')),
      body: !_current
          ? const Center(child: Text('资料空间已切换。'))
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
                final bill = view.find('bill', widget.entityId);
                if (bill == null || bill.deleted) {
                  return const Center(child: Text('此账单已删除或当前无权访问。'));
                }
                final payload = bill.payload,
                    money = Money.fromJson(bill.payload['money']);
                final category = payload['category_id'] == null
                    ? null
                    : view.find('category', payload['category_id'] as String);
                final preferences = widget.app.preferences.value;
                final presentation = BillPresentation.create(
                  preferences: preferences,
                  category: category?.name ?? '${payload['bill_type']}',
                  note: payload['note'] as String? ?? '',
                  parentCategory: category?.payload['parent_id'] is String
                      ? view
                            .find(
                              'category',
                              category!.payload['parent_id'] as String,
                            )
                            ?.name
                      : null,
                );
                final ids = (payload['attachment_ids'] as List).cast<String>();
                final flags = payload['flags'] as Map;
                final basic = {
                  'income',
                  'expense',
                  'transfer',
                  'credit_repayment',
                  'loan_borrow',
                  'loan_lend',
                  'loan_collect',
                  'loan_repay',
                  'balance_adjustment',
                }.contains(payload['bill_type']);
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: ListView(
                      padding: const EdgeInsets.all(24),
                      children: [
                        Text(
                          '${money.currency} ${preferences.formatMoney(money)}',
                          key: const Key('bill-detail-amount'),
                          style: Theme.of(context).textTheme.headlineLarge
                              ?.copyWith(
                                color: payload['bill_type'] == 'expense'
                                    ? preferences.expenseColor
                                    : payload['bill_type'] == 'income'
                                    ? preferences.incomeColor
                                    : null,
                              ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            if (preferences.showCategoryIcons) ...[
                              Icon(EntryIcons.of(category?.payload['icon'])),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: Text(
                                presentation.title,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (presentation.subtitle != null)
                          Text(presentation.subtitle!),
                        const SizedBox(height: 12),
                        Text(
                          '${payload['business_date']} · ${payload['business_timezone']}',
                        ),
                        if (payload['occurred_at'] != null)
                          Text('记录时间 ${payload['occurred_at']}'),
                        if (payload['target_money'] != null) ...[
                          Text(
                            '到账 ${Money.fromJson(payload['target_money']).currency} '
                            '${preferences.formatMoney(Money.fromJson(payload['target_money']))}',
                          ),
                          if (payload['transfer_fx'] is Map)
                            Text(
                              '本次转账汇率 ${preferences.hideAmounts ? '••••' : (payload['transfer_fx'] as Map)['rate']} · '
                              '${(payload['transfer_fx'] as Map)['rate_date']} · '
                              '${(payload['transfer_fx'] as Map)['rate_source']}',
                            )
                          else if (Money.fromJson(
                                payload['target_money'],
                              ).currency !=
                              money.currency)
                            const Text('原记录未保存转账汇率来源，两笔原币金额保留。'),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final id
                                in (payload['tag_ids'] as List).cast<String>())
                              Chip(
                                label: Text(
                                  view.find('tag', id)?.name ?? '标签资料待同步',
                                ),
                              ),
                          ],
                        ),
                        Text(
                          '收支统计：${flags['exclude_from_statistics'] == true ? '不计入' : '计入'} · 预算：${flags['exclude_from_budget'] == true ? '不计入' : '计入'}',
                        ),
                        const SizedBox(height: 12),
                        Text(
                          bill.conflicted
                              ? '存在冲突，请到同步页面处理。'
                              : bill.pending
                              ? '已存本机，待同步。'
                              : '已确认修订 ${bill.revision}',
                        ),
                        if (ids.isNotEmpty && view.epoch != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            child: FutureBuilder(
                              future: widget.app.attachments(),
                              builder: (context, snapshot) {
                                if (snapshot.hasError) {
                                  return const Text('图片存储未就绪，附件引用保留。');
                                }
                                final transfer = snapshot.data;
                                if (transfer == null) {
                                  return const LinearProgressIndicator();
                                }
                                return AttachmentPanel(
                                  repository: transfer.repository,
                                  space: widget.space,
                                  epoch: view.epoch!,
                                  scopeId: bill.scopeId,
                                  attachmentIds: ids,
                                  onChanged: (_) async {},
                                  isCurrent: () => _current,
                                  contextChanges: widget.app,
                                  readOnly: true,
                                  transfer: transfer,
                                  lease: widget.app.identity == null
                                      ? null
                                      : () => AttachmentLease.capture(
                                          widget.app.identity!,
                                        ),
                                );
                              },
                            ),
                          ),
                        const SizedBox(height: 24),
                        if (bill.canEdit &&
                            bill.editablePayload != null &&
                            basic)
                          FilledButton.icon(
                            onPressed: _busy
                                ? null
                                : () => Navigator.push(
                                    context,
                                    MaterialPageRoute<bool>(
                                      builder: (_) => EntryPage(
                                        app: widget.app,
                                        space: widget.space,
                                        bookId: bill.scopeId,
                                        existing: bill,
                                      ),
                                    ),
                                  ),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('编辑账单'),
                          ),
                        if (bill.canEdit && bill.editablePayload != null) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _action(BillBatchAction.copy),
                            icon: const Icon(Icons.copy_outlined),
                            label: const Text('复制账单'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _action(BillBatchAction.delete),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('删除账单'),
                          ),
                        ],
                        if (bill.editMode == 'metadata')
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => Navigator.push(
                                    context,
                                    MaterialPageRoute<bool>(
                                      builder: (_) => BillBatchPage(
                                        app: widget.app,
                                        space: widget.space,
                                        ids: {bill.id},
                                      ),
                                    ),
                                  ),
                            child: const Text('修改可见信息'),
                          ),
                        if (bill.editMode == 'metadata')
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('资金关联受限，只能通过可见信息批量维护修改备注、分类、标签和标记。'),
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
