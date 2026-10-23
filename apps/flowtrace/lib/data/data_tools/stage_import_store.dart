import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../local/app_database.dart';
import '../local/local_repository.dart';
import 'data_tools_models.dart';
import 'stage_import_draft.dart';
import 'stage_import_lease.dart';
import 'stage_import_mapping.dart';
import 'stage_import_models.dart';
import 'stage_import_reauthorization.dart';

final class _StageDigestSink implements Sink<Digest> {
  Digest? result;
  @override
  void add(Digest data) {
    result = data;
  }

  @override
  void close() {}
}

/// Input history is immutable. Only the small, CAS-protected state changes.
final class StageImportRecord {
  StageImportRecord(this.stored) {
    dataToolsUuid(stored.stageId);
    dataToolsUuid(stored.clientId);
    dataToolsUuid(stored.epoch);
    dataToolsUuid(stored.originSessionId);
    ImportFileKind.parse(stored.format);
    stageDigest(stored.sourceSha256);
    stageInteger(stored.expectedBytes, 1, stageImportSourceLimit);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(stored.spaceId) ||
        stored.fileName.isEmpty ||
        stored.fileName.length > 255 ||
        stored.fileName.contains('\u0000')) {
      throw const FormatException('本机暂存来源信息无效。');
    }
    final create = createBody;
    dataToolsFrozenJson(create);
    dataToolsKeys(create, {
      'stage_id',
      'client_id',
      'sync_epoch',
      'format',
      'expected_bytes',
      'source_sha256',
      'mapping',
    });
    if (create['stage_id'] != stageId ||
        create['client_id'] != stored.clientId ||
        create['sync_epoch'] != stored.epoch ||
        create['format'] != stored.format ||
        create['expected_bytes'] != stored.expectedBytes ||
        create['source_sha256'] != stored.sourceSha256) {
      throw const FormatException('原始暂存请求不匹配。');
    }
    stageMapping(dataToolsObject(create['mapping']));
    final current = state;
    dataToolsFrozenJson(current);
    dataToolsKeys(
      current,
      {
        'version',
        'batch_id',
        'stage_version',
        'next_chunk',
        'remote_status',
        'binding',
        'local_released',
        'projection_version',
      },
      {'mapping_draft'},
    );
    if (current['version'] != 1 ||
        current['local_released'] is! bool ||
        stored.reservedBytes !=
            (current['local_released'] == true ? 0 : stored.expectedBytes)) {
      throw const FormatException('本机暂存容量记录无效。');
    }
    if (current['batch_id'] != null) dataToolsUuid(current['batch_id']);
    stageInteger(current['stage_version'], 1, 2147483647);
    stageInteger(
      current['next_chunk'],
      0,
      stageChunkCount(stored.expectedBytes),
    );
    if (current['remote_status'] != null) {
      final remote = StageImportStatus.parse(
        dataToolsObject(current['remote_status']),
      );
      if (remote.stageId != stageId ||
          remote.batchId != batchId ||
          remote.version != version ||
          remote.expectedBytes != stored.expectedBytes ||
          remote.body['format'] != stored.format) {
        throw const FormatException('远端暂存记录不匹配。');
      }
    }
    final origin = binding;
    dataToolsKeys(origin, {'client_id', 'sync_epoch', 'session_id'});
    for (final id in origin.values) {
      dataToolsUuid(id);
    }
    if (current['projection_version'] != null) {
      stageInteger(current['projection_version'], 1, version);
    }
    if (current['mapping_draft'] != null) {
      final draft = StageImportMappingDraft.parse(
        dataToolsObject(current['mapping_draft']),
      );
      if (draft.baseVersion > version) {
        throw const FormatException('资源草稿版本超过当前文件版本。');
      }
    }
  }
  final StoredStageImportSource stored;
  String get stageId => stored.stageId;
  String? get batchId => state['batch_id'] as String?;
  int get version => state['stage_version'] as int;
  int get nextChunk => state['next_chunk'] as int;
  bool get localReleased => state['local_released'] as bool;
  StageImportMappingDraft? get mappingDraft => state['mapping_draft'] == null
      ? null
      : StageImportMappingDraft.parse(dataToolsObject(state['mapping_draft']));
  Map<String, Object?> get createBody =>
      dataToolsObject(jsonDecode(stored.createBodyJson));
  Map<String, Object?> get state =>
      dataToolsObject(jsonDecode(stored.stateJson));
  Map<String, Object?> get binding => dataToolsObject(state['binding']);
  StageImportStatus? get remote => state['remote_status'] == null
      ? null
      : StageImportStatus.parse(dataToolsObject(state['remote_status']));
  void requireLease(StageImportLease lease) {
    lease.check();
    if (stored.spaceId != lease.data.space.id ||
        binding['client_id'] != lease.data.clientId ||
        binding['sync_epoch'] != lease.data.epoch ||
        binding['session_id'] != lease.sessionId) {
      throw const ApiFailure(
        'stage_reauthorization_required',
        '原始文件已保留。账号会话或资料版本已变化，请明确重新授权后继续。',
      );
    }
  }
}

/// All source chunks exist durably before the first HTTP request. The limits
/// apply to actual retained BLOB and JSON bytes, including unacknowledged work.
final class StageImportStore {
  StageImportStore(
    this.local, {
    this.sourceCountLimit = stageImportMaxSources,
    this.sourceBytesLimit = stageImportSpaceBytes,
    this.commandCountLimit = stageImportMaxCommands,
    this.commandBytesLimit = stageImportCommandBytes,
  }) {
    if (sourceCountLimit < 1 ||
        sourceCountLimit > stageImportMaxSources ||
        sourceBytesLimit < 1 ||
        sourceBytesLimit > stageImportSpaceBytes ||
        commandCountLimit < 1 ||
        commandCountLimit > stageImportMaxCommands ||
        commandBytesLimit < 1 ||
        commandBytesLimit > stageImportCommandBytes) {
      throw ArgumentError('本机暂存预算无效。');
    }
  }
  final LocalRepository local;
  final int sourceCountLimit,
      sourceBytesLimit,
      commandCountLimit,
      commandBytesLimit;
  AppDatabase get db => local.database;
  static const _uuid = Uuid();
  int _active = 0;
  bool get busy => _active != 0;

  Future<T> track<T>(Future<T> Function() action) async {
    _active++;
    try {
      return await action();
    } finally {
      _active--;
    }
  }

  Future<StageImportRecord?> read(DataSpace space, String stageId) async {
    dataToolsUuid(stageId);
    final row =
        await (db.select(db.stageImportSources)..where(
              (r) => r.spaceId.equals(space.id) & r.stageId.equals(stageId),
            ))
            .getSingleOrNull();
    return row == null ? null : StageImportRecord(row);
  }

  Future<List<StageImportRecord>> list(DataSpace space) async =>
      (await (db.select(db.stageImportSources)
                ..where((r) => r.spaceId.equals(space.id))
                ..orderBy([(r) => OrderingTerm.desc(r.createdAt)]))
              .get())
          .map(StageImportRecord.new)
          .toList(growable: false);

  Future<StageImportRecord> require(
    StageImportLease lease,
    String stageId,
  ) async {
    lease.check();
    final record = await read(lease.data.space, stageId);
    if (record == null) {
      throw const ApiFailure('stage_local_missing', '本机原始文件不存在。');
    }
    record.requireLease(lease);
    return record;
  }

  Future<StageImportRecord> stage(
    StageImportLease lease, {
    required Uint8List bytes,
    required ImportFileKind format,
    required String fileName,
    Map<String, Object?> mapping = const {},
    String? stageId,
  }) {
    lease.check();
    // Freeze before the first await, including caller-owned Uint8List buffers.
    final source = Uint8List.fromList(bytes);
    if (source.isEmpty ||
        source.length > stageImportSourceLimit ||
        fileName.isEmpty ||
        fileName.length > 255 ||
        fileName.contains('\u0000')) {
      throw const FormatException('请选择不超过50MiB的非空原始文件。');
    }
    final id = dataToolsUuid(stageId ?? _uuid.v4());
    final digest = sha256.convert(source).toString();
    final body = dataToolsFrozenJson({
      'stage_id': id,
      'client_id': lease.data.clientId,
      'sync_epoch': lease.data.epoch,
      'format': format.wire,
      'expected_bytes': source.length,
      'source_sha256': digest,
      'mapping': stageMapping(mapping),
    });
    return track(
      () => db.atomicWrite(() async {
        lease.check();
        final old = await read(lease.data.space, id);
        if (old != null) {
          old.requireLease(lease);
          if (old.stored.createBodyJson != body ||
              old.stored.fileName != fileName ||
              old.localReleased) {
            throw const ApiFailure('stage_local_changed', '固定原始文件记录已存在且不可替换。');
          }
          await verifySource(old);
          return old;
        }
        final usage = await db
            .customSelect(
              'SELECT COUNT(DISTINCT stage_id) AS sources, COALESCE(SUM(LENGTH(body)),0) AS bytes '
              'FROM stage_import_chunks WHERE space_id = ?',
              variables: [Variable.withString(lease.data.space.id)],
              readsFrom: {db.stageImportChunks},
            )
            .getSingle();
        if (usage.read<int>('sources') >= sourceCountLimit ||
            usage.read<int>('bytes') + source.length > sourceBytesLimit) {
          throw const ApiFailure(
            'stage_local_quota',
            '本机原始文件暂存已满，请明确释放已处理文件后继续。',
          );
        }
        final state = dataToolsFrozenJson({
          'version': 1,
          'batch_id': null,
          'stage_version': 1,
          'next_chunk': 0,
          'remote_status': null,
          'binding': {
            'client_id': lease.data.clientId,
            'sync_epoch': lease.data.epoch,
            'session_id': lease.sessionId,
          },
          'local_released': false,
          'projection_version': null,
        });
        await db
            .into(db.stageImportSources)
            .insert(
              StageImportSourcesCompanion.insert(
                spaceId: lease.data.space.id,
                stageId: id,
                clientId: lease.data.clientId,
                epoch: lease.data.epoch,
                originSessionId: lease.sessionId,
                format: format.wire,
                fileName: fileName,
                sourceSha256: digest,
                createBodyJson: body,
                stateJson: state,
                expectedBytes: source.length,
                reservedBytes: source.length,
                createdAt: DateTime.now().toUtc(),
              ),
            );
        for (var index = 0; index < stageChunkCount(source.length); index++) {
          final start = index * stageImportChunkBytes;
          final chunk = Uint8List.fromList(
            source.sublist(
              start,
              (start + stageImportChunkBytes).clamp(0, source.length),
            ),
          );
          await db
              .into(db.stageImportChunks)
              .insert(
                StageImportChunksCompanion.insert(
                  spaceId: lease.data.space.id,
                  stageId: id,
                  chunkIndex: index,
                  body: chunk,
                  sha256: sha256.convert(chunk).toString(),
                  sizeBytes: chunk.length,
                ),
              );
        }
        lease.check();
        return (await read(lease.data.space, id))!;
      }),
    );
  }

  Future<StoredStageImportChunk> chunk(
    StageImportRecord record,
    int index,
  ) async {
    stageInteger(index, 0, stageChunkCount(record.stored.expectedBytes) - 1);
    final row =
        await (db.select(db.stageImportChunks)..where(
              (r) =>
                  r.spaceId.equals(record.stored.spaceId) &
                  r.stageId.equals(record.stageId) &
                  r.chunkIndex.equals(index),
            ))
            .getSingleOrNull();
    final size = (record.stored.expectedBytes - index * stageImportChunkBytes)
        .clamp(0, stageImportChunkBytes);
    if (row == null ||
        row.sizeBytes != size ||
        row.body.length != size ||
        sha256.convert(row.body).toString() != row.sha256) {
      throw const ApiFailure('stage_source_corrupt', '本机原始分片不完整，停止上传并保留现场。');
    }
    return row.copyWith(body: Uint8List.fromList(row.body));
  }

  Future<void> verifySource(StageImportRecord record) async {
    if (record.localReleased) {
      throw const ApiFailure('stage_source_released', '本机原始文件已明确释放。');
    }
    final digest = _StageDigestSink();
    final conversion = sha256.startChunkedConversion(digest);
    for (var i = 0; i < stageChunkCount(record.stored.expectedBytes); i++) {
      conversion.add((await chunk(record, i)).body);
    }
    conversion.close();
    if (digest.result?.toString() != record.stored.sourceSha256) {
      throw const ApiFailure('stage_source_corrupt', '本机原始文件摘要不一致。');
    }
  }

  Future<StageImportRecord> update(
    StageImportLease lease,
    StageImportRecord before,
    Map<String, Object?> next, {
    int? reservedBytes,
  }) => db.atomicWrite(() async {
    before.requireLease(lease);
    final candidate = StageImportRecord(
      before.stored.copyWith(
        stateJson: dataToolsFrozenJson(next),
        reservedBytes: reservedBytes,
      ),
    );
    candidate.requireLease(lease);
    final count =
        await (db.update(db.stageImportSources)..where(
              (r) =>
                  r.spaceId.equals(before.stored.spaceId) &
                  r.stageId.equals(before.stageId) &
                  r.stateJson.equals(before.stored.stateJson),
            ))
            .write(
              StageImportSourcesCompanion(
                stateJson: Value(candidate.stored.stateJson),
                reservedBytes: reservedBytes == null
                    ? const Value.absent()
                    : Value(reservedBytes),
              ),
            );
    if (count != 1) {
      throw const ApiFailure('stage_local_changed', '暂存状态已变化，请重新载入。');
    }
    lease.check();
    return candidate;
  });

  Future<StageImportRecord> acceptCreated(
    StageImportLease lease,
    StageImportRecord record,
    StageImportCreated result,
  ) async {
    record.requireLease(lease);
    if (result.stageId != record.stageId ||
        result.version != record.version ||
        result.expectedChunks != stageChunkCount(record.stored.expectedBytes) ||
        (record.batchId != null && record.batchId != result.batchId)) {
      throw const FormatException('创建暂存回执不匹配。');
    }
    return update(lease, record, {...record.state, 'batch_id': result.batchId});
  }

  Future<StageImportRecord> acceptStatus(
    StageImportLease lease,
    StageImportRecord record,
    StageImportStatus remote,
  ) async {
    record.requireLease(lease);
    if (record.batchId == null ||
        remote.stageId != record.stageId ||
        remote.batchId != record.batchId ||
        remote.version != record.version ||
        remote.expectedBytes != record.stored.expectedBytes ||
        remote.body['format'] != record.stored.format ||
        remote.receivedChunks < record.nextChunk) {
      throw const ApiFailure('stage_remote_changed', '远端暂存版本或来源变化，原始文件已保留。');
    }
    return update(lease, record, {
      ...record.state,
      'next_chunk': remote.receivedChunks,
      'remote_status': remote.body,
      'projection_version':
          record.remote?.status == remote.status &&
              record.remote?.previewHash == remote.previewHash &&
              record.remote?.body['mapping_hash'] == remote.body['mapping_hash']
          ? record.state['projection_version']
          : null,
    });
  }

  Future<StageImportRecord> acceptChunk(
    StageImportLease lease,
    StageImportRecord record,
    StageImportChunkReceipt receipt,
  ) => db.atomicWrite(() async {
    record.requireLease(lease);
    final source = await chunk(record, receipt.index);
    if (receipt.stageId != record.stageId ||
        receipt.version != record.version ||
        receipt.expectedBytes != record.stored.expectedBytes ||
        receipt.sha256 != source.sha256 ||
        receipt.sizeBytes != source.sizeBytes ||
        receipt.index != record.nextChunk ||
        receipt.nextIndex != receipt.index + 1) {
      throw const FormatException('分片回执与原始字节不匹配。');
    }
    await (db.update(db.stageImportChunks)..where(
          (r) =>
              r.spaceId.equals(record.stored.spaceId) &
              r.stageId.equals(record.stageId) &
              r.chunkIndex.equals(receipt.index),
        ))
        .write(StageImportChunksCompanion(receiptJson: Value(receipt.encoded)));
    return update(lease, record, {
      ...record.state,
      'next_chunk': receipt.nextIndex,
    });
  });

  Future<StoredStageImportCommand> freezeCommand(
    StageImportLease lease,
    StageImportRecord record,
    String kind,
    Map<String, Object?> body, {
    String? commandId,
  }) => db.atomicWrite(() async {
    record.requireLease(lease);
    final fresh = await require(lease, record.stageId);
    if (fresh.version != record.version) {
      throw const ApiFailure('stage_local_changed', '暂存版本已变化，请重新载入。');
    }
    if (!{
      'create',
      'seal',
      'mapping',
      'preview',
      'apply',
      'undo',
      'reauthorize',
      'cancel',
      'source-release',
    }.contains(kind)) {
      throw ArgumentError('暂存命令类型无效。');
    }
    return _persistCommand(
      lease,
      record,
      kind,
      body,
      record.version,
      commandId: commandId,
    );
  });

  Future<StoredStageImportCommand> _persistCommand(
    StageImportLease lease,
    StageImportRecord record,
    String kind,
    Map<String, Object?> body,
    int version, {
    String? commandId,
  }) async {
    final json = dataToolsFrozenJson(body);
    final id = dataToolsUuid(
      commandId ??
          _uuid.v5(
            record.stageId,
            '$kind:$version:${sha256.convert(utf8.encode(json))}',
          ),
    );
    final old =
        await (db.select(db.stageImportCommands)..where(
              (r) =>
                  r.spaceId.equals(record.stored.spaceId) &
                  r.stageId.equals(record.stageId) &
                  r.commandId.equals(id),
            ))
            .getSingleOrNull();
    if (old != null) {
      if (old.kind != kind ||
          old.stageVersion != version ||
          old.bodyJson != json) {
        throw const ApiFailure('stage_command_changed', '已冻结命令不能替换正文。');
      }
      return old;
    }
    final count =
        await (db.select(db.stageImportCommands)..where(
              (r) =>
                  r.spaceId.equals(record.stored.spaceId) &
                  r.stageId.equals(record.stageId),
            ))
            .get();
    if (count.length >= commandCountLimit) {
      throw const ApiFailure('stage_command_quota', '本批操作记录已达上限，原始记录保持。');
    }
    await _checkCommandBytes(record.stored.spaceId, utf8.encode(json).length);
    final command = StageImportCommandsCompanion.insert(
      spaceId: record.stored.spaceId,
      stageId: record.stageId,
      commandId: id,
      kind: kind,
      stageVersion: version,
      bodyJson: json,
      phase: 'prepared',
      createdAt: DateTime.now().toUtc(),
    );
    await db.into(db.stageImportCommands).insert(command);
    lease.check();
    return (await (db.select(db.stageImportCommands)..where(
          (r) =>
              r.spaceId.equals(record.stored.spaceId) &
              r.stageId.equals(record.stageId) &
              r.commandId.equals(id),
        ))
        .getSingle());
  }

  Future<void> _checkCommandBytes(String spaceId, int extra) async {
    final row = await db
        .customSelect(
          'SELECT COALESCE(SUM(LENGTH(CAST(body_json AS BLOB)) + '
          'COALESCE(LENGTH(CAST(response_json AS BLOB)),0)),0) AS bytes '
          'FROM stage_import_commands WHERE space_id = ?',
          variables: [Variable.withString(spaceId)],
          readsFrom: {db.stageImportCommands},
        )
        .getSingle();
    if (row.read<int>('bytes') + extra > commandBytesLimit) {
      throw const ApiFailure('stage_command_quota', '本机操作记录空间已满，原始记录保持。');
    }
  }

  Future<StageImportRecord> saveMappingDraft(
    StageImportLease lease,
    String stageId,
    StageImportMappingDraft draft,
  ) => track(
    () => db.atomicWrite(() async {
      final record = await require(lease, stageId);
      final remote = record.remote;
      if (remote == null ||
          remote.sourceReleased ||
          remote.body['requirements_version'] != record.version ||
          !draft.matches(
            record.version,
            remote.body['requirements_hash'] as String?,
          ) ||
          draft.reviewedPosition > (remote.body['requirements_count'] as int) ||
          draft.choices.length > (remote.body['requirements_count'] as int)) {
        throw const ApiFailure('stage_draft_changed', '资源选择与当前清单版本不一致，原草稿保持。');
      }
      final usage = await db
          .customSelect(
            r"SELECT COALESCE(SUM(LENGTH(CAST(json_extract(state_json, '$.mapping_draft') AS BLOB))),0) AS bytes "
            'FROM stage_import_sources WHERE space_id = ? AND stage_id <> ?',
            variables: [
              Variable.withString(record.stored.spaceId),
              Variable.withString(stageId),
            ],
            readsFrom: {db.stageImportSources},
          )
          .getSingle();
      if (usage.read<int>('bytes') + utf8.encode(draft.encoded).length >
          stageImportCommandBytes) {
        throw const ApiFailure('stage_draft_quota', '本机资源选择草稿已满，原件和此前选择保持。');
      }
      return update(lease, record, {
        ...record.state,
        'mapping_draft': draft.body,
      });
    }),
  );

  void _reauthorizationSource(
    StageImportLease lease,
    StageImportRecord record,
    StageImportReauthorization metadata,
  ) {
    lease.requireCapability();
    if (record.stored.spaceId != lease.data.space.id ||
        record.stored.epoch != lease.data.epoch ||
        metadata.stageId != record.stageId ||
        (record.batchId != null && metadata.batchId != record.batchId) ||
        metadata.expectedBytes != record.stored.expectedBytes ||
        metadata.sourceSha256 != record.stored.sourceSha256 ||
        metadata.format != record.stored.format ||
        metadata.version < record.version) {
      throw const ApiFailure(
        'stage_reauthorization_conflict',
        '待续接的服务器原件与本机来源不一致，请保留原文件并核对。',
      );
    }
  }

  String reauthorizationCommandId(
    StageImportLease lease,
    String stageId,
    int version,
  ) => _uuid.v5(
    dataToolsUuid(stageId),
    'reauthorize:$version:${lease.sessionId}:${lease.data.clientId}:${lease.data.epoch}',
  );

  Future<StoredStageImportCommand?> pendingReauthorization(
    StageImportLease lease,
    String stageId,
  ) async {
    lease.requireCapability();
    final record = await read(lease.data.space, stageId);
    if (record == null) {
      throw const ApiFailure('stage_local_missing', '本机原始文件不存在。');
    }
    final rows =
        await (db.select(db.stageImportCommands)..where(
              (r) =>
                  r.spaceId.equals(record.stored.spaceId) &
                  r.stageId.equals(stageId) &
                  r.kind.equals('reauthorize') &
                  r.phase.equals('prepared'),
            ))
            .get();
    final matching = rows
        .where(
          (row) =>
              row.commandId ==
              reauthorizationCommandId(lease, stageId, row.stageVersion),
        )
        .toList();
    if (matching.length > 1) {
      throw const ApiFailure(
        'stage_reauthorization_conflict',
        '存在多个待核对重新授权请求，请保留原件。',
      );
    }
    return matching.singleOrNull;
  }

  Future<StoredStageImportCommand> prepareReauthorization(
    StageImportLease lease,
    String stageId,
    StageImportReauthorization metadata,
  ) => track(
    () => db.atomicWrite(() async {
      final record = await read(lease.data.space, stageId);
      if (record == null) {
        throw const ApiFailure('stage_local_missing', '本机原始文件不存在。');
      }
      _reauthorizationSource(lease, record, metadata);
      if (metadata.status == 'cancelled') {
        throw const ApiFailure(
          'stage_cancelled',
          '服务器已取消这次处理。原文件保持，可单独释放本机副本。',
        );
      }
      if (metadata.expired &&
          !{'applied', 'undoing', 'undone'}.contains(metadata.status)) {
        throw const ApiFailure(
          'stage_expired',
          '服务器原件已过期。本机文件保持，请明确建立新导入后再上传。',
        );
      }
      return _persistCommand(
        lease,
        record,
        'reauthorize',
        {
          'stage_version': metadata.version,
          'client_id': lease.data.clientId,
          'sync_epoch': lease.data.epoch,
        },
        metadata.version,
        commandId: reauthorizationCommandId(lease, stageId, metadata.version),
      );
    }),
  );

  /// Explicit same-owner disposal does not adopt the old stage's origin. The
  /// original source and binding remain immutable audit history.
  Future<StoredStageImportCommand> prepareOwnerDiscard(
    StageImportLease lease,
    StageImportRecord before,
    StageImportReauthorization metadata,
  ) => track(
    () => db.atomicWrite(() async {
      _reauthorizationSource(lease, before, metadata);
      if ({
        'applying',
        'applied',
        'undoing',
        'undone',
      }.contains(metadata.status)) {
        throw const ApiFailure(
          'stage_discard_published',
          '正式处理中的批次不能放弃，请使用正式撤销与原件释放。',
        );
      }
      final current = await read(lease.data.space, before.stageId);
      if (current == null ||
          current.stored.stateJson != before.stored.stateJson) {
        throw const ApiFailure('stage_local_changed', '本机文件状态已变化，请重新核对。');
      }
      String id(int version) => _uuid.v5(
        before.stageId,
        'discard:$version:${lease.sessionId}:${lease.data.clientId}:${lease.data.epoch}',
      );
      final pending =
          await (db.select(db.stageImportCommands)..where(
                (r) =>
                    r.spaceId.equals(before.stored.spaceId) &
                    r.stageId.equals(before.stageId) &
                    r.kind.equals('discard') &
                    r.phase.equals('prepared'),
              ))
              .get();
      final matching = pending
          .where((row) => row.commandId == id(row.stageVersion))
          .toList();
      if (matching.length > 1) {
        throw const ApiFailure('stage_discard_conflict', '存在多个待确认放弃请求，请保留原件。');
      }
      if (matching.isNotEmpty) {
        final command = matching.single;
        if (metadata.version != command.stageVersion &&
            !(metadata.status == 'cancelled' &&
                metadata.version == command.stageVersion + 1)) {
          throw const ApiFailure(
            'stage_discard_conflict',
            '原放弃请求已有其他版本进展，原件和请求保持。',
          );
        }
        return command;
      }
      return _persistCommand(
        lease,
        before,
        'discard',
        {
          'stage_version': metadata.version,
          'batch_id': metadata.batchId,
          'client_id': lease.data.clientId,
          'sync_epoch': lease.data.epoch,
          'source_sha256': before.stored.sourceSha256,
        },
        metadata.version,
        commandId: id(metadata.version),
      );
    }),
  );

  /// The caller explicitly confirmed deleting both temporary originals. An
  /// actual cancelled response plus same-owner source proof permits deletion
  /// without manufacturing a new origin or calling the ordinary ACK helper.
  Future<StageImportRecord> acceptOwnerDiscard(
    StageImportLease lease,
    StageImportRecord before,
    StageImportReauthorization metadata,
    StoredStageImportCommand command,
    StageImportStatus remote,
  ) => track(
    () => db.atomicWrite(() async {
      _reauthorizationSource(lease, before, metadata);
      final body = dataToolsObject(jsonDecode(command.bodyJson));
      final expectedId = _uuid.v5(
        before.stageId,
        'discard:${command.stageVersion}:${lease.sessionId}:${lease.data.clientId}:${lease.data.epoch}',
      );
      if (command.kind != 'discard' ||
          command.commandId != expectedId ||
          command.spaceId != before.stored.spaceId ||
          command.stageId != before.stageId ||
          body['stage_version'] != command.stageVersion ||
          body['batch_id'] != metadata.batchId ||
          body['client_id'] != lease.data.clientId ||
          body['sync_epoch'] != lease.data.epoch ||
          body['source_sha256'] != before.stored.sourceSha256 ||
          {
            'applying',
            'applied',
            'undoing',
            'undone',
          }.contains(metadata.status) ||
          remote.stageId != before.stageId ||
          remote.batchId != metadata.batchId ||
          remote.expectedBytes != before.stored.expectedBytes ||
          remote.body['format'] != before.stored.format ||
          remote.status != 'cancelled' ||
          remote.sourceReleased ||
          remote.receivedChunks != 0 ||
          remote.body['received_bytes'] != 0 ||
          remote.rowCount != 0 ||
          remote.errorCount != 0 ||
          remote.previewHash != null ||
          remote.body['requirements_version'] != null ||
          remote.body['requirements_hash'] != null ||
          remote.body['requirements_count'] != 0 ||
          [
            'parse_job_id',
            'preview_job_id',
            'apply_job_id',
            'undo_job_id',
          ].any((key) => remote.body[key] != null) ||
          !(remote.version == command.stageVersion + 1 ||
              metadata.status == 'cancelled' &&
                  remote.version == command.stageVersion &&
                  metadata.version == remote.version)) {
        throw const ApiFailure(
          'stage_discard_conflict',
          '放弃回执与原件或确认目标不一致，本机副本保持。',
        );
      }
      final stored =
          await (db.select(db.stageImportCommands)..where(
                (r) =>
                    r.spaceId.equals(command.spaceId) &
                    r.stageId.equals(command.stageId) &
                    r.commandId.equals(command.commandId),
              ))
              .getSingleOrNull();
      if (stored == null ||
          stored.bodyJson != command.bodyJson ||
          stored.responseJson != null &&
              stored.responseJson != remote.encoded) {
        throw const ApiFailure('stage_command_changed', '放弃命令或原回执已变化，本机副本保持。');
      }
      if (stored.responseJson == null) {
        await _checkCommandBytes(
          command.spaceId,
          utf8.encode(remote.encoded).length,
        );
        await (db.update(db.stageImportCommands)..where(
              (r) =>
                  r.spaceId.equals(command.spaceId) &
                  r.stageId.equals(command.stageId) &
                  r.commandId.equals(command.commandId) &
                  r.responseJson.isNull(),
            ))
            .write(
              StageImportCommandsCompanion(
                responseJson: Value(remote.encoded),
                phase: const Value('acknowledged'),
              ),
            );
      }
      final candidate = StageImportRecord(
        before.stored.copyWith(
          reservedBytes: 0,
          stateJson: dataToolsFrozenJson({
            ...before.state,
            'batch_id': remote.batchId,
            'stage_version': remote.version,
            'next_chunk': 0,
            'remote_status': remote.body,
            'projection_version': null,
            'local_released': true,
          }),
        ),
      );
      final count =
          await (db.update(db.stageImportSources)..where(
                (r) =>
                    r.spaceId.equals(before.stored.spaceId) &
                    r.stageId.equals(before.stageId) &
                    r.stateJson.equals(before.stored.stateJson),
              ))
              .write(
                StageImportSourcesCompanion(
                  stateJson: Value(candidate.stored.stateJson),
                  reservedBytes: const Value(0),
                ),
              );
      if (count != 1) {
        throw const ApiFailure('stage_local_changed', '确认期间本机状态已变化，原始副本保持。');
      }
      await (db.delete(db.stageImportChunks)..where(
            (r) =>
                r.spaceId.equals(before.stored.spaceId) &
                r.stageId.equals(before.stageId),
          ))
          .go();
      lease.check();
      return candidate;
    }),
  );

  /// Only an explicit reauthorization response (or exact resumed current-origin
  /// GET) can install a new binding. The original input/client/session stays.
  Future<StageImportRecord> acceptReauthorization(
    StageImportLease lease,
    StageImportRecord before,
    StageImportReauthorization metadata,
    StoredStageImportCommand command,
    StageImportStatus remote,
  ) => track(
    () => db.atomicWrite(() async {
      _reauthorizationSource(lease, before, metadata);
      final current = await read(lease.data.space, before.stageId);
      if (current == null ||
          current.stored.stateJson != before.stored.stateJson) {
        throw const ApiFailure('stage_local_changed', '本机续接状态已变化，请重新核对。');
      }
      final expectedBody = dataToolsFrozenJson({
        'stage_version': command.stageVersion,
        'client_id': lease.data.clientId,
        'sync_epoch': lease.data.epoch,
      });
      if (command.kind != 'reauthorize' ||
          command.stageId != before.stageId ||
          command.spaceId != before.stored.spaceId ||
          command.commandId !=
              reauthorizationCommandId(
                lease,
                before.stageId,
                command.stageVersion,
              ) ||
          command.bodyJson != expectedBody ||
          remote.version != command.stageVersion + 1 ||
          !{command.stageVersion, remote.version}.contains(metadata.version) ||
          remote.stageId != metadata.stageId ||
          remote.batchId != metadata.batchId ||
          remote.expectedBytes != metadata.expectedBytes ||
          remote.body['format'] != metadata.format ||
          remote.body['mapping_hash'] != metadata.mappingHash) {
        throw const ApiFailure(
          'stage_reauthorization_conflict',
          '重新授权回执未通过来源与版本核对，原件保持。',
        );
      }
      final frozen =
          await (db.select(db.stageImportCommands)..where(
                (r) =>
                    r.spaceId.equals(before.stored.spaceId) &
                    r.stageId.equals(before.stageId) &
                    r.commandId.equals(command.commandId),
              ))
              .getSingle();
      if (frozen.bodyJson != command.bodyJson ||
          frozen.kind != 'reauthorize' ||
          frozen.stageVersion != command.stageVersion ||
          frozen.responseJson != null) {
        throw const ApiFailure('stage_command_changed', '原重新授权命令已变化。');
      }
      // A lost mapping PUT followed by a lost origin can be confirmed by this
      // actual read-only metadata. It is deliberately not forged into HTTP ACK.
      final pending =
          await (db.select(db.stageImportCommands)..where(
                (r) =>
                    r.spaceId.equals(before.stored.spaceId) &
                    r.stageId.equals(before.stageId) &
                    r.kind.equals('mapping') &
                    r.phase.equals('prepared'),
              ))
              .get();
      final proof = metadata.encoded;
      for (final mapping in pending) {
        final body = dataToolsObject(jsonDecode(mapping.bodyJson));
        if (metadata.version != mapping.stageVersion + 1 ||
            stageMappingHash(dataToolsObject(body['mapping'])) !=
                metadata.mappingHash) {
          continue;
        }
        await _checkCommandBytes(
          before.stored.spaceId,
          utf8.encode(proof).length,
        );
        await (db.update(db.stageImportCommands)..where(
              (r) =>
                  r.spaceId.equals(before.stored.spaceId) &
                  r.stageId.equals(before.stageId) &
                  r.commandId.equals(mapping.commandId) &
                  r.responseJson.isNull(),
            ))
            .write(
              StageImportCommandsCompanion(
                responseJson: Value(proof),
                phase: const Value('confirmed_by_metadata'),
              ),
            );
      }
      await _checkCommandBytes(
        before.stored.spaceId,
        utf8.encode(remote.encoded).length,
      );
      final acked =
          await (db.update(db.stageImportCommands)..where(
                (r) =>
                    r.spaceId.equals(before.stored.spaceId) &
                    r.stageId.equals(before.stageId) &
                    r.commandId.equals(command.commandId) &
                    r.responseJson.isNull(),
              ))
              .write(
                StageImportCommandsCompanion(
                  responseJson: Value(remote.encoded),
                  phase: const Value('acknowledged'),
                ),
              );
      if (acked != 1) {
        throw const ApiFailure('stage_local_changed', '续接确认已变化，请重新载入。');
      }
      final state = {
        ...before.state,
        'batch_id': remote.batchId,
        'stage_version': remote.version,
        'next_chunk': remote.receivedChunks,
        'remote_status': remote.body,
        'projection_version': null,
        'binding': {
          'client_id': lease.data.clientId,
          'sync_epoch': lease.data.epoch,
          'session_id': lease.sessionId,
        },
      };
      final candidate = StageImportRecord(
        before.stored.copyWith(stateJson: dataToolsFrozenJson(state)),
      );
      final changed =
          await (db.update(db.stageImportSources)..where(
                (r) =>
                    r.spaceId.equals(before.stored.spaceId) &
                    r.stageId.equals(before.stageId) &
                    r.stateJson.equals(before.stored.stateJson),
              ))
              .write(
                StageImportSourcesCompanion(
                  stateJson: Value(candidate.stored.stateJson),
                ),
              );
      if (changed != 1) {
        throw const ApiFailure('stage_local_changed', '续接状态发生并发变化，原件保持。');
      }
      lease.check();
      return candidate;
    }),
  );

  Future<void> acknowledgeCommand(
    StageImportLease lease,
    StageImportRecord record,
    StoredStageImportCommand command,
    Map<String, Object?> response,
  ) => db.atomicWrite(() async {
    record.requireLease(lease);
    final fresh = await require(lease, record.stageId);
    if (fresh.version != command.stageVersion ||
        command.spaceId != record.stored.spaceId ||
        command.stageId != record.stageId) {
      throw const ApiFailure('stage_local_changed', '暂存命令的当前绑定已变化。');
    }
    final encoded = dataToolsFrozenJson(response);
    final current =
        await (db.select(db.stageImportCommands)..where(
              (r) =>
                  r.spaceId.equals(record.stored.spaceId) &
                  r.stageId.equals(record.stageId) &
                  r.commandId.equals(command.commandId),
            ))
            .getSingle();
    if (current.bodyJson != command.bodyJson ||
        current.kind != command.kind ||
        current.stageVersion != command.stageVersion ||
        (current.responseJson != null && current.responseJson != encoded)) {
      throw const ApiFailure('stage_command_changed', '冻结命令或确认回执发生变化。');
    }
    if (current.responseJson == encoded) return;
    await _checkCommandBytes(
      record.stored.spaceId,
      utf8.encode(encoded).length,
    );
    await (db.update(db.stageImportCommands)..where(
          (r) =>
              r.spaceId.equals(record.stored.spaceId) &
              r.stageId.equals(record.stageId) &
              r.commandId.equals(command.commandId) &
              r.responseJson.isNull(),
        ))
        .write(
          StageImportCommandsCompanion(
            responseJson: Value(encoded),
            phase: const Value('acknowledged'),
          ),
        );
    lease.check();
  });

  /// Explicit local release removes real active BLOBs. Recovery copies are
  /// independent and remain available; command/input-history rows are retained.
  Future<StageImportRecord> releaseLocalSource(
    StageImportLease lease,
    String stageId,
  ) => track(
    () => db.atomicWrite(() async {
      final record = await require(lease, stageId);
      if (record.localReleased) return record;
      if (record.remote?.sourceReleased != true &&
          record.remote?.status != 'cancelled') {
        throw const ApiFailure(
          'stage_release_unconfirmed',
          '先确认服务器原件释放或取消，再释放本机副本。',
        );
      }
      await (db.delete(db.stageImportChunks)..where(
            (r) =>
                r.spaceId.equals(record.stored.spaceId) &
                r.stageId.equals(stageId),
          ))
          .go();
      return update(lease, record, {
        ...record.state,
        'local_released': true,
      }, reservedBytes: 0);
    }),
  );
}
