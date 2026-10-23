import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/data/attachments/byte_store_native.dart';
import 'package:flowtrace/data/ledger/ledger_reporting.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/data/preferences/preferences_controller.dart';
import 'package:flowtrace/features/budgets/budget_editor.dart';
import 'package:flowtrace/features/entry/entry_page.dart';
import 'package:flowtrace/features/statistics/report_widgets.dart';
import 'package:flowtrace/features/statistics/statistics_page.dart';
import 'package:flowtrace/platform/windows/windows_runtime.dart';

import 'entry_page_test.dart' show setupApp, bookId, categoryId;

const _client = 'fa000000-0000-4000-8000-000000000080';
const _epoch = 'fa000000-0000-4000-8000-000000000081';

Map<String, Object?> _money(String amount) => {
  'currency': 'CNY',
  'currency_scale': 2,
  'amount_minor': amount,
};

Future<AppController> _setup() async {
  final app = await setupApp();
  await SyncStore(app.repository).configure(app.space!, _client, _epoch);
  final book = (await app.ledger.read(app.space!)).find('book', bookId)!;
  await app.ledger.save(
    app.space!,
    entityType: 'book',
    entityId: bookId,
    scopeId: bookId,
    payload: {...book.editablePayload!, 'month_start_day': 31},
  );
  return app;
}

Future<void> _expense(
  AppController app,
  String id,
  String day,
  String minor, {
  bool noStatistics = false,
  bool noBudget = false,
}) => app.ledger.save(
  app.space!,
  entityType: 'bill',
  entityId: id,
  scopeId: bookId,
  payload: {
    'book_id': bookId,
    'bill_type': 'expense',
    'money': _money(minor),
    'business_date': day,
    'business_timezone': 'Asia/Shanghai',
    'category_id': categoryId,
    'note': '隔离统计样本',
    'flags': {
      'exclude_from_statistics': noStatistics,
      'exclude_from_budget': noBudget,
    },
  },
);

Future<void> _flush(WidgetTester tester) async {
  // Route transitions can first subscribe to an already completed platform
  // Future inside their final frame. Give both real and fake queues a turn.
  for (var step = 0; step < 3; step++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 20),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  } catch (_) {
    for (final element in find.byType(CircularProgressIndicator).evaluate()) {
      final parents = <String>[];
      element.visitAncestorElements((parent) {
        parents.add('${parent.widget.runtimeType}');
        return parents.length < 12;
      });
      debugPrint('STATS waiting circular: ${parents.join(' / ')}');
    }
    debugPrint(
      'STATS pending linear: ${tester.widgetList<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).map((widget) => widget.value).toList()}',
    );
    rethrow;
  }
}

Future<void> _prepareAttachments(WidgetTester tester, AppController app) async {
  final folder = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('flowtrace-statistics-'),
  ))!;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  messenger.setMockMethodCallHandler(channel, (_) async => folder.path);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  if (Platform.isWindows) {
    messenger.setMockMethodCallHandler(WindowsRuntime.channel, (call) async {
      expect(call.method, 'dataDirectory');
      return {'path': folder.path, 'leaseHeld': true};
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(WindowsRuntime.channel, null),
    );
  }
  addTearDown(() async {
    final parent = await folder.parent.resolveSymbolicLinks();
    final expected = await Directory.systemTemp.resolveSymbolicLinks();
    final name = folder.path.split(Platform.pathSeparator).last;
    if (parent != expected || !name.startsWith('flowtrace-statistics-')) {
      throw StateError('Refusing to remove unexpected fixture path');
    }
    await folder.delete(recursive: true);
  });
  final transfer = (await tester.runAsync(app.attachments))!;
  expect(transfer.repository.bytes, isA<NativeAttachmentBytes>());
  expect(
    (transfer.repository.bytes as NativeAttachmentBytes).directory.path,
    startsWith(folder.path),
  );
}

Future<void> _mount(
  WidgetTester tester,
  AppController app, {
  int tab = 0,
  String date = '2026-11-01',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData.dark(),
      home: StatisticsPage(
        app: app,
        space: app.space!,
        bookId: bookId,
        initialDate: date,
        initialTab: tab,
      ),
    ),
  );
  await _flush(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  final visible = finder.hitTestable();
  final target = visible.evaluate().isEmpty ? finder.last : visible.last;
  if (visible.evaluate().isEmpty) await tester.ensureVisible(target);
  await tester.tap(target);
  await _flush(tester);
}

String _metric(WidgetTester tester, String label) => tester
    .widgetList<ReportMetric>(find.byType(ReportMetric))
    .singleWhere((metric) => metric.label == label)
    .value;

void _case(
  String name,
  Future<void> Function(WidgetTester tester, AppController app) body,
) {
  testWidgets(name, (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = (await tester.runAsync(_setup))!;
    try {
      await body(tester, app);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      app.dispose();
      await tester.runAsync(app.database.close);
    }
  });
}

void main() {
  _case(
    'statistics and budget flags stay independent across a 31st-start period',
    (tester, app) async {
      await tester.runAsync(() async {
        await _expense(
          app,
          'bb000000-0000-4000-8000-000000000081',
          '2026-10-31',
          '30',
          noStatistics: true,
        );
        await _expense(
          app,
          'bb000000-0000-4000-8000-000000000082',
          '2026-11-29',
          '20',
          noBudget: true,
        );
        await _expense(
          app,
          'bb000000-0000-4000-8000-000000000083',
          '2026-10-30',
          '1000',
        );
        await _expense(
          app,
          'bb000000-0000-4000-8000-000000000084',
          '2026-11-30',
          '2000',
        );
        await app.ledger.save(
          app.space!,
          entityType: 'budget',
          scopeId: bookId,
          payload: {
            'period_start': '2026-10-31',
            'period_end_exclusive': '2026-11-30',
            'total': _money('1000'),
            'categories': [],
            'carry_forward': false,
          },
        );
      });
      await _mount(tester, app);
      expect(find.text('2026-10-31 至 2026-11-29'), findsOneWidget);
      expect(_metric(tester, '支出'), '0.20');
      expect(_metric(tester, '可见原始记录'), '2笔');
      await _tap(tester, find.text('预算'));
      expect(find.textContaining('已用 0.30  ·  剩余 9.70'), findsOneWidget);
      expect(find.textContaining('限额 10.00'), findsOneWidget);
    },
  );

  _case(
    'budget create edit and previous-period copy retain exact large minor units',
    (tester, app) async {
      await _mount(tester, app, tab: 2);
      await _tap(tester, find.byKey(const Key('create-budget')));
      await tester.enterText(
        find.byKey(const Key('budget-total')),
        '90071992547409.93',
      );
      await _tap(tester, find.byKey(const Key('save-budget')));
      expect(find.byType(BudgetEditor), findsNothing);
      var budgets = (await app.ledger.read(app.space!)).budgets;
      expect(budgets, hasLength(1));
      final original = budgets.single.id;
      expect(
        (budgets.single.payload['total'] as Map)['amount_minor'],
        '9007199254740993',
      );
      await _tap(tester, find.byKey(const Key('edit-budget')));
      await tester.enterText(
        find.byKey(const Key('budget-total')),
        '90071992547409.94',
      );
      await _tap(tester, find.byKey(const Key('save-budget')));
      budgets = (await app.ledger.read(app.space!)).budgets;
      expect(budgets.single.id, original);
      expect(
        (budgets.single.payload['total'] as Map)['amount_minor'],
        '9007199254740994',
      );
      await _tap(tester, find.byTooltip('下一期'));
      expect(find.text('2026-11-30 至 2026-12-30'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('copy-previous-budget')));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('budget-total')))
            .controller!
            .text,
        '90071992547409.94',
      );
      await _tap(tester, find.byKey(const Key('save-budget')));
      budgets = (await app.ledger.read(app.space!)).budgets;
      expect(budgets, hasLength(2));
      final copied = budgets.singleWhere((budget) => budget.id != original);
      expect(copied.payload['period_start'], '2026-11-30');
      expect(copied.payload['period_end_exclusive'], '2026-12-31');
      expect(
        (copied.payload['total'] as Map)['amount_minor'],
        '9007199254740994',
      );
      expect(
        (budgets.singleWhere((budget) => budget.id == original).payload['total']
            as Map)['amount_minor'],
        '9007199254740994',
      );
    },
  );

  _case(
    'calendar selection opens an entry and saves to that exact business day',
    (tester, app) async {
      await _prepareAttachments(tester, app);
      await _mount(tester, app, tab: 1);
      // The 31st-start window initially shows October; navigate within the same
      // business period to November before selecting the actual calendar cell.
      await _tap(tester, find.byTooltip('下一个日历月'));
      await _tap(tester, find.byKey(const ValueKey('calendar-2026-11-15')));
      await _tap(tester, find.byKey(const Key('calendar-add-entry')));
      expect(
        tester.widget<EntryPage>(find.byType(EntryPage)).initialBusinessDate,
        '2026-11-15',
      );
      expect(find.text('2026-11-15'), findsOneWidget);
      await _tap(tester, find.text('餐饮'));
      await tester.enterText(find.byKey(const Key('entry-note')), '日历合成补记');
      for (final key in ['1', '.', '2', '5']) {
        await _tap(tester, find.byKey(Key('entry-key-$key')));
      }
      await _tap(tester, find.byKey(const Key('entry-key-保存')));
      final bills = (await app.ledger.read(app.space!)).bills;
      expect(bills, hasLength(1));
      expect(bills.single.payload['business_date'], '2026-11-15');
      expect((bills.single.payload['money'] as Map)['amount_minor'], '125');
      expect(bills.single.payload['note'], '日历合成补记');
    },
  );

  for (final revoke in [false, true]) {
    _case(
      'independent fullscreen chart hides after ${revoke ? 'database revoke' : 'space switch'}',
      (tester, app) async {
        await tester.runAsync(
          () => _expense(
            app,
            'bb000000-0000-4000-8000-000000000085',
            '2026-11-15',
            '12345',
          ),
        );
        await _mount(tester, app);
        expect(_metric(tester, '支出'), '123.45');
        await _tap(tester, find.byTooltip('全屏趋势'));
        expect(find.text('收支趋势'), findsOneWidget);
        expect(find.byType(ReportDailyChart), findsOneWidget);
        if (revoke) {
          // No app notification: the independent chart must observe the real DB.
          await tester.runAsync(
            () =>
                (app.database.update(
                  app.database.syncStates,
                )..where((table) => table.spaceId.equals(app.space!.id))).write(
                  SyncStatesCompanion(
                    revokedScopesJson: Value(jsonEncode([bookId])),
                  ),
                ),
          );
        } else {
          await app.setServerAddress('https://statistics-new.example.test');
        }
        await _flush(tester);
        expect(find.byType(ReportDailyChart), findsNothing);
        expect(find.text('123.45'), findsNothing);
        expect(
          find.text(revoke ? '当前汇总不可用，请核对权限与同步状态。' : '资料空间已切换。'),
          findsOneWidget,
        );
      },
    );
  }

  _case(
    'narrow large-text bar and line charts keep exact report data and fit',
    (tester, app) async {
      tester.view.physicalSize = const Size(390, 844);
      await tester.runAsync(
        () => _expense(
          app,
          'bb000000-0000-4000-8000-000000000086',
          '2026-11-15',
          '12345',
        ),
      );
      final query = ReportQuery(
        bookId: bookId,
        reportCurrency: 'CNY',
        reportScale: 2,
        startDate: '2026-10-31',
        endDateExclusive: '2026-11-30',
      );
      final report = (await tester.runAsync(
        () => LedgerReportingService(app.repository).read(app.space!, query),
      ))!;
      expect(report.available, isTrue);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              textScaler: TextScaler.linear(1.8),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: ReportDailyChart(report: report, query: query),
              ),
            ),
          ),
        ),
      );
      await _flush(tester);
      expect(report.totals!.expense.minor.toString(), '12345');
      await _tap(tester, find.text('折线图'));
      expect(
        tester
            .widget<ReportDailyChart>(find.byType(ReportDailyChart))
            .report
            .totals!
            .expense
            .minor
            .toString(),
        '12345',
      );
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('柱状图'));
      expect(tester.takeException(), isNull);
    },
  );

  _case(
    'privacy removes an already visible chart tooltip and all statistics/calendar/budget numeric views',
    (tester, app) async {
      final semantics = tester.ensureSemantics();
      try {
        await app.preferences.initialize();
        await tester.runAsync(
          () => _expense(
            app,
            'bb000000-0000-4000-8000-000000000087',
            '2026-11-15',
            '123456',
          ),
        );
        await _mount(tester, app);
        expect(_metric(tester, '支出'), '1234.56');
        await _tap(tester, find.byTooltip('全屏趋势'));
        final point = find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              (widget.message?.contains('2026-11-15') ?? false),
        );
        await tester.ensureVisible(point);
        await tester.longPress(point);
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.textContaining('1234.56'), findsOneWidget);
        await app.preferences.update(
          app.preferences.value.copyWith(
            hideAmounts: true,
            groupThousands: true,
          ),
        );
        await _flush(tester);
        expect(find.textContaining('1234.56'), findsNothing);
        expect(find.textContaining('1,234.56'), findsNothing);
        expect(
          tester
              .widgetList<Tooltip>(find.byType(Tooltip))
              .map((tooltip) => tooltip.message ?? '')
              .join(),
          isNot(contains('1234.56')),
        );
        expect(find.textContaining('数值趋势图暂不展示'), findsOneWidget);
        Navigator.of(tester.element(find.byType(ReportDailyChart))).pop();
        await _flush(tester);
        expect(_metric(tester, '支出'), '••••');
        expect(find.text('100.0%'), findsNothing);
        await _tap(tester, find.text('日历'));
        await _tap(tester, find.byTooltip('下一个日历月'));
        await _tap(tester, find.byKey(const ValueKey('calendar-2026-11-15')));
        expect(find.textContaining('1,234.56'), findsNothing);
        final calendarSemantics = tester
            .getSemantics(find.byType(Scaffold).last)
            .toStringDeep();
        expect(calendarSemantics, isNot(contains('1234.56')));
        await _tap(tester, find.text('预算'));
        expect(find.text('预算金额已隐藏'), findsOneWidget);
        expect(find.textContaining('1234.56'), findsNothing);
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: false),
        );
        await _flush(tester);
        await _tap(tester, find.text('统计'));
        expect(_metric(tester, '支出'), '1,234.56');
        expect(
          (await app.ledger.read(app.space!)).bills.single.payload['money'],
          _money('123456'),
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  _case(
    'calendar uses persisted device week start and a chip writes the same preference',
    (tester, app) async {
      await app.preferences.initialize();
      await app.preferences.update(
        app.preferences.value.copyWith(weekStartsMonday: false),
      );
      await _mount(tester, app, tab: 1);
      List<String?> labels() => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const Key('calendar-weekday-labels')),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data)
          .toList();
      expect(labels(), ['日', '一', '二', '三', '四', '五', '六']);
      await _tap(tester, find.text('周一开始'));
      expect(labels(), ['一', '二', '三', '四', '五', '六', '日']);
      final reopened = PreferencesController(app.repository);
      await reopened.initialize();
      expect(reopened.value.weekStartsMonday, isTrue);
      reopened.dispose();
      expect((await app.ledger.read(app.space!)).bills, isEmpty);
    },
  );

  _case(
    'legacy per-space Sunday migrates only when no versioned device preferences exist',
    (tester, app) async {
      await app.repository.writeSetting(
        'calendar.week-start.${app.space!.id}',
        'sunday',
      );
      await _mount(tester, app, tab: 1);
      expect(app.preferences.value.weekStartsMonday, isFalse);
      expect(
        await app.repository.readSetting(
          'calendar.week-start.${app.space!.id}',
        ),
        'sunday',
      );
      expect(
        await app.repository.readSetting(PreferencesController.settingKey),
        isNotNull,
      );
      await app.preferences.update(
        app.preferences.value.copyWith(weekStartsMonday: true),
      );
      await _mount(tester, app, tab: 1);
      expect(app.preferences.value.weekStartsMonday, isTrue);
    },
  );
}
