import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../../data/assets/asset_config_repository.dart';
import '../../data/assets/asset_config_store.dart';
import '../../data/sync/sync_engine.dart';
import '../../domain/assets/asset_config.dart';

/// One page owns one identity-bound configuration session and its finite status.
final class AssetConfigurationController extends ChangeNotifier {
  AssetConfigurationController(this.app, this.space) {
    app.addListener(_identity);
  }
  final AppController app;
  final DataSpace space;
  late final store = AssetConfigStore(app.repository);
  late final repository = AssetConfigRepository(
    store,
    refreshPermissions: (lease) async {
      await app.syncEngine.refreshScopes(lease);
    },
  );
  bool busy = false, loading = true, _disposed = false;
  String? message;
  Map<AssetConfigSection, AssetConfigSectionSnapshot> sections = {};
  List<AssetConfigOperation> operations = [];
  bool get current =>
      !_disposed && app.space?.id == space.id && !app.switchingSpace;
  void _identity() {
    if (!current) {
      sections = {};
      operations = [];
    }
    if (!_disposed) notifyListeners();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  SyncLease _lease() {
    final identity = app.identity;
    if (identity == null || !current) {
      throw StateError('Missing configuration identity');
    }
    final captured = SyncLease.capture(identity);
    return SyncLease(
      space: captured.space,
      clientId: captured.clientId,
      epoch: captured.epoch,
      supportsGroupPull: captured.supportsGroupPull,
      request: captured.request,
      isCurrent: () => current && captured.isCurrent(),
    );
  }

  Future<void> load() async {
    try {
      final result = <AssetConfigSection, AssetConfigSectionSnapshot>{};
      for (final section in AssetConfigSection.values) {
        final snapshot = await store.readSection(space, section);
        if (!current) return;
        if (snapshot != null) result[section] = snapshot;
      }
      final pending = await repository.operations(space);
      if (current) {
        sections = result;
        operations = pending;
      }
    } catch (_) {
      if (current) message = '请联网登录并完成资料同步后读取配置。';
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> refresh() async {
    await perform((lease) async {
      // Bounded retries obtain coherent preference/rate snapshots if another
      // client changed the shared user revision between the individual reads.
      for (var attempt = 0; attempt < 3; attempt++) {
        final snapshots = <AssetConfigSectionSnapshot>[];
        for (final section in AssetConfigSection.values) {
          snapshots.add(await repository.refresh(lease, section));
        }
        if (snapshots.map((snapshot) => snapshot.revision).toSet().length ==
            1) {
          return;
        }
      }
      throw const ApiFailure(
        'asset_config_conflict',
        '配置正在变化，请重新刷新。',
        status: 409,
      );
    }, success: '配置已刷新。');
  }

  Future<bool> perform(
    Future<void> Function(SyncLease lease) action, {
    String success = '配置已由服务器确认。',
  }) async {
    if (busy || !current) return false;
    busy = true;
    message = null;
    _notify();
    try {
      final lease = _lease();
      await action(lease);
      lease.check();
      if (current) message = success;
      return current;
    } catch (error) {
      if (current) {
        message = error is ApiFailure && error.status == 409
            ? '服务器配置已变化，原请求与输入已保留。请刷新并核对，再明确放弃旧请求或重试原请求。'
            : '操作未完成。原请求与输入会保留；请检查登录、恢复状态或联网后重试。';
      }
      return false;
    } finally {
      if (current) await load();
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    app.removeListener(_identity);
    super.dispose();
  }
}

class PendingAssetOperations extends StatelessWidget {
  const PendingAssetOperations(this.controller, {super.key});
  final AssetConfigurationController controller;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final operation in controller.operations.where(
        (operation) => operation.pending,
      ))
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${switch (operation.section) {
                    AssetConfigSection.groups => '账户分组',
                    AssetConfigSection.preferences => '币种设置',
                    AssetConfigSection.rates => '手动估值',
                  }} · ${operation.state == 'conflict' ? '需要核对' : '等待确认'}',
                ),
                const Text('冻结请求已保留。重试会发送相同内容，放弃后可按刷新结果重新填写。'),
                Wrap(
                  spacing: 12,
                  children: [
                    TextButton(
                      onPressed: controller.busy
                          ? null
                          : () => controller.perform((lease) async {
                              await controller.repository.retry(
                                lease,
                                operation.id,
                              );
                            }),
                      child: const Text('重试原请求'),
                    ),
                    TextButton(
                      onPressed: controller.busy
                          ? null
                          : () async {
                              final abandon = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('放弃原配置请求？'),
                                  content: const Text(
                                    '原请求仍保存在本机。若上次服务器已保存但回复丢失，请优先重试并刷新核对，避免重复创建。',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('返回'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('已核对，放弃'),
                                    ),
                                  ],
                                ),
                              );
                              if (abandon == true && controller.current) {
                                await controller.perform(
                                  (lease) => controller.repository.abandon(
                                    lease,
                                    operation.id,
                                  ),
                                  success: '原请求已标记放弃，冻结内容仍保留。',
                                );
                              }
                            },
                      child: const Text('放弃原请求'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

/// Dialog overlays outlive their underlying route's rebuild. Bind their
/// private contents to the same identity guard as the page itself.
class AssetConfigConfirmation extends StatelessWidget {
  const AssetConfigConfirmation({
    required this.controller,
    required this.title,
    required this.content,
    this.confirm = '删除',
    super.key,
  });
  final AssetConfigurationController controller;
  final String title, content, confirm;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => !controller.current
        ? const AlertDialog(content: Text('资料空间已切换，请关闭此窗口。'))
        : AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirm),
              ),
            ],
          ),
  );
}
