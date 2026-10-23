import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/network/api_failure.dart';
import '../local/app_database.dart';
import 'data_tools_models.dart';
import 'stage_import_lease.dart';
import 'stage_import_jobs.dart';
import 'stage_import_mapping.dart';
import 'stage_import_models.dart';
import 'stage_import_mutation_models.dart';
import 'stage_import_requirements.dart';
import 'stage_import_reauthorization.dart';
import 'stage_import_store.dart';

typedef StageProjectionRefresh = Future<void> Function(StageImportLease lease);

final class StageImportReauthorizationPlan {
  const StageImportReauthorizationPlan._(
    this.record,
    this.metadata,
    this.sessionId,
    this.clientId,
    this.epoch,
  );
  final StageImportRecord record;
  final StageImportReauthorization metadata;
  final String sessionId, clientId, epoch;
}

/// Each entry is an explicit user action. All write bodies are frozen before
/// HTTP; job responses remain metadata until a fresh stage GET proves a result.
final class StageImportCommands {
  StageImportCommands(this.store, {required this.refreshProjection});
  final StageImportStore store;
  final StageProjectionRefresh refreshProjection;
  static const _uuid = Uuid();

  Future<Map<String, Object?>> _request(
    StageImportLease lease,
    String method,
    String path, {
    String? bodyJson,
  }) async {
    lease.requireCapability();
    try {
      return await lease.data.request(method, path, bodyJson: bodyJson);
    } finally {
      lease.check();
    }
  }

  Future<StageImportStatus> _remote(
    StageImportLease lease,
    String stageId,
  ) async => StageImportStatus.parse(
    await _request(lease, 'GET', '/data-tools/import-stages/$stageId'),
  );

  void _sameSource(StageImportRecord record, StageImportStatus remote) {
    if (remote.stageId != record.stageId ||
        remote.batchId != record.batchId ||
        remote.expectedBytes != record.stored.expectedBytes ||
        remote.body['format'] != record.stored.format) {
      throw const ApiFailure('stage_remote_changed', '远端文件来源已变化，原始文件与请求保持。');
    }
  }

  void _completeRequirements(
    StageImportRecord record,
    StageImportRequirementsReader reader,
  ) {
    if (!reader.complete ||
        reader.record.stageId != record.stageId ||
        reader.record.stored.spaceId != record.stored.spaceId ||
        reader.record.version != record.version ||
        reader.hash != record.remote?.body['requirements_hash'] ||
        reader.count != record.remote?.body['requirements_count']) {
      throw const ApiFailure(
        'stage_requirements_incomplete',
        '请完整读取并核对当前版本的原始资源清单，再确认选择。',
      );
    }
  }

  Future<StageImportJobs> jobs(
    StageImportLease lease,
    String stageId,
  ) => store.track(() async {
    final record = await store.require(lease, stageId);
    final result = StageImportJobs.parse(
      await _request(
        lease,
        'GET',
        '/data-tools/import-stages/$stageId/jobs?stage_version=${record.version}',
      ),
    );
    final current = await store.require(lease, stageId);
    if (result.stageId != stageId ||
        result.version != record.version ||
        current.version != record.version ||
        current.batchId != record.batchId) {
      throw const ApiFailure('stage_remote_changed', '文件版本已变化，请刷新服务器状态。');
    }
    return result;
  });

  Future<StageImportReauthorizationPlan> inspectReauthorization(
    StageImportLease lease,
    String stageId,
  ) => store.track(() async {
    lease.requireCapability();
    final record = await store.read(lease.data.space, dataToolsUuid(stageId));
    if (record == null) {
      throw const ApiFailure('stage_local_missing', '本机原始文件不存在。');
    }
    final metadata = StageImportReauthorization.parse(
      await _request(
        lease,
        'GET',
        '/data-tools/import-stages/$stageId/reauthorization',
      ),
    );
    if (record.stored.epoch != lease.data.epoch ||
        metadata.stageId != stageId ||
        (record.batchId != null && metadata.batchId != record.batchId) ||
        metadata.sourceSha256 != record.stored.sourceSha256 ||
        metadata.expectedBytes != record.stored.expectedBytes ||
        metadata.format != record.stored.format ||
        metadata.version < record.version) {
      throw const ApiFailure(
        'stage_reauthorization_conflict',
        '服务器原件与本机来源不一致，原文件保持。',
      );
    }
    return StageImportReauthorizationPlan._(
      record,
      metadata,
      lease.sessionId,
      lease.data.clientId,
      lease.data.epoch,
    );
  });

  /// The caller shows this plan and obtains an explicit user confirmation.
  /// A probe alone never changes the local origin, even after a lost response.
  Future<StageImportRecord> confirmReauthorization(
    StageImportLease lease,
    StageImportReauthorizationPlan plan,
  ) => store.track(() async {
    lease.requireCapability();
    if (lease.sessionId != plan.sessionId ||
        lease.data.clientId != plan.clientId ||
        lease.data.epoch != plan.epoch ||
        lease.data.space.id != plan.record.stored.spaceId) {
      throw const ApiFailure('identity_changed', '确认期间账号已变化，请重新核对原件。');
    }
    final current = await store.read(lease.data.space, plan.record.stageId);
    if (current == null ||
        current.stored.stateJson != plan.record.stored.stateJson) {
      throw const ApiFailure('stage_local_changed', '本机文件状态已变化，请重新核对。');
    }
    final latest = await inspectReauthorization(lease, current.stageId);
    if (latest.metadata.encoded != plan.metadata.encoded) {
      throw const ApiFailure(
        'stage_reauthorization_conflict',
        '服务器文件状态已变化，请重新核对并确认。',
      );
    }
    var command = await store.pendingReauthorization(lease, current.stageId);
    if (command != null &&
        latest.metadata.version == command.stageVersion + 1) {
      // Another session may have won the CAS. Only a successful strict ordinary
      // GET proves this exact current session/client owns the resulting origin.
      final remote = await _remote(lease, current.stageId);
      return store.acceptReauthorization(
        lease,
        current,
        latest.metadata,
        command,
        remote,
      );
    }
    if (command != null && latest.metadata.version != command.stageVersion) {
      throw const ApiFailure(
        'stage_reauthorization_conflict',
        '原重新授权请求已有其他版本进展，原件和请求保持。',
      );
    }
    command ??= await store.prepareReauthorization(
      lease,
      current.stageId,
      latest.metadata,
    );
    final response = StageImportStatus.parse(
      await _request(
        lease,
        'POST',
        '/data-tools/import-stages/${current.stageId}/reauthorize',
        bodyJson: command.bodyJson,
      ),
    );
    if (response.version != command.stageVersion + 1 ||
        response.stageId != current.stageId) {
      throw const FormatException('重新授权版本回执不匹配。');
    }
    final remote = await _remote(lease, current.stageId);
    return store.acceptReauthorization(
      lease,
      current,
      latest.metadata,
      command,
      remote,
    );
  });

  /// Explicit owner cleanup is allowed across old origins. It never changes
  /// the binding or replays a financial command, even when the source expired.
  Future<StageImportRecord> discard(
    StageImportLease lease,
    StageImportReauthorizationPlan plan,
  ) => store.track(() async {
    lease.requireCapability();
    if (lease.sessionId != plan.sessionId ||
        lease.data.clientId != plan.clientId ||
        lease.data.epoch != plan.epoch ||
        lease.data.space.id != plan.record.stored.spaceId) {
      throw const ApiFailure('identity_changed', '确认期间账号已变化，请重新核对原件。');
    }
    final latest = await inspectReauthorization(lease, plan.record.stageId);
    if (latest.metadata.encoded != plan.metadata.encoded ||
        latest.record.stored.stateJson != plan.record.stored.stateJson) {
      throw const ApiFailure('stage_discard_conflict', '文件状态已变化，请重新核对并确认放弃。');
    }
    final command = await store.prepareOwnerDiscard(
      lease,
      plan.record,
      latest.metadata,
    );
    final response = StageImportStatus.parse(
      await _request(
        lease,
        'POST',
        '/data-tools/import-stages/${plan.record.stageId}/discard',
        bodyJson: command.bodyJson,
      ),
    );
    return store.acceptOwnerDiscard(
      lease,
      plan.record,
      latest.metadata,
      command,
      response,
    );
  });

  Future<StageImportRecord> _advance(
    StageImportLease lease,
    StageImportRecord record,
    StoredStageImportCommand command,
    StageImportStatus remote,
  ) => store.db.atomicWrite(() async {
    _sameSource(record, remote);
    if (remote.version != record.version + 1) {
      throw const ApiFailure('stage_remote_changed', '远端版本已变化，原请求保留，请重新核对。');
    }
    await store.acknowledgeCommand(lease, record, command, remote.body);
    final next = {
      ...record.state,
      'stage_version': remote.version,
      'next_chunk': remote.receivedChunks,
      'remote_status': remote.body,
      'projection_version': null,
    };
    return store.update(lease, record, next);
  });

  Future<StageImportRecord> changeMapping(
    StageImportLease lease,
    String stageId,
    Map<String, Object?> mapping,
    StageImportRequirementsReader requirements,
  ) => store.track(() async {
    lease.requireCapability();
    var record = await store.require(lease, stageId);
    _completeRequirements(record, requirements);
    if (record.remote?.sourceReleased == true ||
        {
          'applying',
          'applied',
          'undoing',
          'undone',
          'cancelled',
        }.contains(record.remote?.status)) {
      throw const ApiFailure('stage_mapping_locked', '该文件已进入正式处理，不能修改资源选择。');
    }
    final desired = stageMapping(mapping);
    final hash = stageMappingHash(desired);
    final command = await store.freezeCommand(lease, record, 'mapping', {
      'stage_version': record.version,
      'mapping': desired,
    });
    var remote = await _remote(lease, stageId);
    _sameSource(record, remote);
    if (remote.version == record.version + 1 &&
        remote.body['mapping_hash'] == hash) {
      // Only this durable, exact vN command may reconcile desired state vN+1.
      return _advance(lease, record, command, remote);
    }
    if (remote.version != record.version) {
      throw const ApiFailure(
        'stage_remote_changed',
        '资源选择已在其他操作中变化，原选择已保留，请重新核对。',
      );
    }
    record = await store.acceptStatus(lease, record, remote);
    remote = StageImportStatus.parse(
      await _request(
        lease,
        'PUT',
        '/data-tools/import-stages/$stageId/mapping',
        bodyJson: command.bodyJson,
      ),
    );
    if (remote.body['mapping_hash'] != hash) {
      throw const FormatException('资源选择确认摘要不匹配。');
    }
    return _advance(lease, record, command, remote);
  });

  Future<void> _ackJob(
    StageImportLease lease,
    StageImportRecord record,
    StoredStageImportCommand command,
    StageImportJob job,
  ) async {
    if (job.stageId != record.stageId || job.version != record.version) {
      throw const FormatException('正式作业回执与文件版本不匹配。');
    }
    final old = await store.freezeCommand(
      lease,
      record,
      command.kind,
      dataToolsObject(jsonDecode(command.bodyJson)),
      commandId: command.commandId,
    );
    var receipt = job.body;
    if (old.responseJson != null) {
      final previous = StageImportJob.parse(
        dataToolsObject(jsonDecode(old.responseJson!)),
      );
      if (previous.stageId != job.stageId ||
          previous.version != job.version ||
          previous.jobId != job.jobId) {
        throw const FormatException('重放作业标识发生变化。');
      }
      receipt = previous.body;
    }
    await store.acknowledgeCommand(lease, record, old, receipt);
  }

  Future<StageImportRecord> requestPreview(
    StageImportLease lease,
    String stageId,
    StageImportRequirementsReader requirements,
  ) => store.track(() async {
    lease.requireCapability();
    var record = await store.require(lease, stageId);
    record = await store.acceptStatus(
      lease,
      record,
      await _remote(lease, stageId),
    );
    _completeRequirements(record, requirements);
    if (!{'parsed', 'previewing', 'ready'}.contains(record.remote!.status) ||
        record.remote!.errorCount != 0) {
      throw const ApiFailure(
        'stage_preview_not_ready',
        '请等待解析完成并处理所有错误，再生成导入预览。',
      );
    }
    final command = await store.freezeCommand(lease, record, 'preview', {
      'stage_version': record.version,
    });
    final job = StageImportJob.parse(
      await _request(
        lease,
        'POST',
        '/data-tools/import-stages/$stageId/preview',
        bodyJson: command.bodyJson,
      ),
    );
    await _ackJob(lease, record, command, job);
    return store.acceptStatus(lease, record, await _remote(lease, stageId));
  });

  void _requireGroup(StageImportLease lease) {
    lease.requireCapability();
    if (!lease.data.supportsGroupPull) {
      throw const ApiFailure(
        'stage_group_required',
        '当前服务器尚未提供整批资料同步，请稍后再确认导入或撤销。',
      );
    }
  }

  Future<StageImportRecord> apply(
    StageImportLease lease,
    String stageId, {
    required int version,
    required String previewHash,
  }) => store.track(() async {
    _requireGroup(lease);
    stageInteger(version, 1, 2147483647);
    stageDigest(previewHash);
    var record = await store.require(lease, stageId);
    if (record.version != version ||
        record.remote?.previewHash != previewHash) {
      throw const ApiFailure('stage_preview_changed', '预览已变化，请重新查看后再确认导入。');
    }
    record = await store.acceptStatus(
      lease,
      record,
      await _remote(lease, stageId),
    );
    if (record.remote!.previewHash != previewHash ||
        record.remote!.errorCount != 0 ||
        !{'ready', 'applying', 'applied'}.contains(record.remote!.status)) {
      throw const ApiFailure('stage_preview_changed', '预览已变化，请重新查看后再确认导入。');
    }
    final command = await store.freezeCommand(lease, record, 'apply', {
      'stage_version': version,
      'batch_id': record.batchId,
      'preview_hash': previewHash,
    });
    final job = StageImportJob.parse(
      await _request(
        lease,
        'POST',
        '/data-tools/import-stages/$stageId/apply',
        bodyJson: command.bodyJson,
      ),
    );
    await _ackJob(lease, record, command, job);
    return refresh(lease, stageId);
  });

  Future<StageImportRecord> undo(
    StageImportLease lease,
    String stageId, {
    required int version,
    required String batchId,
  }) => store.track(() async {
    _requireGroup(lease);
    dataToolsUuid(batchId);
    var record = await store.require(lease, stageId);
    if (record.version != version || record.batchId != batchId) {
      throw const ApiFailure('stage_remote_changed', '撤销目标已变化，请重新核对。');
    }
    record = await store.acceptStatus(
      lease,
      record,
      await _remote(lease, stageId),
    );
    if (!{'applied', 'undoing', 'undone'}.contains(record.remote!.status)) {
      throw const ApiFailure('stage_undo_not_ready', '该文件尚无可撤销的正式导入。');
    }
    final command = await store.freezeCommand(lease, record, 'undo', {
      'stage_version': version,
      'batch_id': batchId,
    });
    final job = StageImportJob.parse(
      await _request(
        lease,
        'POST',
        '/data-tools/import-stages/$stageId/undo',
        bodyJson: command.bodyJson,
      ),
    );
    await _ackJob(lease, record, command, job);
    return refresh(lease, stageId);
  });

  Future<StageImportRecord> refresh(
    StageImportLease lease,
    String stageId,
  ) => store.track(() async {
    lease.requireCapability();
    var record = await store.require(lease, stageId);
    record = await store.acceptStatus(
      lease,
      record,
      await _remote(lease, stageId),
    );
    var attemptedProjection = false;
    for (
      var attempt = 0;
      attempt < 2 && {'applied', 'undone'}.contains(record.remote!.status);
      attempt++
    ) {
      attemptedProjection = true;
      _requireGroup(lease);
      // This callback must be the real group pull. No local entity is invented
      // from a job ID, and failures keep the confirmed remote state for retry.
      final before = record.remote!;
      await refreshProjection(lease);
      lease.check();
      record = await store.acceptStatus(
        lease,
        record,
        await _remote(lease, stageId),
      );
      final after = record.remote!;
      if (after.status != before.status) continue;
      if (after.previewHash != before.previewHash ||
          after.body['mapping_hash'] != before.body['mapping_hash']) {
        throw const ApiFailure(
          'stage_projection_pending',
          '处理状态已变化，原回执保留，请继续刷新最新资料。',
        );
      }
      record = await store.update(lease, record, {
        ...record.state,
        'projection_version': record.version,
      });
      return record;
    }
    if (attemptedProjection &&
        {
          'applying',
          'undoing',
          'applied',
          'undone',
        }.contains(record.remote!.status)) {
      throw const ApiFailure(
        'stage_projection_pending',
        '服务器状态仍在变化，请继续刷新；原回执已保留。',
      );
    }
    return record;
  });

  Future<StageImportRecord> cancel(
    StageImportLease lease,
    String stageId,
  ) => store.track(() async {
    lease.requireCapability();
    var record = await store.require(lease, stageId);
    final command = await store.freezeCommand(lease, record, 'cancel', {
      'stage_version': record.version,
    });
    var remote = await _remote(lease, stageId);
    _sameSource(record, remote);
    if (remote.version == record.version + 1 && remote.status == 'cancelled') {
      return _advance(lease, record, command, remote);
    }
    if (remote.version != record.version) {
      throw const ApiFailure('stage_remote_changed', '服务器版本已变化，原件保持。');
    }
    if (remote.status == 'cancelled') {
      return store.acceptStatus(lease, record, remote);
    }
    record = await store.acceptStatus(lease, record, remote);
    remote = StageImportStatus.parse(
      await _request(
        lease,
        'POST',
        '/data-tools/import-stages/$stageId/cancel',
        bodyJson: command.bodyJson,
      ),
    );
    if (remote.status != 'cancelled') throw const FormatException('取消回执状态无效。');
    return _advance(lease, record, command, remote);
  });

  Future<StageImportRecord> releaseSource(
    StageImportLease lease,
    String stageId,
  ) => store.track(() async {
    lease.requireCapability();
    var record = await store.require(lease, stageId);
    record = await store.acceptStatus(
      lease,
      record,
      await _remote(lease, stageId),
    );
    if (!{'applied', 'undone'}.contains(record.remote!.status)) {
      throw const ApiFailure('stage_release_not_ready', '请等待正式导入或撤销完成后，再释放原件。');
    }
    if (record.remote!.sourceReleased) return record;
    final requestId = _uuid.v5(
      record.stageId,
      'source-release:v${record.version}',
    );
    final command = await store.freezeCommand(lease, record, 'source-release', {
      'stage_version': record.version,
      'request_id': requestId,
      'batch_id': record.batchId,
      'client_id': lease.data.clientId,
      'sync_epoch': lease.data.epoch,
      'source_sha256': record.stored.sourceSha256,
    });
    final receipt = StageImportSourceReleased.parse(
      await _request(
        lease,
        'POST',
        '/data-tools/import-stages/$stageId/source-release',
        bodyJson: command.bodyJson,
      ),
    );
    if (receipt.stageId != stageId ||
        receipt.batchId != record.batchId ||
        receipt.version != record.version ||
        receipt.requestId != requestId ||
        receipt.reservedBytes != record.stored.expectedBytes) {
      throw const FormatException('原件释放回执与原始文件不匹配。');
    }
    var preserved = receipt.body;
    if (command.responseJson != null) {
      final previous = StageImportSourceReleased.parse(
        dataToolsObject(jsonDecode(command.responseJson!)),
      );
      if (canonicalStageJson(previous.stable) !=
          canonicalStageJson(receipt.stable)) {
        throw const FormatException('原件释放重放改变已确认事实。');
      }
      preserved = previous.body;
    }
    await store.acknowledgeCommand(lease, record, command, preserved);
    record = await store.acceptStatus(
      lease,
      record,
      await _remote(lease, stageId),
    );
    if (!record.remote!.sourceReleased) {
      throw const FormatException('原件释放状态尚未确认。');
    }
    return record;
  });

  Future<StageImportRowsPage> rows(
    StageImportLease lease,
    String stageId, {
    required int version,
    String? cursor,
    int after = 0,
  }) => store.track(() async {
    lease.requireCapability();
    final record = await store.require(lease, stageId);
    if (record.version != version ||
        (cursor != null && (cursor.isEmpty || cursor.length > 256))) {
      throw const ApiFailure('stage_preview_changed', '分页预览版本已变化，请重新载入。');
    }
    final suffix = cursor == null
        ? ''
        : '&cursor=${Uri.encodeQueryComponent(cursor)}';
    final page = StageImportRowsPage.parse(
      await _request(
        lease,
        'GET',
        '/data-tools/import-stages/$stageId/rows?stage_version=$version&limit=100$suffix',
      ),
    );
    if (page.stageId != stageId || page.version != version) {
      throw const FormatException('预览分页来源不匹配。');
    }
    var position = after;
    for (final row in page.rows) {
      if (row.position != ++position) {
        throw const FormatException('预览分页存在缺项或重复。');
      }
    }
    if (position > record.remote!.rowCount ||
        page.hasMore != (position < record.remote!.rowCount)) {
      throw const FormatException('预览分页终点不匹配。');
    }
    return page;
  });
}
