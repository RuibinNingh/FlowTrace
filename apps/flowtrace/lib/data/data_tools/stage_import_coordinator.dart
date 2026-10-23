import 'data_tools_models.dart';
import '../../core/network/api_failure.dart';
import 'stage_import_lease.dart';
import 'stage_import_models.dart';
import 'stage_import_store.dart';

/// Upload/parse orchestration sends source chunks and closed job commands only.
/// Financial projection installation belongs to the negotiated group pull.
final class StageImportCoordinator {
  StageImportCoordinator(this.store);
  final StageImportStore store;
  final Map<String, Future<StageImportRecord>> _running = {};

  Future<StageImportRecord> uploadAndSeal(
    StageImportLease lease,
    String stageId, {
    int requestBudget = 128,
  }) {
    dataToolsUuid(stageId);
    if (requestBudget < 1 || requestBudget > 128) {
      throw ArgumentError('上传请求预算无效。');
    }
    lease.requireCapability();
    final key = '${lease.data.space.id}:$stageId';
    final existing = _running[key];
    if (existing != null) return existing;
    final operation = store.track(() => _upload(lease, stageId, requestBudget));
    _running[key] = operation;
    return operation.whenComplete(() {
      if (identical(_running[key], operation)) _running.remove(key);
    });
  }

  Future<StageImportRecord> _upload(
    StageImportLease lease,
    String stageId,
    int budget,
  ) async {
    var used = 0;
    void consume() {
      lease.check();
      if (used >= budget) {
        throw const ApiFailure('stage_pending', '原始文件和上传位置已保存，再次继续即可恢复。');
      }
      used++;
    }

    Future<Map<String, Object?>> request(
      String method,
      String path, {
      String? bodyJson,
    }) async {
      consume();
      try {
        return await lease.data.request(method, path, bodyJson: bodyJson);
      } finally {
        lease.check();
      }
    }

    final path = '/data-tools/import-stages/$stageId';
    var record = await store.require(lease, stageId);
    if (record.batchId == null) {
      // Probe a fixed ID after a lost create response, but do not infer source
      // identity from length/format: only replaying the frozen creation proves
      // the server's complete create intent and binds its returned batch UUID.
      try {
        final observed = StageImportStatus.parse(await request('GET', path));
        if (observed.stageId != stageId ||
            observed.version != 1 ||
            observed.expectedBytes != record.stored.expectedBytes ||
            observed.body['format'] != record.stored.format) {
          throw const ApiFailure('stage_remote_changed', '固定远端来源已变化，原始文件保持。');
        }
      } on ApiFailure catch (error) {
        if (error.status != 404) rethrow;
      }
      final command = await store.freezeCommand(
        lease,
        record,
        'create',
        record.createBody,
      );
      final created = StageImportCreated.parse(
        await request(
          'POST',
          '/data-tools/import-stages',
          bodyJson: command.bodyJson,
        ),
      );
      // Save proof and binding atomically, so a process close cannot leave a
      // durable ACK with an unknown local batch (or the opposite).
      record = await store.db.atomicWrite(() async {
        await store.acknowledgeCommand(lease, record, command, created.body);
        return store.acceptCreated(lease, record, created);
      });
    }
    record = await store.acceptStatus(
      lease,
      record,
      StageImportStatus.parse(await request('GET', path)),
    );
    if (record.remote!.status != 'uploading') return record;
    await store.verifySource(record);
    while (record.nextChunk < stageChunkCount(record.stored.expectedBytes)) {
      consume();
      final piece = await store.chunk(record, record.nextChunk);
      final result = StageImportChunkReceipt.parse(
        await lease.sendChunk(
          stageId,
          piece.chunkIndex,
          record.version,
          piece.body,
          piece.sha256,
        ),
      );
      record = await store.acceptChunk(lease, record, result);
    }
    final command = await store.freezeCommand(lease, record, 'seal', {
      'stage_version': record.version,
      'total_bytes': record.stored.expectedBytes,
      'source_sha256': record.stored.sourceSha256,
    });
    final job = StageImportJob.parse(
      await request('POST', '$path/seal', bodyJson: command.bodyJson),
    );
    if (job.stageId != stageId || job.version != record.version) {
      throw const FormatException('解析作业与原始文件不匹配。');
    }
    await store.acknowledgeCommand(lease, record, command, job.body);
    // A seal response is job metadata, never an applied financial result.
    return store.acceptStatus(
      lease,
      record,
      StageImportStatus.parse(await request('GET', path)),
    );
  }

  Future<StageImportRecord> refresh(StageImportLease lease, String stageId) =>
      store.track(() async {
        lease.requireCapability();
        final record = await store.require(lease, stageId);
        if (record.batchId == null) {
          throw const ApiFailure('stage_pending', '创建确认尚未保存，请继续原上传。');
        }
        final raw = await lease.data.request(
          'GET',
          '/data-tools/import-stages/$stageId',
        );
        lease.check();
        return store.acceptStatus(lease, record, StageImportStatus.parse(raw));
      });
}
