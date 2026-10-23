import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/features/entry/entry_page.dart';

import '../data/local_repository_test.dart' show testSpace;

const bookId = 'ba000000-0000-4000-8000-000000000001';
const categoryId = 'ca000000-0000-4000-8000-000000000001';

Future<AppController> setupApp({String instance = 'instance-a'}) async {
  final app = AppController(AppDatabase(NativeDatabase.memory()))
    ..space = testSpace(
      user: 'fa000000-0000-4000-8000-000000000001',
      instance: instance,
    )
    ..loading = false;
  await app.repository.registerSpace(app.space!);
  await app.ledger.save(
    app.space!,
    entityType: 'book',
    scopeId: app.space!.userId,
    entityId: bookId,
    payload: {
      'name': 'UI合成账本',
      'currency': 'CNY',
      'timezone': 'Asia/Shanghai',
      'month_start_day': 1,
    },
  );
  await app.ledger.save(
    app.space!,
    entityType: 'category',
    scopeId: bookId,
    entityId: categoryId,
    payload: {
      'name': '餐饮',
      'kind': 'expense',
      'parent_id': null,
      'icon': 'food',
      'sort_order': 0,
    },
  );
  return app;
}

void main() {
  testWidgets(
    'incomplete calculator and note survive automatic full draft save',
    (tester) async {
      final app = (await tester.runAsync(setupApp))!;
      await tester.pumpWidget(
        MaterialApp(
          home: EntryPage(app: app, space: app.space!, bookId: bookId),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('entry-note')), '保留尚未完成的输入');
      await tester.tap(find.byKey(const Key('entry-key-1')));
      await tester.tap(find.byKey(const Key('entry-key-+')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final drafts = (await tester.runAsync(
        () => app.ledger.watchDrafts(app.space!).first,
      ))!;
      expect(drafts, hasLength(1));
      expect(drafts.single.ui['expression'], '1+');
      expect(drafts.single.payload['note'], '保留尚未完成的输入');
      expect((await app.ledger.read(app.space!)).bills, isEmpty);
      final saved = drafts.single;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EntryPage(
            app: app,
            space: app.space!,
            bookId: bookId,
            draft: saved,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('1+'), findsOneWidget);
      expect(find.text('保留尚未完成的输入'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      app.dispose();
      await tester.runAsync(app.database.close);
    },
  );

  testWidgets(
    'save and continue writes one exact bill and consumes its draft',
    (tester) async {
      final app = (await tester.runAsync(setupApp))!;
      await tester.pumpWidget(
        MaterialApp(
          home: EntryPage(app: app, space: app.space!, bookId: bookId),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('餐饮'));
      await tester.enterText(find.byKey(const Key('entry-note')), '合成午餐');
      for (final key in ['0', '.', '1', '+', '0', '.', '2']) {
        await tester.tap(find.byKey(Key('entry-key-$key')));
      }
      await tester.tap(find.byKey(const Key('entry-key-再记')));
      await tester.pumpAndSettle();
      final view = await app.ledger.read(app.space!);
      expect(view.bills, hasLength(1));
      expect((view.bills.single.payload['money'] as Map)['amount_minor'], '30');
      expect(view.bills.single.payload['category_id'], categoryId);
      expect(view.bills.single.payload['note'], '合成午餐');
      expect(
        (await tester.runAsync(
          () => app.ledger.watchDrafts(app.space!).first,
        ))!,
        isEmpty,
      );
      expect(find.byKey(const Key('entry-expression')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('entry-expression'))).data,
        '0',
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        (await tester.runAsync(
          () => app.ledger.watchDrafts(app.space!).first,
        ))!,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      app.dispose();
      await tester.runAsync(app.database.close);
    },
  );

  testWidgets(
    'switching server hides old note and stops its pending autosave',
    (tester) async {
      final app = (await tester.runAsync(setupApp))!;
      final old = app.space!;
      await tester.pumpWidget(
        MaterialApp(
          home: EntryPage(app: app, space: old, bookId: bookId),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('entry-note')), '旧空间尚未保存的备注');
      await app.setServerAddress('https://another-isolated.example');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('旧空间尚未保存的备注'), findsNothing);
      expect(find.text('资料空间已切换，请关闭此编辑器。'), findsOneWidget);
      expect(
        (await tester.runAsync(
          () => app.ledger.watchDrafts(app.space!).first,
        ))!,
        isEmpty,
      );
      expect((await app.ledger.read(old)).bills, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      app.dispose();
      await tester.runAsync(app.database.close);
    },
  );

  testWidgets(
    'editing a note preserves the original instant precision and timezone',
    (tester) async {
      final app = (await tester.runAsync(setupApp))!;
      const id = 'bb000000-0000-4000-8000-000000000001';
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
            'amount_minor': '100',
          },
          'business_date': '2026-10-20',
          'business_timezone': 'UTC',
          'occurred_at': '2026-10-20T12:34:56.123456Z',
        },
      );
      final existing = (await app.ledger.read(app.space!)).find('bill', id)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => EntryPage(
                      app: app,
                      space: app.space!,
                      bookId: bookId,
                      existing: existing,
                    ),
                  ),
                ),
                child: const Text('打开编辑'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('entry-note')), '仅改备注');
      await tester.tap(find.byKey(const Key('entry-key-保存')));
      await tester.pumpAndSettle();
      final payload = (await app.ledger.read(
        app.space!,
      )).find('bill', id)!.payload;
      expect(payload['note'], '仅改备注');
      expect(payload['business_timezone'], 'UTC');
      expect(payload['business_date'], '2026-10-20');
      expect(payload['occurred_at'], '2026-10-20T12:34:56.123456Z');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      app.dispose();
      await tester.runAsync(app.database.close);
    },
  );
}
