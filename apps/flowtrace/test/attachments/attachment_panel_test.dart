import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/attachments/attachment_panel.dart';
import 'package:flowtrace/features/attachments/image_attachment_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'attachment_repository_test.dart'
    show AttachmentHarness, picture, epoch, scope, attachmentId;

Future<void> flushUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150; i++) {
    await tester.pump();
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(ready(), isTrue, reason: 'Attachment UI did not finish isolated I/O');
}

void main() {
  late AttachmentHarness harness;
  setUp(() async {
    harness = AttachmentHarness(
      await Directory.systemTemp.createTemp('flowtrace-panel-test-'),
    );
    await harness.open();
  });
  tearDown(() async {
    await harness.close();
    final absolute = p.normalize(p.absolute(harness.directory.path));
    if (!p.isWithin(p.absolute(Directory.systemTemp.path), absolute) ||
        !p.basename(absolute).startsWith('flowtrace-panel-test-')) {
      throw StateError('Unsafe attachment panel fixture directory');
    }
    await Directory(absolute).delete(recursive: true);
  });

  testWidgets(
    'selection persists references; removing a draft reference keeps original file',
    (tester) async {
      var ids = <String>[];
      final busy = <bool>[];
      late StateSetter setEditor;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setEditor = setState;
                return SingleChildScrollView(
                  child: AttachmentPanel(
                    repository: harness.repository,
                    space: harness.space,
                    epoch: epoch,
                    scopeId: scope,
                    attachmentIds: ids,
                    isCurrent: () => true,
                    onBusyChanged: busy.add,
                    picker: () async =>
                        SelectedAttachmentImage(picture(), 'image/png', 3, 2),
                    onChanged: (next) async {
                      await harness.local.writeSetting(
                        'synthetic-draft-refs',
                        jsonEncode(next),
                      );
                      setEditor(() => ids = List.from(next));
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('attachment-add')));
      await flushUntil(tester, () => ids.isNotEmpty);
      await tester.pumpAndSettle();
      final id = ids.single;
      final record = (await tester.runAsync(
        () => harness.repository.get(harness.space, id),
      ))!;
      expect(
        await tester.runAsync(
          () => harness.repository.original(harness.space, record),
        ),
        picture(),
      );
      expect(find.text('图片 1'), findsOneWidget);
      expect(busy, [true, false]);
      await tester.tap(find.byTooltip('从本笔移除图片1'));
      await flushUntil(tester, () => ids.isEmpty);
      await tester.pumpAndSettle();
      expect(
        await tester.runAsync(
          () => harness.local.readSetting('synthetic-draft-refs'),
        ),
        '[]',
      );
      expect(
        await tester.runAsync(
          () => harness.repository.original(harness.space, record),
        ),
        picture(),
      );
      expect(tester.takeException(), isNull);
      expect(busy, [true, false, true, false]);
    },
  );

  testWidgets('cancelled selection creates no reference or original', (
    tester,
  ) async {
    var callbacks = 0;
    final busy = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttachmentPanel(
            repository: harness.repository,
            space: harness.space,
            epoch: epoch,
            scopeId: scope,
            attachmentIds: const [],
            isCurrent: () => true,
            picker: () async => null,
            onBusyChanged: busy.add,
            onChanged: (ids) async {
              callbacks++;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('attachment-add')));
    await tester.pumpAndSettle();
    expect(callbacks, 0);
    expect(busy, [true, false]);
    expect(
      await tester.runAsync(() => harness.repository.list(harness.space)),
      isEmpty,
    );
  });

  testWidgets(
    'failed draft association can retry the same staged ID without choosing again',
    (tester) async {
      var ids = <String>[];
      var reject = true;
      var picks = 0;
      late StateSetter setEditor;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setEditor = setState;
                return SingleChildScrollView(
                  child: AttachmentPanel(
                    repository: harness.repository,
                    space: harness.space,
                    epoch: epoch,
                    scopeId: scope,
                    attachmentIds: ids,
                    isCurrent: () => true,
                    picker: () async {
                      picks++;
                      return SelectedAttachmentImage(
                        picture(),
                        'image/png',
                        3,
                        2,
                      );
                    },
                    onChanged: (next) async {
                      if (reject) throw StateError('synthetic disk failure');
                      setEditor(() => ids = List.from(next));
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('attachment-add')));
      await flushUntil(
        tester,
        () => find.text('重新关联已暂存图片').evaluate().isNotEmpty,
      );
      final pending = (await tester.runAsync(
        () => harness.repository.list(harness.space),
      ))!.single;
      reject = false;
      await tester.tap(find.text('重新关联已暂存图片'));
      await flushUntil(tester, () => ids.isNotEmpty);
      await tester.pumpAndSettle();
      expect(ids, [pending.id]);
      expect(picks, 1);
      expect(
        (await tester.runAsync(() => harness.repository.list(harness.space)))!,
        hasLength(1),
      );
      expect(find.textContaining('草稿关联尚未保存'), findsNothing);
    },
  );

  testWidgets(
    'late picker after data-space change cannot stage or call the new editor',
    (tester) async {
      final choice = Completer<SelectedAttachmentImage?>();
      var callbacks = 0;
      final busy = <bool>[];
      Widget editor(DataSpace space) => MaterialApp(
        home: Scaffold(
          body: AttachmentPanel(
            repository: harness.repository,
            space: space,
            epoch: epoch,
            scopeId: scope,
            attachmentIds: const [],
            isCurrent: () => true,
            onBusyChanged: busy.add,
            picker: () => choice.future,
            onChanged: (ids) async {
              callbacks++;
            },
          ),
        ),
      );
      await tester.pumpWidget(editor(harness.space));
      await tester.tap(find.byKey(const Key('attachment-add')));
      await tester.pump();
      final other = DataSpace(
        server: harness.space.server,
        serverInstanceId: harness.space.serverInstanceId,
        userId: 'other-user',
      );
      await tester.pumpWidget(editor(other));
      choice.complete(SelectedAttachmentImage(picture(), 'image/png', 3, 2));
      await tester.pumpAndSettle();
      expect(callbacks, 0);
      expect(busy, [
        true,
      ]); // The cancelled old action cannot clear a new space.
      expect(
        await tester.runAsync(() => harness.repository.list(harness.space)),
        isEmpty,
      );
    },
  );

  testWidgets(
    'preview uses local original and hides immediately when captured identity changes',
    (tester) async {
      final record = (await tester.runAsync(() => harness.stage()))!;
      var current = true;
      final changes = ChangeNotifier();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentPanel(
              repository: harness.repository,
              space: harness.space,
              epoch: epoch,
              scopeId: scope,
              attachmentIds: [record.id],
              isCurrent: () => current,
              contextChanges: changes,
              onChanged: (ids) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('预览图片1'));
      await flushUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      current = false;
      changes.notifyListeners();
      await tester.pump();
      expect(find.text('资料空间已变化，请返回。'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      changes.dispose();
    },
  );

  testWidgets(
    'persisted scope revocation hides an open downloaded image without app notification',
    (tester) async {
      await tester.runAsync(() async {
        await harness.state();
        await harness.repository.cache(
          harness.space,
          epoch,
          scope,
          attachmentId,
          'original',
          picture(),
          sha256.convert(picture()).toString(),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentPanel(
              repository: harness.repository,
              space: harness.space,
              epoch: epoch,
              scopeId: scope,
              attachmentIds: const [attachmentId],
              // Deliberately no AppController notification or permission shortcut.
              isCurrent: () => true,
              onChanged: (ids) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('预览图片1'));
      await flushUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(find.byType(Image), findsOneWidget);
      await tester.runAsync(
        () => SyncStore(harness.local).revokeScope(harness.space, scope),
      );
      await flushUntil(
        tester,
        () => find.text('资料空间已变化，请返回。').evaluate().isNotEmpty,
      );
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('disposing the editor clears its separately pushed preview', (
    tester,
  ) async {
    final record = (await tester.runAsync(() => harness.stage()))!;
    var showEditor = true;
    late StateSetter updateParent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              updateParent = setState;
              return showEditor
                  ? AttachmentPanel(
                      repository: harness.repository,
                      space: harness.space,
                      epoch: epoch,
                      scopeId: scope,
                      attachmentIds: [record.id],
                      isCurrent: () => true,
                      onChanged: (ids) async {},
                    )
                  : const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('预览图片1'));
    await flushUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
    updateParent(() => showEditor = false);
    await flushUntil(
      tester,
      () => find.text('资料空间已变化，请返回。').evaluate().isNotEmpty,
    );
    expect(find.byType(AttachmentPreviewPage), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
  });
}
