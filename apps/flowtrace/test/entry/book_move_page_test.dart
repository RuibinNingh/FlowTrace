import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/features/transactions/bill_book_move_page.dart';

import '../ledger/query_fixtures.dart';

const tagName = '仅目标有权标签';

Future<void> flush(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, Finder field, String text) async {
  await tester.ensureVisible(field);
  await tester.tap(field.hitTestable());
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).hitTestable());
  await tester.pumpAndSettle();
}

void scenario(
  String name,
  Future<void> Function(WidgetTester, QueryFixture, AppController) action, {
  bool narrow = false,
}) {
  testWidgets(name, (tester) async {
    final f = QueryFixture();
    await tester.runAsync(() async {
      await f.seed();
      await f.put('tag', qid(65), qOtherBook, {
        'projection_kind': 'tag',
        'payload': {
          'name': tagName,
          'kind': 'tag',
          'group_id': null,
          'color': '#2279D7',
          'sort_order': 0,
          'archived': false,
        },
      });
    });
    final app = AppController(f.db)
      ..space = f.space
      ..loading = false;
    if (narrow) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        builder: narrow
            ? (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.8)),
                child: child!,
              )
            : null,
        home: BillBookMovePage(app: app, space: f.space, ids: {qc}),
      ),
    );
    await flush(tester);
    try {
      await action(tester, f, app);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      app.dispose();
      await tester.runAsync(f.close);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}

void main() {
  scenario(
    'move form requires explicit category/tag decisions and never writes while offline',
    (tester, f, app) async {
      await choose(
        tester,
        find.byKey(const ValueKey('move-target-null')),
        '合成旅行',
      );
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(ValueKey('move-category-$qc-unselected')),
            )
            .initialValue,
        'unselected',
      );
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(ValueKey('move-tags-$qc-unselected')),
            )
            .initialValue,
        'unselected',
      );
      await choose(
        tester,
        find.byKey(ValueKey('move-category-$qc-unselected')),
        '清空分类',
      );
      await choose(
        tester,
        find.byKey(ValueKey('move-tags-$qc-unselected')),
        '清空标签',
      );
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(ValueKey('move-category-$qc-clear')),
            )
            .initialValue,
        'clear',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('review-book-move')))
            .onPressed,
        isNull,
      );
      expect(await f.local.pending(f.space), isEmpty);
      expect((await f.entity(qc)).scopeId, qBook);
    },
  );
  scenario(
    'database source revocation removes selected bill without app notification',
    (tester, f, app) async {
      await choose(
        tester,
        find.byKey(const ValueKey('move-target-null')),
        '合成旅行',
      );
      expect(find.textContaining('50.00 CNY'), findsOneWidget);
      await tester.runAsync(() => f.sync.revokeScope(f.space, qBook));
      await flush(tester);
      expect(find.textContaining('50.00 CNY'), findsNothing);
      expect(find.text('账单或账本权限已变化，请返回重新选择。'), findsOneWidget);
    },
  );
  scenario(
    'open target tag chooser hides cached names immediately on database revocation',
    (tester, f, app) async {
      await choose(
        tester,
        find.byKey(const ValueKey('move-target-null')),
        '合成旅行',
      );
      await choose(
        tester,
        find.byKey(ValueKey('move-tags-$qc-unselected')),
        '选择目标标签',
      );
      final button = find.widgetWithText(TextButton, '选择目标账本标签');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await flush(tester);
      expect(find.text(tagName), findsOneWidget);
      await tester.runAsync(() => f.sync.revokeScope(f.space, qOtherBook));
      await flush(tester);
      expect(find.text(tagName), findsNothing);
      expect(find.text('账单、账本权限或资料空间已变化，请返回。'), findsOneWidget);
    },
  );
  scenario(
    'narrow large-text move form keeps mapping controls inside layout',
    (tester, f, app) async {
      await choose(
        tester,
        find.byKey(const ValueKey('move-target-null')),
        '合成旅行',
      );
      await choose(
        tester,
        find.byKey(ValueKey('move-category-$qc-unselected')),
        '清空分类',
      );
      await choose(
        tester,
        find.byKey(ValueKey('move-tags-$qc-unselected')),
        '清空标签',
      );
      await tester.ensureVisible(find.byKey(const Key('review-book-move')));
      expect(tester.takeException(), isNull);
    },
    narrow: true,
  );
}
