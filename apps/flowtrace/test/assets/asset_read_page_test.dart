import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/features/assets/asset_account_page.dart';
import 'package:flowtrace/features/assets/asset_history_page.dart';
import 'package:flowtrace/features/assets/asset_read_view.dart';
import 'package:flowtrace/features/assets/credit_calendar_page.dart';

import '../ledger/query_fixtures.dart';
import 'asset_read_fixtures.dart';

Future<void> drainAssetIo(WidgetTester tester) async {
  // Parent ledger watch can mount the nested read view on the first pump.
  // Drain both real SQLite I/O and that newly mounted view before settling.
  for (var turn = 0; turn < 4; turn++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }
}

Future<void> flushAssetReads(WidgetTester tester) async {
  await drainAssetIo(tester);
  await tester.pumpAndSettle();
}

void assetPageTest(
  String name,
  Future<void> Function(WidgetTester tester, AssetReadFixture f) body,
) {
  testWidgets(name, (tester) async {
    final f = (await tester.runAsync(() async {
      final f = AssetReadFixture();
      await f.open();
      return f;
    }))!;
    try {
      await body(tester, f);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.runAsync(f.close);
    }
  });
}

Widget narrowAssetApp(Widget page) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(1.8)),
    child: child!,
  ),
  home: page,
);

void main() {
  assetPageTest(
    'global privacy removes live asset curve, detail and credit amounts then exact grouped values return',
    (tester, f) async {
      final semantics = tester.ensureSemantics();
      try {
        await f.app.preferences.initialize();
        await f.app.preferences.update(
          f.app.preferences.value.copyWith(groupThousands: true),
        );
        f.request = (method, path, {body, bodyJson}) async => f.historyBody();
        await tester.runAsync(() => f.reads.fetch(f.lease, f.historyQuery));
        await tester.pumpWidget(
          MaterialApp(
            home: AssetHistoryPage(
              app: f.app,
              space: f.data.space,
              initialDate: DateTime.utc(2026, 10, 21),
            ),
          ),
        );
        await flushAssetReads(tester);
        expect(find.text('净资产 CNY 90,071,992,547,409.93'), findsWidgets);
        expect(find.byKey(const Key('asset-history-chart')), findsOneWidget);
        await f.app.preferences.update(
          f.app.preferences.value.copyWith(hideAmounts: true),
        );
        await flushAssetReads(tester);
        expect(find.byKey(const Key('asset-history-chart')), findsNothing);
        expect(
          find.byKey(const Key('asset-history-chart-hidden')),
          findsOneWidget,
        );
        expect(find.textContaining('90,071,992,547,409.93'), findsNothing);
        expect(
          tester.getSemantics(find.byType(Scaffold)).toStringDeep(),
          isNot(contains('90,071,992,547,409.93')),
        );
        f.request = (method, path, {body, bodyJson}) async => f.entriesBody();
        await tester.runAsync(() => f.reads.fetch(f.lease, f.entriesQuery));
        await tester.pumpWidget(
          MaterialApp(
            home: AssetAccountPage(
              app: f.app,
              space: f.data.space,
              accountId: qCash,
              initialDate: DateTime.utc(2026, 10, 21),
            ),
          ),
        );
        await flushAssetReads(tester);
        expect(find.text('本机原币余额 ••••'), findsOneWidget);
        expect(find.textContaining('98.75'), findsNothing);
        expect(find.textContaining('0.01'), findsNothing);
        f.request = (method, path, {body, bodyJson}) async => f.creditBody();
        await tester.runAsync(() => f.reads.fetch(f.lease, f.creditQuery));
        await tester.pumpWidget(
          MaterialApp(
            home: CreditCalendarPage(
              app: f.app,
              space: f.data.space,
              accountId: qBank,
              initialDate: DateTime.utc(2026, 10, 21),
            ),
          ),
        );
        await flushAssetReads(tester);
        expect(find.text('服务器已同步总欠款 ••••'), findsOneWidget);
        expect(find.textContaining('50.00'), findsNothing);
        expect(
          tester.getSemantics(find.byType(Scaffold)).toStringDeep(),
          isNot(contains('50.00')),
        );
        await f.app.preferences.update(
          f.app.preferences.value.copyWith(hideAmounts: false),
        );
        await flushAssetReads(tester);
        expect(find.text('服务器已同步总欠款 CNY 50.00'), findsOneWidget);
        await tester.pumpWidget(
          MaterialApp(
            home: AssetHistoryPage(
              app: f.app,
              space: f.data.space,
              initialDate: DateTime.utc(2026, 10, 21),
            ),
          ),
        );
        await flushAssetReads(tester);
        expect(find.text('净资产 CNY 90,071,992,547,409.93'), findsWidgets);
        expect(find.byKey(const Key('asset-history-chart')), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  assetPageTest(
    'account details clear server note after database-only book revocation',
    (tester, f) async {
      await tester.runAsync(() => f.reads.fetch(f.lease, f.entriesQuery));
      var appNotifications = 0;
      f.app.addListener(() => appNotifications++);
      await tester.pumpWidget(
        MaterialApp(
          home: AssetAccountPage(
            app: f.app,
            space: f.data.space,
            accountId: qCash,
            initialDate: DateTime.utc(2026, 10, 21),
          ),
        ),
      );
      await flushAssetReads(tester);
      expect(find.text('本机原币余额 CNY 98.75'), findsOneWidget);
      expect(find.textContaining('合成授权备注'), findsOneWidget);
      expect(find.textContaining('原账本当前不可访问，仅保留本人分录金额和业务日期。'), findsOneWidget);
      expect(find.textContaining('已确认缓存 · 账务版本 5'), findsOneWidget);
      await tester.runAsync(() => f.data.sync.revokeScope(f.data.space, qBook));
      await flushAssetReads(tester);
      expect(appNotifications, 0);
      expect(find.textContaining('合成授权备注'), findsNothing);
      expect(find.byKey(const Key('asset-read-unavailable')), findsOneWidget);
      expect(find.text('本机原币余额 CNY 98.75'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  assetPageTest(
    '390px 1.8x history shows exact large amounts and selectable evidence gaps then hides on space switch',
    (tester, f) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      f.request = (method, path, {body, bodyJson}) async => f.historyBody();
      await tester.runAsync(() => f.reads.fetch(f.lease, f.historyQuery));
      await tester.pumpWidget(
        narrowAssetApp(
          AssetHistoryPage(
            app: f.app,
            space: f.data.space,
            initialDate: DateTime.utc(2026, 10, 21),
          ),
        ),
      );
      await flushAssetReads(tester);
      expect(find.text('净资产 CNY 90071992547409.93'), findsWidgets);
      final chart = find.byKey(const Key('asset-history-chart'));
      await tester.ensureVisible(chart);
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(chart));
      await tester.pumpAndSettle();
      final selected = find.byKey(const Key('asset-history-selected'));
      expect(
        find.descendant(of: selected, matching: find.text('2026-10-16')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: selected,
          matching: find.text('缺少账户启用日期，历史余额与账期应还不可用。'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: selected, matching: find.textContaining('净资产')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(
        () => f.app.setServerAddress('http://127.0.0.1:18198'),
      );
      await flushAssetReads(tester);
      expect(find.byKey(const Key('asset-history-chart')), findsNothing);
      expect(find.textContaining('90071992547409.93'), findsNothing);
      expect(find.text('资料空间已变化，请返回。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  assetPageTest(
    '390px 1.8x credit distinguishes three confirmed amounts and clears cached cycles on revoke',
    (tester, f) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      f.request = (method, path, {body, bodyJson}) async => f.creditBody();
      await tester.runAsync(() => f.reads.fetch(f.lease, f.creditQuery));
      await tester.pumpWidget(
        narrowAssetApp(
          CreditCalendarPage(
            app: f.app,
            space: f.data.space,
            accountId: qBank,
            initialDate: DateTime.utc(2026, 10, 21),
          ),
        ),
      );
      await flushAssetReads(tester);
      expect(find.text('服务器已同步总欠款 CNY 50.00'), findsOneWidget);
      expect(find.text('期间消费 CNY 50.00'), findsOneWidget);
      expect(find.text('出账时应还 CNY 50.00'), findsOneWidget);
      expect(find.text('服务器已同步剩余应还 CNY 50.00'), findsOneWidget);
      expect(find.text('所配日历免息日数 10–40 天'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => f.data.sync.revokeScope(f.data.space, qBook));
      await flushAssetReads(tester);
      expect(find.byKey(const Key('credit-cycle-2026-10-31')), findsNothing);
      expect(find.text('服务器已同步总欠款 CNY 50.00'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  assetPageTest(
    'late response cannot render a note after revoke and regrant without App notification',
    (tester, f) async {
      var entered = false;
      final finished = (await tester.runAsync(
        () async => Completer<Map<String, Object?>>(),
      ))!;
      addTearDown(() {
        if (!finished.isCompleted) finished.complete(f.entriesBody());
      });
      f.request = (method, path, {body, bodyJson}) async {
        entered = true;
        return finished.future;
      };
      var rendered = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AssetReadView(
                app: f.app,
                space: f.data.space,
                repository: f.reads,
                query: f.entriesQuery,
                leaseFactory: () => f.lease,
                builder: (context, snapshot) {
                  rendered++;
                  return const Text('不该出现的迟到备注');
                },
              ),
            ),
          ),
        ),
      );
      await flushAssetReads(tester);
      await tester.tap(find.byKey(const Key('asset-read-refresh')));
      await tester.pump();
      for (var turn = 0; turn < 20 && !entered; turn++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(
        entered,
        isTrue,
        reason: 'The bounded GET fixture must be entered before revoking.',
      );
      await tester.runAsync(() => f.data.sync.revokeScope(f.data.space, qBook));
      // Let the fake-zone watch release its SQLite read before another real
      // transaction. Waiting for both mutations inside runAsync deadlocks the
      // fake zone, although no production event loop is blocked this way.
      await drainAssetIo(tester);
      await tester.runAsync(
        () => f.data.sync.restoreScopeAccess(f.data.space, {
          qUser,
          qBook,
          qOtherBook,
        }),
      );
      await drainAssetIo(tester);
      await tester.runAsync(() async {
        finished.complete(f.entriesBody());
      });
      await flushAssetReads(tester);
      expect(rendered, 0);
      expect(find.text('不该出现的迟到备注'), findsNothing);
      expect(find.text('读取期间资料版本已变化，请重新刷新。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  assetPageTest(
    'a real database close ends the authorization watch and hides the rendered trend',
    (tester, f) async {
      f.request = (method, path, {body, bodyJson}) async => f.historyBody();
      await tester.runAsync(() => f.reads.fetch(f.lease, f.historyQuery));
      await tester.pumpWidget(
        MaterialApp(
          home: AssetHistoryPage(
            app: f.app,
            space: f.data.space,
            initialDate: DateTime.utc(2026, 10, 21),
          ),
        ),
      );
      await flushAssetReads(tester);
      expect(find.byKey(const Key('asset-history-chart')), findsOneWidget);
      expect(find.text('净资产 CNY 90071992547409.93'), findsWidgets);
      var closed = false;
      Object? closingError;
      await tester.runAsync(() async {
        unawaited(
          f.closeStorage().then(
            (_) {
              closed = true;
            },
            onError: (Object error) {
              closingError = error;
            },
          ),
        );
      });
      for (var turn = 0; turn < 20 && !closed && closingError == null; turn++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(closingError, isNull);
      expect(
        closed,
        isTrue,
        reason:
            'Closing the real SQLite store must finish within the bounded test.',
      );
      await flushAssetReads(tester);
      expect(find.byKey(const Key('asset-history-chart')), findsNothing);
      expect(find.textContaining('90071992547409.93'), findsNothing);
      expect(find.text('本地资料监听已中断，原结果已隐藏，请重新打开页面。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
