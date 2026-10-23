import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart' show qid;
import 'stage_import_commands_test.dart' show MutationRig;
import 'stage_import_store_test.dart' show failureCode;

void main() {
  late MutationRig rig;
  setUp(() async {
    rig = MutationRig();
    await rig.init();
  });
  tearDown(() async {
    await rig.close();
  });

  test('新会话明确放弃过期原件，真删BLOB但不冒认旧binding', () async {
    final old = (await rig.source.store.read(
      rig.source.fixture.space,
      rig.source.stageId,
    ))!;
    rig.source.sessionId = qid(94);
    rig.expired = true;
    final plan = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    expect(plan.record.localReleased, isFalse);
    final result = await rig.commands.discard(rig.lease, plan);
    expect(result.binding, old.binding);
    expect(result.stored.createBodyJson, old.stored.createBodyJson);
    expect(result.stored.sourceSha256, old.stored.sourceSha256);
    expect(result.version, 2);
    expect(result.remote!.status, 'cancelled');
    expect(result.remote!.sourceReleased, isFalse);
    expect(result.localReleased, isTrue);
    expect(result.stored.reservedBytes, 0);
    expect(
      await rig.source.fixture.db
          .select(rig.source.fixture.db.stageImportChunks)
          .get(),
      isEmpty,
    );
    expect(
      () => result.requireLease(rig.lease),
      throwsA(failureCode('stage_reauthorization_required')),
    );
    expect(
      rig.source.calls.any(
        (call) => call.contains('/reauthorize') || call.contains('/sync/'),
      ),
      isFalse,
    );
    expect(
      await rig.source.fixture.db
          .select(rig.source.fixture.db.pendingOperations)
          .get(),
      isEmpty,
    );
  });

  test('放弃成功回复丢失，保真字节直到本人再次确认并重放原body', () async {
    rig.source.sessionId = qid(95);
    rig.lostDiscard = true;
    final plan = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    await expectLater(
      rig.commands.discard(rig.lease, plan),
      throwsA(isA<ApiFailure>()),
    );
    final retained = (await rig.source.store.read(
      rig.source.fixture.space,
      rig.source.stageId,
    ))!;
    expect(retained.localReleased, isFalse);
    await rig.source.store.verifySource(retained);
    final nextPlan = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    expect(nextPlan.metadata.status, 'cancelled');
    final result = await rig.commands.discard(rig.lease, nextPlan);
    expect(result.localReleased, isTrue);
    expect(rig.bodies['discard'], hasLength(2));
    expect(rig.bodies['discard']!.toSet(), hasLength(1));
  });

  test('已发布或确认后远端改变，拒绝本机删除与新binding', () async {
    final old = (await rig.source.store.read(
      rig.source.fixture.space,
      rig.source.stageId,
    ))!;
    rig.source.status = 'applied';
    final plan = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    await expectLater(
      rig.commands.discard(rig.lease, plan),
      throwsA(failureCode('stage_discard_published')),
    );
    rig.source.status = 'parsed';
    final another = await rig.commands.inspectReauthorization(
      rig.lease,
      rig.source.stageId,
    );
    rig.source.version++;
    await expectLater(
      rig.commands.discard(rig.lease, another),
      throwsA(failureCode('stage_discard_conflict')),
    );
    final retained = (await rig.source.store.read(
      rig.source.fixture.space,
      rig.source.stageId,
    ))!;
    expect(retained.stored.stateJson, old.stored.stateJson);
    await rig.source.store.verifySource(retained);
    expect(rig.bodies['discard'], isNull);
  });
}
