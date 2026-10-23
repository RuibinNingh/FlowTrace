import 'package:flutter/material.dart';

import '../../core/money/money.dart';
import '../../core/money/currency_catalog.dart';
import '../../core/network/api_failure.dart';
import '../../data/ledger/ledger_models.dart';
import '../../domain/ledger/timezone_rules.dart';
import '../entry/entry_icons.dart';
import 'management_templates.dart';

const managementColors = [
  '#2279D7',
  '#F2A4CB',
  '#DD0087',
  '#FF8800',
  '#D72626',
  '#00A89C',
  '#07879A',
  '#277523',
  '#005973',
  '#326CE5',
  '#6827D9',
  '#8E4938',
  '#748694',
  '#844A88',
  '#77815C',
  '#51544B',
  '#455A64',
];

String managementMessage(Object error) {
  if (error is ApiFailure) return error.message;
  final code = error is DomainError ? error.code : '';
  return switch (code) {
    'category.invalid_parent' => '请选择同账本、同收支类型的一级分类；含子分类时不能降级。',
    'category.budget_overlap' => '移动后会与现有预算重复，请先调整预算。',
    'category.definition_in_use' => '此分类仍被账单、预算或子分类使用，不能执行此次操作。',
    'category.in_use' || 'entity.in_use' => '此项仍被账单、预算或子项引用，不能删除。',
    'tag.group_not_empty' => '请先迁出或删除组内标签，再删除或转换分组。',
    'tag.definition_in_use' => '标签或分组仍被引用，请先处理引用后再操作。',
    'tag.invalid_group' => '请选择同账本的标签分组。',
    'book_not_empty' || 'book.not_empty' => '账本仍有业务记录，不能删除。',
    'scope_forbidden' ||
    'scope.readonly' ||
    'ledger.read_only' ||
    'ledger.not_writable' => '当前无编辑权限，资料已保留。',
    'revision_conflict' ||
    'ledger.stale_revision' ||
    'ledger.local_revision_changed' => '记录已变化，请关闭后重新打开核对。',
    'ledger.conflicted' => '此项有未解决的同步冲突，请先到同步页面处理。',
    'currency.unsupported' => '请选择当前支持的币种。',
    'book_currency_in_use' => '账本已有该币种的业务记录，不能直接修改基础币种。',
    'date.invalid_timezone' => '时区无效，请检查地区名称。',
    _ => '未能保存，请检查输入或同步状态后重试。输入仍保留在此页。',
  };
}

final class ManagementEdit {
  ManagementEdit({required this.payload, this.names = const []});
  final Map<String, Object?> payload;
  final List<String> names;
}

class ManagementEditor extends StatefulWidget {
  const ManagementEditor({
    required this.type,
    required this.title,
    required this.initial,
    required this.onSave,
    required this.isCurrent,
    this.sessionChanges,
    this.isNew = false,
    this.parents = const [],
    this.hasChildren = false,
    super.key,
  });
  final String type;
  final String title;
  final Map<String, Object?> initial;
  final bool isNew;
  final bool hasChildren;
  final List<LedgerEntity> parents;
  final Future<void> Function(ManagementEdit edit) onSave;
  final bool Function() isCurrent;
  final Listenable? sessionChanges;

  @override
  State<ManagementEditor> createState() => _ManagementEditorState();
}

class _ManagementEditorState extends State<ManagementEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.initial['name'] as String? ?? '',
  );
  late final _currency = TextEditingController(
    text: widget.initial['currency'] as String? ?? 'CNY',
  );
  late final _timezone = TextEditingController(
    text: widget.initial['timezone'] as String? ?? 'Asia/Shanghai',
  );
  late final _color = TextEditingController(
    text:
        (widget.initial[widget.type == 'book' ? 'cover_color' : 'color']
            as String?) ??
        managementColors.first,
  );
  late String _icon = widget.initial['icon'] as String? ?? 'book';
  late String _kind =
      widget.initial['kind'] as String? ??
      (widget.type == 'tag' ? 'tag' : 'expense');
  late String? _parent =
      widget.initial[widget.type == 'tag' ? 'group_id' : 'parent_id']
          as String?;
  late int _monthStart = widget.initial['month_start_day'] as int? ?? 1;
  late String _displayMode =
      widget.initial['display_mode'] as String? ?? 'month';
  late String _template = widget.initial['template'] as String? ?? 'blank';
  late bool _showAssets = widget.initial['show_assets'] as bool? ?? false;
  bool _batch = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in [_name, _currency, _timezone, _color]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<String> get _names => _batch
      ? _name.text
            .split(RegExp(r'[\r\n]+'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList()
      : [_name.text.trim()];

  String? _nameError(String? _) {
    if (_names.isEmpty || _names.any((s) => s.isEmpty || s.length > 80)) {
      return '每个名称须为1–80个字符。';
    }
    if (_names.length > 100) return '一次最多添加100个分类。';
    if (_names.toSet().length != _names.length) return '请移除本次输入中重复的名称。';
    return null;
  }

  Future<void> _submit() async {
    if (_busy || !widget.isCurrent() || !_form.currentState!.validate()) return;
    final payload = <String, Object?>{...widget.initial, 'name': _names.first};
    if (widget.type == 'book') {
      payload.addAll({
        'currency': _currency.text.trim().toUpperCase(),
        'timezone': _timezone.text.trim(),
        'month_start_day': _monthStart,
        'template': _template,
        'icon': _icon,
        'cover_color': _color.text.trim(),
        'show_assets': _showAssets,
        'display_mode': _displayMode,
      });
    } else if (widget.type == 'category') {
      payload.addAll({
        'kind': _kind,
        'parent_id': _parent,
        'icon': _icon,
        'sort_order': payload['sort_order'] ?? 0,
        'archived': payload['archived'] ?? false,
      });
    } else {
      payload.addAll({
        'kind': _kind,
        'group_id': _kind == 'group' ? null : _parent,
        'color': _color.text.trim(),
        'sort_order': payload['sort_order'] ?? 0,
        'archived': payload['archived'] ?? false,
      });
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(ManagementEdit(payload: payload, names: _names));
      if (mounted && widget.isCurrent()) Navigator.pop(context);
    } catch (error) {
      if (mounted && widget.isCurrent()) {
        setState(() => _error = managementMessage(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _parentField() {
    final choices = widget.parents
        .where(
          (p) =>
              p.payload[widget.type == 'tag' ? 'kind' : 'parent_id'] ==
                  (widget.type == 'tag' ? 'group' : null) &&
              (widget.type == 'tag' || p.payload['kind'] == _kind) &&
              (!p.effectiveArchived || p.id == _parent),
        )
        .toList();
    if (_parent != null && !choices.any((p) => p.id == _parent)) {
      return const Text('原上级项当前不可用，请返回并核对同步权限。');
    }
    return DropdownButtonFormField<String>(
      key: ValueKey('parent:$_kind:$_parent'),
      initialValue: _parent ?? '',
      decoration: InputDecoration(
        labelText: widget.type == 'tag' ? '所属分组' : '层级与上级分类',
        helperText: widget.hasChildren ? '含子项时不能降级或转换类型。' : null,
      ),
      items: [
        DropdownMenuItem(
          value: '',
          child: Text(widget.type == 'tag' ? '未分组' : '一级分类'),
        ),
        for (final p in choices)
          DropdownMenuItem(
            value: p.id,
            child: Text('${p.name}${p.effectiveArchived ? '（已归档）' : ''}'),
          ),
      ],
      onChanged: _busy || widget.hasChildren
          ? null
          : (value) => setState(() => _parent = value == '' ? null : value),
    );
  }

  Widget _colorField() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final color in managementColors)
            Semantics(
              label: '选择颜色$color',
              button: true,
              selected: _color.text.toUpperCase() == color.toUpperCase(),
              child: InkWell(
                onTap: _busy ? null : () => setState(() => _color.text = color),
                borderRadius: BorderRadius.circular(24),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(
                      int.parse(color.substring(1), radix: 16) | 0xFF000000,
                    ),
                  ),
                  child: _color.text.toUpperCase() == color.toUpperCase()
                      ? const Icon(Icons.check, color: Colors.white)
                      : null,
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _color,
        enabled: !_busy,
        decoration: const InputDecoration(
          labelText: '颜色',
          helperText: '六位颜色值，例如 #2279D7',
        ),
        onChanged: (_) => setState(() {}),
        validator: (value) =>
            RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(value?.trim() ?? '')
            ? null
            : '请输入#与六位十六进制颜色。',
      ),
    ],
  );

  Widget _fields() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      TextFormField(
        controller: _name,
        enabled: !_busy,
        maxLines: _batch ? 5 : 1,
        maxLength: _batch ? 8100 : 80,
        decoration: InputDecoration(
          labelText: widget.type == 'book'
              ? '账本名称'
              : widget.type == 'category'
              ? '分类名称'
              : _kind == 'group'
              ? '分组名称'
              : '标签名称',
          hintText: _batch ? '一行一个名称' : null,
        ),
        validator: _nameError,
      ),
      if (widget.type == 'category' && widget.isNew)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('批量添加'),
          subtitle: const Text('每行一个名称，整批先保存在本机，再逐项同步。'),
          value: _batch,
          onChanged: _busy ? null : (v) => setState(() => _batch = v),
        ),
      if (widget.type == 'book') ...[
        DropdownButtonFormField<String>(
          initialValue: _template,
          decoration: const InputDecoration(labelText: '账本类型与模板'),
          items: [
            for (final template in BookTemplates.values)
              DropdownMenuItem(value: template.id, child: Text(template.name)),
            if (BookTemplates.find(_template) == null)
              DropdownMenuItem(
                value: _template,
                child: Text('自定义类型：$_template'),
              ),
          ],
          onChanged: _busy ? null : (v) => setState(() => _template = v!),
        ),
        const SizedBox(height: 12),
        Text(
          widget.isNew
              ? '模板将添加${BookTemplates.find(_template)?.categories.length ?? 0}项流迹默认分类，不创建流水或资产。'
              : '修改类型只更改标识，不覆盖已有分类、流水或资产。',
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _currency.text,
                decoration: const InputDecoration(labelText: '基础币种'),
                items: [
                  for (final currency in currencyScales.keys)
                    DropdownMenuItem(value: currency, child: Text(currency)),
                  if (!currencyScales.containsKey(_currency.text))
                    DropdownMenuItem(
                      value: _currency.text,
                      child: Text(_currency.text),
                    ),
                ],
                validator: (value) =>
                    currencyScales.containsKey(value) ? null : '请选择支持的币种。',
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _currency.text = value!),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _monthStart,
                decoration: const InputDecoration(labelText: '月份起始日'),
                items: [
                  for (var day = 1; day <= 31; day++)
                    DropdownMenuItem(value: day, child: Text('$day日')),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _monthStart = v!),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _displayMode,
          decoration: const InputDecoration(labelText: '显示方式'),
          items: const [
            DropdownMenuItem(value: 'month', child: Text('按月')),
            DropdownMenuItem(value: 'year', child: Text('按年')),
            DropdownMenuItem(value: 'all', child: Text('全部')),
          ],
          onChanged: _busy ? null : (v) => setState(() => _displayMode = v!),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _timezone,
          enabled: !_busy,
          maxLength: 64,
          decoration: const InputDecoration(
            labelText: '账本时区',
            helperText: '例如 Asia/Shanghai',
          ),
          validator: (v) {
            try {
              instantBusinessDate('2026-01-01T00:00:00Z', v?.trim() ?? '');
              return null;
            } catch (_) {
              return '请输入有效的地区时区。';
            }
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('显示资产记账入口'),
          subtitle: const Text('只改变入口显示，不改变私人资产权限或余额。'),
          value: _showAssets,
          onChanged: _busy ? null : (v) => setState(() => _showAssets = v),
        ),
      ],
      if (widget.type == 'category' || widget.type == 'tag') ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _kind,
          decoration: InputDecoration(
            labelText: widget.type == 'category' ? '收支类型' : '标签类型',
          ),
          items: widget.type == 'category'
              ? const [
                  DropdownMenuItem(value: 'expense', child: Text('支出')),
                  DropdownMenuItem(value: 'income', child: Text('收入')),
                ]
              : const [
                  DropdownMenuItem(value: 'tag', child: Text('标签')),
                  DropdownMenuItem(value: 'group', child: Text('分组')),
                ],
          onChanged: _busy || widget.hasChildren
              ? null
              : (v) => setState(() {
                  _kind = v!;
                  _parent = null;
                }),
        ),
        const SizedBox(height: 16),
        if (widget.type == 'category' || _kind == 'tag') _parentField(),
      ],
      if (widget.type != 'tag') ...[
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  final value = await showManagementIconPicker(context, _icon);
                  if (value != null && mounted && widget.isCurrent()) {
                    setState(() => _icon = value);
                  }
                },
          icon: Icon(EntryIcons.of(_icon)),
          label: const Text('选择图标'),
        ),
      ],
      if (widget.type != 'category') ...[
        const SizedBox(height: 20),
        _colorField(),
      ],
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: Text(_busy ? '正在保存…' : '保存'),
      ),
      const SizedBox(height: 24),
    ],
  );

  Widget _page() => !widget.isCurrent()
      ? Scaffold(
          appBar: AppBar(title: const Text('资料已切换')),
          body: const Center(child: Text('账号或服务器已切换，请返回重新打开。')),
        )
      : PopScope(
          canPop: !_busy,
          child: Scaffold(
            appBar: AppBar(title: Text(widget.title)),
            body: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Form(
                  key: _form,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [_fields()],
                  ),
                ),
              ),
            ),
          ),
        );

  @override
  Widget build(BuildContext context) => widget.sessionChanges == null
      ? _page()
      : ListenableBuilder(
          listenable: widget.sessionChanges!,
          builder: (_, _) => _page(),
        );
}

Future<String?> showManagementIconPicker(
  BuildContext context,
  String selected,
) {
  var query = '';
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocalState) {
        final icons = EntryIcons.values.entries
            .where(
              (e) => '${e.key} ${_iconNames[e.key] ?? ''}'
                  .toLowerCase()
                  .contains(query.trim().toLowerCase()),
            )
            .toList();
        return AlertDialog(
          title: const Text('选择图标'),
          content: SizedBox(
            width: 480,
            height: 440,
            child: Column(
              children: [
                TextField(
                  decoration: const InputDecoration(
                    labelText: '搜索图标',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setLocalState(() => query = v),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: icons.isEmpty
                      ? const Center(child: Text('没有匹配的图标'))
                      : GridView.extent(
                          maxCrossAxisExtent: 100,
                          childAspectRatio: .9,
                          children: [
                            for (final icon in icons)
                              Semantics(
                                button: true,
                                selected: icon.key == selected,
                                label: _iconNames[icon.key] ?? icon.key,
                                child: InkWell(
                                  onTap: () => Navigator.pop(context, icon.key),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        icon.value,
                                        color: icon.key == selected
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : null,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _iconNames[icon.key] ?? icon.key,
                                        maxLines: 2,
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        );
      },
    ),
  );
}

const _iconNames = {
  'book': '账本',
  'food': '餐饮',
  'restaurant': '餐厅',
  'snack': '零食',
  'shopping': '购物',
  'home': '住房',
  'transport': '交通',
  'travel': '旅行',
  'health': '医疗',
  'education': '教育',
  'study': '学习',
  'salary': '工资',
  'bonus': '奖金',
  'gift': '礼物',
  'entertainment': '娱乐',
  'sport': '运动',
  'digital': '数码',
  'utilities': '水电',
  'service': '服务',
  'investment': '投资',
  'cash': '现金',
  'bank': '银行',
  'credit_card': '信用卡',
  'other': '其他',
};

class ManagementNameDialog extends StatefulWidget {
  const ManagementNameDialog({
    required this.title,
    required this.initialName,
    required this.description,
    required this.onSave,
    required this.isCurrent,
    this.sessionChanges,
    super.key,
  });
  final String title;
  final String initialName;
  final String description;
  final Future<void> Function(String name) onSave;
  final bool Function() isCurrent;
  final Listenable? sessionChanges;
  @override
  State<ManagementNameDialog> createState() => _ManagementNameDialogState();
}

class _ManagementNameDialogState extends State<ManagementNameDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initialName);
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !widget.isCurrent() || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(_name.text.trim());
      if (mounted && widget.isCurrent()) Navigator.pop(context);
    } catch (error) {
      if (mounted && widget.isCurrent()) {
        setState(() => _error = managementMessage(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _dialog() => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(widget.isCurrent() ? widget.title : '资料已切换'),
      content: !widget.isCurrent()
          ? const Text('账号或服务器已切换，请返回重新打开。')
          : SizedBox(
              width: 440,
              child: Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(widget.description),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _name,
                      enabled: !_busy,
                      maxLength: 80,
                      decoration: const InputDecoration(labelText: '新账本名称'),
                      validator: (v) =>
                          v == null || v.trim().isEmpty || v.trim().length > 80
                          ? '请输入1–80个字符。'
                          : null,
                    ),
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy || !widget.isCurrent() ? null : _save,
          child: Text(_busy ? '正在复制…' : '复制'),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => widget.sessionChanges == null
      ? _dialog()
      : ListenableBuilder(
          listenable: widget.sessionChanges!,
          builder: (_, _) => _dialog(),
        );
}
