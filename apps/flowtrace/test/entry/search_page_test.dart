import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/features/search/search_page.dart';
import 'package:flowtrace/features/transactions/bill_book_move_page.dart';

import 'entry_page_test.dart' show setupApp, bookId;

void main() {
  testWidgets('move route freezes the selected bill and cancel preserves it', (
    tester,
  ) async {
    final app = (await tester.runAsync(setupApp))!;
    const id = 'bb000000-0000-4000-8000-000000000022';
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
          'amount_minor': '125',
        },
        'business_date': '2026-10-20',
        'business_timezone': 'Asia/Shanghai',
        'note': '合成移动入口',
      },
    );
    final before = (await app.repository.pending(
      app.space!,
    )).map((operation) => operation.operationJson).toList();
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(app: app, space: app.space!, initialBookId: bookId),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('search-bill-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('move-selected-bills')));
    await tester.pumpAndSettle();
    final page = tester.widget<BillBookMovePage>(find.byType(BillBookMovePage));
    expect(page.ids, {id});
    expect(() => page.ids.clear(), throwsUnsupportedError);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('move-selected-bills')), findsOneWidget);
    expect(
      (await app.repository.pending(
        app.space!,
      )).map((operation) => operation.operationJson).toList(),
      before,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    app.dispose();
    await tester.runAsync(app.database.close);
  });

  testWidgets(
    'search and selection maintain only the confirmed matching bill',
    (tester) async {
      final app = (await tester.runAsync(setupApp))!;
      const first = 'bb000000-0000-4000-8000-000000000020',
          second = 'bb000000-0000-4000-8000-000000000021';
      for (final row in {first: '第一笔合成午餐', second: '第二笔合成交通'}.entries) {
        await app.ledger.save(
          app.space!,
          entityType: 'bill',
          scopeId: bookId,
          entityId: row.key,
          payload: {
            'bill_type': 'expense',
            'book_id': bookId,
            'money': {
              'currency': 'CNY',
              'currency_scale': 2,
              'amount_minor': '100',
            },
            'business_date': '2026-10-20',
            'business_timezone': 'Asia/Shanghai',
            'note': row.value,
          },
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: SearchPage(app: app, space: app.space!, initialBookId: bookId),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('bill-search-keyword')),
        '午餐',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-bill-$first')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-bill-$second')), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('search-bill-$first')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量维护'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('batch-change-备注')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置为').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('batch-note')), '核对后修改');
      await tester.scrollUntilVisible(
        find.byKey(const Key('preview-bill-batch')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('preview-bill-batch')));
      await tester.pumpAndSettle();
      expect(find.text('核对1笔账单'), findsOneWidget);
      expect(find.text('新备注：核对后修改'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('confirm-bill-batch')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('confirm-bill-batch')));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final view = await app.ledger.read(app.space!);
      expect(view.find('bill', first)!.payload['note'], '核对后修改');
      expect(view.find('bill', second)!.payload['note'], '第二笔合成交通');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      app.dispose();
      await tester.runAsync(app.database.close);
    },
  );
}
