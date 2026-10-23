import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/data/ledger/ledger_reporting.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/budgets/budget_editor.dart';
import 'package:flowtrace/features/budgets/budget_view.dart';

import 'entry_page_test.dart' show setupApp, bookId, categoryId;

const _budget = 'bd000000-0000-4000-8000-000000000096';
Map<String, Object?> _money(String minor) => {
  'currency': 'CNY',
  'currency_scale': 2,
  'amount_minor': minor,
};

Future<AppController> _fixture() async {
  final app = await setupApp();
  await SyncStore(app.repository).configure(
    app.space!,
    'fa000000-0000-4000-8000-000000000096',
    'fa000000-0000-4000-8000-000000000097',
  );
  await app.preferences.initialize();
  await app.preferences.update(
    app.preferences.value.copyWith(groupThousands: true),
  );
  await app.ledger.save(
    app.space!,
    entityType: 'budget',
    scopeId: bookId,
    entityId: _budget,
    payload: {
      'period_start': '2026-11-01',
      'period_end_exclusive': '2026-12-01',
      'total': _money('9007199254740993'),
      'categories': [
        {'category_id': categoryId, 'limit': _money('12300')},
      ],
      'carry_forward': false,
    },
  );
  return app;
}

Future<void> _close(WidgetTester tester, AppController app) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  app.dispose();
  await tester.runAsync(app.database.close);
}

void main() {
  testWidgets(
    'already-open budget editor masks on each privacy change and saves exact raw total/category values',
    (tester) async {
      final app = (await tester.runAsync(_fixture))!;
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(1000, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        final view = await app.ledger.read(app.space!);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => BudgetEditor(
                        app: app,
                        space: app.space!,
                        book: view.find('book', bookId)!,
                        existing: view.find('budget', _budget),
                        periodStart: '2026-11-01',
                        periodEndExclusive: '2026-12-01',
                      ),
                    ),
                  ),
                  child: const Text('打开预算编辑'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开预算编辑'));
        await tester.pumpAndSettle();
        final total = find.byKey(const Key('budget-total'));
        final category = find.byKey(
          const ValueKey('budget-category-$categoryId'),
        );
        expect(
          tester.widget<TextField>(total).controller!.text,
          '90071992547409.93',
        );
        await tester.enterText(total, '90071992547409.92');
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: true),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(total).obscureText, isTrue);
        expect(tester.widget<TextField>(category).obscureText, isTrue);
        expect(tester.widget<TextField>(category).controller!.text, '123.00');
        expect(
          tester.getSemantics(find.byType(Scaffold).last).toStringDeep(),
          isNot(contains('90071992547409.92')),
        );
        await tester.ensureVisible(
          find.byKey(const Key('budget-reveal-amounts')),
        );
        await tester.tap(find.byKey(const Key('budget-reveal-amounts')));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(total).obscureText, isFalse);
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: false),
        );
        await tester.pumpAndSettle();
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: true),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(total).obscureText, isTrue);
        await tester.ensureVisible(find.byKey(const Key('save-budget')));
        await tester.tap(find.byKey(const Key('save-budget')));
        await tester.pumpAndSettle();
        expect(find.byType(BudgetEditor), findsNothing);
        final saved = (await app.ledger.read(
          app.space!,
        )).find('budget', _budget)!.payload;
        expect(saved['total'], _money('9007199254740992'));
        expect((saved['categories'] as List).single, {
          'category_id': categoryId,
          'limit': _money('12300'),
        });
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await _close(tester, app);
      }
    },
  );

  testWidgets(
    'real budget projection uses exact grouped display and live privacy removes amount ratios without writes',
    (tester) async {
      final app = (await tester.runAsync(_fixture))!;
      try {
        final view = await app.ledger.read(app.space!);
        final query = ReportQuery(
          bookId: bookId,
          reportCurrency: 'CNY',
          reportScale: 2,
          startDate: '2026-11-01',
          endDateExclusive: '2026-12-01',
        );
        final report = await LedgerReportingService(
          app.repository,
        ).read(app.space!, query);
        final pending = (await app.repository.pending(
          app.space!,
        )).map((row) => row.operationJson).toList();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: BudgetView(
                  app: app,
                  space: app.space!,
                  book: view.find('book', bookId)!,
                  view: view,
                  query: query,
                  report: report,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('限额 90,071,992,547,409.93'), findsOneWidget);
        expect(find.text('限额 123.00'), findsOneWidget);
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: true),
        );
        await tester.pumpAndSettle();
        expect(find.text('预算金额已隐藏'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.textContaining('90,071,992,547,409.93'), findsNothing);
        expect(
          (await app.repository.pending(
            app.space!,
          )).map((row) => row.operationJson).toList(),
          pending,
        );
        expect(
          (await app.ledger.read(
            app.space!,
          )).find('budget', _budget)!.payload['total'],
          _money('9007199254740993'),
        );
      } finally {
        await _close(tester, app);
      }
    },
  );
}
