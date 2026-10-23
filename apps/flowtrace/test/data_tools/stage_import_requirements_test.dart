import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/data_tools/data_tools_repository.dart';
import 'package:flowtrace/data/data_tools/stage_import_lease.dart';
import 'package:flowtrace/data/data_tools/stage_import_models.dart';
import 'package:flowtrace/data/data_tools/stage_import_requirements.dart';
import 'package:flowtrace/data/data_tools/stage_import_store.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart' show qid;
import 'stage_import_store_test.dart' show StageRig, stageBytes, failureCode;

Map<String, Object?> requirement(int position, String name) => {
  'position': position,
  'kind': 'account',
  'source_kind': 'name',
  'source_key': name,
  'resource_type': null,
  'first_line': position + 200001,
  'attachment_source': null,
};
String requirementsHash(List<Map<String, Object?>> items) =>
    sha256.convert(utf8.encode(canonicalSyncJson(items))).toString();

Future<StageImportRecord> withRequirements(
  StageRig rig,
  List<Map<String, Object?>> items,
) async {
  await rig.stage(stageBytes(30));
  var record = await rig.coordinator.uploadAndSeal(rig.lease, rig.stageId);
  rig.status = 'parsed';
  return rig.store.acceptStatus(
    rig.lease,
    record,
    StageImportStatus.parse({
      ...rig.statusBody(),
      'requirements_version': 1,
      'requirements_hash': requirementsHash(items),
      'requirements_count': items.length,
    }),
  );
}

StageImportLease pageLease(
  StageRig rig,
  Future<Map<String, Object?>> Function(String) handler,
) {
  final original = rig.lease;
  return StageImportLease(
    sessionId: original.sessionId,
    upload: original.upload,
    supportsStages: original.supportsStages,
    data: DataToolsLease(
      space: original.data.space,
      clientId: original.data.clientId,
      epoch: original.data.epoch,
      isCurrent: original.data.isCurrent,
      download: original.data.download,
      request: (method, path, {body, bodyJson, bodyBytes, contentType}) async {
        expect(method, 'GET');
        return handler(path);
      },
    ),
  );
}

Map<String, Object?> requirementPage(
  StageRig rig,
  List<Map<String, Object?>> all,
  List<Map<String, Object?>> items, {
  String? cursor,
}) => {
  'stage_id': rig.stageId,
  'stage_version': 1,
  'requirements_hash': requirementsHash(all),
  'items': items,
  'has_more': cursor != null,
  'next_cursor': cursor,
};

void main() {
  test('资源原名分页按精确位置与完整canonical SHA验证后才complete', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final items = [requirement(1, '原现金🧾'), requirement(2, '原银行')];
    final record = await withRequirements(rig, items);
    final reader = StageImportRequirementsReader(rig.store, record);
    var calls = 0;
    final lease = pageLease(rig, (path) async {
      final uri = Uri.parse(path);
      expect(uri.queryParameters['stage_version'], '1');
      expect(uri.queryParameters['limit'], '100');
      calls++;
      if (calls == 1) {
        expect(uri.queryParameters.containsKey('cursor'), isFalse);
        return requirementPage(rig, items, [items[0]], cursor: 'safe+/=cursor');
      }
      expect(uri.queryParameters['cursor'], 'safe+/=cursor');
      return requirementPage(rig, items, [items[1]]);
    });
    final first = await reader.next(lease);
    expect(first.items.single.sourceKey, '原现金🧾');
    expect(first.items.single.firstLine, 200002);
    expect(reader.complete, isFalse);
    expect(reader.loaded, 1);
    await reader.next(lease);
    expect(reader.complete, isTrue);
    expect(reader.loaded, 2);
    await expectLater(
      reader.next(lease),
      throwsA(failureCode('stage_requirements_state')),
    );
    expect(calls, 2);
    expect(
      await rig.fixture.db.select(rig.fixture.db.pendingOperations).get(),
      isEmpty,
    );
  });

  test('真实零资源和未派生旧stage分别处理', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final record = await withRequirements(rig, []);
    final reader = StageImportRequirementsReader(rig.store, record);
    await reader.next(
      pageLease(rig, (_) async => requirementPage(rig, [], [])),
    );
    expect(reader.complete, isTrue);
    final old = await rig.store.acceptStatus(
      rig.lease,
      record,
      StageImportStatus.parse(rig.statusBody()),
    );
    expect(
      () => StageImportRequirementsReader(rig.store, old),
      throwsA(failureCode('stage_requirements_pending')),
    );
  });

  test('缺页/重复位置/同hash篡改正文均拒绝完整确认', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final items = [requirement(1, '现金'), requirement(2, '银行')];
    final record = await withRequirements(rig, items);
    for (final changed in [
      [items[1]],
      [items[0], items[0]],
      [
        items[0],
        {...items[1], 'source_key': '错误原名'},
      ],
    ]) {
      final reader = StageImportRequirementsReader(rig.store, record);
      await expectLater(
        reader.next(
          pageLease(rig, (_) async => requirementPage(rig, items, changed)),
        ),
        throwsFormatException,
      );
      expect(reader.complete, isFalse);
    }
  });

  test('分页version或hash变化拒绝，不能把两个快照合并', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final items = [requirement(1, '现金')];
    final record = await withRequirements(rig, items);
    for (final patch in [
      {'stage_version': 2},
      {'requirements_hash': List.filled(64, 'a').join()},
    ]) {
      final reader = StageImportRequirementsReader(rig.store, record);
      await expectLater(
        reader.next(
          pageLease(
            rig,
            (_) async => {...requirementPage(rig, items, items), ...patch},
          ),
        ),
        throwsFormatException,
      );
      expect(reader.complete, isFalse);
    }
  });

  test('第二页离线保留游标与hash进度，重试完整核验', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final items = [requirement(1, '现金'), requirement(2, '银行')];
    final record = await withRequirements(rig, items);
    final reader = StageImportRequirementsReader(rig.store, record);
    var attempts = 0;
    final lease = pageLease(rig, (path) async {
      attempts++;
      if (attempts == 1) {
        return requirementPage(rig, items, [items[0]], cursor: 'next');
      }
      expect(Uri.parse(path).queryParameters['cursor'], 'next');
      if (attempts == 2) {
        throw const ApiFailure('network_unavailable', 'offline', offline: true);
      }
      return requirementPage(rig, items, [items[1]]);
    });
    await reader.next(lease);
    await expectLater(reader.next(lease), throwsA(isA<ApiFailure>()));
    expect(reader.loaded, 1);
    await reader.next(lease);
    expect(reader.complete, isTrue);
  });

  test('显式identifier/manifest关系与int32物理行边界，不从错误行猜', () {
    final raw = {
      ...requirement(1, qid(80)),
      'kind': 'image',
      'source_kind': 'identifier',
      'attachment_source': {
        'source_id': qid(80),
        'sha256': List.filled(64, 'a').join(),
        'size_bytes': 77,
        'media_type': 'image/png',
      },
    };
    final image = StageImportRequirement.parse(raw);
    expect(image.attachment!.sizeBytes, 77);
    for (final patch in [
      {'source_kind': 'name'},
      {'resource_type': 'account'},
      {'source_key': qid(81)},
      {'first_line': 2147483648},
      {'first_line': 0},
    ]) {
      expect(
        () => StageImportRequirement.parse({...raw, ...patch}),
        throwsFormatException,
      );
    }
    expect(
      () => StageImportRequirement.parse({
        ...requirement(1, '现金'),
        'row': {'amount': '1'},
      }),
      throwsFormatException,
    );
  });
}
