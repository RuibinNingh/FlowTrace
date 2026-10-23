import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../core/network/api_failure.dart';
import '../../data/attachments/attachment_transfer.dart';
import '../../data/ledger/ledger_book_move.dart';
import '../../data/ledger/ledger_models.dart';

class BillBookMovePage extends StatefulWidget {
  const BillBookMovePage({
    required this.app,
    required this.space,
    required this.ids,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final Set<String> ids;
  @override
  State<BillBookMovePage> createState() => _BillBookMovePageState();
}

final class _Mapping {
  String category = 'unselected',
      feeCategory = 'unselected',
      tags = 'unselected';
  Set<String> selectedTags = {};
}

class _BillBookMovePageState extends State<BillBookMovePage> {
  late final Set<String> _ids = Set.unmodifiable(widget.ids);
  late final _stream = widget.app.ledger.watch(
    widget.space,
    query: const LedgerQuery(includeArchived: true),
  );
  final Map<String, _Mapping> _mappings = {};
  String? _target, _message;
  bool _busy = false;
  int _completedImages = 0;
  LedgerBookMoveService? _service;
  LedgerBookMovePreview? _preview;
  LedgerBookMovePrepared? _prepared;
  AttachmentLease? _lease;
  bool get _current =>
      mounted &&
      widget.app.space?.id == widget.space.id &&
      !widget.app.switchingSpace;

  void _invalidate() {
    _preview = null;
    _prepared = null;
    _lease = null;
    _message = null;
  }

  AttachmentLease _capture() {
    final identity = widget.app.identity;
    if (identity == null) {
      throw const ApiFailure('session_invalid', '请联网登录后移动账单。');
    }
    final captured = AttachmentLease.capture(identity);
    return AttachmentLease(
      space: captured.space,
      epoch: captured.epoch,
      clientId: captured.clientId,
      generation: captured.generation,
      isCurrent: () => _current && captured.isCurrent(),
      request: captured.request,
      download: captured.download,
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_current) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on ApiFailure catch (error) {
      if (_current) setState(() => _message = error.message);
    } on LedgerBookMoveException catch (error) {
      if (_current) {
        setState(
          () => _message = error.issues.values.map(_issue).toSet().join('\n'),
        );
      }
    } catch (_) {
      if (_current) setState(() => _message = '移动尚未完成。输入已保留，请同步核对后重新预览。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _review(LedgerView view) => _run(() async {
    final lease = _capture(), target = _target;
    if (target == null) return;
    final transfer = await widget.app.attachments();
    lease.check();
    final service = _service ??= LedgerBookMoveService(
      widget.app.ledger,
      transfer.repository,
      transfer: transfer,
      refreshPermissions: widget.app.refreshAttachmentPermissions,
    );
    final preview = await service.preview(
      lease,
      ids: _ids,
      targetBookId: target,
      mappings: {
        for (final id in _ids)
          id: BillBookMoveMapping(
            categoryId: _mappings[id]!.category == 'clear'
                ? null
                : _mappings[id]!.category,
            tagIds:
                _mappings[id]!.tags == 'clear'
                      ? []
                      : _mappings[id]!.selectedTags.toList()
                  ..sort(),
            feeCategoryId:
                view.find('bill', id)!.payload['fee'] == null ||
                    _mappings[id]!.feeCategory == 'clear'
                ? null
                : _mappings[id]!.feeCategory,
          ),
      },
    );
    lease.check();
    if (_current) {
      setState(() {
        _lease = lease;
        _preview = preview;
        _prepared = null;
      });
    }
  });

  Future<void> _prepare() => _run(() async {
    final lease = _lease, preview = _preview, service = _service;
    if (lease == null || preview == null || service == null) return;
    setState(() => _completedImages = 0);
    final prepared = await service.prepare(
      lease,
      preview,
      onProgress: (done, total) {
        if (_current) setState(() => _completedImages = done);
      },
    );
    lease.check();
    if (_current) setState(() => _prepared = prepared);
  });

  Future<void> _confirm() => _run(() async {
    final lease = _lease, prepared = _prepared, service = _service;
    if (lease == null || prepared == null || service == null) return;
    final result = await service.confirm(lease, prepared);
    lease.check();
    if (mounted && _current) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已在本机保存${result.operationIds.length}笔移动，待同步；完整统计将在同步后更新。',
          ),
        ),
      );
      Navigator.pop(context, true);
    }
  });

  String _issue(String code) => switch (code) {
    'move.scope_readonly' => '来源和目标账本均需编辑权限，请先同步权限。',
    'move.sync_bill_first' ||
    'move.sync_definitions_first' => '账单、账本或分类标签尚未完成同步，请同步后重试。',
    'move.has_allocations' => '有关联退款或报销的账单暂不能移动。',
    'move.financial_links_unavailable' ||
    'move.shared_account' => '此账单包含当前无法携带的资金账户，请核对共享账户与权限。',
    'move.currency_mismatch' => '来源与目标账本的报表币种必须相同。',
    'move.category_invalid' ||
    'move.tag_invalid' ||
    'move.mapping_required' => '请明确选择目标分类、标签及手续费分类。',
    'move.recovery_required' => '本机资料需要恢复，请先在同步页面处理。',
    'move.images_not_ready' => '目标图片尚未准备完成，请重新核对图片。',
    _ => '账单、权限或选择已变化，请重新核对移动方案。',
  };

  List<LedgerEntity> _categories(
    LedgerView view,
    LedgerEntity bill, {
    bool fee = false,
  }) => view.categories
      .where(
        (c) =>
            c.scopeId == _target &&
            !c.effectiveArchived &&
            (fee
                ? c.payload['kind'] == 'expense'
                : !{'income', 'expense'}.contains(bill.payload['bill_type']) ||
                      c.payload['kind'] == bill.payload['bill_type']),
      )
      .toList();

  bool _complete(LedgerView view, List<LedgerEntity> bills) {
    if (_target == null) return false;
    for (final bill in bills) {
      final choice = _mappings[bill.id];
      if (choice == null) return false;
      bool valid(String value, List<LedgerEntity> options) =>
          value == 'clear' || options.any((e) => e.id == value);
      if (!valid(choice.category, _categories(view, bill)) ||
          bill.payload['fee'] != null &&
              !valid(choice.feeCategory, _categories(view, bill, fee: true)) ||
          choice.tags == 'unselected' ||
          choice.tags == 'set' &&
              (choice.selectedTags.isEmpty ||
                  choice.selectedTags.any(
                    (id) => !view.tags.any(
                      (tag) =>
                          tag.id == id &&
                          tag.scopeId == _target &&
                          !tag.effectiveArchived &&
                          tag.payload['kind'] == 'tag',
                    ),
                  ))) {
        return false;
      }
    }
    return true;
  }

  Widget _categoryPicker(
    LedgerEntity bill,
    LedgerView view,
    _Mapping choice, {
    bool fee = false,
  }) {
    final value = fee ? choice.feeCategory : choice.category,
        options = _categories(view, bill, fee: fee);
    final selected = value == 'clear' || options.any((e) => e.id == value)
        ? value
        : 'unselected';
    return DropdownButtonFormField<String>(
      key: ValueKey(
        'move-${fee ? 'fee-category' : 'category'}-${bill.id}-$value',
      ),
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(labelText: fee ? '目标手续费分类' : '目标分类'),
      items: [
        const DropdownMenuItem(value: 'unselected', child: Text('请选择处理方式')),
        const DropdownMenuItem(value: 'clear', child: Text('清空分类')),
        for (final category in options)
          DropdownMenuItem(
            value: category.id,
            child: Text(category.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _busy
          ? null
          : (value) => setState(() {
              if (fee) {
                choice.feeCategory = value!;
              } else {
                choice.category = value!;
              }
              _invalidate();
            }),
    );
  }

  Future<void> _selectTags(LedgerView view, _Mapping choice) async {
    final capturedTarget = _target;
    final tagStream = widget.app.ledger.watch(
      widget.space,
      query: const LedgerQuery(includeArchived: true),
    );
    final selected = {...choice.selectedTags};
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AnimatedBuilder(
          animation: widget.app,
          builder: (context, _) => StreamBuilder<LedgerView>(
            stream: tagStream,
            builder: (context, snapshot) {
              final live = snapshot.data;
              final visible =
                  _current &&
                  capturedTarget != null &&
                  capturedTarget == _target &&
                  live != null &&
                  live.canCreate('bill', capturedTarget) &&
                  live.find('book', capturedTarget) != null &&
                  _ids.every((id) => live.find('bill', id) != null);
              if (!visible) {
                return SizedBox(
                  height: 180,
                  child: Center(
                    child: Text(
                      live == null && !snapshot.hasError
                          ? '正在读取标签…'
                          : '账单、账本权限或资料空间已变化，请返回。',
                    ),
                  ),
                );
              }
              final available = live.tags
                  .where(
                    (t) =>
                        t.scopeId == capturedTarget &&
                        !t.effectiveArchived &&
                        t.payload['kind'] == 'tag',
                  )
                  .toList();
              selected.retainAll(available.map((tag) => tag.id));
              return SizedBox(
                height: MediaQuery.sizeOf(context).height * .7,
                child: Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('选择目标账本标签'),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final tag in available)
                            CheckboxListTile(
                              title: Text(tag.name),
                              value: selected.contains(tag.id),
                              onChanged: (checked) => update(() {
                                if (checked == true) {
                                  selected.add(tag.id);
                                } else {
                                  selected.remove(tag.id);
                                }
                              }),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: FilledButton(
                        onPressed: selected.isEmpty
                            ? null
                            : () => Navigator.pop(context, selected),
                        child: const Text('使用所选标签'),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    if (_current && capturedTarget == _target && result != null) {
      setState(() {
        choice.selectedTags = result;
        choice.tags = 'set';
        _invalidate();
      });
    }
  }

  Widget _billCard(LedgerView view, LedgerEntity bill) {
    final choice = _mappings.putIfAbsent(bill.id, _Mapping.new),
        payload = bill.payload;
    final source = view.find('book', bill.scopeId)?.name ?? '来源账本';
    final sourceCategory = payload['category_id'] == null
        ? '未分类'
        : view.find('category', payload['category_id'] as String)?.name ??
              '历史分类';
    final oldTags = (payload['tag_ids'] as List)
        .map((id) => view.find('tag', id as String)?.name ?? '历史标签')
        .join('、');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${payload['business_date']} · $source',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              '${widget.app.preferences.value.formatMoney(Money.fromJson(payload['money']))} ${Money.fromJson(payload['money']).currency} · ${payload['note']}',
              style: TextStyle(
                color: payload['bill_type'] == 'expense'
                    ? widget.app.preferences.value.expenseColor
                    : payload['bill_type'] == 'income'
                    ? widget.app.preferences.value.incomeColor
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '原分类：$sourceCategory · 原标签：${oldTags.isEmpty ? '无' : oldTags}',
            ),
            if (payload['fee'] != null)
              Text(
                '原手续费分类：${(payload['fee'] as Map)['category_id'] == null ? '未分类' : view.find('category', (payload['fee'] as Map)['category_id'] as String)?.name ?? '历史分类'}',
              ),
            const SizedBox(height: 16),
            _categoryPicker(bill, view, choice),
            if (payload['fee'] != null) ...[
              const SizedBox(height: 12),
              _categoryPicker(bill, view, choice, fee: true),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('move-tags-${bill.id}-${choice.tags}'),
              initialValue: choice.tags,
              decoration: const InputDecoration(labelText: '目标标签'),
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'unselected', child: Text('请选择处理方式')),
                DropdownMenuItem(value: 'clear', child: Text('清空标签')),
                DropdownMenuItem(value: 'set', child: Text('选择目标标签')),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      choice.tags = value!;
                      _invalidate();
                    }),
            ),
            if (choice.tags == 'set')
              TextButton(
                onPressed: _busy ? null : () => _selectTags(view, choice),
                child: Text(
                  choice.selectedTags.isEmpty
                      ? '选择目标账本标签'
                      : choice.selectedTags
                            .map((id) => view.find('tag', id)?.name ?? '待核对标签')
                            .join('、'),
                ),
              ),
            if (_preview?.issues[bill.id] case final issue?)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _issue(issue),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('移动到账本')),
        body: !_current
            ? const Center(child: Text('资料空间已切换。'))
            : StreamBuilder<LedgerView>(
                stream: _stream,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(child: Text('账单读取失败，请返回后重试。'));
                  }
                  final view = snapshot.data;
                  if (view == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final bills = _ids
                      .map((id) => view.find('bill', id))
                      .whereType<LedgerEntity>()
                      .toList();
                  if (_ids.isEmpty ||
                      _ids.length > 1000 ||
                      bills.length != _ids.length ||
                      bills.any((b) => b.deleted) ||
                      _target != null && view.find('book', _target!) == null) {
                    return const Center(child: Text('账单或账本权限已变化，请返回重新选择。'));
                  }
                  final sourceIds = bills.map((b) => b.scopeId).toSet();
                  final targets = view.books
                      .where(
                        (b) =>
                            !sourceIds.contains(b.id) &&
                            view.canCreate('bill', b.id),
                      )
                      .toList();
                  final allowed =
                      view.writable &&
                      bills.every((b) => b.canEdit) &&
                      (_target == null || view.canCreate('bill', _target!));
                  final ready = _complete(view, bills), preview = _preview;
                  return Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 800),
                      child: ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          Text(
                            '将${bills.length}笔账单移入另一个账本',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '金额、资金账户和原日期保持。请逐笔指定目标分类和标签，或明确清空；不会自动按同名匹配。',
                          ),
                          const SizedBox(height: 20),
                          DropdownButtonFormField<String>(
                            key: ValueKey('move-target-$_target'),
                            initialValue: targets.any((b) => b.id == _target)
                                ? _target
                                : null,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '目标账本',
                            ),
                            items: [
                              for (final book in targets)
                                DropdownMenuItem(
                                  value: book.id,
                                  child: Text(
                                    book.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: _busy || !allowed
                                ? null
                                : (value) => setState(() {
                                    _target = value;
                                    _mappings.clear();
                                    _invalidate();
                                  }),
                          ),
                          if (targets.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text('需要另一个有编辑权限且已同步的账本。'),
                            ),
                          const SizedBox(height: 16),
                          if (_target != null) ...[
                            for (final bill in bills) _billCard(view, bill),
                          ],
                          if (!allowed) const Text('账单含冲突、隐藏资金或当前只读权限，请先同步核对。'),
                          if (_message != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Text(_message!),
                            ),
                          const SizedBox(height: 16),
                          FilledButton(
                            key: const Key('review-book-move'),
                            onPressed:
                                _busy ||
                                    !allowed ||
                                    !ready ||
                                    widget.app.canSync != true
                                ? null
                                : () => _review(view),
                            child: const Text('核对移动方案'),
                          ),
                          if (preview != null) ...[
                            const SizedBox(height: 20),
                            Text(
                              '核对结果：${preview.items.length}笔 · ${preview.imageCount}张图片副本',
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '准备只上传目标图片副本；返回取消时账单保持原处。最终确认后才在本机移动，服务端同步逐笔确认；完整统计将在同步后更新。',
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              key: const Key('prepare-book-move'),
                              onPressed:
                                  _busy ||
                                      !allowed ||
                                      !ready ||
                                      !preview.canPrepare
                                  ? null
                                  : _prepare,
                              child: Text(
                                _prepared == null
                                    ? '准备图片并复核账单'
                                    : '图片和账单已核对，可重新复核',
                              ),
                            ),
                            if (_busy)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Text(
                                  '正在核对… 已准备$_completedImages/${preview.imageCount}张图片',
                                ),
                              ),
                            const SizedBox(height: 8),
                            FilledButton(
                              key: const Key('confirm-book-move'),
                              onPressed:
                                  _busy ||
                                      !allowed ||
                                      !ready ||
                                      _prepared == null
                                  ? null
                                  : _confirm,
                              child: const Text('确认移动到本机并待同步'),
                            ),
                          ],
                          if (!widget.app.canSync)
                            const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text('请联网登录后核对移动权限。'),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    ),
  );
}
