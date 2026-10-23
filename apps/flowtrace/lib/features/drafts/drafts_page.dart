import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../data/local/app_database.dart';

class DraftsPage extends StatelessWidget {
  const DraftsPage({required this.controller, super.key});
  final AppController controller;

  Future<void> _edit(BuildContext context, [StoredDraft? draft]) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _DraftEditor(controller: controller, draft: draft),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => _scaffold(context),
  );

  Widget _scaffold(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('流迹', style: TextStyle(fontWeight: FontWeight.w600)),
      actions: [
        IconButton(
          tooltip: '设置',
          key: const Key('open-settings'),
          onPressed: () => Navigator.pushNamed(context, '/settings'),
          icon: const Icon(Icons.tune_rounded),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 120),
          children: [
            if (controller.identity != null) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline_rounded),
                title: Text(controller.identity!.account?.username ?? '未登录'),
                subtitle: Text(
                  controller.switchingSpace
                      ? '正在打开账号资料空间…'
                      : controller.identity!.online
                      ? '账号已连接 · 资料独立保存'
                      : controller.identity!.account != null
                      ? '离线 · 会话待验证'
                      : '当前仅保存本地草稿',
                ),
                trailing: TextButton(
                  onPressed: () => Navigator.pushNamed(context, '/account'),
                  child: Text(controller.identity!.online ? '管理' : '登录'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Text('本地草稿', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              '随手记下，离线也能继续。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 26),
            if (controller.drafts.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 44,
                    horizontal: 24,
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.edit_note_rounded,
                        size: 52,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '还没有草稿',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '点击下方 +，保存你的第一条记录。',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            else
              for (final draft in controller.drafts) ...[
                Card(
                  child: ListTile(
                    key: ValueKey('draft-${draft.id}'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    onTap: () => _edit(context, draft),
                    title: Text(draft.body),
                    subtitle: const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('已保存到本机 · 尚未记入账本'),
                    ),
                    trailing: IconButton(
                      tooltip: '删除草稿',
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('删除这条草稿？'),
                            content: const Text('此草稿尚未记入账本。'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, false),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, true),
                                child: const Text('删除'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true) {
                          try {
                            await controller.deleteDraft(draft.id);
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('删除失败，草稿已保留。')),
                              );
                            }
                          }
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            const SizedBox(height: 22),
            const Text(
              '草稿保存在当前服务器资料空间，不会自动发送。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    ),
    floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    floatingActionButton: FloatingActionButton.large(
      key: const Key('new-draft'),
      tooltip: '新建草稿',
      onPressed: () => _edit(context),
      child: const Icon(Icons.add_rounded, size: 34),
    ),
  );
}

class _DraftEditor extends StatefulWidget {
  const _DraftEditor({required this.controller, this.draft});
  final AppController controller;
  final StoredDraft? draft;

  @override
  State<_DraftEditor> createState() => _DraftEditorState();
}

class _DraftEditorState extends State<_DraftEditor> {
  late final TextEditingController _text;
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;
  String? _savedId;
  String? _savedBody;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.draft?.body);
    _savedId = widget.draft?.id;
    _savedBody = widget.draft?.body;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.controller.registerUpdateParticipant(
      this,
      route: ModalRoute.of(context),
      prepare: _prepareUpdate,
    );
  }

  Future<bool> _prepareUpdate() async {
    if (_saving || !mounted) return false;
    final body = _text.text.trim();
    if (body == _savedBody || (body.isEmpty && (_savedBody ?? '').isEmpty)) {
      return true;
    }
    if (body.isEmpty || body.length > 2000) return false;
    final space = widget.controller.space;
    if (space == null) return false;
    _savedId = await widget.controller.repository.saveDraft(
      space,
      body,
      draftId: _savedId,
    );
    _savedBody = body;
    await widget.controller.reloadDrafts();
    return mounted &&
        widget.controller.space?.id == space.id &&
        _text.text.trim() == body;
  }

  @override
  void dispose() {
    widget.controller.unregisterUpdateParticipant(this);
    // The route's pop future completes before its exit animation. Keep the
    // editing controller alive until the actual sheet widget is unmounted.
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.saveDraft(_text.text, draftId: _savedId);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '未能保存，请保留输入后重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      24,
      24,
      24,
      MediaQuery.viewInsetsOf(context).bottom + 24,
    ),
    child: Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.draft == null ? '新建草稿' : '编辑草稿',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text('先记下想法，草稿尚未记入账本。'),
          const SizedBox(height: 20),
          TextFormField(
            key: const Key('draft-body'),
            controller: _text,
            autofocus: true,
            maxLines: 4,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: '备注',
              hintText: '例如：午餐，稍后补充金额和分类',
            ),
            validator: (value) =>
                value == null || value.trim().isEmpty ? '请先写一点内容' : null,
          ),
          if (_error != null) ...[
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton(
            key: const Key('save-draft'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '正在保存…' : '保存到本机'),
          ),
        ],
      ),
    ),
  );
}
