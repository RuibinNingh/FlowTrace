import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../../data/ledger/ledger_repository.dart';
import '../entry/entry_icons.dart';
import 'management_editor.dart';
import 'management_templates.dart';

enum ManagementSection { books, categories, tags }

class ManagementPage extends StatefulWidget {
  const ManagementPage({
    required this.repository,
    required this.space,
    required this.isCurrent,
    this.initialBookId,
    this.onBookSelected,
    this.sessionChanges,
    this.initialSection = ManagementSection.books,
    super.key,
  });
  final LedgerRepository repository;
  final DataSpace space;
  final String? initialBookId;
  final bool Function() isCurrent;
  final ValueChanged<String>? onBookSelected;
  final Listenable? sessionChanges;
  final ManagementSection initialSection;

  @override
  State<ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends State<ManagementPage>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: widget.initialSection.index,
  );
  late Stream<LedgerView> _stream = _watch();
  late String? _bookId = widget.initialBookId;
  bool _archived = false;
  String _kind = 'expense';
  bool _busy = false;
  String? _error;
  late final _openingSpaceId = widget.space.id;
  late final _openingRepository = widget.repository;
  bool _invalidated = false;

  bool _current() {
    final predicate = widget.isCurrent;
    if (!mounted ||
        widget.space.id != _openingSpaceId ||
        widget.repository != _openingRepository ||
        !predicate()) {
      _invalidated = true;
    }
    return !_invalidated;
  }

  Stream<LedgerView> _watch() => widget.repository.watch(
    widget.space,
    query: const LedgerQuery(includeArchived: true),
  );

  @override
  void didUpdateWidget(covariant ManagementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.space.id != widget.space.id ||
        oldWidget.repository != widget.repository) {
      _bookId = widget.initialBookId;
      _stream = _watch();
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _select(String id) {
    if (!mounted || !_current()) return;
    setState(() => _bookId = id);
    widget.onBookSelected?.call(id);
  }

  void _checkCurrent() {
    if (!_current()) {
      throw const ApiFailure('identity_changed', '账号或服务器已切换，请重新打开。');
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (!mounted || _busy || !_current()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _checkCurrent();
      await action();
    } catch (error) {
      if (mounted && _current()) {
        setState(() => _error = managementMessage(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _editable(LedgerView view, LedgerEntity item) =>
      !_busy &&
      view.writable &&
      item.canEdit &&
      !item.conflicted &&
      item.editablePayload != null;

  Future<void> _edit(
    LedgerView view,
    String type, {
    LedgerEntity? entity,
    LedgerEntity? book,
    String? parentId,
    bool group = false,
  }) async {
    if (!mounted || !_current()) return;
    final scope = type == 'book' ? widget.space.userId : book!.id;
    if (entity == null
        ? !view.canCreate(type, scope)
        : !_editable(view, entity)) {
      return;
    }
    final payload =
        entity?.editablePayload ??
        <String, Object?>{
          'name': '',
          if (type == 'book') ...{
            'currency': 'CNY',
            'timezone': 'Asia/Shanghai',
            'month_start_day': 1,
            'template': 'blank',
            'icon': 'book',
            'cover_color': '#2279D7',
            'show_assets': false,
            'display_mode': 'month',
          },
          if (type == 'category') ...{
            'kind': _kind,
            'parent_id': parentId,
            'icon': _kind == 'income' ? 'salary' : 'other',
            'sort_order': _nextOrder(
              view.categories.where(
                (e) =>
                    e.scopeId == scope &&
                    e.payload['kind'] == _kind &&
                    e.payload['parent_id'] == parentId,
              ),
            ),
            'archived': false,
          },
          if (type == 'tag') ...{
            'kind': group ? 'group' : 'tag',
            'group_id': parentId,
            'color': managementColors.first,
            'sort_order': _nextOrder(
              view.tags.where(
                (e) =>
                    e.scopeId == scope &&
                    e.payload['kind'] == (group ? 'group' : 'tag') &&
                    e.payload['group_id'] == parentId,
              ),
            ),
            'archived': false,
          },
        };
    final definitions = (type == 'category' ? view.categories : view.tags)
        .where((e) => e.scopeId == scope && e.id != entity?.id)
        .toList();
    final hasChildren =
        entity != null &&
        definitions.any(
          (e) =>
              e.payload[type == 'category' ? 'parent_id' : 'group_id'] ==
              entity.id,
        );
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ManagementEditor(
          type: type,
          title: entity != null
              ? '编辑${type == 'book'
                    ? '账本'
                    : type == 'category'
                    ? '分类'
                    : payload['kind'] == 'group'
                    ? '分组'
                    : '标签'}'
              : type == 'book'
              ? '新建账本'
              : type == 'category'
              ? (parentId == null ? '添加一级分类' : '添加二级分类')
              : group
              ? '添加标签分组'
              : '添加标签',
          initial: payload,
          isNew: entity == null,
          parents: definitions,
          hasChildren: hasChildren,
          isCurrent: _current,
          sessionChanges: widget.sessionChanges,
          onSave: (edit) async {
            _checkCurrent();
            if (type == 'book' && entity == null) {
              final id = const Uuid().v4();
              final template = BookTemplates.find(
                edit.payload['template'] as String,
              )!;
              await widget.repository.saveBatch(
                widget.space,
                template.writes(
                  userScope: widget.space.userId,
                  bookId: id,
                  book: edit.payload,
                ),
              );
              if (mounted && _current()) _select(id);
            } else if (type == 'category' && entity == null) {
              final start = payload['sort_order'] as int;
              await widget.repository.saveBatch(widget.space, [
                for (var i = 0; i < edit.names.length; i++)
                  LedgerWrite(
                    entityType: type,
                    scopeId: scope,
                    payload: {
                      ...edit.payload,
                      'name': edit.names[i],
                      'sort_order': (start + i).clamp(0, 2147483647).toInt(),
                    },
                  ),
              ]);
            } else {
              await widget.repository.save(
                widget.space,
                entityType: type,
                scopeId: entity?.scopeId ?? scope,
                entityId: entity?.id,
                baseRevision: entity?.revision,
                payload: edit.payload,
              );
            }
          },
        ),
      ),
    );
  }

  int _nextOrder(Iterable<LedgerEntity> items) =>
      (items.fold<int>(
                -1,
                (value, item) =>
                    value > (item.payload['sort_order'] as int? ?? 0)
                    ? value
                    : (item.payload['sort_order'] as int? ?? 0),
              ) +
              1)
          .clamp(0, 2147483647)
          .toInt();
  int _compare(LedgerEntity a, LedgerEntity b) {
    final order = (a.payload['sort_order'] as int? ?? 0).compareTo(
      b.payload['sort_order'] as int? ?? 0,
    );
    return order == 0 ? a.id.compareTo(b.id) : order;
  }

  String _siblingKey(LedgerEntity item) =>
      '${item.type}:${item.scopeId}:${item.payload['kind']}:${item.payload[item.type == 'category' ? 'parent_id' : 'group_id']}';

  Future<void> _order(
    LedgerView view,
    List<LedgerEntity> displayed,
    int oldIndex,
    int newIndex,
  ) async {
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex == newIndex || newIndex < 0 || newIndex >= displayed.length) {
      return;
    }
    final moved = displayed[oldIndex], target = displayed[newIndex];
    if (_siblingKey(moved) != _siblingKey(target)) {
      setState(() => _error = '请在同一上级内排序。跨层级或分组移动请使用编辑。');
      return;
    }
    final source = moved.type == 'category' ? view.categories : view.tags;
    final siblings =
        source.where((e) => _siblingKey(e) == _siblingKey(moved)).toList()
          ..sort(_compare);
    final visible = displayed
        .where((e) => _siblingKey(e) == _siblingKey(moved))
        .toList();
    final from = visible.indexWhere((e) => e.id == moved.id),
        to = visible.indexWhere((e) => e.id == target.id);
    visible.insert(to, visible.removeAt(from));
    var cursor = 0;
    final visibleIds = visible.map((e) => e.id).toSet();
    final ordered = [
      for (final item in siblings)
        visibleIds.contains(item.id) ? visible[cursor++] : item,
    ];
    await _perform(() async {
      if (ordered.any(
        (e) => !e.canEdit || e.editablePayload == null || e.conflicted,
      )) {
        throw const ApiFailure('scope_forbidden', '当前有项目不可编辑，请先核对权限或冲突。');
      }
      await widget.repository.saveBatch(widget.space, [
        for (var i = 0; i < ordered.length; i++)
          LedgerWrite(
            entityType: ordered[i].type,
            scopeId: ordered[i].scopeId,
            entityId: ordered[i].id,
            baseRevision: ordered[i].revision,
            payload: {...ordered[i].editablePayload!, 'sort_order': i},
          ),
      ]);
    });
  }

  Future<void> _archive(LedgerEntity item) => _perform(() async {
    final latest = (await widget.repository.read(
      widget.space,
      query: const LedgerQuery(includeArchived: true),
    )).find(item.type, item.id);
    _checkCurrent();
    if (latest == null || !latest.canEdit || latest.editablePayload == null) {
      throw const ApiFailure('scope_forbidden', '此项当前不可编辑。');
    }
    await widget.repository.save(
      widget.space,
      entityType: latest.type,
      scopeId: latest.scopeId,
      entityId: latest.id,
      baseRevision: latest.revision,
      payload: {
        ...latest.editablePayload!,
        'archived': !(latest.payload['archived'] as bool? ?? false),
      },
    );
  });

  Widget _guardDialog(Widget Function() build) => widget.sessionChanges == null
      ? build()
      : ListenableBuilder(
          listenable: widget.sessionChanges!,
          builder: (_, _) => build(),
        );

  Future<void> _delete(LedgerEntity item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _guardDialog(
        () => AlertDialog(
          title: Text(_current() ? '删除“${item.name}”？' : '资料已切换'),
          content: Text(
            _current() ? '仍被账单、预算或子项引用时会拒绝删除。删除不会抹掉已发生的账务。' : '请返回后重新打开管理页面。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _current()
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && mounted) {
      await _perform(() => widget.repository.delete(widget.space, item));
    }
  }

  Future<void> _copy(LedgerEntity book) async {
    await showDialog<void>(
      context: context,
      builder: (_) => ManagementNameDialog(
        title: '仅复制账本设置',
        initialName: '${book.name} 副本',
        description: '复制封面、分类和标签配置；不复制流水、资产、余额、成员或附件。',
        isCurrent: _current,
        sessionChanges: widget.sessionChanges,
        onSave: (name) async {
          _checkCurrent();
          final id = await widget.repository.copyBookConfiguration(
            widget.space,
            book.id,
            name: name,
          );
          if (mounted && _current()) _select(id);
        },
      ),
    );
  }

  String _status(LedgerEntity item) => [
    if (item.pending) '待同步',
    if (item.conflicted) '有冲突，请到同步页处理',
    if (item.effectiveArchived) '已归档',
    if (!item.canEdit) '只读',
  ].join(' · ');
  Color _color(Object? value) =>
      value is String && RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(value)
      ? Color(int.parse(value.substring(1), radix: 16) | 0xFF000000)
      : const Color(0xFF2279D7);

  Widget _books(LedgerView view, LedgerEntity? selected) => Column(
    children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final book in view.books)
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      color: _color(
                        book.payload['cover_color'],
                      ).withValues(alpha: .16),
                      child: Row(
                        children: [
                          Icon(
                            EntryIcons.of(book.payload['icon']),
                            size: 34,
                            color: _color(book.payload['cover_color']),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  book.name,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                Text(
                                  '${book.payload['currency']} · ${_role(view.roleFor(book.id))}',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      title: Text(
                        '${BookTemplates.find(book.payload['template'] as String? ?? 'blank')?.name ?? '自定义'} · ${_display(book.payload['display_mode'])}',
                      ),
                      subtitle: Text(
                        '每月${book.payload['month_start_day']}日起 · ${_status(book)}',
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: '账本操作 ${book.name}',
                        onSelected: (action) {
                          if (action == 'edit') {
                            _edit(view, 'book', entity: book);
                          }
                          if (action == 'copy') _copy(book);
                          if (action == 'delete') _delete(book);
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'edit',
                            enabled: _editable(view, book),
                            child: const Text('编辑账本与显示设置'),
                          ),
                          PopupMenuItem(
                            value: 'copy',
                            enabled:
                                !_busy &&
                                view.canCreate('book', widget.space.userId),
                            child: const Text('仅复制设置'),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            enabled: _editable(view, book),
                            child: const Text('删除账本'),
                          ),
                        ],
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: TextButton.icon(
                          onPressed: () => _select(book.id),
                          icon: Icon(
                            selected?.id == book.id
                                ? Icons.check_circle
                                : Icons.book_outlined,
                          ),
                          label: Text(
                            selected?.id == book.id ? '当前账本' : '使用此账本',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (view.books.isEmpty)
              const Padding(
                padding: EdgeInsets.all(28),
                child: Text('还没有可访问的账本。新建后可以离线保存，联网时再同步。'),
              ),
          ],
        ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: !_busy && view.canCreate('book', widget.space.userId)
                ? () => _edit(view, 'book')
                : null,
            icon: const Icon(Icons.add),
            label: const Text('新建账本'),
          ),
        ),
      ),
    ],
  );

  String _display(Object? mode) => switch (mode) {
    'year' => '按年',
    'all' => '全部',
    _ => '按月',
  };
  Widget _archiveSwitch(String type) => SegmentedButton<bool>(
    key: ValueKey('management-$type-archive'),
    segments: const [
      ButtonSegment(value: false, label: Text('启用')),
      ButtonSegment(value: true, label: Text('已归档')),
    ],
    selected: {_archived},
    onSelectionChanged: (value) => setState(() => _archived = value.single),
  );

  List<LedgerEntity> _ordered(
    List<LedgerEntity> all,
    String parentField, {
    bool groups = false,
  }) {
    final roots =
        all
            .where(
              (e) => groups
                  ? e.payload['kind'] == 'group'
                  : e.payload[parentField] == null,
            )
            .toList()
          ..sort(_compare);
    final result = <LedgerEntity>[];
    for (final root in roots) {
      if (root.effectiveArchived == _archived) result.add(root);
      final children =
          all.where((e) => e.payload[parentField] == root.id).toList()
            ..sort(_compare);
      result.addAll(children.where((e) => e.effectiveArchived == _archived));
    }
    final ids = result.map((e) => e.id).toSet();
    final remaining =
        all
            .where(
              (e) => e.effectiveArchived == _archived && !ids.contains(e.id),
            )
            .toList()
          ..sort(_compare);
    result.addAll(remaining);
    return result;
  }

  Widget _rows(LedgerView view, List<LedgerEntity> items, LedgerEntity? book) =>
      items.isEmpty
      ? Center(child: Text(_archived ? '没有已归档项目' : '还没有项目，可以从下方添加。'))
      : ReorderableListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          buildDefaultDragHandles: false,
          itemCount: items.length,
          onReorder: (oldIndex, newIndex) =>
              _order(view, items, oldIndex, newIndex),
          itemBuilder: (context, index) {
            final item = items[index],
                parentId =
                    item.payload[item.type == 'category'
                        ? 'parent_id'
                        : 'group_id'];
            final parent = parentId is String
                ? view.find(item.type, parentId)
                : null;
            final editable = _editable(view, item);
            final ownArchived = item.payload['archived'] == true;
            return ReorderableDelayedDragStartListener(
              key: ValueKey(item.id),
              index: index,
              enabled: editable,
              child: Card(
                margin: EdgeInsets.only(
                  bottom: 8,
                  left: parentId == null ? 0 : 20,
                ),
                child: ListTile(
                  leading: item.type == 'category'
                      ? Icon(EntryIcons.of(item.payload['icon']))
                      : Icon(
                          item.payload['kind'] == 'group'
                              ? Icons.folder_outlined
                              : Icons.label_outline,
                          color: _color(item.payload['color']),
                        ),
                  title: Text(item.name),
                  subtitle: Text(
                    [
                      if (parentId != null)
                        '${item.type == 'category' ? '上级' : '分组'}：${parent?.name ?? '当前不可用'}',
                      if (item.type == 'category' && parentId == null) '一级分类',
                      if (item.type == 'tag' && item.payload['kind'] == 'group')
                        '标签分组',
                      _status(item),
                    ].where((s) => s.isNotEmpty).join(' · '),
                  ),
                  onTap: editable
                      ? () => _edit(view, item.type, entity: item, book: book)
                      : null,
                  trailing: PopupMenuButton<String>(
                    tooltip:
                        '${item.type == 'category' ? '分类' : '标签'}操作 ${item.name}',
                    onSelected: (action) {
                      if (action == 'edit') {
                        _edit(view, item.type, entity: item, book: book);
                      }
                      if (action == 'child') {
                        _edit(view, 'category', book: book, parentId: item.id);
                      }
                      if (action == 'tag') {
                        _edit(view, 'tag', book: book, parentId: item.id);
                      }
                      if (action == 'archive') _archive(item);
                      if (action == 'delete') _delete(item);
                      if (action == 'up') _order(view, items, index, index - 1);
                      if (action == 'down') {
                        _order(view, items, index, index + 2);
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'edit',
                        enabled: editable,
                        child: const Text('编辑'),
                      ),
                      if (item.type == 'category' && parentId == null)
                        PopupMenuItem(
                          value: 'child',
                          enabled:
                              !_busy &&
                              !item.effectiveArchived &&
                              book != null &&
                              view.canCreate('category', book.id),
                          child: const Text('添加二级分类'),
                        ),
                      if (item.type == 'tag' && item.payload['kind'] == 'group')
                        PopupMenuItem(
                          value: 'tag',
                          enabled:
                              !_busy &&
                              !item.effectiveArchived &&
                              book != null &&
                              view.canCreate('tag', book.id),
                          child: const Text('在此分组添加标签'),
                        ),
                      PopupMenuItem(
                        value: 'up',
                        enabled:
                            editable &&
                            index > 0 &&
                            _siblingKey(item) == _siblingKey(items[index - 1]),
                        child: const Text('上移'),
                      ),
                      PopupMenuItem(
                        value: 'down',
                        enabled:
                            editable &&
                            index + 1 < items.length &&
                            _siblingKey(item) == _siblingKey(items[index + 1]),
                        child: const Text('下移'),
                      ),
                      PopupMenuItem(
                        value: 'archive',
                        enabled:
                            editable &&
                            (!item.effectiveArchived || ownArchived),
                        child: Text(ownArchived ? '恢复' : '归档'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        enabled: editable,
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );

  Widget _categories(LedgerView view, LedgerEntity? book) {
    final all = view.categories
        .where((e) => e.scopeId == book?.id && e.payload['kind'] == _kind)
        .toList();
    final items = _ordered(all, 'parent_id');
    return Column(
      children: [
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'expense', label: Text('支出')),
            ButtonSegment(value: 'income', label: Text('收入')),
          ],
          selected: {_kind},
          onSelectionChanged: (v) => setState(() => _kind = v.single),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: _archiveSwitch('category'),
        ),
        const Text('长按同级分类排序，点击分类修改层级与图标。'),
        Expanded(child: _rows(view, items, book)),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed:
                  !_busy && book != null && view.canCreate('category', book.id)
                  ? () => _edit(view, 'category', book: book)
                  : null,
              icon: const Icon(Icons.add),
              label: const Text('添加分类'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tags(LedgerView view, LedgerEntity? book) {
    final all = view.tags.where((e) => e.scopeId == book?.id).toList();
    final canCreate = !_busy && book != null && view.canCreate('tag', book.id);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: _archiveSwitch('tag'),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text('归档保留历史引用；归档分组会停用组内标签，恢复不覆盖子项自身的归档设置。'),
        ),
        Expanded(
          child: _rows(view, _ordered(all, 'group_id', groups: true), book),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canCreate
                        ? () => _edit(view, 'tag', book: book)
                        : null,
                    icon: const Icon(Icons.add),
                    label: const Text('添加标签'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canCreate
                        ? () => _edit(view, 'tag', book: book, group: true)
                        : null,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('添加分组'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _contents(BuildContext context) {
    if (!_current()) {
      return const Center(child: Text('账号或服务器已切换，请返回后重新打开。'));
    }
    return StreamBuilder<LedgerView>(
      key: ValueKey(widget.space.id),
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('本机资料暂时无法读取，请返回后重试。'));
        }
        final view = snapshot.data;
        if (view == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final selected =
            view.books.where((b) => b.id == _bookId).firstOrNull ??
            view.books.firstOrNull;
        return Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (!view.writable)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('当前资料只读，请先处理同步或恢复状态。'),
              ),
            if (selected != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: DropdownButtonFormField<String>(
                  key: ValueKey('${widget.space.id}:${selected.id}'),
                  initialValue: selected.id,
                  decoration: const InputDecoration(labelText: '当前账本'),
                  items: [
                    for (final book in view.books)
                      DropdownMenuItem(value: book.id, child: Text(book.name)),
                  ],
                  onChanged: (id) {
                    if (id != null) _select(id);
                  },
                ),
              ),
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: '账本'),
                Tab(text: '分类'),
                Tab(text: '标签'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _books(view, selected),
                  _categories(view, selected),
                  _tags(view, selected),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  String _role(String? role) => switch (role) {
    'owner' => '所有者',
    'editor' => '可编辑成员',
    'viewer' => '只读成员',
    _ => '权限待确认',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('账本与分类管理')),
    body: widget.sessionChanges == null
        ? _contents(context)
        : ListenableBuilder(
            listenable: widget.sessionChanges!,
            builder: (context, _) => _contents(context),
          ),
  );
}
