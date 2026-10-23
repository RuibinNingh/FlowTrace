import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../local/app_database.dart';
import 'group_progress.dart';
import 'group_protocol.dart';
import 'group_store.dart';
import 'snapshot_protocol.dart';

typedef GroupRequest =
    Future<Map<String, Object?>> Function(
      String method,
      String path, {
      Map<String, Object?>? body,
      String? bodyJson,
    });

Map<String, Object?> _receive(StoredGroupPull pull) =>
    syncObject(jsonDecode(pull.receiveStateJson));

/// A bounded pull-only coordinator. Its caller owns the outer synchronization
/// mutex and identity/epoch recovery. This class never reads or publishes outbox.
final class GroupPullCoordinator {
  GroupPullCoordinator(this.store, {String Function()? newRequestId})
    : _newRequestId = newRequestId ?? const Uuid().v4;

  final GroupPullStore store;
  final String Function() _newRequestId;
  bool _running = false;

  Future<void> run({
    required DataSpace space,
    required String clientId,
    required String epoch,
    required bool Function() isCurrent,
    required GroupRequest request,
    required Future<Map<String, String>> Function() refreshPermissions,
    int maxSteps = 64,
    int maxPages = 128,
    bool requireFresh = false,
  }) async {
    if (maxSteps < 0 || maxSteps > 64 || maxPages < 0 || maxPages > 128) {
      throw ArgumentError('Invalid trusted group call budget');
    }
    if (_running) {
      throw const ApiFailure('sync_busy', '正在接收分组资料，请稍后再同步。');
    }
    _running = true;
    try {
      var remainingSteps = maxSteps, remainingPages = maxPages;
      // At most two older fixed pulls may exist. A post-mutation refresh must
      // finish them, then complete a pull created during this invocation. The
      // original total step/page budget still applies across all three runs.
      for (var attempt = 0; attempt < (requireFresh ? 3 : 1); attempt++) {
        final run = _GroupRun(
          store,
          space,
          clientId,
          epoch,
          isCurrent,
          request,
          refreshPermissions,
          _newRequestId,
          remainingSteps,
          remainingPages,
        );
        final fresh = await run.run();
        remainingSteps -= run.steps;
        remainingPages -= run.pages;
        if (!requireFresh || fresh) return;
      }
      throw const ApiFailure('group_pending', '最新资料尚未接收完成，已保存同步进度。');
    } finally {
      _running = false;
    }
  }
}

final class _GroupRun {
  _GroupRun(
    this.store,
    this.space,
    this.clientId,
    this.epoch,
    this.isCurrent,
    this.request,
    this.refreshPermissions,
    this.newRequestId,
    this.maxSteps,
    this.maxPages,
  );

  final GroupPullStore store;
  final DataSpace space;
  final String clientId;
  final String epoch;
  final bool Function() isCurrent;
  final GroupRequest request;
  final Future<Map<String, String>> Function() refreshPermissions;
  final String Function() newRequestId;
  final int maxSteps;
  final int maxPages;
  int steps = 0;
  int pages = 0;

  void check() {
    if (!isCurrent()) {
      throw const ApiFailure('identity_changed', '资料空间已切换，分组同步已停止。');
    }
  }

  Future<Map<String, Object?>> send(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? bodyJson,
  }) async {
    check();
    try {
      return await request(method, path, body: body, bodyJson: bodyJson);
    } finally {
      check();
    }
  }

  Never pending() =>
      throw const ApiFailure('group_pending', '分组资料尚未接收完成，进度已保存；再次同步即可继续。');

  Future<StoredGroupPull> current(String requestId) async {
    check();
    final pull = await store.read(space, requestId);
    check();
    if (pull == null) {
      throw const ApiFailure('permission_changed', '访问权限已变化，受控分组缓存已清除。');
    }
    return pull;
  }

  Future<String?> recoverHandle(StoredGroupPull pull) async {
    final listing = await send('GET', '/sync/group-pulls');
    if (listing.length != 1 || listing['pulls'] is! List) {
      throw const FormatException('Invalid owned group listing');
    }
    final summaries = listing['pulls'] as List;
    if (summaries.length > 2) {
      throw const FormatException('Too many owned group pulls');
    }
    String? match;
    final identifiers = <String>{};
    for (final raw in summaries) {
      final value = syncObject(raw);
      const keys = {
        'pull_id',
        'request_id',
        'client_id',
        'sync_epoch',
        'status',
        'expires_at',
      };
      if (value.length != keys.length ||
          !value.keys.toSet().containsAll(keys)) {
        throw const FormatException('Invalid group summary');
      }
      final handle = syncIdentifier(value['pull_id']);
      syncIdentifier(value['request_id']);
      syncIdentifier(value['client_id']);
      syncIdentifier(value['sync_epoch']);
      if (!identifiers.add(handle) ||
          !{
            'planning',
            'materializing',
            'ready',
            'failed',
          }.contains(value['status']) ||
          value['expires_at'] is! String) {
        throw const FormatException('Invalid group summary metadata');
      }
      if (value['request_id'] == pull.requestId &&
          value['client_id'] == pull.clientId &&
          value['sync_epoch'] == pull.epoch) {
        if (match != null) {
          throw const FormatException('Ambiguous recovered group handle');
        }
        match = handle;
      }
    }
    if (match != null) {
      await store.rememberHandle(
        space,
        pull.requestId,
        pullId: match,
        clientId: pull.clientId,
        epoch: pull.epoch,
        isCurrent: isCurrent,
      );
    }
    return match;
  }

  Future<void> discard(StoredGroupPull pull) async {
    final handle = pull.pullId ?? await recoverHandle(pull);
    if (handle != null) {
      await discardHandle(pull.requestId, handle);
    }
    await store.markServerCollected(
      space,
      pull.requestId,
      isCurrent: isCurrent,
    );
  }

  Future<void> discardHandle(String requestId, String handle) async {
    try {
      final response = await send(
        'POST',
        '/sync/group-pulls/$handle/discard',
        body: {'client_id': clientId},
      );
      if (response.length != 2 ||
          response['pull_id'] != handle ||
          response['status'] != 'collected') {
        throw const FormatException('Invalid group collection receipt');
      }
    } on ApiFailure catch (error) {
      if (error.code != 'not_found' || error.status != 404) rethrow;
    }
    await store.finishCleanup(space, requestId, handle, isCurrent: isCurrent);
  }

  Future<void> abandonAndDiscard(String requestId, String? handle) async {
    check();
    final pull = await store.read(space, requestId);
    if (pull != null) {
      await store.abandon(space, requestId, isCurrent: isCurrent);
      await discard(await current(requestId));
    } else if (handle != null) {
      // Permission refresh may already have removed the local controlled cache.
      // The captured, locally bound handle is still safe for owned cleanup.
      await discardHandle(requestId, handle);
    }
  }

  Future<GroupProgress> status(StoredGroupPull pull) async {
    final raw = await send(
      'GET',
      '/sync/group-pulls/${pull.pullId}?client_id=$clientId',
    );
    return accept(pull, raw);
  }

  Future<GroupProgress> accept(
    StoredGroupPull pull,
    Map<String, Object?> raw,
  ) async {
    final progress = GroupProgress.parse(raw);
    if (progress.requestId != pull.requestId ||
        progress.epoch != epoch ||
        (pull.pullId != null && progress.id != pull.pullId)) {
      throw const FormatException(
        'Group continuation belongs to another request',
      );
    }
    await store.rememberHandle(
      space,
      pull.requestId,
      pullId: progress.id,
      clientId: clientId,
      epoch: epoch,
      isCurrent: isCurrent,
    );
    if (progress.status == 'failed') {
      throw const ApiFailure('group_pull_failed', '服务端未完成此分组，请再次同步以重新接收。');
    }
    if (progress.status == 'expired' ||
        !DateTime.now().toUtc().isBefore(progress.expiresAt)) {
      throw const ApiFailure('group_pull_expired', '分组缓存已过期，请再次同步以重新接收。');
    }
    await store.rememberProgress(
      space,
      pull.requestId,
      progress,
      isCurrent: isCurrent,
    );
    return progress;
  }

  bool installable(StoredGroupPull pull) {
    final receive = _receive(pull);
    return receive['phase'] == 'complete' ||
        (receive['unit'] is int &&
            (receive['unit'] as int) > pull.installedUnits);
  }

  Future<bool> run() async {
    check();
    final local = await store.sync.state(space);
    check();
    if (local == null ||
        local.status != 'active' ||
        local.clientId != clientId ||
        local.epoch != epoch) {
      throw const ApiFailure('resync_required', '同步身份已变化，请先处理恢复提示。');
    }
    var collectedHistory = false;
    for (final binding in await store.listCleanup(space)) {
      final row = await store.read(space, binding.requestId);
      if (row != null &&
          row.clientId == clientId &&
          row.epoch == epoch &&
          row.pullId == binding.pullId &&
          !{'done', 'abandoned'}.contains(_receive(row)['phase'])) {
        continue; // Still resumable: an offline authorization check changes no pages.
      }
      await discardHandle(binding.requestId, binding.pullId);
      if (row != null && row.clientId == clientId && row.epoch == epoch) {
        await store.markServerCollected(
          space,
          row.requestId,
          isCurrent: isCurrent,
        );
      }
      collectedHistory = true;
    }
    final retained = await store.listActive(
      space,
      clientId: clientId,
      epoch: epoch,
    );
    StoredGroupPull? active;
    var collectedLocal = false;
    for (final pull in retained) {
      final phase = _receive(pull)['phase'];
      if (phase == 'done' || phase == 'abandoned') {
        await discard(pull);
        collectedLocal = true;
      } else {
        active ??= pull;
      }
    }
    if (active == null && (collectedLocal || collectedHistory)) {
      throw const ApiFailure('group_pending', '旧同步缓存已回收，再次同步获取最新资料。');
    }
    final resumed = active != null;
    if (active == null) {
      final state = (await store.sync.state(space))!;
      check();
      final requestId = syncIdentifier(newRequestId());
      if (await store.read(space, requestId) != null) {
        throw StateError('New group request UUID was already used');
      }
      active = await store.begin(
        space,
        requestId,
        clientId: clientId,
        epoch: epoch,
        cursors: syncVector(jsonDecode(state.cursorsJson)),
        isCurrent: isCurrent,
      );
    }
    final requestId = active.requestId;
    String? handle = active.pullId;
    try {
      if (handle == null && resumed) handle = await recoverHandle(active);
      GroupProgress progress;
      if (handle == null) {
        // The persisted canonical bytes, including the UUID/base, are the POST.
        final raw = await send(
          'POST',
          '/sync/group-pulls',
          bodyJson: active.intentJson,
        );
        progress = await accept(active, raw);
      } else {
        progress = await status(await current(requestId));
      }
      handle = progress.id;
      while (progress.status != 'ready') {
        if (steps >= maxSteps) pending();
        steps++;
        final raw = await send(
          'POST',
          '/sync/group-pulls/$handle/steps',
          body: {'client_id': clientId, 'step_token': progress.stepToken},
        );
        progress = await accept(await current(requestId), raw);
      }
      while (true) {
        final pull = await current(requestId);
        if (_receive(pull)['phase'] == 'done') {
          await discard(pull);
          return !resumed;
        }
        if (installable(pull)) {
          final fresh = await status(pull);
          if (fresh.status != 'ready') {
            throw const FormatException('Sealed group status regressed');
          }
          check();
          await store.stageCleanup(space, pull, isCurrent: isCurrent);
          final permissions = await refreshPermissions();
          check();
          await current(
            requestId,
          ); // The permission callback may revoke/cache-clear.
          final manifest = GroupManifest.fromStatus(fresh.body);
          if (canonicalSyncJson(permissions) !=
              canonicalSyncJson(manifest.permissions)) {
            throw const ApiFailure('permission_changed', '访问权限已变化，分组资料需重新接收。');
          }
          await store.installNext(
            space,
            requestId,
            authorizedManifest: manifest,
            permissionVersions: permissions,
            isCurrent: isCurrent,
          );
          await store.finishCleanup(
            space,
            requestId,
            manifest.id,
            isCurrent: isCurrent,
          );
          continue;
        }
        if (pages >= maxPages) pending();
        final token = pull.nextToken;
        if (token == null) {
          throw StateError('Group continuation page is absent');
        }
        pages++;
        final page = await send(
          'POST',
          '/sync/group-pulls/$handle/pages',
          body: {'client_id': clientId, 'page_token': token},
        );
        await store.receive(
          space,
          requestId,
          token,
          page,
          isCurrent: isCurrent,
        );
      }
    } on ApiFailure catch (error) {
      if ({
            'group_pull_expired',
            'group_pull_collected',
            'group_origin_changed',
            'group_pull_failed',
            'permission_changed',
          }.contains(error.code) ||
          (error.code == 'not_found' && error.status == 404)) {
        final latest = await store.read(space, requestId);
        await abandonAndDiscard(requestId, latest?.pullId ?? handle);
      }
      rethrow;
    }
  }
}
