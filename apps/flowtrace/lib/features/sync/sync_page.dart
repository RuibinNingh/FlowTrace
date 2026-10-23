import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../../data/local/app_database.dart';
import '../../data/local/local_repository.dart';
import '../../data/sync/snapshot_protocol.dart';
import '../../data/sync/sync_engine.dart';
import '../../data/sync/sync_store.dart';

class SyncPage extends StatefulWidget {
  const SyncPage({required this.app, required this.engine, super.key});
  final AppController app;
  final SyncEngine engine;
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  SyncStore get store => widget.engine.store;
  DataSpace? _space;
  SpaceSyncState? _state;
  List<StoredConflict> _conflicts = [];
  List<RecoveryBackup> _backups = [];
  Set<String> _moveConflicts = {};
  StreamSubscription<dynamic>? _databaseChanges;
  String? _watchedSpace;
  int _pending = 0;
  bool _busy = false;
  String? _message;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_identityChanged);
    _observeDatabase();
    _reload();
  }

  @override
  void dispose() {
    ++_generation;
    widget.app.removeListener(_identityChanged);
    unawaited(_databaseChanges?.cancel());
    super.dispose();
  }

  void _identityChanged() {
    _observeDatabase();
    if (widget.app.space?.id != _space?.id) {
      _reload();
    } else if (mounted) {
      setState(() {});
    }
  }

  void _observeDatabase() {
    final id = widget.app.space?.id;
    if (id == _watchedSpace) return;
    _watchedSpace = id;
    unawaited(_databaseChanges?.cancel());
    _databaseChanges = null;
    if (id == null) return;
    final db = store.db;
    _databaseChanges = db
        .customSelect(
          'SELECT 1',
          readsFrom: {
            db.syncStates,
            db.syncConflicts,
            db.pendingOperations,
            db.syncRecoveryBackups,
          },
        )
        .watch()
        .listen(
          (_) {
            if (!mounted || _watchedSpace != id || widget.app.space?.id != id) {
              return;
            }
            // Drop cached server text immediately, before asynchronous rereads. Local
            // unsent input remains in the journal and the refreshed conflict list.
            setState(() => _conflicts = []);
            unawaited(
              _reload().catchError((Object _) {
                if (mounted && _watchedSpace == id) {
                  setState(() {
                    _conflicts = [];
                    _state = null;
                    _message = '同步资料读取失败，请重新打开后重试。';
                  });
                }
              }),
            );
          },
          onError: (Object _) {
            if (mounted && _watchedSpace == id) {
              setState(() {
                _conflicts = [];
                _state = null;
              });
            }
          },
        );
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    final space = widget.app.space;
    if (space?.id != _space?.id && mounted) {
      setState(() {
        _space = null;
        _state = null;
        _conflicts = [];
        _backups = [];
        _pending = 0;
        _message = null;
      });
    }
    if (space == null || !space.verified) {
      if (mounted) {
        setState(() {
          _space = null;
          _state = null;
          _conflicts = [];
          _backups = [];
          _pending = 0;
        });
      }
      return;
    }
    final state = await store.state(space);
    final conflicts = await store.conflicts(space);
    final backups = await store.recoveryBackups(space);
    final pending = await store.repository.pending(space);
    if (!mounted ||
        generation != _generation ||
        widget.app.space?.id != space.id) {
      return;
    }
    final chains = <(String, String), List<StoredOperation>>{};
    for (final operation in pending) {
      chains
          .putIfAbsent((operation.entityType, operation.entityId), () => [])
          .add(operation);
    }
    final moveOperations = {
      for (final chain in chains.values)
        if (_requiresMoveReview(chain))
          for (final operation in chain) operation.operationId,
    };
    setState(() {
      _space = space;
      _state = state;
      _conflicts = conflicts;
      _backups = backups;
      _moveConflicts = moveOperations;
      _pending = pending
          .where((op) => {'queued', 'sending', 'retry'}.contains(op.state))
          .length;
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on ApiFailure catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _message = '同步尚未完成，本机内容已保留。请核对网络、登录状态或恢复提示后重试。');
      }
    } finally {
      if (mounted) {
        await _reload();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _synchronize() => _perform(() async {
    final report = await widget.engine.synchronize(
      SyncLease.capture(widget.app.identity!),
    );
    if (mounted) {
      setState(
        () => _message = report.conflicts > 0
            ? '同步已完成，${report.conflicts} 项修改需要你处理。'
            : report.pending > 0
            ? '已同步 ${report.applied} 项，剩余 ${report.pending} 项待继续。'
            : '已与服务器同步。',
      );
    }
  });

  Future<void> _startRecovery() async {
    final space = _space;
    final identity = widget.app.identity;
    if (space == null || identity == null) return;
    final generation = identity.sessionGeneration;
    if (!await _confirm(
      '准备恢复资料',
      '本机完整备份会保留。接下来退出当前设备并重新登录，再下载服务器资料；原有账单不会自动重复提交。',
    )) {
      return;
    }
    await _perform(() async {
      await store.requireRebuild(space, 'user_requested');
      await identity.rotateClientForRecovery(
        expectedSpaceId: space.id,
        expectedGeneration: generation,
      );
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _finishRecovery() async {
    final lease = SyncLease.capture(widget.app.identity!);
    if (!await _confirm(
      '从服务器恢复',
      '校验完整快照后替换当前资料，原来的本机备份和草稿继续保留。恢复完成后请核对备份中的差异记录。',
    )) {
      return;
    }
    await _perform(() async {
      lease.check();
      await widget.engine.rebuildFromServer(lease);
      if (mounted) {
        setState(() => _message = '资料已恢复。请打开下方恢复备份，核对服务器缺少或内容不同的记录。');
      }
    });
  }

  Future<void> _resolve(StoredConflict conflict, bool keepMine) async {
    final lease = SyncLease.capture(widget.app.identity!);
    await _perform(() async {
      final operations = await store.repository.pending(lease.space);
      final operation = operations
          .where((op) => op.operationId == conflict.operationId)
          .firstOrNull;
      if (operation == null || operation.state != 'rejected') {
        throw const ApiFailure('not_found', '这项修改已隔离保留或已处理，可复制内容后重新录入。');
      }
      final chain = operations
          .where(
            (op) =>
                op.entityType == operation.entityType &&
                op.entityId == operation.entityId,
          )
          .toList();
      final command = syncObject(jsonDecode(chain.last.operationJson));
      if (keepMine &&
          (_requiresMoveReview(chain) || conflict.code == 'entity_moved')) {
        throw const ApiFailure(
          'move_repreview_required',
          '账本移动需要重新选择目标并预览，不能直接重新提交旧移动。请先核对当前服务器记录，本机输入可复制保留。',
        );
      }
      final response = await widget.engine.currentForConflict(lease, operation);
      final event = decodeSyncEvent(response['event']);
      if (event.entityType != operation.entityType ||
          event.entityId != operation.entityId) {
        throw const FormatException('Conflict entity changed');
      }
      if (keepMine &&
          (response['editable_payload'] == null ||
              event.deleted ||
              event.scopeId != conflict.scopeId ||
              command['action'] == 'create')) {
        throw const ApiFailure(
          'not_editable',
          '此记录已删除、不可完整编辑或与新增记录重名。请复制本机内容，在账单编辑中核对后另存。',
        );
      }
      if (!mounted) return;
      if (!await _confirm(
        keepMine ? '保留我的修改' : '使用服务器版本',
        keepMine
            ? '将以刚刚读取的服务器版本为基准重新提交本机修改；如果再次发生冲突，会继续保留并提示。'
            : '将放弃这项记录尚未提交的本机修改，使用刚刚读取的服务器版本。',
      )) {
        return;
      }
      lease.check();
      if (keepMine) {
        await store.resolveWithNewCommand(
          lease.space,
          conflict.operationId,
          QueuedCommand(
            operationId: const Uuid().v4(),
            scopeId: conflict.scopeId,
            entityType: operation.entityType,
            entityId: operation.entityId,
            action: command['action'] as String,
            baseRevision: event.revision,
            payload: syncObject(jsonDecode(conflict.localJson)),
          ),
        );
        await widget.engine.synchronize(lease);
      } else {
        await store.acceptServerVersion(
          lease.space,
          conflict.operationId,
          event,
        );
      }
    });
  }

  Future<void> _reviewBackup(RecoveryBackup backup) => _perform(() async {
    final space = _space!;
    final differences = await store.recoveryDifferences(space, backup);
    if (!mounted || widget.app.space?.id != space.id) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RecoveryReviewPage(
          app: widget.app,
          spaceId: space.id,
          differences: differences,
        ),
      ),
    );
  });

  Widget _section(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final identity = widget.app.identity;
    final online = widget.app.canSync && !_busy;
    final recovery = _state?.status == 'recovery_required';
    final newClient = _state != null && _state!.clientId != identity?.clientId;
    return Scaffold(
      appBar: AppBar(title: const Text('同步与恢复')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16, top: 8),
                  child: Text(_message!, key: const Key('sync-message')),
                ),
              if (_space == null)
                const Text('登录账号后，可以同步资料并查看这个账号的恢复备份。')
              else ...[
                _section(
                  recovery
                      ? '需要恢复资料'
                      : _pending > 0
                      ? '有 $_pending 项待同步'
                      : '同步资料',
                  [
                    Text(
                      recovery
                          ? '本机备份已保存。恢复完成前，正式记录暂停修改；你仍可保存草稿。'
                          : '联网后核对服务器与本机修改。冲突会保留，等待你选择。',
                    ),
                    const SizedBox(height: 16),
                    if (!recovery)
                      FilledButton.icon(
                        onPressed: online ? _synchronize : null,
                        icon: const Icon(Icons.sync),
                        label: const Text('立即同步'),
                      ),
                    if (recovery && !newClient)
                      FilledButton(
                        onPressed: !_busy ? _startRecovery : null,
                        child: const Text('保留备份并重新登录'),
                      ),
                    if (recovery && newClient)
                      FilledButton(
                        onPressed: online ? _finishRecovery : null,
                        child: const Text('从服务器恢复'),
                      ),
                    if (!widget.app.canSync)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('当前无法联网同步，请到账号页登录或检查连接。'),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_conflicts.isNotEmpty)
                  _section('需要处理 · ${_conflicts.length}', [
                    for (final conflict in _conflicts)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              conflict.code == 'scope_revoked'
                                  ? '账本访问已撤销，本机输入已保留'
                                  : conflict.code == 'revision_conflict'
                                  ? '这项记录在其他设备上发生了变化'
                                  : '这项修改尚未被服务器接受',
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '本机内容：${_recordLabel(syncObject(jsonDecode(conflict.localJson)))}',
                            ),
                            if (conflict.serverJson != null)
                              Text(
                                '服务器内容：${_recordLabel(syncObject(jsonDecode(conflict.serverJson!)))}',
                              ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                TextButton(
                                  onPressed: () => _showCopy(
                                    context,
                                    '本机内容',
                                    conflict.localJson,
                                    app: widget.app,
                                    spaceId: _space!.id,
                                  ),
                                  child: const Text('查看与复制'),
                                ),
                                if ({
                                  'revision_conflict',
                                  'entity_moved',
                                  'entity_deleted',
                                }.contains(conflict.code)) ...[
                                  TextButton(
                                    onPressed: online && !recovery
                                        ? () => _resolve(conflict, false)
                                        : null,
                                    child: const Text('使用服务器版本'),
                                  ),
                                  if (conflict.code == 'revision_conflict' &&
                                      !_moveConflicts.contains(
                                        conflict.operationId,
                                      ))
                                    TextButton(
                                      onPressed: online && !recovery
                                          ? () => _resolve(conflict, true)
                                          : null,
                                      child: const Text('保留我的修改'),
                                    ),
                                  if (_moveConflicts.contains(
                                        conflict.operationId,
                                      ) ||
                                      conflict.code == 'entity_moved')
                                    const Text(
                                      '请核对当前服务器版本，再重新预览移动或编辑；本机输入仍可复制。',
                                    ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                  ]),
                if (_backups.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _section('恢复备份', [
                    const Text('备份包含恢复前的本机记录。可核对差异、查看并复制原始内容，旧账不会自动重新入账。'),
                    for (final backup in _backups)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_localDate(backup.createdAt)),
                        subtitle: const Text('核对缺失和变化的记录'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: !_busy ? () => _reviewBackup(backup) : null,
                      ),
                  ]),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

bool _requiresMoveReview(List<StoredOperation> chain) {
  final scopes = <Object?>{};
  for (final operation in chain) {
    final command = syncObject(jsonDecode(operation.operationJson));
    if (command['move'] != null) return true;
    scopes.add(command['scope_id']);
  }
  return scopes.length > 1;
}

class RecoveryReviewPage extends StatelessWidget {
  const RecoveryReviewPage({
    required this.app,
    required this.spaceId,
    required this.differences,
    super.key,
  });
  final AppController app;
  final String spaceId;
  final List<Map<String, Object?>> differences;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('核对恢复备份')),
      body: app.space?.id != spaceId
          ? const Center(child: Text('账号已切换，请返回当前账号。'))
          : differences.isEmpty
          ? const Center(child: Text('备份中的记录与当前资料一致。'))
          : ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: differences.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final row = differences[index];
                final local = syncObject(row['local']);
                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    title: Text(_recordLabel(local)),
                    subtitle: Text(switch (row['difference']) {
                      'missing' => '服务器中缺少此记录',
                      'deleted' => '服务器已删除此记录',
                      _ => '内容与服务器不同',
                    }),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showCopy(
                      context,
                      '恢复前的记录',
                      const JsonEncoder.withIndent('  ').convert(row),
                      app: app,
                      spaceId: spaceId,
                    ),
                  ),
                );
              },
            ),
    ),
  );
}

String _recordLabel(Map<String, Object?> raw) {
  final event = raw['event'];
  if (event is Map<String, Object?>) {
    return event['data'] == null
        ? '服务器已删除此记录'
        : _recordLabel(syncObject(event['data']));
  }
  final payload = raw['payload'];
  final data = payload is Map<String, Object?> ? payload : raw;
  final words = [
    data['name'],
    data['note'],
    data['business_date'],
  ].whereType<String>().where((v) => v.isNotEmpty).toList();
  final money = data['money'];
  if (money is Map &&
      money['amount_minor'] is String &&
      money['currency_scale'] is int) {
    final minor = money['amount_minor'] as String;
    final scale = money['currency_scale'] as int;
    if (scale >= 0 && scale <= 8 && RegExp(r'^-?[0-9]+$').hasMatch(minor)) {
      final digits = minor.replaceFirst('-', '').padLeft(scale + 1, '0');
      final formatted = scale == 0
          ? digits
          : '${digits.substring(0, digits.length - scale)}.${digits.substring(digits.length - scale)}';
      words.add(
        '${money['currency']} ${minor.startsWith('-') ? '-' : ''}$formatted',
      );
    }
  }
  return words.isEmpty ? '已保留记录，可查看完整内容' : words.join(' · ');
}

String _localDate(DateTime value) {
  final d = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

Future<void> _showCopy(
  BuildContext context,
  String title,
  String content, {
  required AppController app,
  required String spaceId,
}) => showDialog<void>(
  context: context,
  builder: (context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 600,
        child: app.space?.id == spaceId
            ? SingleChildScrollView(child: SelectableText(content))
            : const Text('账号已切换，此内容已隐藏。'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: app.space?.id != spaceId
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: content));
                  if (context.mounted) Navigator.pop(context);
                },
          child: const Text('复制内容'),
        ),
      ],
    ),
  ),
);
