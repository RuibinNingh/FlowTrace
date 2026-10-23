import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/entry/entry_page.dart';
import 'package:flowtrace/features/home/home_page.dart';

import 'entry_page_test.dart' show setupApp, bookId;

const _selected = 'ba000000-0000-4000-8000-000000000094';

Future<AppController> _fixture({bool quick = true}) async {
  final app = await setupApp();
  await SyncStore(app.repository).configure(
    app.space!,
    'fa000000-0000-4000-8000-000000000094',
    'fa000000-0000-4000-8000-000000000095',
  );
  await app.preferences.initialize();
  await app.preferences.update(
    app.preferences.value.copyWith(quickEntry: quick, billImagesEnabled: false),
  );
  await app.protection.initialize();
  return app;
}

Future<void> _mount(
  WidgetTester tester,
  AppController app, {
  Key? key,
  GlobalKey<NavigatorState>? navigator,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: HomePage(
        key: key,
        app: app,
        space: app.space!,
        clock: () => DateTime.utc(2026, 11, 15),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _cancel(WidgetTester tester) async {
  await tester.tap(find.byTooltip('返回并保留草稿'));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.byType(EntryPage), findsNothing);
}

Future<void> _close(WidgetTester tester, AppController app) async {
  try {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    app.dispose();
    await tester.runAsync(app.database.close);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);

  testWidgets(
    'startup opens the persisted writable selected book once and preserves the existing full draft',
    (tester) async {
      final app = (await tester.runAsync(_fixture))!;
      try {
        await app.ledger.save(
          app.space!,
          entityType: 'book',
          entityId: _selected,
          scopeId: app.space!.userId,
          payload: {
            'name': '秒开指定账本',
            'currency': 'CNY',
            'timezone': 'Asia/Shanghai',
            'month_start_day': 1,
          },
        );
        await app.repository.writeSetting(
          'ledger.selected-book.${app.space!.id}',
          _selected,
        );
        final draft = await app.ledger.saveDraft(
          app.space!,
          bookId: bookId,
          payload: {
            'note': '保留原完整草稿',
            'attachment_ids': ['aa000000-0000-4000-8000-000000000094'],
          },
          ui: {'expression': '12+', 'discount': '0.01'},
        );
        final original = (await app.ledger.readDraft(app.space!, draft))!;
        final operations = (await app.repository.pending(
          app.space!,
        )).map((row) => row.operationJson).toList();
        await _mount(tester, app);
        expect(find.byType(EntryPage), findsOneWidget);
        final entry = tester.widget<EntryPage>(find.byType(EntryPage));
        expect(entry.bookId, _selected);
        expect(entry.draft, isNull);
        await _cancel(tester);
        await app.preferences.update(
          app.preferences.value.copyWith(groupThousands: true),
        );
        await tester.pumpAndSettle();
        expect(find.byType(EntryPage), findsNothing);
        final retained = (await app.ledger.readDraft(app.space!, draft))!;
        expect(retained.payload, original.payload);
        expect(retained.ui, original.ui);
        expect((await app.ledger.read(app.space!)).bills, isEmpty);
        expect(
          (await app.repository.pending(
            app.space!,
          )).map((row) => row.operationJson).toList(),
          operations,
        );
      } finally {
        await _close(tester, app);
      }
    },
  );

  testWidgets(
    'changing quick-entry while home is active waits for a new home lifecycle',
    (tester) async {
      final app = (await tester.runAsync(() => _fixture(quick: false)))!;
      try {
        await _mount(tester, app, key: const ValueKey('first-home'));
        await app.preferences.update(
          app.preferences.value.copyWith(quickEntry: true),
        );
        await tester.pumpAndSettle();
        expect(find.byType(EntryPage), findsNothing);
        await _mount(tester, app, key: const ValueKey('next-home'));
        expect(find.byType(EntryPage), findsOneWidget);
        await _cancel(tester);
        expect((await app.ledger.read(app.space!)).bills, isEmpty);
      } finally {
        await _close(tester, app);
      }
    },
  );

  testWidgets(
    'locked startup waits for a real unlock and for the home route to become current',
    (tester) async {
      final app = (await tester.runAsync(_fixture))!;
      final navigator = GlobalKey<NavigatorState>();
      try {
        expect(
          await tester.runAsync(
            () => app.protection.setPassword('synthetic-quick-entry-password'),
          ),
          isTrue,
        );
        await app.protection.lock();
        await _mount(tester, app, navigator: navigator);
        expect(find.byType(EntryPage), findsNothing);
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('覆盖首页的当前页面')),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          await tester.runAsync(
            () => app.protection.unlock('synthetic-quick-entry-password'),
          ),
          isTrue,
        );
        await tester.pumpAndSettle();
        expect(find.byType(EntryPage), findsNothing);
        expect(find.text('覆盖首页的当前页面'), findsOneWidget);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byType(EntryPage), findsOneWidget);
        await _cancel(tester);
        expect((await app.ledger.read(app.space!)).bills, isEmpty);
      } finally {
        await _close(tester, app);
      }
    },
  );

  testWidgets(
    'startup never opens an entry while the selected ledger is in recovery read-only state',
    (tester) async {
      final app = (await tester.runAsync(_fixture))!;
      try {
        await SyncStore(
          app.repository,
        ).requireRebuild(app.space!, 'epoch_changed');
        await _mount(tester, app);
        expect(find.byType(EntryPage), findsNothing);
        expect(find.byType(HomePage), findsOneWidget);
        expect((await app.ledger.read(app.space!)).bills, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await _close(tester, app);
      }
    },
  );
}
