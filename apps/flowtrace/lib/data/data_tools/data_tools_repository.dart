import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../../features/identity/identity_controller.dart';
import '../local/app_database.dart';
import '../local/local_repository.dart';
import '../sync/sync_engine.dart';
import 'data_tools_models.dart';

typedef DataToolsRequest =
    Future<Map<String, Object?>> Function(
      String method,
      String path, {
      Map<String, Object?>? body,
      String? bodyJson,
      Uint8List? bodyBytes,
      String? contentType,
    });
typedef DataToolsDownload =
    Future<Uint8List> Function(
      String path, {
      String method,
      Map<String, Object?>? body,
      int maxBytes,
    });

/// Each request belongs to one captured identity; late responses cannot be
/// attributed to a different user, server installation, epoch or device.
final class DataToolsLease {
  const DataToolsLease({
    required this.space,
    required this.clientId,
    required this.epoch,
    required this.isCurrent,
    required this.request,
    required this.download,
    this.generation = 0,
    this.supportsGroupPull = false,
  });
  final DataSpace space;
  final String clientId, epoch;
  final int generation;
  final bool supportsGroupPull;
  final bool Function() isCurrent;
  final DataToolsRequest request;
  final DataToolsDownload download;

  factory DataToolsLease.capture(IdentityController identity) {
    final space = identity.accountSpace;
    final client = identity.clientId;
    final epoch = identity.serverIdentity?.syncEpoch;
    final generation = identity.sessionGeneration;
    if (!identity.online ||
        identity.busy ||
        space == null ||
        client == null ||
        epoch == null) {
      throw const ApiFailure('session_invalid', '请先联网登录，再使用数据迁移。', status: 401);
    }
    return DataToolsLease(
      space: space,
      clientId: client,
      epoch: epoch,
      generation: generation,
      supportsGroupPull: identity.serverIdentity!.supportsGroupPull,
      isCurrent: () =>
          identity.online &&
          !identity.busy &&
          identity.sessionGeneration == generation &&
          identity.accountSpace?.id == space.id &&
          identity.clientId == client &&
          identity.serverIdentity?.syncEpoch == epoch,
      request: (method, path, {body, bodyJson, bodyBytes, contentType}) =>
          identity.authorizedRequest(
            method,
            path,
            body: body,
            bodyJson: bodyJson,
            bodyBytes: bodyBytes,
            contentType: contentType,
            expectedSpaceId: space.id,
            expectedEpoch: epoch,
            expectedClientId: client,
          ),
      download: (path, {method = 'GET', body, maxBytes = 10 * 1024 * 1024}) =>
          identity.authorizedDownload(
            path,
            method: method,
            body: body,
            maxBytes: maxBytes,
            expectedSpaceId: space.id,
            expectedEpoch: epoch,
            expectedClientId: client,
          ),
    );
  }

  void check() {
    if (!space.verified || !isCurrent()) {
      throw const ApiFailure('identity_changed', '账号或资料空间已变化，原操作已停止。');
    }
  }

  /// The post-import refresh retains the same negotiated read protocol and
  /// identity boundary as the captured import operation.
  SyncLease toSyncLease() => SyncLease(
    space: space,
    clientId: clientId,
    epoch: epoch,
    supportsGroupPull: supportsGroupPull,
    isCurrent: isCurrent,
    request: (method, path, {body, bodyJson}) =>
        request(method, path, body: body, bodyJson: bodyJson),
  );
}

final class StoredDataImport {
  StoredDataImport({
    required this.spaceId,
    required this.bodyJson,
    required this.createdAt,
    this.phase = 'draft',
    this.previewHash,
    Map<String, Object?>? result,
  }) : _resultJson = result == null ? null : dataToolsFrozenJson(result) {
    final body = this.body;
    dataToolsKeys(
      body,
      {'batch_id', 'client_id', 'sync_epoch', 'document'},
      {'scope_mapping', 'resource_mapping', 'attachment_transfers'},
    );
    dataToolsUuid(body['batch_id']);
    dataToolsUuid(body['client_id']);
    dataToolsUuid(body['sync_epoch']);
    DataImportDocument.fromJson(dataToolsObject(body['document']));
    for (final field in [
      'scope_mapping',
      'resource_mapping',
      'attachment_transfers',
    ]) {
      final mappings = dataToolsObject(body[field] ?? <String, Object?>{});
      if (mappings.length > 100) throw const FormatException('映射数量超过当前处理范围。');
      for (final entry in mappings.entries) {
        dataToolsUuid(entry.key);
        dataToolsUuid(entry.value);
      }
    }
    dataToolsFrozenJson(body);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(spaceId) ||
        !{
          'draft',
          'prepared',
          'sending',
          'uncertain',
          'applied',
          'undone',
        }.contains(phase) ||
        (previewHash != null &&
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(previewHash!))) {
      throw const FormatException('本机迁移记录无效。');
    }
    if (result != null &&
        DataImportApplied.fromJson(result).batchId != batchId) {
      throw const FormatException('迁移确认记录不匹配。');
    }
  }
  factory StoredDataImport.fromJson(Map<String, Object?> value) {
    dataToolsKeys(value, {
      'version',
      'space_id',
      'body_json',
      'created_at',
      'phase',
      'preview_hash',
      'result',
    });
    if (value['version'] != 1 ||
        value['space_id'] is! String ||
        value['body_json'] is! String ||
        value['created_at'] is! String ||
        value['phase'] is! String ||
        (value['preview_hash'] != null && value['preview_hash'] is! String)) {
      throw const FormatException('本机迁移记录无效。');
    }
    return StoredDataImport(
      spaceId: value['space_id'] as String,
      bodyJson: value['body_json'] as String,
      createdAt: DateTime.parse(value['created_at'] as String),
      phase: value['phase'] as String,
      previewHash: value['preview_hash'] as String?,
      result: value['result'] == null ? null : dataToolsObject(value['result']),
    );
  }
  final String spaceId, bodyJson, phase;
  final DateTime createdAt;
  final String? previewHash, _resultJson;
  Map<String, Object?> get body => dataToolsObject(jsonDecode(bodyJson));
  String get batchId => dataToolsUuid(body['batch_id']);
  String get clientId => dataToolsUuid(body['client_id']);
  String get epoch => dataToolsUuid(body['sync_epoch']);
  DataImportDocument get document =>
      DataImportDocument.fromJson(dataToolsObject(body['document']));
  DataImportApplied? get result => _resultJson == null
      ? null
      : DataImportApplied.fromJson(dataToolsObject(jsonDecode(_resultJson)));
  StoredDataImport withState(
    String next, {
    String? previewHash,
    DataImportApplied? result,
    bool clearPreview = false,
  }) => StoredDataImport(
    spaceId: spaceId,
    bodyJson: bodyJson,
    createdAt: createdAt,
    phase: next,
    previewHash: clearPreview ? null : previewHash ?? this.previewHash,
    result: (result ?? this.result)?.toJson(),
  );
  Map<String, Object?> toJson() => {
    'version': 1,
    'space_id': spaceId,
    'body_json': bodyJson,
    'created_at': createdAt.toUtc().toIso8601String(),
    'phase': phase,
    'preview_hash': previewHash,
    'result': result?.toJson(),
  };
}

/// The frozen request is durable before network execution. A timeout, process
/// close or failed local acknowledgment keeps the same batch ID for replay.
final class DataToolsRepository {
  DataToolsRepository(this.local);
  final LocalRepository local;
  final Map<String, Future<DataImportApplied>> _applying = {};
  int _active = 0;
  bool get busy => _active > 0;
  static const _uuid = Uuid();
  String _prefix(DataSpace space) => 'data_tools.v1.${space.id}.batch.';
  String _key(DataSpace space, String id) =>
      '${_prefix(space)}${dataToolsUuid(id)}';

  Future<T> _track<T>(Future<T> Function() action) async {
    _active++;
    try {
      return await action();
    } finally {
      _active--;
    }
  }

  Future<StoredDataImport?> read(DataSpace space, String id) async {
    final raw = await local.readSetting(_key(space, id));
    if (raw == null) return null;
    final draft = StoredDataImport.fromJson(dataToolsObject(jsonDecode(raw)));
    if (draft.spaceId != space.id || draft.batchId != id) {
      throw const FormatException('迁移记录属于其他资料空间。');
    }
    return draft;
  }

  Future<List<StoredDataImport>> list(DataSpace space) async {
    final rows = await (local.database.select(
      local.database.appSettings,
    )..where((row) => row.key.like('${_prefix(space)}%'))).get();
    final result = rows
        .map(
          (row) =>
              StoredDataImport.fromJson(dataToolsObject(jsonDecode(row.value))),
        )
        .toList();
    if (result.any((row) => row.spaceId != space.id)) {
      throw const FormatException('迁移记录资料空间不一致。');
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<StoredDataImport> _save(
    DataToolsLease lease,
    StoredDataImport record,
  ) => local.database.atomicWrite(() async {
    lease.check();
    if (record.spaceId != lease.space.id ||
        record.clientId != lease.clientId ||
        record.epoch != lease.epoch) {
      throw const ApiFailure('recovery_required', '迁移记录属于旧设备或恢复前资料，已保留，请先核对。');
    }
    final key = _key(lease.space, record.batchId);
    final raw = await local.readSetting(key);
    var next = record;
    if (raw != null) {
      final current = StoredDataImport.fromJson(
        dataToolsObject(jsonDecode(raw)),
      );
      if (current.bodyJson != record.bodyJson ||
          current.spaceId != record.spaceId) {
        throw const ApiFailure('import_local_changed', '固定迁移请求已变化，原记录已保留。');
      }
      // A confirmed undo is terminal. A late formal apply receipt can be
      // retained without changing its wire body or reviving the batch.
      if (current.phase == 'undone') {
        next = current.withState(
          'undone',
          result: current.result ?? record.result,
        );
      } else if (current.phase == 'applied' &&
          !{'applied', 'undone'}.contains(record.phase)) {
        next = current;
      }
      final changed =
          await (local.database.update(
            local.database.appSettings,
          )..where((row) => row.key.equals(key) & row.value.equals(raw))).write(
            AppSettingsCompanion(value: Value(jsonEncode(next.toJson()))),
          );
      if (changed != 1) {
        throw const ApiFailure('import_local_changed', '迁移状态已在其他操作中变化，请重新载入。');
      }
    } else {
      await local.writeSetting(key, jsonEncode(next.toJson()));
    }
    lease.check();
    return next;
  });

  Future<StoredDataImport> stage(
    DataToolsLease lease,
    DataImportDocument document, {
    Map<String, String> scopeMapping = const {},
    Map<String, String> resourceMapping = const {},
    Map<String, String> attachmentTransfers = const {},
  }) async {
    lease.check();
    final draft = StoredDataImport(
      spaceId: lease.space.id,
      createdAt: DateTime.now().toUtc(),
      bodyJson: dataToolsFrozenJson({
        'batch_id': _uuid.v4(),
        'client_id': lease.clientId,
        'sync_epoch': lease.epoch,
        'document': document.toJson(),
        'scope_mapping': scopeMapping,
        'resource_mapping': resourceMapping,
        'attachment_transfers': attachmentTransfers,
      }),
    );
    await _save(lease, draft);
    return draft;
  }

  Future<StoredDataImport> _require(DataToolsLease lease, String id) async {
    lease.check();
    final result = await read(lease.space, id);
    lease.check();
    if (result == null) throw const ApiFailure('import_missing', '没有找到本机迁移请求。');
    if (result.clientId != lease.clientId || result.epoch != lease.epoch) {
      throw const ApiFailure('recovery_required', '迁移记录已保留，请先核对服务器恢复或设备变化。');
    }
    return result;
  }

  Future<DataImportParseResult> parse(
    DataToolsLease lease,
    Uint8List original,
    ImportFileKind kind, {
    Map<String, Object?> options = const {},
  }) => _track(() async {
    lease.check();
    if (original.isEmpty || original.length > dataToolsFileLimit) {
      throw const ApiFailure('import_file_too_large', '请选择不超过5MiB的数据文件。');
    }
    final bytes = Uint8List.fromList(original);
    final multipart =
        http.MultipartRequest('POST', Uri.parse('https://flowtrace.invalid/'))
          ..fields['format'] = kind.wire
          ..fields['options'] = dataToolsFrozenJson({
            ...options,
            'include_diagnostics': true,
          }, maxBytes: 65536)
          ..files.add(
            http.MultipartFile.fromBytes('file', bytes, filename: 'data-file'),
          );
    final body = await multipart.finalize().toBytes();
    lease.check();
    final response = await lease.request(
      'POST',
      '/data-tools/imports/parse',
      bodyBytes: body,
      contentType: multipart.headers['content-type'],
    );
    lease.check();
    final result = DataImportParseResult.fromJson(response);
    if (result.kind != kind ||
        result.sourceSha256 != sha256.convert(bytes).toString()) {
      throw const ApiFailure('invalid_response', '文件解析回执与本次文件不一致。');
    }
    return result;
  });

  void _verifyPreview(
    StoredDataImport draft,
    DataImportPreview preview,
    DataToolsLease lease,
  ) {
    final expected = {
      for (final row in draft.document.rows)
        row.sourceId: _uuid.v5(
          lease.space.userId,
          '${draft.document.namespace}:${row.sourceId}',
        ),
    };
    if (preview.batchId != draft.batchId ||
        preview.rows.length != expected.length ||
        preview.rows.map((row) => row['source_id']).toSet().length !=
            expected.length ||
        preview.rows.any(
          (row) => expected[row['source_id']] != row['entity_id'],
        )) {
      throw const ApiFailure('invalid_response', '导入预览与已固定请求不一致。');
    }
  }

  Future<DataImportPreview> preview(DataToolsLease lease, String id) =>
      _track(() async {
        final draft = await _require(lease, id);
        final raw = await lease.request(
          'POST',
          '/data-tools/imports/preview',
          bodyJson: draft.bodyJson,
        );
        lease.check();
        final result = DataImportPreview.fromJson(raw);
        _verifyPreview(draft, result, lease);
        await local.database.atomicWrite(() async {
          final current = await _require(lease, id);
          if (!{'applied', 'undone'}.contains(current.phase)) {
            await _save(
              lease,
              current.withState(
                result.canApply ? 'prepared' : 'draft',
                previewHash: result.canApply ? result.contentHash : null,
                clearPreview: !result.canApply,
              ),
            );
          }
        });
        return result;
      });

  Future<DataImportApplied> apply(
    DataToolsLease lease,
    String id,
    DataImportPreview preview,
  ) {
    lease.check();
    final key =
        '${lease.space.id}:${lease.epoch}:${lease.clientId}:${lease.generation}:$id';
    return _applying[key] ??= _track(() => _apply(lease, id, preview))
        .whenComplete(() {
          _applying.remove(key);
        });
  }

  Future<DataImportApplied> _apply(
    DataToolsLease lease,
    String id,
    DataImportPreview preview,
  ) async {
    final draft = await _require(lease, id);
    _verifyPreview(draft, preview, lease);
    if (!preview.canApply || draft.previewHash != preview.contentHash) {
      throw const ApiFailure('import_preview_required', '请先完成当前请求的导入预览。');
    }
    if (draft.phase == 'undone') {
      throw const ApiFailure('import_already_undone', '该迁移已撤销，原请求不会重新入账。');
    }
    final sending = await _save(lease, draft.withState('sending'));
    if (sending.phase == 'undone') {
      throw const ApiFailure('import_already_undone', '该迁移已在其他操作中撤销，原请求不会重发。');
    }
    Map<String, Object?> raw;
    try {
      raw = await lease.request(
        'POST',
        '/data-tools/imports/apply',
        bodyJson: draft.bodyJson,
      );
    } catch (_) {
      if (lease.isCurrent()) {
        try {
          await _save(lease, draft.withState('uncertain'));
        } catch (_) {
          /* The original request is already durable. */
        }
      }
      rethrow;
    }
    lease.check();
    final result = DataImportApplied.fromJson(raw);
    final expected = draft.document.rows
        .map(
          (row) => _uuid.v5(
            lease.space.userId,
            '${draft.document.namespace}:${row.sourceId}',
          ),
        )
        .toSet();
    if (result.batchId != id ||
        result.created.followedBy(result.duplicates).toSet().length !=
            expected.length ||
        !result.created
            .followedBy(result.duplicates)
            .every(expected.contains)) {
      throw const ApiFailure('invalid_response', '导入确认与已固定请求不一致，原请求已保留。');
    }
    await _save(lease, draft.withState(result.status, result: result));
    return result;
  }

  Future<DataImportApplied> retryPending(
    DataToolsLease lease,
    String id,
  ) async {
    final draft = await _require(lease, id);
    if (!{'sending', 'uncertain'}.contains(draft.phase) ||
        draft.previewHash == null) {
      throw const ApiFailure('import_retry_unavailable', '该迁移没有待核对的已确认请求。');
    }
    final document = draft.document;
    // This is the same already-confirmed attempt, never a new batch. The
    // server reauthorizes it and either replays its receipt or applies it once.
    final preview = DataImportPreview.fromJson({
      'batch_id': id,
      'content_hash': draft.previewHash,
      'can_apply': true,
      'fingerprint_scan_complete': false,
      'errors': [],
      'rows': [
        for (var index = 0; index < document.rows.length; index++)
          {
            'row': index + 1,
            'source_id': document.rows[index].sourceId,
            'entity_id': _uuid.v5(
              lease.space.userId,
              '${document.namespace}:${document.rows[index].sourceId}',
            ),
            'status': 'new',
            'warning': null,
          },
      ],
    });
    return apply(lease, id, preview);
  }

  Future<DataImportHistoryPage> history(
    DataToolsLease lease, {
    String? cursor,
    int limit = 100,
    String? batchId,
  }) => _track(() async {
    lease.check();
    if (limit < 1 || limit > 100 || (cursor != null && cursor.length > 256)) {
      throw ArgumentError('无效分页。');
    }
    final path = Uri(
      path: '/data-tools/imports/history',
      queryParameters: {
        'limit': '$limit',
        'cursor': ?cursor,
        if (batchId != null) 'batch_id': dataToolsUuid(batchId),
      },
    ).toString();
    final response = await lease.request('GET', path);
    lease.check();
    return DataImportHistoryPage.fromJson(response);
  });

  Future<DataImportHistoryItem?> remoteBatchStatus(
    DataToolsLease lease,
    String id,
  ) => _track(() async {
    final page = await history(lease, limit: 1, batchId: dataToolsUuid(id));
    lease.check();
    if (page.hasMore ||
        page.items.length > 1 ||
        page.items.any((item) => item.batchId != id)) {
      throw const FormatException('远端迁移状态与当前批次不一致。');
    }
    return page.items.firstOrNull;
  });

  Future<bool> refreshRemoteUndo(DataToolsLease lease, String id) =>
      _track(() async {
        final original = await _require(lease, id);
        if (original.phase != 'applied') return false;
        final remote = await remoteBatchStatus(lease, id);
        lease.check();
        if (remote?.status != 'undone') return false;
        return local.database.atomicWrite(() async {
          final current = await _require(lease, id);
          if (current.phase != 'applied' ||
              current.bodyJson != original.bodyJson ||
              jsonEncode(current.toJson()) != jsonEncode(original.toJson())) {
            return false;
          }
          final saved = await _save(lease, current.withState('undone'));
          lease.check();
          return saved.phase == 'undone';
        });
      });

  Future<DataImportUndoPreview> undoPreview(DataToolsLease lease, String id) =>
      _track(() async {
        lease.check();
        final result = await lease.request(
          'GET',
          '/data-tools/imports/${dataToolsUuid(id)}/undo-preview',
        );
        lease.check();
        final preview = DataImportUndoPreview.fromJson(result);
        if (preview.batchId != id) throw const FormatException('撤销预览与当前批次不符。');
        return preview;
      });

  Future<void> undo(DataToolsLease lease, String id) => _track(() async {
    lease.check();
    final response = await lease.request(
      'POST',
      '/data-tools/imports/${dataToolsUuid(id)}/undo',
      body: {'client_id': lease.clientId, 'sync_epoch': lease.epoch},
    );
    lease.check();
    dataToolsKeys(
      response,
      {'batch_id', 'status', 'replayed'},
      {'commit_id', 'scope_revisions'},
    );
    if (response['batch_id'] != id ||
        response['status'] != 'undone' ||
        response['replayed'] is! bool) {
      throw const FormatException('撤销回执无效。');
    }
    final localDraft = await read(lease.space, id);
    if (localDraft != null) await _save(lease, localDraft.withState('undone'));
  });

  Future<Uint8List> export(
    DataToolsLease lease,
    String format,
    Map<String, Object?> filter,
  ) => _track(() async {
    lease.check();
    if (!{'json', 'xlsx'}.contains(format)) throw ArgumentError('导出格式无效。');
    final frozen = dataToolsObject(jsonDecode(dataToolsFrozenJson(filter)));
    final result = await lease.download(
      '/data-tools/exports/$format',
      method: 'POST',
      body: frozen,
      maxBytes: 25 * 1024 * 1024,
    );
    lease.check();
    if (format == 'json') {
      final envelope = dataToolsObject(jsonDecode(utf8.decode(result)));
      dataToolsKeys(envelope, {
        'format',
        'document',
        'attachments',
        'scope_versions',
        'filter',
      });
      if (envelope['format'] != 'flowtrace-export-v1') {
        throw const FormatException('导出文件不完整。');
      }
    } else if (result.length < 22 || result[0] != 0x50 || result[1] != 0x4b) {
      throw const FormatException('Excel导出文件不完整。');
    }
    return Uint8List.fromList(result);
  });
}
