import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../data/ledger/ledger_batch.dart';
import '../../data/ledger/ledger_models.dart';

class BillBatchPage extends StatefulWidget {
  const BillBatchPage({
    required this.app,
    required this.space,
    required this.ids,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final Set<String> ids;
  @override
  State<BillBatchPage> createState() => _BillBatchPageState();
}

class _BillBatchPageState extends State<BillBatchPage> {
  late final _stream = widget.app.ledger.watch(
    widget.space,
    query: const LedgerQuery(includeArchived: true),
  );
  final _note = TextEditingController(),
      _date = TextEditingController(),
      _time = TextEditingController();
  BillBatchAction _action = BillBatchAction.update;
  String _category = 'unchanged',
      _noteMode = 'unchanged',
      _tagMode = 'unchanged',
      _timeMode = 'unchanged';
  final Set<String> _tags = {};
  bool? _statistics, _budget;
  bool _busy = false;
  bool _removeAttachments = false;
  String? _error;
  bool get _current =>
      mounted &&
      widget.app.space?.id == widget.space.id &&
      !widget.app.switchingSpace;

  @override
  void dispose() {
    _note.dispose();
    _date.dispose();
    _time.dispose();
    super.dispose();
  }

  BillBatchPatch _patch() => BillBatchPatch(
    removeAttachments: _removeAttachments,
    categoryId: _category == 'unchanged'
        ? const BillChange.unchanged()
        : _category == 'clear'
        ? const BillChange.clear()
        : BillChange.set(_category),
    note: _noteMode == 'unchanged'
        ? const BillChange.unchanged()
        : _noteMode == 'clear'
        ? const BillChange.clear()
        : BillChange.set(_note.text),
    tagIds: _tagMode == 'unchanged'
        ? const BillChange.unchanged()
        : _tagMode == 'clear'
        ? const BillChange.clear()
        : BillChange.set(_tags.toList()),
    time: _timeMode == 'unchanged'
        ? const BillChange.unchanged()
        : _timeMode == 'clear'
        ? const BillChange.clear()
        : BillChange.set(
            BillTimeEdit(
              date: _date.text.trim().isEmpty ? null : _date.text.trim(),
              time: _time.text.trim().isEmpty ? null : _time.text.trim(),
            ),
          ),
    excludeFromStatistics: _statistics == null
        ? const BillChange.unchanged()
        : BillChange.set(_statistics!),
    excludeFromBudget: _budget == null
        ? const BillChange.unchanged()
        : BillChange.set(_budget!),
  );

  Future<void> _preview() async {
    if (_busy || !_current) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = LedgerBatchService(widget.app.ledger);
      final preview = await service.preview(
        widget.space,
        ids: widget.ids,
        action: _action,
        patch: _patch(),
      );
      if (!mounted || !_current) return;
      final previewStream = widget.app.ledger.watch(
        widget.space,
        query: const LedgerQuery(includeArchived: true),
      );
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AnimatedBuilder(
          animation: widget.app,
          builder: (context, _) => StreamBuilder<LedgerView>(
            stream: previewStream,
            builder: (context, snapshot) {
              final view = snapshot.data;
              final visible =
                  _current &&
                  view != null &&
                  widget.ids.every((id) => view.find('bill', id) != null);
              return AlertDialog(
                title: Text('核对${preview.items.length}笔账单'),
                content: SizedBox(
                  width: 560,
                  child: snapshot.hasError
                      ? const Text('记录读取失败，请关闭后重试。')
                      : view == null
                      ? const SizedBox(
                          height: 90,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : !visible
                      ? const Text('记录或资料空间已变化，请关闭并重新选择。')
                      : SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _action == BillBatchAction.copy
                                    ? '将按原账本、金额和时间新增所选账单，影响余额。'
                                    : _action == BillBatchAction.delete
                                    ? '将删除所选账单；联网后同步到其他设备。'
                                    : '本次仅修改下列字段。未选择的字段保持不变。',
                              ),
                              const SizedBox(height: 16),
                              for (final item in preview.items)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${item.before['business_date'] ?? ''} · ${item.before['note'] ?? ''}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (item.before['money'] != null)
                                        Text(
                                          '${Money.fromJson(item.before['money']).currency} ${widget.app.preferences.value.formatMoney(Money.fromJson(item.before['money']))}',
                                          style: TextStyle(
                                            color:
                                                item.before['bill_type'] ==
                                                    'expense'
                                                ? widget
                                                      .app
                                                      .preferences
                                                      .value
                                                      .expenseColor
                                                : item.before['bill_type'] ==
                                                      'income'
                                                ? widget
                                                      .app
                                                      .preferences
                                                      .value
                                                      .incomeColor
                                                : null,
                                          ),
                                        ),
                                      Text(
                                        item.issue != null
                                            ? '需核对：当前权限、关联或账单状态不允许此项。'
                                            : item.changedFields.isEmpty
                                            ? '此项无需修改'
                                            : item.changedFields
                                                  .map(
                                                    (f) => switch (f) {
                                                      'note' =>
                                                        '新备注：${item.after['note']}',
                                                      'category_id' =>
                                                        '新分类：${item.after['category_id'] == null ? '未分类' : view.find('category', item.after['category_id'] as String)?.name ?? '分类资料待同步'}',
                                                      'tag_ids' =>
                                                        '新标签：${(item.after['tag_ids'] as List).isEmpty ? '无' : (item.after['tag_ids'] as List).map((id) => view.find('tag', id as String)?.name ?? '标签资料待同步').join('、')}',
                                                      'business_date' =>
                                                        '新日期：${item.after['business_date']}',
                                                      'occurred_at' =>
                                                        '新时间：${item.after['occurred_at'] ?? '仅业务日期'}',
                                                      'flags.exclude_from_statistics' =>
                                                        '收支统计：${(item.after['flags'] as Map)['exclude_from_statistics'] == true ? '不计入' : '计入'}',
                                                      'flags.exclude_from_budget' =>
                                                        '预算：${(item.after['flags'] as Map)['exclude_from_budget'] == true ? '不计入' : '计入'}',
                                                      'attachment_ids' =>
                                                        '从本笔移除图片引用',
                                                      'identity' => '新增副本',
                                                      'deleted' => '删除本笔',
                                                      _ => '账单操作',
                                                    },
                                                  )
                                                  .toSet()
                                                  .join('\n'),
                                      ),
                                    ],
                                  ),
                                ),
                              if (preview.issues.isNotEmpty)
                                const Text('存在不能处理的记录，本次不会写入半批结果。请返回调整选择。'),
                            ],
                          ),
                        ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('返回修改'),
                  ),
                  FilledButton(
                    key: const Key('confirm-bill-batch'),
                    onPressed: !visible || !preview.canConfirm
                        ? null
                        : () => Navigator.pop(c, true),
                    child: const Text('确认保存到本机'),
                  ),
                ],
              );
            },
          ),
        ),
      );
      if (confirmed != true || !_current) return;
      final result = await service.confirm(widget.space, preview);
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已处理${result.operationIds.length}笔，${result.unchangedIds.length}笔无需修改，待联网同步。',
            ),
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (_) {
      if (mounted && _current) {
        setState(() => _error = '未完成批量处理，请核对日期/时间格式、所选记录及权限；输入保留。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _mode(String title, String value, void Function(String) changed) =>
      DropdownButtonFormField<String>(
        key: ValueKey('batch-change-$title'),
        initialValue: value,
        decoration: InputDecoration(labelText: title),
        items: const [
          DropdownMenuItem(value: 'unchanged', child: Text('不变')),
          DropdownMenuItem(value: 'set', child: Text('设置为')),
          DropdownMenuItem(value: 'clear', child: Text('清空')),
        ],
        onChanged: (v) => setState(() => changed(v!)),
      );
  Widget _flag(String title, bool? value, void Function(bool?) changed) =>
      DropdownButtonFormField<String>(
        initialValue: value == null
            ? 'unchanged'
            : value
            ? 'yes'
            : 'no',
        decoration: InputDecoration(labelText: title),
        items: const [
          DropdownMenuItem(value: 'unchanged', child: Text('不变')),
          DropdownMenuItem(value: 'yes', child: Text('不计入')),
          DropdownMenuItem(value: 'no', child: Text('计入')),
        ],
        onChanged: (v) =>
            setState(() => changed(v == 'unchanged' ? null : v == 'yes')),
      );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text('维护${widget.ids.length}笔账单')),
      body: !_current
          ? const Center(child: Text('资料空间已切换。'))
          : StreamBuilder<LedgerView>(
              stream: _stream,
              builder: (context, snapshot) {
                final view = snapshot.data;
                if (view == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (widget.ids.any((id) => view.find('bill', id) == null)) {
                  return const Center(child: Text('选择中有记录已删除或无权访问，请返回重新选择。'));
                }
                return AbsorbPointer(
                  absorbing: _busy,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          DropdownButtonFormField<BillBatchAction>(
                            initialValue: _action,
                            decoration: const InputDecoration(labelText: '操作'),
                            items: const [
                              DropdownMenuItem(
                                value: BillBatchAction.update,
                                child: Text('修改可见信息'),
                              ),
                              DropdownMenuItem(
                                value: BillBatchAction.copy,
                                child: Text('复制账单'),
                              ),
                              DropdownMenuItem(
                                value: BillBatchAction.delete,
                                child: Text('删除账单'),
                              ),
                            ],
                            onChanged: (v) => setState(() => _action = v!),
                          ),
                          const SizedBox(height: 20),
                          if (_action == BillBatchAction.update) ...[
                            DropdownButtonFormField<String>(
                              initialValue: _category,
                              decoration: const InputDecoration(
                                labelText: '分类',
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: 'unchanged',
                                  child: Text('不变'),
                                ),
                                const DropdownMenuItem(
                                  value: 'clear',
                                  child: Text('清空'),
                                ),
                                for (final c in view.categories.where(
                                  (c) => !c.effectiveArchived,
                                ))
                                  DropdownMenuItem(
                                    value: c.id,
                                    child: Text(
                                      '${c.name} · ${c.payload['kind'] == 'expense' ? '支出' : '收入'}',
                                    ),
                                  ),
                              ],
                              onChanged: (v) => setState(() => _category = v!),
                            ),
                            const SizedBox(height: 16),
                            _mode('备注', _noteMode, (v) => _noteMode = v),
                            if (_noteMode == 'set')
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: TextField(
                                  key: const Key('batch-note'),
                                  controller: _note,
                                  maxLength: 2000,
                                  decoration: const InputDecoration(
                                    labelText: '新备注',
                                  ),
                                ),
                              ),
                            const SizedBox(height: 16),
                            _mode('标签', _tagMode, (v) => _tagMode = v),
                            if (_tagMode == 'set')
                              Wrap(
                                spacing: 6,
                                children: [
                                  for (final t in view.tags.where(
                                    (t) =>
                                        !t.effectiveArchived &&
                                        t.payload['kind'] != 'group',
                                  ))
                                    FilterChip(
                                      label: Text(t.name),
                                      selected: _tags.contains(t.id),
                                      onSelected: (yes) => setState(() {
                                        yes
                                            ? _tags.add(t.id)
                                            : _tags.remove(t.id);
                                      }),
                                    ),
                                ],
                              ),
                            const SizedBox(height: 16),
                            _mode('日期与时间', _timeMode, (v) => _timeMode = v),
                            if (_timeMode == 'set') ...[
                              const SizedBox(height: 12),
                              TextField(
                                controller: _date,
                                decoration: const InputDecoration(
                                  labelText: '业务日期',
                                  hintText: 'YYYY-MM-DD，留空保留原日期',
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _time,
                                decoration: const InputDecoration(
                                  labelText: '当地时间',
                                  hintText: 'HH:mm:ss，留空保留原时间',
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            _flag('收支统计', _statistics, (v) => _statistics = v),
                            const SizedBox(height: 16),
                            _flag('预算', _budget, (v) => _budget = v),
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('移除所选账单的图片'),
                              subtitle: const Text('本机原件保留。'),
                              value: _removeAttachments,
                              onChanged: (v) =>
                                  setState(() => _removeAttachments = v!),
                            ),
                          ],
                          const SizedBox(height: 24),
                          if (_error != null)
                            Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          FilledButton(
                            key: const Key('preview-bill-batch'),
                            onPressed: _busy ? null : _preview,
                            child: Text(_busy ? '正在核对…' : '预览作用范围'),
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
