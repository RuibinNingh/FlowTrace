import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/data_tools_repository.dart';
import 'package:flowtrace/data/data_tools/stage_import_commands.dart';
import 'package:flowtrace/data/data_tools/stage_import_lease.dart';
import 'package:flowtrace/data/data_tools/stage_import_mapping.dart';
import 'package:flowtrace/data/data_tools/stage_import_models.dart';
import 'package:flowtrace/data/data_tools/stage_import_requirements.dart';
import 'package:flowtrace/data/data_tools/stage_import_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart' show qid;
import 'stage_import_store_test.dart' show StageRig, stageBytes, failureCode;

final class MutationRig {
  final source = StageRig();
  late StageImportCommands commands;
  late StageImportRecord original;
  int refreshes = 0;
  bool lostMapping = false, wrongMapping = false, failProjection = false;
  bool completeJobs = true, released = false;
  bool lostReauthorization = false, foreignReauthorizationWinner = false;
  bool lostDiscard = false, expired = false;
  String? originSession;
  int errors = 0;
  Future<void> Function()? duringProjection;
  String mappingHash = stageMappingHash({});
  final previewHash = List.filled(64, 'b').join();
  final bodies = <String, List<String>>{};
  String get emptyHash => sha256.convert(utf8.encode('[]')).toString();
  Map<String, Object?> get status => {
    ...source.statusBody(released: released),
    'mapping_hash': mappingHash,
    'row_count': 0,
    'error_count': errors,
    'requirements_version': released || source.status == 'cancelled' ? null : source.version,
    'requirements_hash': released || source.status == 'cancelled' ? null : emptyHash,
    'requirements_count': 0,
    if (source.status == 'cancelled') 'parse_job_id': null,
    'preview_hash':
        {
          'ready',
          'applying',
          'applied',
          'undoing',
          'undone',
        }.contains(source.status)
        ? previewHash
        : null,
  };
  StageImportLease get lease => StageImportLease(
    supportsStages: true,
    sessionId: source.sessionId,
    upload: source.lease.upload,
    data: DataToolsLease(
      space: source.fixture.space,
      clientId: source.lease.data.clientId,
      epoch: source.epoch,
      supportsGroupPull: true,
      isCurrent: () => source.current,
      download: source.lease.data.download,
      request: (method, path, {body, bodyJson, bodyBytes, contentType}) async {
        source.calls.add('$method $path');
        final uri = Uri.parse(path), name = Uri.parse(path).pathSegments.last;
        if (method == 'GET' && name == source.stageId) {
          if (originSession != source.sessionId) {
            throw const ApiFailure(
              'import_stage_reauthorization_required',
              'origin required',
              status: 409,
            );
          }
          return status;
        }
        if (method == 'GET' && name == 'reauthorization') {
          return {
            'stage_id': source.stageId,
            'batch_id': source.batchId,
            'stage_version': source.version,
            'format': source.original!['format'],
            'expected_bytes': source.expected,
            'source_sha256': source.hash,
            'mapping_hash': mappingHash,
            'status': source.status,
            'source_released': released,
            'expired': expired,
          };
        }
        if (method == 'GET' && name == 'requirements') {
          return {
            'stage_id': source.stageId,
            'stage_version': source.version,
            'requirements_hash': emptyHash,
            'items': [],
            'has_more': false,
            'next_cursor': null,
          };
        }
        final incoming = bodyJson == null
            ? <String, Object?>{}
            : dataToolsObject(jsonDecode(bodyJson));
        if (bodyJson != null) (bodies[name] ??= []).add(bodyJson);
        if (name == 'discard' && method == 'POST') {
          if ({'applying', 'applied', 'undoing', 'undone'}.contains(source.status) ||
              incoming['batch_id'] != source.batchId || incoming['source_sha256'] != source.hash ||
              incoming['sync_epoch'] != source.epoch ||
              !(incoming['stage_version'] == source.version ||
                source.status == 'cancelled' && incoming['stage_version'] == source.version - 1)) {
            throw const ApiFailure('import_stage_version_changed', 'discard conflict', status: 409);
          }
          if (source.status != 'cancelled') {
            source.version++;
            source.status = 'cancelled';
            source.received = 0;
            errors = 0;
          }
          if (lostDiscard) {
            lostDiscard = false;
            throw const ApiFailure('network_unavailable', 'lost discard', offline: true);
          }
          return status;
        }
        if (name == 'reauthorize' && method == 'POST') {
          if (incoming['stage_version'] != source.version) {
            throw const ApiFailure(
              'import_stage_version_changed',
              'version changed',
              status: 409,
            );
          }
          source.version++;
          originSession = foreignReauthorizationWinner
              ? qid(99)
              : source.sessionId;
          if (lostReauthorization) {
            lostReauthorization = false;
            throw const ApiFailure(
              'network_unavailable',
              'lost reauthorization',
              offline: true,
            );
          }
          return status;
        }
        if (name == 'mapping' && method == 'PUT') {
          expect(incoming['stage_version'], source.version);
          source.version++;
          mappingHash = stageMappingHash(dataToolsObject(incoming['mapping']));
          if (wrongMapping) mappingHash = List.filled(64, 'f').join();
          if (lostMapping) {
            lostMapping = false;
            throw const ApiFailure(
              'network_unavailable',
              'lost mapping',
              offline: true,
            );
          }
          return status;
        }
        if (name == 'preview' || name == 'apply' || name == 'undo') {
          expect(incoming['stage_version'], source.version);
          final jobStatus = switch (name) {
            'preview' => 'parsed',
            'apply' => 'applying',
            _ => 'undoing',
          };
          if (name == 'preview') source.status = 'ready';
          if (name == 'apply') {
            source.status = completeJobs ? 'applied' : 'applying';
          }
          if (name == 'undo') {
            source.status = completeJobs ? 'undone' : 'undoing';
          }
          return {
            'stage_id': source.stageId,
            'stage_version': source.version,
            'job_id': qid(
              name == 'preview'
                  ? 76
                  : name == 'apply'
                  ? 77
                  : 78,
            ),
            'status': jobStatus,
          };
        }
        if (name == 'cancel') {
          expect(incoming['stage_version'], source.version);
          source.version++;
          source.status = 'cancelled';
          source.received = 0;
          return status;
        }
        if (name == 'source-release') {
          final replay = released;
          released = true;
          return {
            'stage_id': source.stageId,
            'batch_id': source.batchId,
            'request_id': incoming['request_id'],
            'stage_version': source.version,
            'source_released': true,
            'source_released_at': '2026-10-23T01:00:00Z',
            'reserved_bytes_released': source.expected,
            'deleted_source_bytes': source.expected,
            'deleted_source_chunks': 1,
            'deleted_preview_rows': 0,
            'deleted_requirement_rows': 0,
            'replayed': replay,
          };
        }
        throw StateError('unexpected mutation $method ${uri.path}');
      },
    ),
  );
  Future<void> init() async {
    await source.init();
    await source.stage(stageBytes(30));
    original = await source.coordinator.uploadAndSeal(
      source.lease,
      source.stageId,
    );
    originSession = source.sessionId;
    source.status = 'parsed';
    original = await source.store.acceptStatus(
      lease,
      original,
      StageImportStatus.parse(status),
    );
    commands = StageImportCommands(
      source.store,
      refreshProjection: (_) async {
        refreshes++;
        await duringProjection?.call();
        if (failProjection) {
          throw const ApiFailure('group_pending', 'projection pending');
        }
      },
    );
    source.calls.clear();
  }

  Future<StageImportRequirementsReader> requirements() async {
    final record = (await source.store.read(
      source.fixture.space,
      source.stageId,
    ))!;
    final reader = StageImportRequirementsReader(source.store, record);
    await reader.next(lease);
    return reader;
  }

  Future<void> ready() async {
    final reader = await requirements();
    await commands.requestPreview(lease, source.stageId, reader);
  }

  Future<void> close() => source.close();
}

void main() {
  late MutationRig rig;
  setUp(() async {
    rig = MutationRig();
    await rig.init();
  });
  tearDown(() => rig.close());

  test('reauth预检只有GET且不改binding，确认后严格origin GET才续接', () async {
    final original = rig.original;
    rig.source.sessionId = qid(85);
    final plan = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    expect(rig.bodies.containsKey('reauthorize'), isFalse);
    expect(
      (await rig.source.store.read(
        rig.source.fixture.space,
        rig.source.stageId,
      ))!.stored.stateJson,
      original.stored.stateJson,
    );
    final result = await rig.commands.confirmReauthorization(rig.lease, plan);
    expect(result.version, 2);
    expect(result.binding['session_id'], qid(85));
    expect(result.stored.originSessionId, original.stored.originSessionId);
    expect(result.stored.createBodyJson, original.stored.createBodyJson);
    expect(rig.bodies['reauthorize'], hasLength(1));
    await rig.source.store.verifySource(result);
  });

  test('reauth响应丢失只按当前origin普通GET恢复，不再POST或猜版本', () async {
    rig.source.sessionId = qid(85);
    var plan = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    rig.lostReauthorization = true;
    await expectLater(
      rig.commands.confirmReauthorization(rig.lease, plan),
      throwsA(isA<ApiFailure>()),
    );
    final before = (await rig.source.store.read(
      rig.source.fixture.space,
      rig.source.stageId,
    ))!;
    expect(before.version, 1);
    expect(before.binding['session_id'], rig.original.stored.originSessionId);
    plan = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    final result = await rig.commands.confirmReauthorization(rig.lease, plan);
    expect(result.version, 2);
    expect(result.binding['session_id'], qid(85));
    expect(rig.bodies['reauthorize'], hasLength(1));
  });

  test('另一session赢reauth，probe同N+1也不能冒认当前origin', () async {
    rig.source.sessionId = qid(85);
    var plan = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    rig.foreignReauthorizationWinner = true;
    rig.lostReauthorization = true;
    await expectLater(
      rig.commands.confirmReauthorization(rig.lease, plan),
      throwsA(isA<ApiFailure>()),
    );
    plan = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    expect(plan.metadata.version, 2);
    await expectLater(
      rig.commands.confirmReauthorization(rig.lease, plan),
      throwsA(failureCode('import_stage_reauthorization_required')),
    );
    final result = (await rig.source.store.read(
      rig.source.fixture.space,
      rig.source.stageId,
    ))!;
    expect(result.version, 1);
    expect(result.binding['session_id'], rig.original.stored.originSessionId);
    expect(rig.bodies['reauthorize'], hasLength(1));
    final command =
        (await rig.source.fixture.db
                .select(rig.source.fixture.db.stageImportCommands)
                .get())
            .singleWhere((row) => row.kind == 'reauthorize');
    expect(command.phase, 'prepared');
    expect(command.responseJson, isNull);
  });

  test('mapping丢回复且原session失效，真实probe proof和新reauth一次原子续接', () async {
    final requirements = await rig.requirements();
    rig.lostMapping = true;
    final mapping = {'source_namespace': '真实待核对'};
    await expectLater(
      rig.commands.changeMapping(
        rig.lease,
        rig.source.stageId,
        mapping,
        requirements,
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(rig.source.version, 2);
    rig.source.sessionId = qid(85);
    final plan = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    expect(plan.metadata.version, 2);
    final result = await rig.commands.confirmReauthorization(rig.lease, plan);
    expect(result.version, 3);
    final rows = await rig.source.fixture.db
        .select(rig.source.fixture.db.stageImportCommands)
        .get();
    final confirmed = rows.singleWhere((row) => row.kind == 'mapping');
    expect(confirmed.phase, 'confirmed_by_metadata');
    expect(
      dataToolsObject(jsonDecode(confirmed.responseJson!))['source_sha256'],
      rig.source.hash,
    );
    expect(result.binding['session_id'], qid(85));
    expect(result.stored.createBodyJson, rig.original.stored.createBodyJson);
    expect(rig.bodies['mapping'], hasLength(1));
    expect(rig.bodies['reauthorize'], hasLength(1));
  });

  test('group读取期间另设备undo，最终状态必须重核并刷新undo', () async {
    await rig.ready();
    rig.duringProjection = () async {
      rig.source.status = 'undone';
    };
    final result = await rig.commands.apply(
      rig.lease,
      rig.source.stageId,
      version: 1,
      previewHash: rig.previewHash,
    );
    expect(result.remote!.status, 'undone');
    expect(rig.refreshes, 2);
    expect(rig.bodies['apply'], hasLength(1));
  });

  test('group期间远端转undoing，保真实状态待刷新而非标记投影完成', () async {
    await rig.ready();
    rig.duringProjection = () async {
      rig.source.status = 'undoing';
    };
    await expectLater(
      rig.commands.apply(
        rig.lease,
        rig.source.stageId,
        version: 1,
        previewHash: rig.previewHash,
      ),
      throwsA(failureCode('stage_projection_pending')),
    );
    final result = (await rig.source.store.read(
      rig.source.fixture.space,
      rig.source.stageId,
    ))!;
    expect(result.remote!.status, 'undoing');
    expect(result.state['projection_version'], isNull);
    expect(rig.bodies['apply'], hasLength(1));
  });

  test('mapping新版本与ACK同事务，原create/session/bytes不变化', () async {
    final reader = await rig.requirements();
    final before = rig.original;
    final result = await rig.commands.changeMapping(
      rig.lease,
      rig.source.stageId,
      {'source_namespace': '合成资源'},
      reader,
    );
    expect(result.version, 2);
    expect(result.stored.createBodyJson, before.stored.createBodyJson);
    expect(result.stored.originSessionId, before.stored.originSessionId);
    expect(
      result.remote!.body['mapping_hash'],
      stageMappingHash({'source_namespace': '合成资源'}),
    );
    await rig.source.store.verifySource(result);
    final command =
        (await rig.source.fixture.db
                .select(rig.source.fixture.db.stageImportCommands)
                .get())
            .singleWhere((row) => row.kind == 'mapping');
    expect(command.phase, 'acknowledged');
  });

  test('丢mapping回执仅vN+1与原desired hash补ACK，不重发PUT', () async {
    final reader = await rig.requirements();
    rig.lostMapping = true;
    final mapping = {'source_namespace': '合成资源'};
    await expectLater(
      rig.commands.changeMapping(
        rig.lease,
        rig.source.stageId,
        mapping,
        reader,
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(
      (await rig.source.store.read(
        rig.source.fixture.space,
        rig.source.stageId,
      ))!.version,
      1,
    );
    final result = await rig.commands.changeMapping(
      rig.lease,
      rig.source.stageId,
      mapping,
      reader,
    );
    expect(result.version, 2);
    expect(rig.bodies['mapping'], hasLength(1));
  });

  test('自洽hash但多推进一版本或摘要不符，保留原版本与命令', () async {
    final reader = await rig.requirements();
    rig.lostMapping = true;
    final mapping = {'source_namespace': '合成资源'};
    await expectLater(
      rig.commands.changeMapping(
        rig.lease,
        rig.source.stageId,
        mapping,
        reader,
      ),
      throwsA(isA<ApiFailure>()),
    );
    rig.source.version = 3;
    await expectLater(
      rig.commands.changeMapping(
        rig.lease,
        rig.source.stageId,
        mapping,
        reader,
      ),
      throwsA(failureCode('stage_remote_changed')),
    );
    expect(
      (await rig.source.store.read(
        rig.source.fixture.space,
        rig.source.stageId,
      ))!.version,
      1,
    );
    expect(rig.bodies['mapping'], hasLength(1));
  });

  test('未完整requirements禁止mapping/preview，无任何写HTTP', () async {
    final record = (await rig.source.store.read(
      rig.source.fixture.space,
      rig.source.stageId,
    ))!;
    final unread = StageImportRequirementsReader(rig.source.store, record);
    await expectLater(
      rig.commands.changeMapping(rig.lease, rig.source.stageId, {}, unread),
      throwsA(failureCode('stage_requirements_incomplete')),
    );
    await expectLater(
      rig.commands.requestPreview(rig.lease, rig.source.stageId, unread),
      throwsA(failureCode('stage_requirements_incomplete')),
    );
    expect(
      rig.source.calls.any(
        (call) => call.startsWith('POST ') || call.startsWith('PUT '),
      ),
      isFalse,
    );
  });

  test('preview→显式apply/undo仅记metadata，fresh GET终态才实际调用刷新', () async {
    await rig.ready();
    final applied = await rig.commands.apply(
      rig.lease,
      rig.source.stageId,
      version: 1,
      previewHash: rig.previewHash,
    );
    expect(applied.remote!.status, 'applied');
    expect(rig.refreshes, 1);
    final undone = await rig.commands.undo(
      rig.lease,
      rig.source.stageId,
      version: 1,
      batchId: rig.source.batchId,
    );
    expect(undone.remote!.status, 'undone');
    expect(rig.refreshes, 2);
    expect(
      await rig.source.fixture.db
          .select(rig.source.fixture.db.localEntities)
          .get(),
      isEmpty,
    );
    expect(
      await rig.source.fixture.db
          .select(rig.source.fixture.db.pendingOperations)
          .get(),
      isEmpty,
    );
    expect(
      rig.source.calls.any((call) => call.contains('/sync/push')),
      isFalse,
    );
  });

  test('尚在applying只提示等待，不调用投影刷新', () async {
    await rig.ready();
    rig.completeJobs = false;
    final pending = await rig.commands.apply(
      rig.lease,
      rig.source.stageId,
      version: 1,
      previewHash: rig.previewHash,
    );
    expect(pending.remote!.status, 'applying');
    expect(rig.refreshes, 0);
    expect(pending.state['projection_version'], isNull);
  });

  test('正式成功但group pending保回执，再fresh refresh不重发金融命令', () async {
    await rig.ready();
    rig.failProjection = true;
    await expectLater(
      rig.commands.apply(
        rig.lease,
        rig.source.stageId,
        version: 1,
        previewHash: rig.previewHash,
      ),
      throwsA(failureCode('group_pending')),
    );
    final pending = (await rig.source.store.read(
      rig.source.fixture.space,
      rig.source.stageId,
    ))!;
    expect(pending.remote!.status, 'applied');
    expect(pending.state['projection_version'], isNull);
    rig.failProjection = false;
    await rig.commands.refresh(rig.lease, rig.source.stageId);
    expect(rig.bodies['apply'], hasLength(1));
    expect(rig.refreshes, 2);
  });

  test('确认preview哈希变化在写之前拒绝', () async {
    await rig.ready();
    await expectLater(
      rig.commands.apply(
        rig.lease,
        rig.source.stageId,
        version: 1,
        previewHash: List.filled(64, 'c').join(),
      ),
      throwsA(failureCode('stage_preview_changed')),
    );
    expect(rig.bodies.containsKey('apply'), isFalse);
  });

  test('取消推进版本与原件在本机保留，另显式动作才真删本机BLOB', () async {
    final cancelled = await rig.commands.cancel(rig.lease, rig.source.stageId);
    expect(cancelled.version, 2);
    expect(cancelled.remote!.status, 'cancelled');
    expect(cancelled.stored.reservedBytes, 30);
    await rig.source.store.verifySource(cancelled);
    final released = await rig.source.store.releaseLocalSource(
      rig.lease,
      rig.source.stageId,
    );
    expect(released.localReleased, isTrue);
    expect(released.stored.createBodyJson, rig.original.stored.createBodyJson);
    expect(
      await rig.source.fixture.db
          .select(rig.source.fixture.db.stageImportChunks)
          .get(),
      isEmpty,
    );
  });

  test('正式释放原件固定请求与typed首回执保留，本机副本单独释放', () async {
    await rig.ready();
    await rig.commands.apply(
      rig.lease,
      rig.source.stageId,
      version: 1,
      previewHash: rig.previewHash,
    );
    final released = await rig.commands.releaseSource(
      rig.lease,
      rig.source.stageId,
    );
    expect(released.remote!.sourceReleased, isTrue);
    expect(released.localReleased, isFalse);
    await rig.source.store.verifySource(released);
    final replay = await rig.commands.releaseSource(
      rig.lease,
      rig.source.stageId,
    );
    expect(replay.remote!.sourceReleased, isTrue);
    expect(rig.bodies['source-release'], hasLength(1));
    final command =
        (await rig.source.fixture.db
                .select(rig.source.fixture.db.stageImportCommands)
                .get())
            .singleWhere((row) => row.kind == 'source-release');
    expect(
      dataToolsObject(jsonDecode(command.responseJson!))['replayed'],
      isFalse,
    );
  });
}
