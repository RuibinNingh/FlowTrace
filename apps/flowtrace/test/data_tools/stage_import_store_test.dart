import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/data_tools_repository.dart';
import 'package:flowtrace/data/data_tools/stage_import_coordinator.dart';
import 'package:flowtrace/data/data_tools/stage_import_lease.dart';
import 'package:flowtrace/data/data_tools/stage_import_models.dart';
import 'package:flowtrace/data/data_tools/stage_import_store.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart';

/// A closed stage server simulation. No fixture endpoint can send a sync push
/// or synthesize installed financial entities.
final class StageRig {
  StageRig({
    this.databaseFile,
    this.sourceBudget = stageImportSpaceBytes,
    this.commandBudget = stageImportCommandBytes,
    this.commandCount = stageImportMaxCommands,
  }) {
    open();
  }
  final File? databaseFile;
  final int sourceBudget, commandBudget, commandCount;
  late QueryFixture fixture;
  late StageImportStore store;
  late StageImportCoordinator coordinator;
  bool current = true, created = false, lostCreate = false, loseChunk = false;
  bool offline = false, lostSeal = false;
  int received = 0, version = 1;
  String status = 'uploading';
  String sessionId = qid(71), epoch = qEpoch;
  Map<String, Object?>? original;
  final calls = <String>[];
  final createBodies = <String>[];
  final uploaded = <int, Uint8List>{};
  final stageId = qid(70), batchId = qid(72), parseJob = qid(73);
  int get expected => original!['expected_bytes'] as int;
  String get hash => original!['source_sha256'] as String;
  void open() {
    fixture = QueryFixture(
      executor: databaseFile == null
          ? NativeDatabase.memory()
          : NativeDatabase(databaseFile!),
    );
    store = StageImportStore(
      fixture.local,
      sourceBytesLimit: sourceBudget,
      commandBytesLimit: commandBudget,
      commandCountLimit: commandCount,
    );
    coordinator = StageImportCoordinator(store);
  }

  Future<void> init() => fixture.local.registerSpace(fixture.space);
  StageImportLease get lease => StageImportLease(
    supportsStages: true,
    sessionId: sessionId,
    data: DataToolsLease(
      space: fixture.space,
      clientId: qid(74),
      epoch: epoch,
      supportsGroupPull: true,
      isCurrent: () => current,
      request: request,
      download: (path, {method = 'GET', body, maxBytes = 1024}) async =>
          throw StateError('no download'),
    ),
    upload: upload,
  );
  Map<String, Object?> statusBody({bool released = false}) => {
    'stage_id': stageId,
    'batch_id': batchId,
    'stage_version': version,
    'format': original!['format'],
    'status': status,
    'expected_bytes': expected,
    'received_bytes': (received * stageImportChunkBytes).clamp(0, expected),
    'received_chunks': received,
    'row_count': status == 'parsed' ? 202 : 0,
    'error_count': 0,
    'preview_hash': null,
    'parse_job_id': status == 'uploading' ? null : parseJob,
    'preview_job_id': null,
    'apply_job_id': null,
    'undo_job_id': null,
    'created_at': '2026-10-23T00:00:00Z',
    'updated_at': '2026-10-23T00:00:01Z',
    'expires_at': '2026-10-30T00:00:00Z',
    'source_released': released,
    'source_released_at': released ? '2026-10-23T00:01:00Z' : null,
    'requirements_version': null,
    'requirements_hash': null,
    'requirements_count': 0,
  };
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? bodyJson,
    Uint8List? bodyBytes,
    String? contentType,
  }) async {
    calls.add('$method $path');
    if (offline) {
      throw const ApiFailure('network_unavailable', 'offline', offline: true);
    }
    if (method == 'GET' && path == '/data-tools/import-stages/$stageId') {
      if (!created) throw const ApiFailure('not_found', 'missing', status: 404);
      return statusBody();
    }
    if (method == 'POST' && path == '/data-tools/import-stages') {
      final raw = bodyJson!;
      createBodies.add(raw);
      final incoming = dataToolsObject(jsonDecode(raw));
      if (original != null && jsonEncode(original) != raw) {
        throw StateError('create mutated');
      }
      original = incoming;
      created = true;
      if (lostCreate) {
        lostCreate = false;
        throw const ApiFailure(
          'network_unavailable',
          'lost create',
          offline: true,
        );
      }
      return {
        'stage_id': stageId,
        'batch_id': batchId,
        'stage_version': version,
        'chunk_bytes': stageImportChunkBytes,
        'expected_chunks': stageChunkCount(expected),
        'expires_at': '2026-10-30T00:00:00Z',
      };
    }
    if (method == 'POST' && path.endsWith('/seal')) {
      final incoming = dataToolsObject(jsonDecode(bodyJson!));
      expect(incoming, {
        'stage_version': version,
        'total_bytes': expected,
        'source_sha256': hash,
      });
      expect(received, stageChunkCount(expected));
      status = 'uploaded';
      if (lostSeal) {
        lostSeal = false;
        throw const ApiFailure(
          'network_unavailable',
          'lost seal',
          offline: true,
        );
      }
      return {
        'stage_id': stageId,
        'stage_version': version,
        'job_id': parseJob,
        'status': status,
      };
    }
    throw StateError('unexpected stage request $method $path');
  }

  Future<Map<String, Object?>> upload(
    String path,
    Uint8List bytes,
    String digest,
  ) async {
    calls.add('PUT $path');
    if (offline) {
      throw const ApiFailure('network_unavailable', 'offline', offline: true);
    }
    final uri = Uri.parse(path);
    final index = int.parse(uri.pathSegments.last);
    expect(uri.queryParameters, {'stage_version': '$version'});
    expect(index, received);
    expect(sha256.convert(bytes).toString(), digest);
    uploaded[index] = Uint8List.fromList(bytes);
    received++;
    if (loseChunk) {
      loseChunk = false;
      throw const ApiFailure(
        'network_unavailable',
        'lost chunk',
        offline: true,
      );
    }
    return {
      'stage_id': stageId,
      'stage_version': version,
      'chunk_index': index,
      'chunk_sha256': digest,
      'size_bytes': bytes.length,
      'next_chunk_index': received,
      'received_bytes': (received * stageImportChunkBytes).clamp(0, expected),
      'expected_bytes': expected,
      'replayed': false,
    };
  }

  Future<StageImportRecord> stage(Uint8List bytes) => store.stage(
    lease,
    bytes: bytes,
    format: ImportFileKind.qianjiCsv,
    fileName: '合成钱迹.csv',
    stageId: stageId,
  );
  Future<void> close() => fixture.db.close();
}

Uint8List stageBytes([int size = stageImportChunkBytes + 17]) =>
    Uint8List.fromList(List.generate(size, (index) => index % 251));

Matcher failureCode(String code) =>
    isA<ApiFailure>().having((e) => e.code, 'code', code);

void main() {
  test('普通CAS更新不能绕过显式reauth改binding', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final record = await rig.stage(stageBytes(30));
    await expectLater(rig.store.update(rig.lease, record, {...record.state,
      'binding': {...record.binding, 'session_id': qid(85)}}),
      throwsA(failureCode('stage_reauthorization_required')));
    final saved = (await rig.store.read(rig.fixture.space, rig.stageId))!;
    expect(saved.stored.stateJson, record.stored.stateJson);
    await rig.store.verifySource(saved);
  });
  test('原件完整分片事务持久，调用者修改不改变原始创建与字节', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final bytes = stageBytes();
    final original = Uint8List.fromList(bytes);
    final pending = rig.stage(bytes);
    bytes.fillRange(0, bytes.length, 0);
    final record = await pending;
    expect(rig.calls, isEmpty);
    expect(record.stored.sourceSha256, sha256.convert(original).toString());
    expect(record.stored.originSessionId, rig.sessionId);
    expect(
      (await rig.store.chunk(record, 0)).body,
      original.sublist(0, stageImportChunkBytes),
    );
    expect(
      (await rig.store.chunk(record, 1)).body,
      original.sublist(stageImportChunkBytes),
    );
    await rig.store.verifySource(record);
    expect(
      (await rig.fixture.db.select(rig.fixture.db.pendingOperations).get()),
      isEmpty,
    );
  });

  test('SQLite晚片失败回滚整个源，实际BLOB配额不部分占用', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    await rig.fixture.db.customStatement(
      "CREATE TRIGGER fail_stage_second BEFORE INSERT ON stage_import_chunks WHEN NEW.chunk_index=1 BEGIN SELECT RAISE(ABORT,'test_second_chunk'); END",
    );
    await expectLater(rig.stage(stageBytes()), throwsA(anything));
    expect(await rig.store.list(rig.fixture.space), isEmpty);
    expect(
      await rig.fixture.db.select(rig.fixture.db.stageImportChunks).get(),
      isEmpty,
    );
    expect(rig.calls, isEmpty);
  });

  test('实际BLOB限额拒绝新原件，显式服务器释放后真删字节可重新预留', () async {
    final rig = StageRig(sourceBudget: 40);
    await rig.init();
    addTearDown(rig.close);
    await rig.stage(stageBytes(30));
    await expectLater(
      rig.store.stage(
        rig.lease,
        bytes: stageBytes(11),
        format: ImportFileKind.flowtraceJson,
        fileName: 'second.json',
      ),
      throwsA(failureCode('stage_local_quota')),
    );
    var record = await rig.coordinator.uploadAndSeal(rig.lease, rig.stageId);
    await expectLater(
      rig.store.releaseLocalSource(rig.lease, rig.stageId),
      throwsA(failureCode('stage_release_unconfirmed')),
    );
    rig.status = 'applied';
    record = await rig.store.acceptStatus(
      rig.lease,
      record,
      StageImportStatus.parse(rig.statusBody(released: true)),
    );
    record = await rig.store.releaseLocalSource(rig.lease, rig.stageId);
    expect(record.stored.reservedBytes, 0);
    expect(
      await rig.fixture.db.select(rig.fixture.db.stageImportChunks).get(),
      isEmpty,
    );
    expect(record.stored.createBodyJson, isNotEmpty);
    await rig.store.stage(
      rig.lease,
      bytes: stageBytes(40),
      format: ImportFileKind.flowtraceJson,
      fileName: 'next.json',
    );
  });

  test('相同命令先查精确重放再检查128上限，正文不可替换', () async {
    final rig = StageRig(commandCount: 1);
    await rig.init();
    addTearDown(rig.close);
    final record = await rig.stage(stageBytes(10));
    final command = await rig.store.freezeCommand(rig.lease, record, 'seal', {
      'stage_version': 1,
    });
    final replay = await rig.store.freezeCommand(rig.lease, record, 'seal', {
      'stage_version': 1,
    });
    expect(replay.commandId, command.commandId);
    await expectLater(
      rig.store.freezeCommand(rig.lease, record, 'preview', {
        'stage_version': 1,
      }),
      throwsA(failureCode('stage_command_quota')),
    );
    await expectLater(
      rig.store.freezeCommand(rig.lease, record, 'seal', {
        'stage_version': 2,
      }, commandId: command.commandId),
      throwsA(failureCode('stage_command_changed')),
    );
  });

  test('命令容量按真实UTF8与确认JSON计，超限不丢原命令', () async {
    final rig = StageRig(commandBudget: 30);
    await rig.init();
    addTearDown(rig.close);
    final record = await rig.stage(stageBytes(10));
    final command = await rig.store.freezeCommand(
      rig.lease,
      record,
      'preview',
      {'a': '中文'},
    );
    await expectLater(
      rig.store.acknowledgeCommand(rig.lease, record, command, {'b': '中文中文中文'}),
      throwsA(failureCode('stage_command_quota')),
    );
    final saved = await rig.fixture.db
        .select(rig.fixture.db.stageImportCommands)
        .getSingle();
    expect(saved.bodyJson, command.bodyJson);
    expect(saved.responseJson, isNull);
  });

  test('新会话或epoch不能自动重放，保留原始源和session历史', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final record = await rig.stage(stageBytes(21));
    rig.sessionId = qid(80);
    await expectLater(
      rig.coordinator.uploadAndSeal(rig.lease, rig.stageId),
      throwsA(failureCode('stage_reauthorization_required')),
    );
    expect(rig.calls, isEmpty);
    rig.sessionId = record.stored.originSessionId;
    rig.epoch = qid(81);
    await expectLater(
      rig.coordinator.uploadAndSeal(rig.lease, rig.stageId),
      throwsA(failureCode('stage_reauthorization_required')),
    );
    final retained = (await rig.store.read(rig.fixture.space, rig.stageId))!;
    expect(retained.stored, record.stored);
    await rig.store.verifySource(retained);
  });

  test('分片被改写即停，不上传已损坏的原件', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final record = await rig.stage(stageBytes(21));
    await (rig.fixture.db.update(rig.fixture.db.stageImportChunks)
          ..where((r) => r.chunkIndex.equals(0)))
        .write(StageImportChunksCompanion(body: Value(Uint8List(21))));
    await expectLater(
      rig.store.verifySource(record),
      throwsA(failureCode('stage_source_corrupt')),
    );
    expect(rig.calls, isEmpty);
  });
}
