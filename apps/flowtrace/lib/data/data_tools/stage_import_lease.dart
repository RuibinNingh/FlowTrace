import 'dart:typed_data';

import '../../features/identity/identity_controller.dart';
import '../../core/network/api_failure.dart';
import '../sync/sync_engine.dart';
import 'data_tools_models.dart';
import 'data_tools_repository.dart';

typedef StageChunkRequest =
    Future<Map<String, Object?>> Function(
      String path,
      Uint8List bytes,
      String chunkSha256,
    );

/// Stage-only binary transport. The existing small-import typedef is unchanged.
/// Session binding is explicit: a new login never silently reauthorizes a stage.
final class StageImportLease {
  const StageImportLease({
    required this.data,
    required this.sessionId,
    required this.upload,
    this.supportsStages = false,
  });

  final DataToolsLease data;
  final String sessionId;
  final StageChunkRequest upload;
  final bool supportsStages;

  factory StageImportLease.capture(IdentityController identity) {
    final data = DataToolsLease.capture(identity);
    final sessionId = dataToolsUuid(identity.account!.sessionId);
    return StageImportLease(
      data: DataToolsLease(
        space: data.space,
        clientId: data.clientId,
        epoch: data.epoch,
        generation: data.generation,
        supportsGroupPull: data.supportsGroupPull,
        request: data.request,
        download: data.download,
        isCurrent: () =>
            data.isCurrent() && identity.account?.sessionId == sessionId,
      ),
      sessionId: sessionId,
      supportsStages: identity.serverIdentity!.supportsStagedImports,
      upload: (path, bytes, chunkSha256) => identity.authorizedRequest(
        'PUT',
        path,
        bodyBytes: Uint8List.fromList(bytes),
        contentType: 'application/octet-stream',
        chunkSha256: chunkSha256,
        expectedSpaceId: data.space.id,
        expectedClientId: data.clientId,
        expectedEpoch: data.epoch,
      ),
    );
  }

  void check() => data.check();
  void requireCapability() {
    check();
    if (!supportsStages) {
      throw const ApiFailure(
        'stage_capability_required',
        '当前服务器尚未开放大文件导入，原件可保留在本机。',
      );
    }
  }

  SyncLease toSyncLease() => data.toSyncLease();

  Future<Map<String, Object?>> sendChunk(
    String stageId,
    int index,
    int version,
    Uint8List bytes,
    String hash,
  ) async {
    dataToolsUuid(stageId);
    if (index < 0 || index >= 100 || version < 1 || version > 2147483647) {
      throw const FormatException('暂存分片位置无效。');
    }
    requireCapability();
    try {
      return await upload(
        '/data-tools/import-stages/$stageId/chunks/$index?stage_version=$version',
        Uint8List.fromList(bytes),
        hash,
      );
    } finally {
      check();
    }
  }
}
