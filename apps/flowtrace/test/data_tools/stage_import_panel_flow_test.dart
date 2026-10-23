import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/data_tools_repository.dart';
import 'package:flowtrace/data/data_tools/stage_import_draft.dart';
import 'package:flowtrace/data/data_tools/stage_import_lease.dart';
import 'package:flowtrace/data/data_tools/stage_import_models.dart';
import 'package:flowtrace/data/data_tools/stage_import_requirements.dart';
import 'package:flowtrace/features/data_tools/stage_import_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../attachments/attachment_repository_test.dart' show picture;
import '../ledger/query_fixtures.dart' show qid;
import 'stage_import_commands_test.dart' show MutationRig;
import 'stage_import_requirements_test.dart'
    show requirementsHash, requirementPage;
import 'stage_import_store_test.dart' show StageRig, stageBytes;

StageImportLease delegateLease(
  StageImportLease base,
  Future<Map<String, Object?>> Function(
    String,
    String,
    Future<Map<String, Object?>> Function(),
  )
  handler,
) => StageImportLease(
  supportsStages: base.supportsStages,
  sessionId: base.sessionId,
  upload: base.upload,
  data: DataToolsLease(
    space: base.data.space,
    clientId: base.data.clientId,
    epoch: base.data.epoch,
    supportsGroupPull: true,
    isCurrent: base.data.isCurrent,
    download: base.data.download,
    request: (method, path, {body, bodyJson, bodyBytes, contentType}) =>
        handler(
          method,
          path,
          () => base.data.request(
            method,
            path,
            body: body,
            bodyJson: bodyJson,
            bodyBytes: bodyBytes,
            contentType: contentType,
          ),
        ),
  ),
);

Map<String, Object?> jobMetadata(String action, String status, int id) => {
  'action': action,
  'job_id': qid(id),
  'stage_version': 1,
  'status': status,
  'attempt': 1,
  'error_code': status == 'failed' ? 'import_stage_changed' : null,
  'available_at': '2026-10-23T00:00:00Z',
  'lease_until': null,
};

void main() {
  late ChangeNotifier authority;
  setUp(() {
    authority = ChangeNotifier();
  });
  tearDown(() {
    authority.dispose();
  });

  Future<GlobalKey<StageImportPanelState>> mount(
    WidgetTester tester,
    StageRig source,
    StageImportLease lease, {
    Future<void> Function(StageImportLease)? refresh,
    Future<String> Function(StageImportLease, Uint8List, String)? upload,
    Future<XFile?> Function()? chooseImage,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey<StageImportPanelState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StageImportPanel(
            key: key,
            store: source.store,
            captureLease: () => lease,
            authority: authority,
            authorityKey: () => 'same-person',
            refreshProjection: refresh,
            uploadImage: upload,
            chooseImage: chooseImage,
            destinations: [
              StageImportDestination(
                id: qid(2),
                name: '合成目标账本',
                timezone: 'UTC',
                currency: 'CNY',
                currencyScale: 2,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('合成钱迹.csv'));
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> tap(WidgetTester tester, String label) async {
    final target = find.text(label);
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> openConfirmation(
    WidgetTester tester,
    String label,
    String action,
  ) async {
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    // The operation deliberately remains busy while the user has not answered
    // this modal. Settling an indeterminate progress bar here would wait for
    // the very confirmation the next test step must supply.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(action), findsOneWidget);
    final panel = tester.state<StageImportPanelState>(
      find.byType(StageImportPanel),
    );
    expect(await panel.prepareForUpdate(), isFalse);
  }

  testWidgets('完整预览后仍需明确导入与撤销，服务器任务和真实同步回调分别确认', (tester) async {
    final rig = MutationRig();
    await rig.init();
    addTearDown(rig.close);
    var projections = 0;
    final jobs = <String, Map<String, Object?>>{};
    final lease = delegateLease(rig.lease, (method, path, next) async {
      final endpoint = Uri.parse(path).pathSegments.last;
      if (method == 'GET' && endpoint == 'jobs') {
        return {
          'stage_id': rig.source.stageId,
          'stage_version': 1,
          'jobs': jobs.values.toList(),
        };
      }
      final result = await next();
      if (method == 'POST' && {'preview', 'apply', 'undo'}.contains(endpoint)) {
        jobs[endpoint] = jobMetadata(
          endpoint,
          'succeeded',
          endpoint == 'preview'
              ? 76
              : endpoint == 'apply'
              ? 77
              : 78,
        );
      }
      return result;
    });
    await mount(
      tester,
      rig.source,
      lease,
      refresh: (_) async {
        projections++;
      },
    );
    await tap(tester, '获取服务器状态');
    await tap(tester, '查看原始资源清单');
    expect(rig.bodies['apply'], isNull);
    await tap(tester, '生成完整导入预览');
    expect(rig.bodies['preview'], hasLength(1));
    expect(rig.bodies['apply'], isNull);
    await openConfirmation(tester, '确认正式导入', '确认导入整个批次');
    expect(find.text('确认导入整个批次'), findsOneWidget);
    expect(rig.bodies['apply'], isNull);
    await tap(tester, '确认导入整个批次');
    expect(rig.bodies['apply'], hasLength(1));
    expect(projections, 1);
    expect(find.text('已导入并同步最新资料。'), findsOneWidget);
    await openConfirmation(tester, '撤销这次正式导入', '确认撤销这个批次');
    expect(rig.bodies['undo'], isNull);
    await tap(tester, '确认撤销这个批次');
    expect(rig.bodies['undo'], hasLength(1));
    expect(projections, 2);
    expect(find.text('已撤销并同步最新资料。'), findsOneWidget);
    expect(
      await rig.source.fixture.db
          .select(rig.source.fixture.db.pendingOperations)
          .get(),
      isEmpty,
    );
    expect(
      await rig.source.fixture.db
          .select(rig.source.fixture.db.localEntities)
          .get(),
      isEmpty,
    );
    final saved = (await rig.source.store.read(
      rig.source.fixture.space,
      rig.source.stageId,
    ))!;
    await rig.source.store.verifySource(saved);
    expect(
      rig.source.calls.any((call) => call.contains('/sync/push')),
      isFalse,
    );
  });

  testWidgets('stage仍ready而真实apply失败，不报告成功或自动再次入队', (tester) async {
    final rig = MutationRig();
    await rig.init();
    addTearDown(rig.close);
    rig.source.status = 'ready';
    var projections = 0;
    final lease = delegateLease(rig.lease, (method, path, next) async {
      if (Uri.parse(path).pathSegments.last == 'jobs') {
        return {
          'stage_id': rig.source.stageId,
          'stage_version': 1,
          'jobs': [jobMetadata('apply', 'failed', 77)],
        };
      }
      return next();
    });
    await mount(
      tester,
      rig.source,
      lease,
      refresh: (_) async {
        projections++;
      },
    );
    await tap(tester, '获取服务器状态');
    expect(find.text('正式导入：执行失败'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认正式导入'),
    );
    expect(button.onPressed, isNull);
    expect(rig.bodies['apply'], isNull);
    expect(projections, 0);
    expect(find.text('已导入并同步最新资料。'), findsNothing);
  });

  Future<void> prime(StageRig source, List<Map<String, Object?>> items) async {
    await source.init();
    await source.store.stage(
      source.lease,
      bytes: stageBytes(30),
      format: ImportFileKind.flowtraceJson,
      fileName: '合成钱迹.csv',
      stageId: source.stageId,
    );
    final record = await source.coordinator.uploadAndSeal(
      source.lease,
      source.stageId,
    );
    source.status = 'parsed';
    await source.store.acceptStatus(
      source.lease,
      record,
      StageImportStatus.parse({
        ...source.statusBody(),
        'requirements_version': 1,
        'requirements_hash': requirementsHash(items),
        'requirements_count': items.length,
      }),
    );
  }

  testWidgets('已发布且本机原件已释放，新会话仍需明确续接后才能正式撤销', (tester) async {
    final rig = MutationRig();
    await rig.init();
    addTearDown(rig.close);
    rig.source.status = 'applied';
    rig.released = true;
    await rig.commands.refresh(rig.lease, rig.source.stageId);
    final released = await rig.source.store.releaseLocalSource(
      rig.lease,
      rig.source.stageId,
    );
    final originalInput = released.stored.createBodyJson;
    final oldBinding = released.binding;
    rig.source.sessionId = qid(93);
    final lease = delegateLease(rig.lease, (method, path, next) async {
      if (Uri.parse(path).pathSegments.last == 'jobs') {
        return {
          'stage_id': rig.source.stageId,
          'stage_version': rig.source.version,
          'jobs': [],
        };
      }
      return next();
    });
    var projections = 0;
    await mount(
      tester,
      rig.source,
      lease,
      refresh: (_) async {
        projections++;
      },
    );
    await tap(tester, '原件、续接与清理');
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '核对原件并重新授权'),
    );
    expect(button.onPressed, isNotNull);
    expect(rig.bodies['reauthorize'], isNull);
    await openConfirmation(tester, '核对原件并重新授权', '明确重新授权');
    expect(find.text('明确重新授权'), findsOneWidget);
    expect(rig.bodies['reauthorize'], isNull);
    expect(
      (await rig.source.store.read(
        rig.source.fixture.space,
        rig.source.stageId,
      ))!.binding,
      oldBinding,
    );
    await tap(tester, '明确重新授权');
    final rebound = (await rig.source.store.read(
      rig.source.fixture.space,
      rig.source.stageId,
    ))!;
    expect(rebound.localReleased, isTrue);
    expect(rebound.version, 2);
    expect(rebound.binding['session_id'], qid(93));
    expect(rebound.stored.createBodyJson, originalInput);
    expect(
      await rig.source.fixture.db
          .select(rig.source.fixture.db.stageImportChunks)
          .get(),
      isEmpty,
    );
    expect(rig.bodies['apply'], isNull);
    await tap(tester, '获取服务器状态');
    await openConfirmation(tester, '撤销这次正式导入', '确认撤销这个批次');
    await tap(tester, '确认撤销这个批次');
    expect(rig.bodies['undo'], hasLength(1));
    expect(find.text('已撤销并同步最新资料。'), findsOneWidget);
    expect(projections, 2);
    expect(rig.source.createBodies, hasLength(1));
    expect(rig.source.uploaded, hasLength(1));
  });

  testWidgets('跨页选择真实落草稿，重开从首全核，未读末页不能保存完整映射', (tester) async {
    final source = StageRig();
    addTearDown(source.close);
    final items = [
      for (var index = 1; index <= 2; index++)
        {
          'position': index,
          'kind': 'scope',
          'source_kind': 'identifier',
          'source_key': qid(200 + index),
          'resource_type': 'book',
          'first_line': index + 1,
          'attachment_source': null,
        },
    ];
    await prime(source, items);
    final cursors = <String?>[];
    final lease = delegateLease(source.lease, (method, path, next) async {
      final uri = Uri.parse(path);
      expect(uri.path.endsWith('/requirements'), isTrue);
      final cursor = uri.queryParameters['cursor'];
      cursors.add(cursor);
      return cursor == null
          ? requirementPage(source, items, [items[0]], cursor: 'page-2')
          : requirementPage(source, items, [items[1]]);
    });
    await mount(tester, source, lease);
    await tap(tester, '查看原始资源清单');
    final first = StageImportRequirement.parse(items.first);
    await tester.ensureVisible(
      find.byKey(ValueKey('${stageRequirementKey(first)}:null')),
    );
    await tester.tap(
      find.byKey(ValueKey('${stageRequirementKey(first)}:null')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('合成目标账本').last);
    await tester.pumpAndSettle();
    final incomplete = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '保存资源选择并重新解析'),
    );
    expect(incomplete.onPressed, isNull);
    expect(
      (await source.store.read(
        source.fixture.space,
        source.stageId,
      ))!.mappingDraft!.choice(first),
      qid(2),
    );
    await tap(tester, '下一页原始资源');
    final second = StageImportRequirement.parse(items.last);
    await tester.ensureVisible(
      find.byKey(ValueKey('${stageRequirementKey(second)}:null')),
    );
    await tester.tap(
      find.byKey(ValueKey('${stageRequirementKey(second)}:null')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('合成目标账本').last);
    await tester.pumpAndSettle();
    expect(
      (await source.store.read(
        source.fixture.space,
        source.stageId,
      ))!.mappingDraft!.choiceCount,
      2,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, '保存资源选择并重新解析'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
    await mount(tester, source, lease);
    await tap(tester, '查看原始资源清单');
    expect(cursors, [null, 'page-2', null]);
    expect(
      find.byKey(ValueKey('${stageRequirementKey(first)}:${qid(2)}')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, '保存资源选择并重新解析'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('图片目标未保存阻更新，真实所选bytes传给上传接口并成对落草稿', (tester) async {
    final source = StageRig();
    addTearDown(source.close);
    final item = {
      'position': 1,
      'kind': 'image',
      'source_kind': 'identifier',
      'source_key': qid(201),
      'resource_type': null,
      'first_line': 2,
      'attachment_source': null,
    };
    final items = [item];
    await prime(source, items);
    final lease = delegateLease(
      source.lease,
      (method, path, next) async => requirementPage(source, items, items),
    );
    var uploads = 0;
    final key = await mount(
      tester,
      source,
      lease,
      chooseImage: () async => XFile.fromData(picture(), path: '实际选择.png'),
      upload: (_, bytes, mime) async {
        uploads++;
        expect(bytes, picture());
        expect(mime, 'image/png');
        return qid(90);
      },
    );
    await tap(tester, '查看原始资源清单');
    final requirement = StageImportRequirement.parse(item);
    await tester.ensureVisible(
      find.byKey(
        ValueKey('image-book:${stageRequirementKey(requirement)}:null'),
      ),
    );
    await tester.tap(
      find.byKey(
        ValueKey('image-book:${stageRequirementKey(requirement)}:null'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('现有账本：合成目标账本').last);
    await tester.pumpAndSettle();
    expect(await key.currentState!.prepareForUpdate(), isFalse);
    await tap(tester, '选择并上传原图');
    expect(uploads, 1);
    expect(await key.currentState!.prepareForUpdate(), isTrue);
    final saved = (await source.store.read(
      source.fixture.space,
      source.stageId,
    ))!.mappingDraft!;
    expect(saved.mapping['resource_mapping'], {qid(201): qid(90)});
    expect(saved.mapping['attachment_transfers'], {qid(90): qid(2)});
    expect(saved.choice(requirement), qid(90));
  });
}
