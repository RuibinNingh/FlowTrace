import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../domain/assets/asset_config.dart';
import 'asset_configuration_controller.dart';

class AssetGroupsPage extends StatefulWidget {
  const AssetGroupsPage({required this.app, required this.space, super.key});
  final AppController app;
  final DataSpace space;
  @override
  State<AssetGroupsPage> createState() => _AssetGroupsPageState();
}

class _AssetGroupsPageState extends State<AssetGroupsPage> {
  late final _controller = AssetConfigurationController(
    widget.app,
    widget.space,
  );
  @override
  void initState() {
    super.initState();
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _edit([AssetGroup? group]) async {
    final name = TextEditingController(text: group?.name ?? '');
    final order = TextEditingController(text: '${group?.sortOrder ?? 0}');
    final form = GlobalKey<FormState>();
    await showDialog<void>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => !_controller.current
            ? const AlertDialog(content: Text('资料空间已切换，请关闭此窗口。'))
            : AlertDialog(
                scrollable: true,
                title: Text(group == null ? '添加分组' : '编辑分组'),
                content: SizedBox(
                  width: 440,
                  child: Form(
                    key: form,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextFormField(
                          controller: name,
                          maxLength: 80,
                          decoration: const InputDecoration(labelText: '分组名称'),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? '请输入名称'
                              : null,
                        ),
                        TextFormField(
                          controller: order,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: '排序'),
                          validator: (value) {
                            final n = int.tryParse(value ?? '');
                            return n == null || n < 0 || n > 2147483647
                                ? '请输入有效的非负整数'
                                : null;
                          },
                        ),
                        if (_controller.message != null)
                          Text(_controller.message!),
                        PendingAssetOperations(_controller),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: _controller.busy
                        ? null
                        : () => Navigator.pop(context),
                    child: const Text('返回'),
                  ),
                  FilledButton(
                    onPressed: _controller.busy
                        ? null
                        : () async {
                            if (!form.currentState!.validate()) return;
                            final saved = await _controller.perform((
                              lease,
                            ) async {
                              if (group == null) {
                                await _controller.repository.createGroup(
                                  lease,
                                  name: name.text.trim(),
                                  sortOrder: int.parse(order.text),
                                );
                              } else {
                                await _controller.repository.updateGroup(
                                  lease,
                                  group,
                                  name: name.text.trim(),
                                  sortOrder: int.parse(order.text),
                                );
                              }
                            });
                            if (saved &&
                                context.mounted &&
                                _controller.current) {
                              Navigator.pop(context);
                            }
                          },
                    child: Text(_controller.busy ? '正在保存…' : '保存并确认'),
                  ),
                ],
              ),
      ),
    );
    // Route transition finishes before disposing controllers used by TextFields.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
    order.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('账户分组'),
        actions: [
          IconButton(
            tooltip: '联网刷新',
            onPressed: _controller.busy ? null : _controller.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !_controller.current
          ? const Center(child: Text('资料空间已切换。'))
          : _controller.loading
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    const Text('分组只属于你。先由服务器确认分组，再将账户放入；空分组会保留，仍被账户引用的分组不能删除。'),
                    if (_controller.message != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(_controller.message!),
                      ),
                    if (_controller.busy) const LinearProgressIndicator(),
                    PendingAssetOperations(_controller),
                    for (final group
                        in _controller
                                .sections[AssetConfigSection.groups]
                                ?.groups ??
                            <AssetGroup>[])
                      ListTile(
                        title: Text(group.name),
                        subtitle: Text('排序 ${group.sortOrder}'),
                        onTap: _controller.busy ? null : () => _edit(group),
                        trailing: IconButton(
                          tooltip: '删除空分组',
                          onPressed: _controller.busy
                              ? null
                              : () async {
                                  final remove = await showDialog<bool>(
                                    context: context,
                                    builder: (context) =>
                                        AssetConfigConfirmation(
                                          controller: _controller,
                                          title: '删除空分组？',
                                          content: group.name,
                                        ),
                                  );
                                  if (remove == true) {
                                    await _controller.perform((lease) async {
                                      await _controller.repository.deleteGroup(
                                        lease,
                                        group.id,
                                      );
                                    });
                                  }
                                },
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _controller.busy ? null : _edit,
                      icon: const Icon(Icons.add),
                      label: const Text('添加分组'),
                    ),
                  ],
                ),
              ),
            ),
    ),
  );
}
