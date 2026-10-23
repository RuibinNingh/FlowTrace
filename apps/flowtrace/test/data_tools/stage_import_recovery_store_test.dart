import 'dart:convert';
import 'dart:io';

import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/stage_import_draft.dart';
import 'package:flowtrace/data/data_tools/stage_import_mapping.dart';
import 'package:flowtrace/data/data_tools/stage_import_models.dart';
import 'package:flowtrace/data/data_tools/stage_import_reauthorization.dart';
import 'package:flowtrace/data/data_tools/stage_import_requirements.dart';
import 'package:flowtrace/data/data_tools/stage_import_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart' show qid;
import 'stage_import_requirements_test.dart'
    show withRequirements, requirement, requirementsHash;
import 'stage_import_store_test.dart' show StageRig, stageBytes, failureCode;

StageImportReauthorization metadataFor(
  StageImportRecord record, {
  int? version,
  String? hash,
  String status = 'parsed',
  bool expired = false,
}) => StageImportReauthorization.parse({
  'stage_id': record.stageId,
  'batch_id': record.batchId,
  'stage_version': version ?? record.version,
  'format': record.stored.format,
  'expected_bytes': record.stored.expectedBytes,
  'source_sha256': record.stored.sourceSha256,
  'mapping_hash': hash ?? stageMappingHash({}),
  'status': status,
  'source_released': false,
  'expired': expired,
});

void main() {
  test('跨页草稿真实SQLite重开保留全部选择，Reader仍须从首核hash', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flowtrace-stage-draft-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final rig = StageRig(
      databaseFile: File(
        '${directory.path}${Platform.pathSeparator}draft.sqlite',
      ),
    );
    await rig.init();
    final items = [requirement(1, '现金'), requirement(2, '银行')];
    final record = await withRequirements(rig, items);
    var draft = StageImportMappingDraft.create(
      version: 1,
      requirementsHash: requirementsHash(items),
      mapping: {
        'template_mapping': {'scope_id': qid(2), 'timezone': 'UTC'},
      },
    );
    final item = StageImportRequirement.parse(items[0]);
    draft = draft
        .withChoice(item, qid(10))
        .withPage(
          StageImportRequirementsPage.parse({
            'stage_id': rig.stageId,
            'stage_version': 1,
            'requirements_hash': requirementsHash(items),
            'items': [items[0]],
            'has_more': true,
            'next_cursor': 'page-2',
          }),
        );
    await rig.store.saveMappingDraft(rig.lease, rig.stageId, draft);
    await rig.close();
    rig.open();
    addTearDown(rig.close);
    final reopened = (await rig.store.read(rig.fixture.space, rig.stageId))!;
    expect(reopened.mappingDraft!.choice(item), qid(10));
    expect(reopened.mappingDraft!.nextCursor, 'page-2');
    expect(reopened.stored.createBodyJson, record.stored.createBodyJson);
    final reader = StageImportRequirementsReader(rig.store, reopened);
    expect(reader.loaded, 0);
    expect(reader.complete, isFalse);
    await rig.store.verifySource(reopened);
  });

  test('草稿错hash/大于1MiB均不覆盖既有选择，原件与commands保持', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final items = [requirement(1, '现金')];
    final record = await withRequirements(rig, items);
    final draft = StageImportMappingDraft.create(
      version: 1,
      requirementsHash: requirementsHash(items),
      mapping: {
        'template_mapping': {'scope_id': qid(2), 'timezone': 'UTC'},
      },
    ).withChoice(StageImportRequirement.parse(items[0]), qid(10));
    await rig.store.saveMappingDraft(rig.lease, rig.stageId, draft);
    final before = (await rig.store.read(rig.fixture.space, rig.stageId))!;
    await expectLater(
      rig.store.saveMappingDraft(
        rig.lease,
        rig.stageId,
        StageImportMappingDraft.parse({
          ...draft.body,
          'requirements_hash': List.filled(64, 'b').join(),
        }),
      ),
      throwsA(failureCode('stage_draft_changed')),
    );
    expect(
      () => StageImportMappingDraft.parse({
        ...draft.body,
        'mapping': {
          'source_namespace': 'x',
          'template_mapping': {
            'scope_id': qid(2),
            'timezone': 'UTC',
            'account_names': {
              for (var i = 0; i < 1000; i++)
                '${i.toString().padLeft(4, '0')}${List.filled(1000, '中').join()}':
                    qid(10),
            },
          },
        },
      }),
      throwsFormatException,
    );
    final after = (await rig.store.read(rig.fixture.space, rig.stageId))!;
    expect(after.stored.stateJson, before.stored.stateJson);
    expect(after.stored.createBodyJson, record.stored.createBodyJson);
    await rig.store.verifySource(after);
  });

  test('显式reauth只改当前binding，原source_session/client/create与BLOB不变', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    await rig.stage(stageBytes(30));
    final record = await rig.coordinator.uploadAndSeal(rig.lease, rig.stageId);
    final metadata = metadataFor(record);
    rig.sessionId = qid(85);
    final command = await rig.store.prepareReauthorization(
      rig.lease,
      rig.stageId,
      metadata,
    );
    expect(
      (await rig.store.read(rig.fixture.space, rig.stageId))!.stored.stateJson,
      record.stored.stateJson,
    );
    rig.version = 2;
    final result = await rig.store.acceptReauthorization(
      rig.lease,
      record,
      metadata,
      command,
      StageImportStatus.parse({
        ...rig.statusBody(),
        'mapping_hash': metadata.mappingHash,
      }),
    );
    result.requireLease(rig.lease);
    expect(result.version, 2);
    expect(result.binding['session_id'], qid(85));
    expect(result.stored.originSessionId, record.stored.originSessionId);
    expect(result.stored.clientId, record.stored.clientId);
    expect(result.stored.createBodyJson, record.stored.createBodyJson);
    await rig.store.verifySource(result);
  });

  test('丢mapping再新session续接，实际probe proof与真实reauth ACK原子保留', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    await rig.stage(stageBytes(30));
    final record = await rig.coordinator.uploadAndSeal(rig.lease, rig.stageId);
    final desired = {'source_namespace': '合成后续'};
    final mapping = await rig.store.freezeCommand(
      rig.lease,
      record,
      'mapping',
      {'stage_version': 1, 'mapping': desired},
    );
    final metadata = metadataFor(
      record,
      version: 2,
      hash: stageMappingHash(desired),
    );
    rig.sessionId = qid(85);
    final command = await rig.store.prepareReauthorization(
      rig.lease,
      rig.stageId,
      metadata,
    );
    rig.version = 3;
    final result = await rig.store.acceptReauthorization(
      rig.lease,
      record,
      metadata,
      command,
      StageImportStatus.parse({
        ...rig.statusBody(),
        'mapping_hash': metadata.mappingHash,
      }),
    );
    expect(result.version, 3);
    final rows = await rig.fixture.db
        .select(rig.fixture.db.stageImportCommands)
        .get();
    final confirmed = rows.singleWhere(
      (row) => row.commandId == mapping.commandId,
    );
    expect(confirmed.phase, 'confirmed_by_metadata');
    expect(confirmed.bodyJson, mapping.bodyJson);
    expect(confirmed.responseJson, metadata.encoded);
    expect(
      () => StageImportStatus.parse(
        dataToolsObject(jsonDecode(confirmed.responseJson!)),
      ),
      throwsFormatException,
    );
    expect(
      rows.singleWhere((row) => row.commandId == command.commandId).phase,
      'acknowledged',
    );
    expect(result.stored.originSessionId, record.stored.originSessionId);
  });

  test('最终source CAS失败回滚ACK与metadata proof，不留半个新binding', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    await rig.stage(stageBytes(30));
    final record = await rig.coordinator.uploadAndSeal(rig.lease, rig.stageId);
    rig.sessionId = qid(85);
    final metadata = metadataFor(record);
    final command = await rig.store.prepareReauthorization(
      rig.lease,
      rig.stageId,
      metadata,
    );
    await rig.fixture.db.customStatement(
      "CREATE TRIGGER reject_stage_binding BEFORE UPDATE ON stage_import_sources BEGIN SELECT RAISE(ABORT,'test_binding_failure'); END",
    );
    rig.version = 2;
    await expectLater(
      rig.store.acceptReauthorization(
        rig.lease,
        record,
        metadata,
        command,
        StageImportStatus.parse({
          ...rig.statusBody(),
          'mapping_hash': metadata.mappingHash,
        }),
      ),
      throwsA(anything),
    );
    final after = (await rig.store.read(rig.fixture.space, rig.stageId))!;
    expect(after.stored.stateJson, record.stored.stateJson);
    final saved =
        (await rig.fixture.db.select(rig.fixture.db.stageImportCommands).get())
            .singleWhere((row) => row.commandId == command.commandId);
    expect(saved.responseJson, isNull);
    expect(saved.phase, 'prepared');
  });

  test('错源/跨epoch/cancelled/过期未发布元数据不能准备reauth', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    await rig.stage(stageBytes(30));
    final record = await rig.coordinator.uploadAndSeal(rig.lease, rig.stageId);
    rig.sessionId = qid(85);
    await expectLater(
      rig.store.prepareReauthorization(
        rig.lease,
        rig.stageId,
        metadataFor(record, status: 'cancelled'),
      ),
      throwsA(failureCode('stage_cancelled')),
    );
    await expectLater(
      rig.store.prepareReauthorization(
        rig.lease,
        rig.stageId,
        metadataFor(record, expired: true),
      ),
      throwsA(failureCode('stage_expired')),
    );
    rig.epoch = qid(86);
    await expectLater(
      rig.store.prepareReauthorization(
        rig.lease,
        rig.stageId,
        metadataFor(record),
      ),
      throwsA(failureCode('stage_reauthorization_conflict')),
    );
    expect(
      (await rig.fixture.db.select(rig.fixture.db.stageImportCommands).get())
          .where((row) => row.kind == 'reauthorize'),
      isEmpty,
    );
  });
}
