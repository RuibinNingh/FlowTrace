import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../../features/identity/identity_controller.dart';
import '../diagnostics/client_diagnostics.dart';
import '../local/app_database.dart';
import 'group_engine.dart';
import 'group_store.dart';
import 'snapshot_protocol.dart';
import 'sync_store.dart';

typedef SyncRequest =
    Future<Map<String, Object?>> Function(
      String method,
      String path, {
      Map<String, Object?>? body,
      String? bodyJson,
    });

/// Every I/O call and application of its result belongs to one captured login.
final class SyncLease {
  SyncLease({
    required this.space,
    required this.clientId,
    required this.epoch,
    required this.request,
    required this.isCurrent,
    this.supportsGroupPull = false,
  });
  final DataSpace space;
  final String clientId;
  final String epoch;
  final SyncRequest request;
  final bool Function() isCurrent;
  final bool supportsGroupPull;

  factory SyncLease.capture(IdentityController identity) {
    final generation = identity.sessionGeneration;
    final space = identity.accountSpace;
    final client = identity.clientId;
    final epoch = identity.serverIdentity?.syncEpoch;
    if (!identity.online ||
        identity.busy ||
        space == null ||
        client == null ||
        epoch == null) {
      throw const ApiFailure('session_invalid', '请联网登录后同步。', status: 401);
    }
    return SyncLease(
      space: space,
      clientId: client,
      epoch: epoch,
      supportsGroupPull: identity.serverIdentity!.supportsGroupPull,
      isCurrent: () =>
          identity.sessionGeneration == generation &&
          identity.online &&
          !identity.busy &&
          identity.accountSpace?.id == space.id &&
          identity.clientId == client &&
          identity.serverIdentity?.syncEpoch == epoch,
      request: (method, path, {body, bodyJson}) {
        String? operationId;
        if (path == '/sync/push' && bodyJson != null) {
          final operations = syncObject(jsonDecode(bodyJson))['operations'];
          if (operations is List && operations.length == 1) {
            operationId =
                syncObject(operations.single)['operation_id'] as String?;
          }
        }
        return identity.authorizedRequest(
          method,
          path,
          body: body,
          bodyJson: bodyJson,
          expectedSpaceId: space.id,
          expectedClientId: client,
          expectedEpoch: epoch,
          diagnosticOperationId: operationId,
        );
      },
    );
  }

  void check() {
    if (!isCurrent()) {
      throw const ApiFailure('identity_changed', '资料空间已切换，同步已停止。');
    }
  }

  Future<Map<String, Object?>> send(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? bodyJson,
  }) async {
    check();
    final result = await request(method, path, body: body, bodyJson: bodyJson);
    check();
    return result;
  }
}

final class SyncReport {
  const SyncReport({
    required this.applied,
    required this.conflicts,
    required this.pending,
  });
  final int applied;
  final int conflicts;
  final int pending;
}

final class SyncEngine {
  SyncEngine(
    this.store, {
    this.onScopeRevoked,
    this.beforePush,
    ClientDiagnostics? diagnostics,
  }) : diagnostics = diagnostics ?? ClientDiagnostics(store.repository),
       _groups = GroupPullCoordinator(GroupPullStore(store));
  final SyncStore store;
  final ClientDiagnostics diagnostics;
  final GroupPullCoordinator _groups;
  final Future<void> Function(DataSpace space, String scopeId)? onScopeRevoked;
  final Future<void> Function(SyncLease lease, Map<String, Object?> command)?
  beforePush;
  Future<SyncReport>? _running;
  bool _rebuilding = false;
  bool _readingConflict = false;
  bool _refreshingScopes = false;
  bool _reconcilingReceipts = false;

  bool get busy =>
      _running != null ||
      _rebuilding ||
      _readingConflict ||
      _refreshingScopes ||
      _reconcilingReceipts;

  Future<SyncReport> synchronize(SyncLease lease) {
    if (_rebuilding) throw StateError('Recovery is already running');
    if (_readingConflict || _refreshingScopes || _reconcilingReceipts) {
      throw const ApiFailure('sync_busy', '正在核对记录或访问权限，请稍后再同步。');
    }
    // Coalesces duplicate taps on this coordinator. Each request still carries
    // a captured identity, so switching accounts cannot redirect a queue.
    return _running ??= _runLogged(lease).whenComplete(() => _running = null);
  }

  /// Refresh the authorized server projection without publishing local outbox.
  /// Used after a server-side import/undo; pending intent stays in its original
  /// queue and is replayed over the newly received confirmed projection.
  Future<void> pullLatest(
    SyncLease lease, {
    bool requireFreshGroup = false,
  }) async {
    if (busy) {
      throw const ApiFailure('sync_busy', '正在同步或核对记录，请稍后再刷新。');
    }
    _refreshingScopes = true;
    try {
      lease.check();
      if (requireFreshGroup && !lease.supportsGroupPull) {
        throw const ApiFailure('group_capability_required', '当前服务器尚未支持完整导入刷新。');
      }
      await store.configure(
        lease.space,
        lease.clientId,
        lease.epoch,
        isCurrent: lease.isCurrent,
      );
      lease.check();
      final versions = await _scopes(lease);
      final current = await store.state(lease.space);
      lease.check();
      if (current == null || current.status != 'active') {
        throw const ApiFailure('resync_required', '本机资料需要恢复，请先处理恢复提示。');
      }
      if (lease.supportsGroupPull) {
        await _groupPull(lease, requireFresh: requireFreshGroup);
      } else if (syncVector(jsonDecode(current.cursorsJson)).isEmpty) {
        await _snapshot(lease, versions);
      } else {
        await _pull(lease, versions.keys.toSet());
      }
      lease.check();
    } on ApiFailure catch (error) {
      if (error.code == 'permission_changed' ||
          error.code == 'scope_forbidden') {
        // A pull can lose authority after the initial scope response. Apply the
        // same immediate controlled-cache cleanup as ordinary synchronization.
        lease.check();
        await _scopes(lease);
      }
      if (_rebuildErrors.contains(error.code)) {
        lease.check();
        await store.requireRebuild(lease.space, error.code);
      }
      rethrow;
    } finally {
      _refreshingScopes = false;
    }
  }

  /// Refresh authorization through the same revocation, role-cache and recovery
  /// path as sync, without pushing pending changes or advancing pull cursors.
  Future<Map<String, String>> refreshScopes(SyncLease lease) async {
    if (_running != null ||
        _rebuilding ||
        _readingConflict ||
        _refreshingScopes ||
        _reconcilingReceipts) {
      throw const ApiFailure('sync_busy', '正在同步或核对记录，请稍后再核对访问权限。');
    }
    _refreshingScopes = true;
    try {
      lease.check();
      final current = await store.state(lease.space);
      lease.check();
      if (current == null || current.status != 'active') {
        throw const ApiFailure('resync_required', '本机资料需要恢复，请先处理恢复提示。');
      }
      if (current.epoch != lease.epoch) {
        throw const ApiFailure('epoch_changed', '服务器资料版本已变化，请先确认恢复。');
      }
      if (current.clientId != lease.clientId) {
        throw const ApiFailure('client_mismatch', '设备身份已变化，请先确认恢复。');
      }
      final versions = await _scopes(lease);
      lease.check();
      return Map.unmodifiable(versions);
    } on ApiFailure catch (error) {
      if (_rebuildErrors.contains(error.code)) {
        lease.check();
        final current = await store.state(lease.space);
        lease.check();
        if (current != null) {
          await store.requireRebuild(lease.space, error.code);
        }
      }
      rethrow;
    } finally {
      _refreshingScopes = false;
    }
  }

  /// Resolve only a server-confirmed, currently authorized public location.
  /// Reading a conflict never rebases, acknowledges or resubmits its intent.
  Future<Map<String, Object?>> currentForConflict(
    SyncLease lease,
    StoredOperation operation,
  ) async {
    if (_running != null ||
        _rebuilding ||
        _readingConflict ||
        _refreshingScopes ||
        _reconcilingReceipts) {
      throw const ApiFailure('sync_busy', '同步正在进行，请完成后再核对冲突记录。');
    }
    _readingConflict = true;
    try {
      lease.check();
      if (operation.spaceId != lease.space.id) {
        throw const ApiFailure('identity_changed', '资料空间已切换，冲突读取已停止。');
      }
      final state = await store.state(lease.space);
      lease.check();
      if (state == null || state.status != 'active') {
        throw const ApiFailure('resync_required', '本机资料需要恢复，请先处理恢复提示。');
      }
      if (state.epoch != lease.epoch) {
        throw const ApiFailure('epoch_changed', '服务器资料版本已变化，请先确认恢复。');
      }
      if (state.clientId != lease.clientId) {
        throw const ApiFailure('client_mismatch', '设备身份已变化，请先确认恢复。');
      }
      var allowed = await _scopes(lease);
      var candidate = await _conflictCandidate(lease, operation, allowed);
      final firstCandidate = candidate;
      String? attemptedScope;
      if (candidate != null) {
        attemptedScope = candidate.scopeId;
        try {
          return await _readConflictProjection(
            lease,
            operation,
            candidate,
            allowed,
          );
        } on ApiFailure catch (error) {
          if (!_relocatableReadFailure(error)) rethrow;
        }
      }
      // A record may move again between scope refresh and GET. Materialize one
      // fresh authorized pull; a second read requires a different confirmed
      // public location, never a guess based on the original command's scope.
      allowed = await _scopes(lease);
      await _authorizedPull(lease, allowed);
      candidate = await _conflictCandidate(lease, operation, allowed);
      if (candidate == null ||
          candidate.scopeId == attemptedScope ||
          (firstCandidate != null &&
              (BigInt.parse(candidate.revision) <
                      BigInt.parse(firstCandidate.revision) ||
                  (candidate.revision == firstCandidate.revision &&
                      candidate.deleted &&
                      !firstCandidate.deleted)))) {
        throw _conflictUnavailable;
      }
      try {
        return await _readConflictProjection(
          lease,
          operation,
          candidate,
          allowed,
        );
      } on ApiFailure catch (error) {
        if (!_relocatableReadFailure(error)) rethrow;
        if (error.status == 403) await _scopes(lease);
        throw _conflictUnavailable;
      }
    } on ApiFailure catch (error) {
      if (_rebuildErrors.contains(error.code)) {
        lease.check();
        final current = await store.state(lease.space);
        lease.check();
        if (current != null) {
          await store.requireRebuild(lease.space, error.code);
        }
      } else if (error.code == 'permission_changed') {
        await _scopes(lease);
      }
      rethrow;
    } finally {
      _readingConflict = false;
    }
  }

  static const _conflictUnavailable = ApiFailure(
    'conflict_current_unavailable',
    '当前记录版本暂时无法定位，请先同步后重试。本机修改已保留。',
  );

  static bool _relocatableReadFailure(ApiFailure error) =>
      !error.offline &&
      error.code != 'identity_changed' &&
      !_rebuildErrors.contains(error.code) &&
      (error.status == 403 || error.status == 404);

  Future<SyncEvent?> _conflictCandidate(
    SyncLease lease,
    StoredOperation operation,
    Map<String, String> allowed,
  ) async {
    lease.check();
    final candidate = await store.latestPublicProjection(
      lease.space,
      operation.entityType,
      operation.entityId,
    );
    lease.check();
    if (candidate == null ||
        !allowed.containsKey(candidate.scopeId) ||
        candidate.data['projection_kind'] == 'bill_private_finance' ||
        (operation.entityType == 'bill' &&
            candidate.scopeId == lease.space.userId)) {
      return null;
    }
    return candidate;
  }

  Future<Map<String, Object?>> _readConflictProjection(
    SyncLease lease,
    StoredOperation operation,
    SyncEvent candidate,
    Map<String, String> allowed,
  ) async {
    final response = await lease.send(
      'GET',
      '/sync/entities/${operation.entityType}/${operation.entityId}?scope_id=${candidate.scopeId}',
    );
    final event = decodeSyncEvent(response['event']);
    final editable = response['editable_payload'];
    final kind = event.data['projection_kind'];
    if (event.entityType != operation.entityType ||
        event.entityId != operation.entityId ||
        event.scopeId != candidate.scopeId ||
        !allowed.containsKey(event.scopeId) ||
        event.data['projection_kind'] == 'bill_private_finance' ||
        (event.entityType == 'bill' && event.scopeId == lease.space.userId) ||
        BigInt.parse(event.revision) < BigInt.parse(candidate.revision) ||
        (!event.deleted &&
            kind !=
                (event.entityType == 'bill'
                    ? 'bill_public'
                    : event.entityType)) ||
        !response.containsKey('editable_payload') ||
        (event.deleted && editable != null) ||
        (editable != null && editable is! Map<String, Object?>)) {
      throw const FormatException('Conflict current projection mismatch');
    }
    if (!event.deleted &&
        event.entityType == 'bill' &&
        syncObject(event.data['payload'])['book_id'] != event.scopeId) {
      throw const FormatException('Conflict current book mismatch');
    }
    lease.check();
    return response;
  }

  Future<SyncReport> _runLogged(SyncLease lease) async {
    await diagnostics.recordQuietly(
      lease.space,
      'sync_started',
      category: 'sync',
    );
    try {
      final report = await _run(lease);
      await diagnostics.recordQuietly(
        lease.space,
        'sync_completed',
        category: 'sync',
      );
      return report;
    } catch (error) {
      await diagnostics.recordQuietly(
        lease.space,
        'sync_failed',
        category: 'sync',
        code: error is ApiFailure ? error.code : 'sync_failed',
        status: error is ApiFailure ? error.status : null,
      );
      rethrow;
    }
  }

  Future<Map<String, String>> _scopes(SyncLease lease) async {
    final response = await lease.send('GET', '/sync/scopes');
    if (response['sync_epoch'] != lease.epoch) {
      await store.requireRebuild(lease.space, 'epoch_changed');
      throw const ApiFailure('epoch_changed', '服务器资料版本已变化，本机数据已备份，需确认恢复。');
    }
    final rawScopes = response['scopes'];
    final rawRevoked = response['revoked_scope_ids'];
    if (rawScopes is! List ||
        rawScopes.length > 1000 ||
        rawRevoked is! List ||
        response['requires_rebuild'] is! bool) {
      throw const FormatException('Invalid scope response');
    }
    final versions = <String, String>{};
    final scopeDetails = <Map<String, Object?>>[];
    for (final raw in rawScopes) {
      final scope = syncObject(raw);
      final id = syncIdentifier(scope['scope_id']);
      if (versions.containsKey(id) ||
          !{'user', 'book'}.contains(scope['kind']) ||
          !{'owner', 'editor', 'viewer'}.contains(scope['role'])) {
        throw const FormatException('Invalid scope');
      }
      syncRevision(scope['revision']);
      versions[id] = syncRevision(scope['permission_version']);
      scopeDetails.add({
        'scope_id': id,
        'kind': scope['kind'],
        'role': scope['role'],
        'permission_version': versions[id],
      });
    }
    if (!versions.containsKey(lease.space.userId)) {
      throw const FormatException('Missing personal scope');
    }
    final prior = await store.repository.readSetting(
      'sync.scopes.${lease.space.id}',
    );
    final oldVersions = prior == null
        ? <String, String>{}
        : syncVector(jsonDecode(prior));
    final old = oldVersions.keys.toSet();
    final current = await store.state(lease.space);
    if (current != null) {
      old.addAll(syncVector(jsonDecode(current.cursorsJson)).keys);
    }
    final revoked = {
      ...old.difference(versions.keys.toSet()),
      ...rawRevoked.map(syncIdentifier),
    };
    lease.check();
    for (final id in revoked) {
      await store.revokeScope(lease.space, id);
    }
    // Repeat a previous revocation cleanup after an interrupted process. The
    // SQLite cache removal commits before filesystem deletion can complete.
    final cleanup = {
      ...revoked,
      if (current != null)
        ...(jsonDecode(current.revokedScopesJson) as List).cast<String>(),
    }.difference(versions.keys.toSet());
    for (final id in cleanup) {
      lease.check();
      await onScopeRevoked?.call(lease.space, id);
    }
    await store.restoreScopeAccess(lease.space, versions.keys.toSet());
    lease.check();
    await store.db.atomicWrite(() async {
      for (final entry in versions.entries) {
        if (oldVersions.containsKey(entry.key) &&
            oldVersions[entry.key] != entry.value) {
          await store.invalidateReceiptEvidenceForScope(lease.space, entry.key);
        }
      }
      await store.repository.writeSetting(
        'sync.scopes.${lease.space.id}',
        canonicalSyncJson(versions),
      );
      await store.repository.writeSetting(
        'sync.scope-details.${lease.space.id}',
        canonicalSyncJson({
          'version': 1,
          'epoch': lease.epoch,
          'scopes': scopeDetails,
        }),
      );
    });
    if (response['requires_rebuild'] == true) {
      await store.requireRebuild(lease.space, 'resync_required');
      throw const ApiFailure('resync_required', '此设备需要重建同步资料，本机数据已保留。');
    }
    return versions;
  }

  Future<SyncReport> _run(SyncLease lease) async {
    lease.check();
    await store.configure(lease.space, lease.clientId, lease.epoch);
    try {
      final scopes = await _scopes(lease);
      final current = await store.state(lease.space);
      if (current == null || current.status != 'active') {
        throw const ApiFailure('resync_required', '本机备份已保留，请先处理恢复。');
      }
      if (lease.supportsGroupPull) {
        await _groupPull(lease);
      } else if (syncVector(jsonDecode(current.cursorsJson)).isEmpty) {
        await _snapshot(lease, scopes);
      } else {
        await _pull(lease, scopes.keys.toSet());
      }
      var applied = 0;
      // Bounded work per foreground request. Remaining work is visible and can
      // continue on the next user/foreground trigger without a tight retry loop.
      for (var n = 0; n < 100; n++) {
        lease.check();
        final frozen = await store.nextPush(lease.space);
        if (frozen == null) break;
        final outgoing = syncObject(
          (syncObject(jsonDecode(frozen.body))['operations'] as List).single,
        );
        try {
          lease.check();
          await beforePush?.call(lease, outgoing);
          lease.check();
        } catch (error) {
          // Attachment/storage preflight failure is not a server rejection of
          // this financial command. Keep the original intent and frozen bytes.
          await store.retryLater(
            lease.space,
            frozen.operationId,
            error is ApiFailure ? error.code : 'preflight_failed',
          );
          rethrow;
        }
        try {
          final response = await lease.send(
            'POST',
            '/sync/push',
            bodyJson: frozen.body,
          );
          final results = response['results'];
          if (results is! List || results.length != 1) {
            throw const FormatException('Invalid push receipt');
          }
          final receipt = syncObject(results.single);
          final command = syncObject(
            (syncObject(jsonDecode(frozen.body))['operations'] as List).single,
          );
          if (receipt['operation_id'] != frozen.operationId) {
            throw const FormatException('Wrong operation receipt');
          }
          if (receipt['status'] == 'applied') {
            if (receipt['entity_id'] != command['entity_id']) {
              throw const FormatException('Wrong entity receipt');
            }
            await store.acknowledgeApplied(
              lease.space,
              frozen,
              receipt,
              clientId: lease.clientId,
              epoch: lease.epoch,
              isCurrent: lease.isCurrent,
            );
            await diagnostics.recordQuietly(
              lease.space,
              'sync_receipt',
              operationId: frozen.operationId,
              scopeId: command['scope_id'] as String,
              entityId: command['entity_id'] as String,
              category: 'sync',
              status: 200,
            );
            applied++;
          } else if (receipt['status'] == 'rejected') {
            final error = syncObject(receipt['error']);
            if (error['code'] is! String || error['http_status'] is! int) {
              throw const FormatException('Invalid rejection');
            }
            throw ApiFailure.server(
              error['code'] as String,
              error['http_status'] as int,
            );
          } else {
            throw const FormatException('Unknown receipt status');
          }
        } on ApiFailure catch (error) {
          await store.retryLater(lease.space, frozen.operationId, error.code);
          if (error.offline ||
              error.status == 401 ||
              error.status == 429 ||
              (error.status ?? 0) >= 500 ||
              error.code == 'identity_changed' ||
              _rebuildErrors.contains(error.code)) {
            rethrow;
          }
          lease.check();
          Map<String, Object?>? server;
          final command = syncObject(
            (syncObject(jsonDecode(frozen.body))['operations'] as List).single,
          );
          if (error.code == 'revision_conflict') {
            try {
              server = await lease.send(
                'GET',
                '/sync/entities/${command['entity_type']}/${command['entity_id']}?scope_id=${command['scope_id']}',
              );
            } on ApiFailure catch (readError) {
              if (readError.code == 'identity_changed' ||
                  readError.status == 401 ||
                  _rebuildErrors.contains(readError.code)) {
                rethrow;
              }
              if (readError.status == 403 || readError.status == 404) {
                await _scopes(lease);
              }
            }
          }
          await store.reject(
            lease.space,
            frozen.operationId,
            error.code,
            authorizedServer: server,
          );
          await diagnostics.recordQuietly(
            lease.space,
            'sync_conflict',
            operationId: frozen.operationId,
            scopeId: command['scope_id'] as String,
            entityId: command['entity_id'] as String,
            code: error.code,
            category: 'sync',
          );
          if (error.status == 403 || error.status == 404) await _scopes(lease);
        } on FormatException {
          await store.retryLater(
            lease.space,
            frozen.operationId,
            'invalid_response',
          );
          rethrow;
        }
      }
      final fresh = await _scopes(lease);
      await _authorizedPull(lease, fresh);
      return SyncReport(
        applied: applied,
        conflicts: (await store.conflicts(lease.space)).length,
        pending: (await store.repository.pending(lease.space)).length,
      );
    } on ApiFailure catch (error) {
      if (error.code == 'permission_changed' ||
          error.code == 'scope_forbidden') {
        // A page can become invalid after earlier complete commits were
        // applied. Refresh authorization now, rather than retaining revoked
        // cache until the next manual sync.
        await _scopes(lease);
      }
      if (_rebuildErrors.contains(error.code)) {
        await store.requireRebuild(lease.space, error.code);
      }
      rethrow;
    }
  }

  static const _rebuildErrors = {
    'epoch_changed',
    'resync_required',
    'invalid_cursor',
    'client_mismatch',
  };

  /// Explicitly repair legacy missing proofs through a read-only server receipt
  /// lookup. It never resubmits money writes, invents a new ID, or uses a new
  /// identity. Missing/expired/unauthorized receipts remain recoverable errors.
  Future<int> reconcileAppliedReceipts(
    SyncLease lease,
    List<String> operationIds,
  ) async {
    if (_running != null ||
        _rebuilding ||
        _readingConflict ||
        _refreshingScopes ||
        _reconcilingReceipts) {
      throw const ApiFailure('sync_busy', '同步正在进行，请稍后核对回执。');
    }
    if (operationIds.isEmpty ||
        operationIds.length > 100 ||
        operationIds.toSet().length != operationIds.length) {
      throw ArgumentError('Choose one to 100 distinct receipt operations');
    }
    _reconcilingReceipts = true;
    try {
      lease.check();
      final current = await store.state(lease.space);
      if (current == null ||
          current.status != 'active' ||
          current.clientId != lease.clientId ||
          current.epoch != lease.epoch) {
        throw const ApiFailure(
          'receipt_recovery_required',
          '同步身份已变化，请先核对恢复备份。',
        );
      }
      final scopes = await _scopes(lease);
      var repaired = 0;
      for (final id in operationIds) {
        syncIdentifier(id);
        lease.check();
        final operation =
            await (store.db.select(store.db.pendingOperations)..where(
                  (row) =>
                      row.spaceId.equals(lease.space.id) &
                      row.operationId.equals(id),
                ))
                .getSingleOrNull();
        if (operation == null ||
            operation.state != 'applied' ||
            operation.frozenRequestJson == null) {
          throw const ApiFailure(
            'receipt_proof_unavailable',
            '原确认请求不可用，请保留备份后重建资料。',
          );
        }
        final frozen = FrozenPush(
          id,
          operation.frozenRequestJson!,
          operation.attemptCount,
        );
        final request = syncObject(jsonDecode(frozen.body));
        final command = syncObject((request['operations'] as List).single);
        if (request['client_id'] != lease.clientId ||
            request['sync_epoch'] != lease.epoch) {
          throw const ApiFailure(
            'receipt_identity_mismatch',
            '旧身份回执只能核对备份，不能跨身份重放。',
          );
        }
        if (!scopes.containsKey(command['scope_id']) ||
            command['move'] is Map &&
                !scopes.containsKey(
                  (command['move'] as Map)['target_scope_id'],
                )) {
          throw const ApiFailure(
            'receipt_scope_forbidden',
            '原操作权限已变化，请重新核对可访问资料。',
          );
        }
        final response = await lease.send(
          'POST',
          '/sync/receipts/lookup',
          bodyJson: frozen.body,
        );
        final results = response['results'];
        if (results is! List || results.length != 1) {
          throw const FormatException('Invalid receipt lookup response');
        }
        final receipt = syncObject(results.single);
        if (receipt['status'] != 'applied' ||
            receipt['replayed'] != true ||
            receipt['revision'] != operation.appliedRevision) {
          throw const FormatException(
            'Lookup must return the same original Applied receipt',
          );
        }
        await store.acknowledgeApplied(
          lease.space,
          frozen,
          receipt,
          clientId: lease.clientId,
          epoch: lease.epoch,
          isCurrent: lease.isCurrent,
        );
        repaired++;
      }
      return repaired;
    } on ApiFailure catch (error) {
      if (_rebuildErrors.contains(error.code)) {
        await store.requireRebuild(lease.space, error.code);
      }
      rethrow;
    } finally {
      _reconcilingReceipts = false;
    }
  }

  Future<void> _groupPull(SyncLease lease, {bool requireFresh = false}) =>
      _groups.run(
        space: lease.space,
        clientId: lease.clientId,
        epoch: lease.epoch,
        isCurrent: lease.isCurrent,
        request: lease.send,
        refreshPermissions: () => _scopes(lease),
        requireFresh: requireFresh,
      );

  Future<void> _authorizedPull(SyncLease lease, Map<String, String> scopes) =>
      lease.supportsGroupPull
      ? _groupPull(lease)
      : _pull(lease, scopes.keys.toSet());

  Future<void> _pull(SyncLease lease, Set<String> scopes) async {
    final current = (await store.state(lease.space))!;
    final old = syncVector(jsonDecode(current.cursorsJson));
    final cursors = {for (final scope in scopes) scope: old[scope] ?? '0'};
    String? token;
    final tokens = <String>{};
    for (var page = 0; page < 1000; page++) {
      final response = await lease.send(
        'POST',
        '/sync/pull',
        body: {
          'sync_epoch': lease.epoch,
          'cursors': cursors,
          'limit': 200,
          'page_token': token,
        },
      );
      if (response['sync_epoch'] != lease.epoch ||
          response['commits'] is! List) {
        throw const FormatException('Invalid pull response');
      }
      final commits = <List<SyncEvent>>[];
      for (final raw in response['commits'] as List) {
        final commit = syncObject(raw);
        syncIdentifier(commit['commit_id']);
        final items = commit['events'];
        if (items is! List || items.isEmpty || items.length > 200) {
          throw const FormatException('Invalid complete commit');
        }
        final events = items.map(decodeSyncEvent).toList();
        if (events.any((e) => !scopes.contains(e.scopeId))) {
          throw const FormatException('Unexpected event scope');
        }
        commits.add(events);
      }
      final next = response['next_page_token'];
      if (next != null &&
          (next is! String || next.isEmpty || !tokens.add(next))) {
        throw const FormatException('Invalid next page');
      }
      final checkpoint = next == null
          ? syncVector(response['checkpoint'])
          : null;
      if (next != null && response['checkpoint'] != null ||
          checkpoint != null &&
              (checkpoint.length != cursors.length ||
                  checkpoint.keys.toSet().difference(scopes).isNotEmpty)) {
        throw const FormatException('Invalid pull checkpoint');
      }
      lease.check();
      await store.applyPullPage(
        lease.space,
        lease.epoch,
        commits,
        finalPage: next == null,
        checkpoint: checkpoint,
      );
      if (next == null) return;
      token = next as String;
    }
    throw const FormatException('Pull page limit exceeded');
  }

  Future<void> rebuildFromServer(SyncLease lease) async {
    if (_running != null ||
        _rebuilding ||
        _readingConflict ||
        _refreshingScopes ||
        _reconcilingReceipts) {
      throw StateError('Sync is already running');
    }
    _rebuilding = true;
    try {
      lease.check();
      final current = await store.state(lease.space);
      if (current == null ||
          current.status != 'recovery_required' ||
          current.clientId == lease.clientId) {
        throw StateError(
          'Explicit recovery requires a new authenticated client',
        );
      }
      final scopes = await _scopes(lease);
      await _snapshot(lease, scopes, recovery: true);
    } on ApiFailure catch (error) {
      if (error.code == 'permission_changed' ||
          error.code == 'scope_forbidden') {
        await _scopes(lease);
      }
      rethrow;
    } finally {
      _rebuilding = false;
    }
  }

  Future<void> _snapshot(
    SyncLease lease,
    Map<String, String> scopes, {
    bool recovery = false,
  }) async {
    final status = await lease.send(
      'POST',
      '/sync/snapshots',
      body: {
        'protocol_version': 1,
        'client_id': lease.clientId,
        'sync_epoch': lease.epoch,
        'scope_ids': scopes.keys.toList()..sort(),
      },
    );
    final manifest = SnapshotManifest.fromStatus(status);
    manifest.checkIdentity(lease.space.serverInstanceId, lease.epoch);
    if (canonicalSyncJson(scopes) !=
        canonicalSyncJson(manifest.permissionVersions)) {
      throw const ApiFailure('permission_changed', '权限已变化，请重新同步。');
    }
    var token = status['first_page_token'];
    final seen = <String>{};
    for (var index = 0; index < manifest.pages.length; index++) {
      if (token is! String || token.isEmpty || !seen.add(token)) {
        throw const FormatException('Invalid snapshot token');
      }
      final response = await lease.send(
        'POST',
        '/sync/snapshots/${manifest.id}/pages',
        body: {'client_id': lease.clientId, 'page_token': token},
      );
      if (response['snapshot_id'] != manifest.id ||
          response['page_index'] != index ||
          response['items'] is! List ||
          response['page_sha256'] is! String) {
        throw const FormatException('Invalid snapshot page');
      }
      lease.check();
      await store.stageSnapshotPage(
        lease.space,
        manifest,
        index,
        response['items'] as List,
        response['page_sha256'] as String,
      );
      token = response['next_page_token'];
    }
    if (token != null) {
      throw const FormatException('Snapshot has unexpected pages');
    }
    final fresh = await _scopes(lease);
    lease.check();
    await store.installSnapshot(
      lease.space,
      manifest,
      clientId: lease.clientId,
      permissionVersions: fresh,
      allowRecovery: recovery,
    );
  }
}
