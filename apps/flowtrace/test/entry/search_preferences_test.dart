import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/data/ledger/ledger_query.dart';
import 'package:flowtrace/data/preferences/app_preferences.dart';
import 'package:flowtrace/features/search/search_page.dart';
import 'package:flowtrace/features/transactions/bill_detail_page.dart';
import 'package:flowtrace/features/transactions/bill_book_move_page.dart';

import 'entry_page_test.dart' show setupApp, bookId, categoryId;

const _bill = 'bb000000-0000-4000-8000-000000000096';
const _category = 'ca000000-0000-4000-8000-000000000096';
const _otherBook = 'ba000000-0000-4000-8000-000000000096';

Future<AppController> _fixture() async {
  final app = await setupApp();
  await app.preferences.initialize();
  await app.preferences.update(
    app.preferences.value.copyWith(
      groupThousands: true,
      showFullCategory: true,
      preferNote: true,
      showCategoryIcons: false,
      incomeExpenseColors: IncomeExpenseColors.incomeRed,
    ),
  );
  await app.ledger.save(
    app.space!,
    entityType: 'book',
    scopeId: app.space!.userId,
    entityId: _otherBook,
    payload: {
      'name': '合成移动目标',
      'currency': 'CNY',
      'timezone': 'Asia/Shanghai',
      'month_start_day': 1,
    },
  );
  await app.ledger.save(
    app.space!,
    entityType: 'category',
    scopeId: bookId,
    entityId: _category,
    payload: {
      'name': '晚餐',
      'kind': 'expense',
      'parent_id': categoryId,
      'icon': 'food',
      'sort_order': 0,
    },
  );
  await app.ledger.save(
    app.space!,
    entityType: 'bill',
    scopeId: bookId,
    entityId: _bill,
    payload: {
      'book_id': bookId,
      'bill_type': 'expense',
      'money': {
        'currency': 'CNY',
        'currency_scale': 2,
        'amount_minor': '9007199254740993',
      },
      'business_date': '2026-11-15',
      'business_timezone': 'Asia/Shanghai',
      'category_id': _category,
      'note': '合成隐私晚餐',
    },
  );
  return app;
}

Future<void> _mount(
  WidgetTester tester,
  AppController app, {
  BillFilter? filter,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SearchPage(
        app: app,
        space: app.space!,
        initialBookId: bookId,
        initialFilter: filter,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester, AppController app) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  app.dispose();
  await tester.runAsync(app.database.close);
}

void main() {
  testWidgets(
    'search detail move and an open batch preview obey live exact display and privacy without a ledger write',
    (tester) async {
      final app = (await tester.runAsync(_fixture))!;
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        final pending = (await app.repository.pending(
          app.space!,
        )).map((row) => row.operationJson).toList();
        await _mount(tester, app);
        final row = tester.widget<ListTile>(
          find.byKey(const ValueKey('search-bill-$_bill')),
        );
        expect((row.title as Text).data, '合成隐私晚餐');
        expect((row.subtitle as Text).data, '2026-11-15 · 餐饮 / 晚餐');
        expect(row.leading, isNull);
        expect(
          tester
              .widget<Text>(find.text('CNY 90,071,992,547,409.93'))
              .style!
              .color,
          app.preferences.value.expenseColor,
        );
        await tester.tap(find.byKey(const ValueKey('search-bill-$_bill')));
        await tester.pumpAndSettle();
        expect(find.byType(BillDetailPage), findsOneWidget);
        expect(find.text('餐饮 / 晚餐'), findsOneWidget);
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: true),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const Key('bill-detail-amount'))).data,
          'CNY ••••',
        );
        expect(
          tester.getSemantics(find.byType(Scaffold).last).toStringDeep(),
          isNot(contains('90,071,992,547,409.93')),
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.textContaining('90,071,992,547,409.93'), findsNothing);
        await tester.longPress(
          find.byKey(const ValueKey('search-bill-$_bill')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('move-selected-bills')));
        await tester.pumpAndSettle();
        expect(find.byType(BillBookMovePage), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('move-target-null')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('合成移动目标').last);
        await tester.pumpAndSettle();
        expect(find.textContaining('•••• CNY'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('批量维护'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('batch-change-备注')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('设置为').last);
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('batch-note')), '只预览不入账');
        await tester.ensureVisible(find.byKey(const Key('preview-bill-batch')));
        await tester.tap(find.byKey(const Key('preview-bill-batch')));
        await tester.pumpAndSettle();
        expect(find.textContaining('核对1笔账单'), findsOneWidget);
        expect(find.text('CNY ••••'), findsOneWidget);
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: false),
        );
        await tester.pumpAndSettle();
        expect(find.text('CNY 90,071,992,547,409.93'), findsOneWidget);
        await tester.tap(find.text('返回修改'));
        await tester.pumpAndSettle();
        expect(
          (await app.ledger.read(
            app.space!,
          )).find('bill', _bill)!.payload['note'],
          '合成隐私晚餐',
        );
        expect(
          (await app.repository.pending(
            app.space!,
          )).map((row) => row.operationJson).toList(),
          pending,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await _close(tester, app);
      }
    },
  );

  testWidgets(
    'open amount filters re-mask on each privacy change and keep exact raw bounds',
    (tester) async {
      final app = (await tester.runAsync(_fixture))!;
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        await _mount(
          tester,
          app,
          filter: BillFilter(
            bookIds: {bookId},
            currency: 'CNY',
            minAmount: Money('CNY', 2, BigInt.parse('9007199254740992')),
          ),
        );
        await tester.tap(find.byTooltip('组合筛选'));
        await tester.pumpAndSettle();
        final minimum = find.byKey(const Key('filter-minimum'));
        await tester.scrollUntilVisible(
          minimum,
          200,
          scrollable: find.byType(Scrollable).last,
        );
        expect(
          tester.widget<TextField>(minimum).controller!.text,
          '90071992547409.92',
        );
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: true),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(minimum).obscureText, isTrue);
        await tester.ensureVisible(
          find.byKey(const Key('filter-reveal-amounts')),
        );
        await tester.tap(find.byKey(const Key('filter-reveal-amounts')));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(minimum).obscureText, isFalse);
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: false),
        );
        await tester.pumpAndSettle();
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: true),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(minimum).obscureText, isTrue);
        expect(
          tester.widget<TextField>(minimum).controller!.text,
          '90071992547409.92',
        );
        expect(
          (await app.ledger.read(app.space!)).bills.single.payload['money'],
          {
            'currency': 'CNY',
            'currency_scale': 2,
            'amount_minor': '9007199254740993',
          },
        );
      } finally {
        await _close(tester, app);
      }
    },
  );

  testWidgets(
    '390px large-text search wraps exact grouped amounts without overflow',
    (tester) async {
      final app = (await tester.runAsync(_fixture))!;
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.8)),
              child: child!,
            ),
            home: SearchPage(
              app: app,
              space: app.space!,
              initialBookId: bookId,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('CNY 90,071,992,547,409.93'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await _close(tester, app);
      }
    },
  );
}
