import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/features/home/home_page.dart';
import 'package:flowtrace/features/entry/entry_page.dart';
import 'package:flowtrace/features/search/search_page.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/data/preferences/app_preferences.dart';
import 'package:flowtrace/platform/windows/windows_runtime.dart';

import 'entry_page_test.dart' show setupApp, bookId, categoryId;

const _bill = 'bb000000-0000-4000-8000-000000000099';
const _childCategory = 'ca000000-0000-4000-8000-000000000099';

Future<AppController> _homeFixture() async {
  final app = await setupApp();
  await SyncStore(app.repository).configure(
    app.space!,
    'fa000000-0000-4000-8000-000000000090',
    'fa000000-0000-4000-8000-000000000091',
  );
  await app.preferences.initialize();
  await app.ledger.save(
    app.space!,
    entityType: 'category',
    scopeId: bookId,
    entityId: _childCategory,
    payload: {
      'name': '晚餐',
      'kind': 'expense',
      'parent_id': categoryId,
      'icon': 'food',
      'sort_order': 1,
    },
  );
  await app.ledger.save(
    app.space!,
    entityType: 'bill',
    scopeId: bookId,
    entityId: _bill,
    payload: {
      'bill_type': 'expense',
      'book_id': bookId,
      'category_id': _childCategory,
      'note': '朋友聚餐备注',
      'money': {
        'currency': 'CNY',
        'currency_scale': 2,
        'amount_minor': '9007199254740993',
      },
      'business_date': '2026-11-15',
      'business_timezone': 'Asia/Shanghai',
    },
  );
  await app.ledger.save(
    app.space!,
    entityType: 'budget',
    scopeId: bookId,
    payload: {
      'period_start': '2026-11-01',
      'period_end_exclusive': '2026-12-01',
      'total': {
        'currency': 'CNY',
        'currency_scale': 2,
        'amount_minor': '9007199254741993',
      },
      'categories': [],
      'carry_forward': false,
    },
  );
  return app;
}

Future<void> _homeMount(
  WidgetTester tester,
  AppController app, {
  double width = 1400,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      routes: {
        '/settings': (_) => const Scaffold(body: Text('HOME_SETTINGS_ROUTE')),
      },
      home: HomePage(
        app: app,
        space: app.space!,
        clock: () => DateTime.utc(2026, 11, 15, 8),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _closeHome(WidgetTester tester, AppController app) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  app.dispose();
  await tester.runAsync(app.database.close);
}

Future<void> _homeAttachments(WidgetTester tester, AppController app) async {
  final folder = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('flowtrace-home-'),
  ))!;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const provider = MethodChannel('plugins.flutter.io/path_provider');
  messenger.setMockMethodCallHandler(provider, (_) async => folder.path);
  if (Platform.isWindows) {
    messenger.setMockMethodCallHandler(
      WindowsRuntime.channel,
      (_) async => {'path': folder.path, 'leaseHeld': true},
    );
  }
  addTearDown(() async {
    messenger.setMockMethodCallHandler(provider, null);
    messenger.setMockMethodCallHandler(WindowsRuntime.channel, null);
    final parent = await folder.parent.resolveSymbolicLinks();
    if (parent != await Directory.systemTemp.resolveSymbolicLinks() ||
        !folder.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('flowtrace-home-')) {
      throw StateError('Unexpected home attachment fixture directory');
    }
    await folder.delete(recursive: true);
  });
  await tester.runAsync(app.attachments);
}

Future<void> _homeChord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool alt = true,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
    'default month uses the period containing the book business day',
    (tester) async {
      final app = (await tester.runAsync(setupApp))!;
      await SyncStore(app.repository).configure(
        app.space!,
        'fa000000-0000-4000-8000-000000000090',
        'fa000000-0000-4000-8000-000000000091',
      );
      final book = (await app.ledger.read(app.space!)).find('book', bookId)!;
      await app.ledger.save(
        app.space!,
        entityType: 'book',
        scopeId: bookId,
        entityId: bookId,
        payload: {
          ...book.payload,
          'month_start_day': 31,
          'timezone': 'Pacific/Honolulu',
        },
      );
      const id = 'bb000000-0000-4000-8000-000000000010';
      await app.ledger.save(
        app.space!,
        entityType: 'bill',
        scopeId: bookId,
        entityId: id,
        payload: {
          'bill_type': 'expense',
          'book_id': bookId,
          'money': {
            'currency': 'CNY',
            'currency_scale': 2,
            'amount_minor': '123',
          },
          'business_date': '2026-02-10',
          'business_timezone': 'Pacific/Honolulu',
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(
            app: app,
            space: app.space!,
            clock: () => DateTime.utc(2026, 2, 11, 5),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2026-01-31 – 2026-02-27'), findsOneWidget);
      expect(find.text('CNY 1.23'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('bill-$id')),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('home-transactions-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.byKey(const ValueKey('bill-$id')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      app.dispose();
      await tester.runAsync(app.database.close);
    },
  );

  testWidgets(
    'desktop preferences use exact bill presentation and real production budget without changing ledger or queue',
    (tester) async {
      final app = (await tester.runAsync(_homeFixture))!;
      try {
        await app.preferences.update(
          app.preferences.value.copyWith(
            groupThousands: true,
            showCategoryIcons: false,
            showFullCategory: true,
            preferNote: true,
            incomeExpenseColors: IncomeExpenseColors.incomeRed,
          ),
        );
        final before = (await app.ledger.read(
          app.space!,
        )).find('bill', _bill)!.payload;
        final pending = (await app.repository.pending(
          app.space!,
        )).map((row) => row.operationJson).toList();
        await _homeMount(tester, app);
        expect(find.byKey(const Key('home-desktop-shell')), findsOneWidget);
        expect(find.byKey(const Key('home-desktop-panes')), findsOneWidget);
        final row = tester.widget<ListTile>(
          find.byKey(const ValueKey('bill-$_bill')),
        );
        expect((row.title as Text).data, '朋友聚餐备注');
        expect((row.subtitle as Text).data, '餐饮 / 晚餐');
        expect(row.leading, isNull);
        final amount = tester.widget<Text>(
          find.text('-90,071,992,547,409.93 CNY'),
        );
        expect(amount.style!.color, app.preferences.value.expenseColor);
        expect(find.text('限额 90,071,992,547,419.93 CNY'), findsOneWidget);
        expect(
          find.text('已用 90,071,992,547,409.93 · 剩余 10.00'),
          findsOneWidget,
        );
        expect(
          (await app.ledger.read(app.space!)).find('bill', _bill)!.payload,
          before,
        );
        expect(
          (await app.repository.pending(
            app.space!,
          )).map((row) => row.operationJson).toList(),
          pending,
        );
      } finally {
        await _closeHome(tester, app);
      }
    },
  );

  testWidgets(
    'live privacy and all home-card switches remove numbers, tooltip and empty desktop side pane',
    (tester) async {
      final app = (await tester.runAsync(_homeFixture))!;
      final semantics = tester.ensureSemantics();
      try {
        await _homeMount(tester, app);
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: true),
        );
        await tester.pumpAndSettle();
        expect(find.text('CNY ••••'), findsOneWidget);
        expect(find.text('•••• CNY'), findsOneWidget);
        final semanticsText = tester
            .getSemantics(find.byKey(const Key('home-desktop-shell')))
            .toStringDeep();
        expect(semanticsText, isNot(contains('90071992547409.93')));
        expect(semanticsText, isNot(contains('90,071,992,547,409.93')));
        expect(
          tester
              .widgetList<Tooltip>(find.byType(Tooltip))
              .map((tip) => tip.message ?? '')
              .join(),
          isNot(contains('90071992547409.93')),
        );
        expect(find.textContaining('数值趋势图暂不展示'), findsOneWidget);
        await app.preferences.update(
          app.preferences.value.copyWith(
            showHomeSummary: false,
            showHomeBudget: false,
            showHomeTrend: false,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('home-summary-card')), findsNothing);
        expect(find.byKey(const Key('home-budget-card')), findsNothing);
        expect(find.byKey(const Key('home-trend-card')), findsNothing);
        expect(find.byKey(const Key('home-desktop-panes')), findsNothing);
        expect(find.byKey(const ValueKey('bill-$_bill')), findsOneWidget);
      } finally {
        semantics.dispose();
        await _closeHome(tester, app);
      }
    },
  );

  testWidgets(
    'desktop secondary-click and keyboard search/new-entry/settings use the same routes',
    (tester) async {
      final app = (await tester.runAsync(_homeFixture))!;
      try {
        await _homeAttachments(tester, app);
        await _homeMount(tester, app);
        await tester.tap(
          find.byKey(const ValueKey('bill-$_bill')),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text('查看当天流水'), findsOneWidget);
        await tester.tap(find.text('查看当天流水'));
        await tester.pumpAndSettle();
        expect(find.byType(SearchPage), findsOneWidget);
        Navigator.of(tester.element(find.byType(SearchPage))).pop();
        await tester.pumpAndSettle();
        await _homeChord(tester, LogicalKeyboardKey.keyF);
        expect(find.byType(SearchPage), findsOneWidget);
        Navigator.of(tester.element(find.byType(SearchPage))).pop();
        await tester.pumpAndSettle();
        await _homeChord(tester, LogicalKeyboardKey.keyN);
        expect(find.byType(EntryPage), findsOneWidget);
        Navigator.of(tester.element(find.byType(EntryPage))).pop();
        await tester.pumpAndSettle();
        await _homeChord(tester, LogicalKeyboardKey.comma, alt: false);
        expect(find.text('HOME_SETTINGS_ROUTE'), findsOneWidget);
        expect((await app.ledger.read(app.space!)).bills, hasLength(1));
      } finally {
        await _closeHome(tester, app);
      }
    },
  );

  testWidgets(
    'narrow large-text home keeps drawer layout and exact amount input independent',
    (tester) async {
      final app = (await tester.runAsync(_homeFixture))!;
      try {
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: true),
        );
        await _homeMount(tester, app, width: 390, textScale: 1.8);
        expect(find.byKey(const Key('home-desktop-shell')), findsNothing);
        expect(find.byTooltip('Open navigation menu'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(
          (await app.ledger.read(
            app.space!,
          )).find('bill', _bill)!.payload['money'],
          {
            'currency': 'CNY',
            'currency_scale': 2,
            'amount_minor': '9007199254740993',
          },
        );
      } finally {
        await _closeHome(tester, app);
      }
    },
  );
}
