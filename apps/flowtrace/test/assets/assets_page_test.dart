import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/data/assets/asset_config_store.dart';
import 'package:flowtrace/data/preferences/preferences_controller.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/domain/assets/asset_config.dart';
import 'package:flowtrace/features/assets/account_editor.dart';
import 'package:flowtrace/features/assets/asset_groups_page.dart';
import 'package:flowtrace/features/assets/assets_page.dart';
import 'package:flowtrace/features/currencies/currencies_page.dart';

import '../ledger/query_fixtures.dart';

void main() {
  late QueryFixture f;
  late AppController app;
  late VoidCallback markCleaned;
  Future<void> setup(WidgetTester tester) async {
    f = QueryFixture();
    await tester.runAsync(f.seed);
    app = AppController(f.db)
      ..space = f.space
      ..loading = false;
    await app.preferences.initialize();
    var cleaned = false;
    addTearDown(() async {
      if (!cleaned) {
        app.dispose();
        await f.close();
      }
    });
    // The normal cleanup marks this after closing; failed assertions still
    // release their own database before the next widget starts.
    markCleaned = () => cleaned = true;
    await tester.binding.setSurfaceSize(const Size(1100, 1100));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    app.dispose();
    await tester.runAsync(f.close);
    markCleaned();
    await tester.binding.setSurfaceSize(null);
  }

  testWidgets('overview toggles amounts and never displays a shared account', (
    tester,
  ) async {
    await setup(tester);
    await tester.runAsync(
      () => f.put('account', qid(701), qBook, {
        'projection_kind': 'account',
        'payload': {
          'name': '共享账户秘密',
          'kind': 'cash',
          'opening': qmoney('999999'),
          'hidden': false,
          'include_in_net_assets': true,
        },
        'balance': qmoney('999999'),
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AssetsPage(app: app, space: f.space),
      ),
    );
    await settle(tester);
    expect(find.text('合成现金'), findsOneWidget);
    expect(find.text('共享账户秘密'), findsNothing);
    expect(find.text('CNY 1000.00'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('asset-toggle-amounts')));
    await settle(tester);
    expect(find.text('CNY 1000.00'), findsNothing);
    expect(find.text('••••'), findsWidgets);
    expect(app.preferences.value.hideAmounts, isTrue);
    final reopened = PreferencesController(app.repository);
    await reopened.initialize();
    expect(reopened.value.hideAmounts, isTrue);
    reopened.dispose();
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets(
    'account editor re-masks on each global privacy enable while saving its exact raw opening',
    (tester) async {
      await setup(tester);
      await app.preferences.update(
        app.preferences.value.copyWith(hideAmounts: true),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountEditor(app: app, space: f.space, groups: const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('account-name')), '合成隐私开户');
      final opening = find.byKey(const Key('account-opening'));
      await tester.ensureVisible(opening);
      await tester.enterText(opening, '90071992547409.93');
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: opening, matching: find.byType(TextField)),
            )
            .obscureText,
        isTrue,
      );
      await tester.ensureVisible(
        find.byKey(const Key('account-reveal-amounts')),
      );
      await tester.tap(find.byKey(const Key('account-reveal-amounts')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: opening, matching: find.byType(TextField)),
            )
            .obscureText,
        isFalse,
      );
      await app.preferences.update(
        app.preferences.value.copyWith(hideAmounts: false),
      );
      await tester.pumpAndSettle();
      await app.preferences.update(
        app.preferences.value.copyWith(hideAmounts: true),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: opening, matching: find.byType(TextField)),
            )
            .obscureText,
        isTrue,
      );
      expect(
        tester.widget<TextFormField>(opening).controller!.text,
        '90071992547409.93',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('save-account')));
      await tester.tap(find.byKey(const Key('save-account')));
      await settle(tester);
      final created = (await app.ledger.read(
        f.space,
      )).accounts.singleWhere((a) => a.name == '合成隐私开户');
      expect(
        (created.payload['opening'] as Map)['amount_minor'],
        '9007199254740993',
      );
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'new credit card saves explicit opening date and independent limit without calendar guesses',
    (tester) async {
      await setup(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountEditor(app: app, space: f.space, groups: const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('account-name')), '合成部分条款卡');
      await tester.tap(find.byKey(const Key('account-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('信用卡').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('account-bank')));
      await tester.tap(find.byKey(const Key('account-bank')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('account-bank-search')),
        '招商',
      );
      await tester.pumpAndSettle();
      expect(find.text('中国银行'), findsNothing);
      await tester.tap(find.text('招商银行'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('account-opening')));
      await tester.enterText(
        find.byKey(const Key('account-opening')),
        '-500.16',
      );
      await tester.ensureVisible(find.byKey(const Key('account-credit-limit')));
      await tester.enterText(
        find.byKey(const Key('account-credit-limit')),
        '10000.25',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('save-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-account')));
      await settle(tester);
      final view = (await tester.runAsync(() => app.ledger.read(f.space)))!;
      final created = view.accounts
          .singleWhere((row) => row.name == '合成部分条款卡')
          .payload;
      expect((created['opening'] as Map)['amount_minor'], '-50016');
      expect(created['opening_date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(created['bank_id'], 'cmb');
      final credit = created['credit'] as Map;
      expect((credit['limit'] as Map)['amount_minor'], '1000025');
      expect(credit['statement_day'], isNull);
      expect(credit['due_mode'], isNull);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'existing account preserves locked opening and unknown historical date while metadata changes',
    (tester) async {
      await setup(tester);
      final entity = (await tester.runAsync(
        () => app.ledger.read(f.space),
      ))!.accounts.firstWhere((row) => row.id == qCash);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountEditor(
              app: app,
              space: f.space,
              groups: const [],
              entity: entity,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('account-opening')))
            .enabled,
        isFalse,
      );
      await tester.ensureVisible(find.byKey(const Key('account-note')));
      await tester.enterText(
        find.byKey(const Key('account-note')),
        '保留本金与历史日期',
      );
      await tester.ensureVisible(find.byKey(const Key('save-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-account')));
      await settle(tester);
      final updated = (await tester.runAsync(
        () => app.ledger.read(f.space),
      ))!.accounts.firstWhere((row) => row.id == qCash).payload;
      expect(updated['note'], '保留本金与历史日期');
      expect(updated['opening_date'], isNull);
      expect(updated['opening'], entity.payload['opening']);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'group save without login retains visible name and makes no request',
    (tester) async {
      await setup(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: AssetGroupsPage(app: app, space: f.space),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('添加分组'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '未登录仍保留分组');
      await tester.tap(find.text('保存并确认'));
      await settle(tester);
      expect(find.text('未登录仍保留分组'), findsOneWidget);
      expect(find.text('配置已由服务器确认。'), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'manual quote save without login retains entered decimal and dialog',
    (tester) async {
      await setup(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: CurrenciesPage(app: app, space: f.space),
        ),
      );
      await settle(tester);
      await tester.ensureVisible(find.text('添加手动估值报价'));
      await tester.tap(find.text('添加手动估值报价'));
      await tester.pumpAndSettle();
      final rateField = find.widgetWithText(TextFormField, '1来源币 = 目标币金额');
      await tester.enterText(rateField, '7.123456789012345678');
      await tester.tap(find.text('保存并确认'));
      await settle(tester);
      expect(find.text('7.123456789012345678'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('配置已由服务器确认。'), findsNothing);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'preference draft remains selected after failed unauthenticated save',
    (tester) async {
      await setup(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: CurrenciesPage(app: app, space: f.space),
        ),
      );
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('policy-exact_date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用估值日或之前最新报价').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存币种与估值偏好'));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('policy-latest_on_or_before')),
        findsOneWidget,
      );
      expect(find.text('配置已由服务器确认。'), findsNothing);
      await close(tester);
    },
  );

  testWidgets(
    'account editor supports narrow large text and currency changes clear numeric input',
    (tester) async {
      await setup(tester);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: AccountEditor(
              app: app,
              space: f.space,
              groups: const [],
              preferredCurrencies: const ['COP', 'CNY'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('account-opening')));
      await tester.enterText(
        find.byKey(const Key('account-opening')),
        '123.45',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('account-currency')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-currency')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('COP Colombian Peso · 常用'),
        60,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('COP Colombian Peso · 常用'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('account-opening')))
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'asset overview and manual preference controls fit narrow large text',
    (tester) async {
      await setup(tester);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      Widget framed(Widget child) => MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: child,
      );
      await tester.pumpWidget(framed(AssetsPage(app: app, space: f.space)));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(framed(CurrenciesPage(app: app, space: f.space)));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'group delete overlay removes private name immediately after identity switch',
    (tester) async {
      await setup(tester);
      await tester.runAsync(() async {
        final lease = SyncLease(
          space: f.space,
          clientId: qid(5),
          epoch: qEpoch,
          isCurrent: () => true,
          request: (method, path, {body, bodyJson}) async => {},
        );
        await AssetConfigStore(app.repository).acceptSection(
          lease,
          AssetConfigSectionSnapshot.fromJson(AssetConfigSection.groups, {
            'instance_id': f.space.serverInstanceId,
            'sync_epoch': qEpoch,
            'revision': '1',
            'groups': [
              {
                'id': qid(800),
                'name': '不能跨身份显示的分组',
                'sort_order': 0,
                'revision': '1',
              },
            ],
          }),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AssetGroupsPage(app: app, space: f.space),
        ),
      );
      await settle(tester);
      await tester.tap(find.byTooltip('删除空分组'));
      await tester.pumpAndSettle();
      expect(find.text('不能跨身份显示的分组'), findsNWidgets(2));
      await tester.runAsync(
        () => app.setServerAddress('http://127.0.0.1:18198'),
      );
      await settle(tester);
      expect(find.text('不能跨身份显示的分组'), findsNothing);
      expect(find.text('资料空间已切换，请关闭此窗口。'), findsOneWidget);
      expect(find.text('删除'), findsNothing);
      await close(tester);
    },
  );

  testWidgets(
    'fund action overlay removes old book names after identity switch',
    (tester) async {
      await setup(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: AssetsPage(app: app, space: f.space),
        ),
      );
      await settle(tester);
      await tester.tap(find.byTooltip('合成现金操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('余额调账'));
      await tester.pumpAndSettle();
      expect(find.text('合成日常'), findsOneWidget);
      expect(find.text('合成旅行'), findsOneWidget);
      await tester.runAsync(
        () => app.setServerAddress('http://127.0.0.1:18198'),
      );
      await settle(tester);
      expect(find.text('合成日常'), findsNothing);
      expect(find.text('合成旅行'), findsNothing);
      expect(find.text('资料空间已切换，请关闭此窗口。'), findsOneWidget);
      await close(tester);
    },
  );
}
