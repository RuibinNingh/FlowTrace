import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/data_tools_repository.dart';
import 'package:flowtrace/data/data_tools/stage_import_lease.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stage_import_store_test.dart' show StageRig, stageBytes, failureCode;

void main() {
  test('未协商stage能力可保本机原件，上传或refresh均无HTTP', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final original = rig.lease;
    final restricted = StageImportLease(
      data: original.data,
      sessionId: original.sessionId,
      upload: original.upload,
    );
    final staged = await rig.store.stage(
      restricted,
      bytes: stageBytes(24),
      format: ImportFileKind.qianjiCsv,
      fileName: '保留.csv',
      stageId: rig.stageId,
    );
    expect(
      () => rig.coordinator.uploadAndSeal(restricted, rig.stageId),
      throwsA(failureCode('stage_capability_required')),
    );
    await expectLater(
      rig.coordinator.refresh(restricted, rig.stageId),
      throwsA(failureCode('stage_capability_required')),
    );
    expect(rig.calls, isEmpty);
    await rig.store.verifySource(staged);
  });
  test('完整两片只上传原件与seal作业元数据，不push也不创建金融投影', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final bytes = stageBytes();
    final staged = await rig.stage(bytes);
    final result = await rig.coordinator.uploadAndSeal(rig.lease, rig.stageId);
    expect(result.remote!.status, 'uploaded');
    expect(result.stored.createBodyJson, staged.stored.createBodyJson);
    expect(result.stored.originSessionId, staged.stored.originSessionId);
    expect(rig.uploaded.length, 2);
    final uploaded = BytesBuilder();
    for (final piece in rig.uploaded.values) {
      uploaded.add(piece);
    }
    expect(
      sha256.convert(uploaded.takeBytes()).toString(),
      staged.stored.sourceSha256,
    );
    expect(rig.calls.any((call) => call.contains('/sync/')), isFalse);
    expect(
      await rig.fixture.db.select(rig.fixture.db.localEntities).get(),
      isEmpty,
    );
    expect(
      await rig.fixture.db.select(rig.fixture.db.pendingOperations).get(),
      isEmpty,
    );
    final commands = await rig.fixture.db
        .select(rig.fixture.db.stageImportCommands)
        .get();
    expect(commands.map((row) => row.kind).toSet(), {'create', 'seal'});
    expect(commands.every((row) => row.phase == 'acknowledged'), isTrue);
    expect(rig.store.busy, isFalse);
  });

  test('丢创建响应保相同stage/body，探测后完整原请求重放绑定batch', () async {
    final rig = StageRig()..lostCreate = true;
    await rig.init();
    addTearDown(rig.close);
    final staged = await rig.stage(stageBytes(23));
    await expectLater(
      rig.coordinator.uploadAndSeal(rig.lease, rig.stageId),
      throwsA(isA<ApiFailure>()),
    );
    expect(
      (await rig.store.read(rig.fixture.space, rig.stageId))!.batchId,
      isNull,
    );
    final completed = await rig.coordinator.uploadAndSeal(
      rig.lease,
      rig.stageId,
    );
    expect(rig.createBodies, [
      staged.stored.createBodyJson,
      staged.stored.createBodyJson,
    ]);
    expect(completed.batchId, rig.batchId);
    expect(
      rig.calls.where((call) => call == 'POST /data-tools/import-stages'),
      hasLength(2),
    );
    expect(
      (await rig.fixture.db.select(rig.fixture.db.stageImportSources).get()),
      hasLength(1),
    );
  });

  test('丢分片回执后GET真实进度，不重复原件不跳过后续片', () async {
    final rig = StageRig()..loseChunk = true;
    await rig.init();
    addTearDown(rig.close);
    await rig.stage(stageBytes());
    await expectLater(
      rig.coordinator.uploadAndSeal(rig.lease, rig.stageId),
      throwsA(isA<ApiFailure>()),
    );
    final uncertain = (await rig.store.read(rig.fixture.space, rig.stageId))!;
    expect(uncertain.nextChunk, 0);
    expect(rig.received, 1);
    final completed = await rig.coordinator.uploadAndSeal(
      rig.lease,
      rig.stageId,
    );
    expect(completed.nextChunk, 2);
    expect(rig.calls.where((call) => call.startsWith('PUT ')), hasLength(2));
    expect((await rig.store.chunk(completed, 0)).receiptJson, isNull);
    await rig.store.verifySource(completed);
  });

  test('文件SQLite关闭重开延续有界位置，第二片原字节仍在', () async {
    final root = await Directory.systemTemp.createTemp(
      'flowtrace-stage-import-',
    );
    addTearDown(() => root.delete(recursive: true));
    final rig = StageRig(
      databaseFile: File('${root.path}${Platform.pathSeparator}stage.sqlite'),
    );
    await rig.init();
    final staged = await rig.stage(stageBytes());
    // initial GET/POST/GET + first PUT, then the finite call stops.
    await expectLater(
      rig.coordinator.uploadAndSeal(rig.lease, rig.stageId, requestBudget: 4),
      throwsA(failureCode('stage_pending')),
    );
    expect(
      (await rig.store.read(rig.fixture.space, rig.stageId))!.nextChunk,
      1,
    );
    await rig.close();
    rig.open();
    addTearDown(rig.close);
    final reopened = (await rig.store.read(rig.fixture.space, rig.stageId))!;
    expect(reopened.stored.createBodyJson, staged.stored.createBodyJson);
    expect(reopened.stored.originSessionId, staged.stored.originSessionId);
    final completed = await rig.coordinator.uploadAndSeal(
      rig.lease,
      rig.stageId,
    );
    expect(completed.remote!.status, 'uploaded');
    expect(rig.calls.where((call) => call.startsWith('PUT ')), hasLength(2));
    await rig.store.verifySource(completed);
  });

  test('离线不清页或重建请求，恢复后继续相同原件', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final staged = await rig.stage(stageBytes());
    await expectLater(
      rig.coordinator.uploadAndSeal(rig.lease, rig.stageId, requestBudget: 4),
      throwsA(failureCode('stage_pending')),
    );
    final before = (await rig.store.read(rig.fixture.space, rig.stageId))!;
    rig.offline = true;
    await expectLater(
      rig.coordinator.uploadAndSeal(rig.lease, rig.stageId),
      throwsA(isA<ApiFailure>()),
    );
    final offline = (await rig.store.read(rig.fixture.space, rig.stageId))!;
    expect(offline.stored.stateJson, before.stored.stateJson);
    expect(offline.stored.createBodyJson, staged.stored.createBodyJson);
    expect(offline.nextChunk, 1);
    rig.offline = false;
    await rig.coordinator.uploadAndSeal(rig.lease, rig.stageId);
    expect(rig.received, 2);
  });

  test('seal掉响应按已上传job状态恢复，不重复seal也不误称已导入', () async {
    final rig = StageRig()..lostSeal = true;
    await rig.init();
    addTearDown(rig.close);
    await rig.stage(stageBytes(30));
    await expectLater(
      rig.coordinator.uploadAndSeal(rig.lease, rig.stageId),
      throwsA(isA<ApiFailure>()),
    );
    final completed = await rig.coordinator.uploadAndSeal(
      rig.lease,
      rig.stageId,
    );
    expect(completed.remote!.status, 'uploaded');
    expect(rig.calls.where((call) => call.endsWith('/seal')), hasLength(1));
    expect(
      await rig.fixture.db.select(rig.fixture.db.localEntities).get(),
      isEmpty,
    );
    final seal =
        (await rig.fixture.db.select(rig.fixture.db.stageImportCommands).get())
            .singleWhere((command) => command.kind == 'seal');
    expect(seal.phase, 'prepared');
  });

  test('HTTP迟到响应期间账号失效，保本机原bytes而不归入新身份', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final staged = await rig.stage(stageBytes(32));
    final original = rig.lease;
    final arrived = Completer<void>(), release = Completer<void>();
    final delayed = StageImportLease(
      supportsStages: original.supportsStages,
      sessionId: original.sessionId,
      upload: original.upload,
      data: DataToolsLease(
        space: original.data.space,
        clientId: original.data.clientId,
        epoch: original.data.epoch,
        isCurrent: original.data.isCurrent,
        download: original.data.download,
        request:
            (method, path, {body, bodyJson, bodyBytes, contentType}) async {
              final response = await original.data.request(
                method,
                path,
                bodyJson: bodyJson,
              );
              if (method == 'POST') {
                arrived.complete();
                await release.future;
              }
              return response;
            },
      ),
    );
    final pending = rig.coordinator.uploadAndSeal(delayed, rig.stageId);
    final checked = expectLater(
      pending,
      throwsA(failureCode('identity_changed')),
    );
    await arrived.future;
    expect(rig.store.busy, isTrue);
    rig.current = false;
    release.complete();
    await checked;
    final retained = (await rig.store.read(rig.fixture.space, rig.stageId))!;
    expect(retained.stored.createBodyJson, staged.stored.createBodyJson);
    expect(retained.batchId, isNull);
    await rig.store.verifySource(retained);
    expect(rig.calls.any((call) => call.startsWith('PUT ')), isFalse);
    expect(rig.store.busy, isFalse);
  });

  test('格式或batch版本变化立即保留原件并停止续片', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    await rig.stage(stageBytes());
    await expectLater(
      rig.coordinator.uploadAndSeal(rig.lease, rig.stageId, requestBudget: 3),
      throwsA(failureCode('stage_pending')),
    );
    rig.version = 2;
    await expectLater(
      rig.coordinator.uploadAndSeal(rig.lease, rig.stageId),
      throwsA(failureCode('stage_remote_changed')),
    );
    expect(rig.uploaded, isEmpty);
    expect((await rig.store.read(rig.fixture.space, rig.stageId))!.version, 1);
  });
}
