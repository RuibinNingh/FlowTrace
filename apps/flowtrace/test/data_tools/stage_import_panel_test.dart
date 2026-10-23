import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flowtrace/data/data_tools/stage_import_lease.dart';
import 'package:flowtrace/features/data_tools/stage_import_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stage_import_store_test.dart' show StageRig, stageBytes;
import '../ledger/query_fixtures.dart' show qid;

void main() {
  late StageRig rig;
  late ChangeNotifier authority;
  var authorityKey = 'original';
  setUp(() async {
    rig = StageRig();
    await rig.init();
    authority = ChangeNotifier();
    authorityKey = 'original';
  });
  tearDown(() async {
    authority.dispose();
    await rig.close();
  });

  Future<GlobalKey<StageImportPanelState>> mount(
    WidgetTester tester, {
    Future<XFile?> Function()? chooseFile,
    StageImportLease? captured,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey<StageImportPanelState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StageImportPanel(
            key: key,
            store: rig.store,
            captureLease: () => captured ?? rig.lease,
            authority: authority,
            authorityKey: () => authorityKey,
            chooseFile: chooseFile,
            destinations: [
              StageImportDestination(
                id: qid(2),
                name: '合成目标账本',
                timezone: 'Asia/Shanghai',
                currency: 'CNY',
                currencyScale: 2,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  testWidgets('选择原件先完整落本机，无上传或财务效果', (tester) async {
    await mount(
      tester,
      // Native cross_file ignores `name`; supplying its synthetic path makes
      // this fixture represent a real picker result without touching a file.
      chooseFile: () async =>
          XFile.fromData(stageBytes(25), path: '合成原件.csv', name: '合成原件.csv'),
    );
    await tester.tap(find.text('选择并保存原件'));
    await tester.pumpAndSettle();
    expect(find.textContaining('原始文件已保存在本机'), findsOneWidget);
    final records = await rig.store.list(rig.fixture.space);
    expect(records, hasLength(1));
    expect(records.single.stored.fileName, '合成原件.csv');
    expect((records.single.createBody['mapping'] as Map)['template_mapping'], {
      'scope_id': qid(2),
      'timezone': 'Asia/Shanghai',
      'currency': 'CNY',
      'currency_scale': 2,
    });
    await rig.store.verifySource(records.single);
    expect(rig.calls, isEmpty);
    expect(
      await rig.fixture.db.select(rig.fixture.db.pendingOperations).get(),
      isEmpty,
    );
  });

  testWidgets('继续上传后仅显示真实待解析状态，不出现导入成功', (tester) async {
    await rig.stage(stageBytes(25));
    await mount(tester);
    await tester.tap(find.text('合成钱迹.csv'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('继续上传与解析'));
    await tester.tap(find.text('继续上传与解析'));
    await tester.pumpAndSettle();
    expect(find.textContaining('等待解析'), findsWidgets);
    expect(find.text('导入成功'), findsNothing);
    expect(
      await rig.fixture.db.select(rig.fixture.db.localEntities).get(),
      isEmpty,
    );
    expect(rig.calls.any((call) => call.contains('/sync/')), isFalse);
  });

  testWidgets('未协商stage能力明确说明，原件可保存但上传不可点', (tester) async {
    await rig.stage(stageBytes(25));
    final original = rig.lease;
    await mount(
      tester,
      captured: StageImportLease(
        data: original.data,
        sessionId: original.sessionId,
        upload: original.upload,
      ),
    );
    expect(find.textContaining('当前服务器尚未开放大文件导入'), findsOneWidget);
    await tester.tap(find.text('合成钱迹.csv'));
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '继续上传与解析'),
    );
    expect(button.onPressed, isNull);
    expect(rig.calls, isEmpty);
  });

  testWidgets('选择期间拒更新，取消后可更新；切身份清视图保原源', (tester) async {
    await rig.stage(stageBytes(25));
    final chooser = Completer<XFile?>();
    final key = await mount(tester, chooseFile: () => chooser.future);
    await tester.tap(find.text('选择并保存原件'));
    await tester.pump();
    expect(await key.currentState!.prepareForUpdate(), isFalse);
    chooser.complete(null);
    await tester.pumpAndSettle();
    expect(await key.currentState!.prepareForUpdate(), isTrue);
    authorityKey = 'new-account';
    authority.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('合成钱迹.csv'), findsNothing);
    expect(find.textContaining('原始文件仍保留在原资料空间'), findsOneWidget);
    expect(await rig.store.list(rig.fixture.space), hasLength(1));
  });
}
