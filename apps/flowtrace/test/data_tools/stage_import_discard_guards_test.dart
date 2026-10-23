import 'package:flowtrace/data/data_tools/stage_import_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart' show qid;
import 'stage_import_commands_test.dart' show MutationRig;
import 'stage_import_store_test.dart' show failureCode;

Map<String, Object?> cancelledReceipt(MutationRig rig) => {
  ...rig.status,
  'stage_version': 2,
  'status': 'cancelled',
  'received_bytes': 0,
  'received_chunks': 0,
  'row_count': 0,
  'error_count': 0,
  'requirements_version': null,
  'requirements_hash': null,
  'requirements_count': 0,
  'parse_job_id': null,
  'preview_job_id': null,
  'apply_job_id': null,
  'undo_job_id': null,
  'preview_hash': null,
};

void main() {
  late MutationRig rig;
  setUp(() async {
    rig = MutationRig();
    await rig.init();
  });
  tearDown(() async {
    await rig.close();
  });

  test('错误版本、来源、仍有字节、持久行或job的取消响应不得释放本机副本', () async {
    final plan = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    final command = await rig.source.store.prepareOwnerDiscard(
      rig.lease,
      plan.record,
      plan.metadata,
    );
    final valid = cancelledReceipt(rig);
    for (final changed in [
      {'stage_version': 3},
      {'format': 'qianji_xlsx'},
      {'expected_bytes': rig.source.expected + 1},
      {'received_bytes': rig.source.expected, 'received_chunks': 1},
      {'row_count': 1},
      {'parse_job_id': qid(89)},
      {'batch_id': qid(90)},
    ]) {
      final remote = StageImportStatus.parse({...valid, ...changed});
      await expectLater(
        rig.source.store.acceptOwnerDiscard(
          rig.lease,
          plan.record,
          plan.metadata,
          command,
          remote,
        ),
        throwsA(failureCode('stage_discard_conflict')),
      );
      final actual = (await rig.source.store.read(
        rig.source.fixture.space,
        rig.source.stageId,
      ))!;
      expect(actual.stored.stateJson, plan.record.stored.stateJson);
      await rig.source.store.verifySource(actual);
    }
    final stored = await (rig.source.fixture.db.select(
      rig.source.fixture.db.stageImportCommands,
    )..where((row) => row.commandId.equals(command.commandId))).getSingle();
    expect(stored.responseJson, isNull);
    expect(stored.phase, 'prepared');
  });

  test('最终SQLite写失败必须回滚先写ACK、额度和所有BLOB删除', () async {
    final plan = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    final command = await rig.source.store.prepareOwnerDiscard(
      rig.lease,
      plan.record,
      plan.metadata,
    );
    await rig.source.fixture.db.customStatement(
      'CREATE TEMP TRIGGER synthetic_discard_late_failure '
      'BEFORE UPDATE ON stage_import_sources BEGIN SELECT RAISE(ABORT, \'synthetic_late_failure\'); END',
    );
    await expectLater(
      rig.source.store.acceptOwnerDiscard(
        rig.lease,
        plan.record,
        plan.metadata,
        command,
        StageImportStatus.parse(cancelledReceipt(rig)),
      ),
      throwsA(anything),
    );
    final actual = (await rig.source.store.read(
      rig.source.fixture.space,
      rig.source.stageId,
    ))!;
    expect(actual.stored.stateJson, plan.record.stored.stateJson);
    expect(actual.stored.reservedBytes, plan.record.stored.expectedBytes);
    expect(actual.localReleased, isFalse);
    await rig.source.store.verifySource(actual);
    final stored = await (rig.source.fixture.db.select(
      rig.source.fixture.db.stageImportCommands,
    )..where((row) => row.commandId.equals(command.commandId))).getSingle();
    expect(stored.phase, 'prepared');
    expect(stored.responseJson, isNull);
  });
}
