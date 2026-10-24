import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flowtrace/data/data_tools/data_tools_repository.dart';
import 'package:flowtrace/data/data_tools/export_saver.dart';
import 'package:flowtrace/features/data_tools/data_tools_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import '../ledger/query_fixtures.dart';
import 'data_tools_models_test.dart' show documentJson;
import 'stage_import_store_test.dart' show StageRig;

final class _Destination implements DataToolsExportDestination {
  Uint8List? written;
  bool discarded = false;
  @override
  Future<DataToolsExportStatus> write(
    Uint8List bytes, {
    required void Function() guard,
  }) async {
    guard();
    written = bytes;
    return DataToolsExportStatus.downloadStarted;
  }

  @override
  Future<void> discard() async => discarded = true;
}

void main() {
  late QueryFixture fixture;
  late DataToolsRepository repository;
  late ChangeNotifier authority;
  late Map<String, Object?> document;
  late Uint8List original;
  var current = true, uploadCount = 0, refreshCount = 0;
  String key = 'original';
  final destination = _Destination();
  Map<String, Object?>? lastExport;
  List<Map<String, Object?>> parseErrors = [];
  String? parseRequestId;
  List<Map<String, Object?>> attachmentSources = [];
  Map<String, Object?>? applied;
  var undoBeforeApplyReturn = false;
  var undoDuringRefresh = false;
  bool? lastMutationUndo;

  DataToolsLease lease() => DataToolsLease(
    space: fixture.space,
    clientId: qid(90),
    epoch: qEpoch,
    isCurrent: () => current,
    request: (method, path, {body, bodyJson, bodyBytes, contentType}) async {
      if (path.contains('/history')) {
        return {
          'batches': [],
          'limit': 100,
          'has_more': false,
          'next_cursor': null,
        };
      }
      if (path.endsWith('/parse')) {
        return {
          'format': 'flowtrace_json',
          'source_sha256': sha256.convert(original).toString(),
          'document': parseErrors.isEmpty ? document : null,
          'errors': parseErrors,
          'mapping_requirements': [],
          'attachment_sources': attachmentSources,
          'request_id': ?parseRequestId,
        };
      }
      if (path.endsWith('/undo')) {
        return {
          'batch_id': path.split('/')[3],
          'status': 'undone',
          'replayed': false,
        };
      }
      final request = jsonDecode(bodyJson!) as Map;
      final importDocument = request['document'] as Map;
      final target = const Uuid().v5(
        fixture.space.userId,
        '${importDocument['source_namespace']}:$qa',
      );
      if (path.endsWith('/preview')) {
        return {
          'batch_id': request['batch_id'],
          'content_hash': 'a' * 64,
          'can_apply': true,
          'fingerprint_scan_complete': true,
          'rows': [
            {
              'row': 1,
              'source_id': qa,
              'entity_id': target,
              'status': 'new',
              'warning': null,
            },
          ],
          'errors': [],
        };
      }
      if (path.endsWith('/apply')) {
        applied = request.cast<String, Object?>();
        if (undoBeforeApplyReturn) {
          await DataToolsRepository(
            fixture.local,
          ).undo(lease(), request['batch_id'] as String);
        }
        return {
          'batch_id': request['batch_id'],
          'status': 'applied',
          'created': [target],
          'duplicates': [],
          'commit_id': qb,
          'scope_revisions': {qBook: '1'},
          'replayed': false,
          'attachment_transfers': [],
        };
      }
      throw StateError('Unexpected test route');
    },
    download:
        (path, {method = 'GET', body, maxBytes = 10 * 1024 * 1024}) async {
          expect(method, 'POST');
          lastExport = body;
          return Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'format': 'flowtrace-export-v1',
                'document': document,
                'attachments': [],
                'scope_versions': {},
                'filter': body,
              }),
            ),
          );
        },
  );

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
    bool syncFails = false,
    StageRig? stages,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: DataToolsPage(
          repository: repository,
          captureLease: lease,
          loadCatalog: (_) async => DataToolsCatalog(
            books: [
              DataToolsBookOption(
                id: qBook,
                name: '合成账本',
                currency: 'CNY',
                currencyScale: 2,
                timezone: 'Asia/Shanghai',
              ),
            ],
            resources: [],
          ),
          onMutation: (_, result, {required undo}) async {
            refreshCount++;
            lastMutationUndo = undo;
            if (syncFails) throw StateError('synthetic offline');
            if (undoDuringRefresh && result != null) {
              await repository.undo(lease(), result.batchId);
            }
          },
          authority: authority,
          authorityKey: () => key,
          chooseFile: () async => XFile.fromData(
            original,
            path: 'synthetic.json',
            name: 'synthetic.json',
          ),
          chooseImage: () async => XFile.fromData(
            Uint8List.fromList([1, 2, 3]),
            path: 'different.png',
            name: 'different.png',
          ),
          uploadImage: (_, bytes, media) async {
            uploadCount++;
            return qc;
          },
          chooseExportDestination: (_) async => destination,
          stageStore: stages?.store,
          captureStageLease: stages == null ? null : () => stages.lease,
          refreshStageProjection: stages == null ? null : (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectFile(WidgetTester tester) async {
    await tester.tap(find.text('选择数据文件'));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    fixture = QueryFixture();
    await fixture.local.registerSpace(fixture.space);
    repository = DataToolsRepository(fixture.local);
    authority = ChangeNotifier();
    document = documentJson(amount: '125');
    original = Uint8List.fromList(utf8.encode(jsonEncode(document)));
    current = true;
    key = 'original';
    uploadCount = refreshCount = 0;
    applied = lastExport = null;
    parseErrors = attachmentSources = [];
    parseRequestId = null;
    undoBeforeApplyReturn = false;
    undoDuringRefresh = false;
    lastMutationUndo = null;
  });
  tearDown(() async {
    authority.dispose();
    await fixture.db.close();
  });

  testWidgets(
    'parse errors show row, field, reason, code and request correlation',
    (tester) async {
      parseErrors = [
        {'row': 1, 'field': '表头', 'code': 'unsupported_qianji_columns'},
      ];
      parseRequestId = qid(501);
      await mount(tester);
      await selectFile(tester);
      expect(find.textContaining('第1行 · 字段：表头'), findsOneWidget);
      expect(find.textContaining('未识别钱迹表头'), findsOneWidget);
      expect(
        find.textContaining('错误码：unsupported_qianji_columns'),
        findsOneWidget,
      );
      expect(find.text('请求ID：${qid(501)}'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'complete import keeps the already selected source without upload or apply',
    (tester) async {
      final stages = StageRig();
      await stages.init();
      addTearDown(stages.close);
      parseErrors = [
        {'row': 52, 'field': null, 'code': 'too_many_rows'},
      ];
      await mount(tester, stages: stages);
      await selectFile(tester);
      final target = find.text('钱迹原始导出 / 超过50条完整导入');
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      final saved = await stages.store.list(stages.fixture.space);
      expect(saved, hasLength(1));
      expect(saved.single.stored.fileName, 'synthetic.json');
      expect(saved.single.stored.format, 'flowtrace_json');
      await stages.store.verifySource(saved.single);
      expect(stages.calls, isEmpty);
      expect(applied, isNull);
      expect(
        await fixture.db.select(fixture.db.pendingOperations).get(),
        isEmpty,
      );
      expect(find.textContaining('所选原件已完整保存在本机'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'confirmation is durable and reports pending local sync honestly',
    (tester) async {
      await mount(tester, syncFails: true);
      await selectFile(tester);
      await tester.tap(find.text('生成导入预览'));
      await tester.pumpAndSettle();
      expect(find.text('CNY 1.25'), findsOneWidget);
      await tester.ensureVisible(find.text('确认正式导入'));
      await tester.tap(find.text('确认正式导入'));
      await tester.pumpAndSettle();
      expect(applied, isNull);
      await tester.tap(find.widgetWithText(FilledButton, '确认导入'));
      await tester.pumpAndSettle();
      expect(applied, isNotNull);
      expect(refreshCount, 1);
      expect(find.text('服务端已确认导入，本机同步尚未完成，请稍后同步查看。'), findsOneWidget);
      expect((await repository.list(fixture.space)).single.phase, 'applied');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid file row remains visible without parsed document at narrow width',
    (tester) async {
      parseErrors = [
        {'row': 2, 'field': 'money', 'code': 'invalid_exact_amount'},
      ];
      parseRequestId = qid(502);
      await mount(tester, size: const Size(320, 750));
      await selectFile(tester);
      final error = find.textContaining('错误码：invalid_exact_amount');
      await tester.ensureVisible(error);
      expect(error, findsOneWidget);
      expect(find.textContaining('第2行 · 字段：money'), findsOneWidget);
      expect(find.textContaining('金额精度或范围不正确'), findsOneWidget);
      final correlation = find.text('请求ID：${qid(502)}');
      await tester.ensureVisible(correlation);
      expect(correlation, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late confirmed apply uses already-undone local phase for refresh and message',
    (tester) async {
      undoBeforeApplyReturn = true;
      await mount(tester);
      await selectFile(tester);
      await tester.tap(find.text('生成导入预览'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认正式导入'));
      await tester.tap(find.text('确认正式导入'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认导入'));
      await tester.pumpAndSettle();
      expect(lastMutationUndo, isTrue);
      expect(find.text('该批次已在其他操作中撤销，本机账本已刷新。'), findsOneWidget);
      final stored = (await repository.list(fixture.space)).single;
      expect(stored.phase, 'undone');
      expect(stored.result!.toJson()['status'], 'applied');
    },
  );

  testWidgets(
    'undo discovered during refresh changes final message without rewriting receipt',
    (tester) async {
      undoDuringRefresh = true;
      await mount(tester);
      await selectFile(tester);
      await tester.tap(find.text('生成导入预览'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认正式导入'));
      await tester.tap(find.text('确认正式导入'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认导入'));
      await tester.pumpAndSettle();
      expect(find.text('该批次已在其他操作中撤销，本机账本已刷新。'), findsOneWidget);
      final stored = (await repository.list(fixture.space)).single;
      expect(stored.phase, 'undone');
      expect(stored.result!.toJson()['status'], 'applied');
    },
  );

  testWidgets(
    'identity notification clears source selection and in-memory mapping',
    (tester) async {
      await mount(tester);
      await selectFile(tester);
      expect(find.text('synthetic.json'), findsOneWidget);
      final state = tester.state<DataToolsPageState>(
        find.byType(DataToolsPage),
      );
      expect(await state.prepareForUpdate(), isFalse);
      current = false;
      key = 'different';
      authority.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('synthetic.json'), findsNothing);
      expect(find.text('联网载入数据工具'), findsOneWidget);
      expect(await state.prepareForUpdate(), isTrue);
    },
  );

  testWidgets('original image mismatch is rejected before upload', (
    tester,
  ) async {
    final row = (document['rows'] as List).single as Map;
    (row['payload'] as Map)['attachment_ids'] = [qd];
    original = Uint8List.fromList(utf8.encode(jsonEncode(document)));
    attachmentSources = [
      {
        'source_id': qd,
        'sha256': 'a' * 64,
        'size_bytes': 3,
        'media_type': 'image/png',
      },
    ];
    await mount(tester);
    await selectFile(tester);
    await tester.ensureVisible(find.text('选择原图'));
    await tester.tap(find.text('选择原图'));
    await tester.pumpAndSettle();
    expect(uploadCount, 0);
    expect(find.text('所选图片与导出清单不一致，请选择原始图片。'), findsOneWidget);
  });

  testWidgets(
    'export uses authorized POST and describes browser download accurately',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('导出').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('导出并保存'));
      await tester.tap(find.text('导出并保存'));
      await tester.pumpAndSettle();
      expect(
        lastExport!['scope_ids'],
        containsAll([qBook, fixture.space.userId]),
      );
      expect(destination.written, isNotNull);
      expect(destination.discarded, isTrue);
      expect(find.text('已发起浏览器下载，请在下载列表查看文件。'), findsOneWidget);
    },
  );
}
