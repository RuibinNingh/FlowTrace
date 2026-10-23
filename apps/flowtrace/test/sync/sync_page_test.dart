import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/sync/sync_page.dart';

import '../data/local_repository_test.dart' show testSpace;
import '../data/sync_store_test.dart' show client, epoch, edit, operationId;

void main() {
  testWidgets(
    'offline conflict keeps input visible and disables network decisions',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db);
      final repo = LocalRepository(db);
      final store = SyncStore(repo);
      final space = testSpace();
      app.space = space;
      await repo.registerSpace(space);
      await store.configure(space, client, epoch);
      await repo.saveEntityAndQueue(
        space,
        edit(1, 'my conflict note', action: 'create'),
      );
      await store.nextPush(space);
      await store.reject(space, operationId(1), 'revision_conflict');
      await tester.pumpWidget(
        MaterialApp(
          home: SyncPage(app: app, engine: SyncEngine(store)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('需要处理 · 1'), findsOneWidget);
      expect(find.textContaining('my conflict note'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '保留我的修改'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('查看与复制'));
      await tester.pumpAndSettle();
      expect(
        find.text(jsonEncode({'name': 'my conflict note'})),
        findsOneWidget,
      );
      await app.setServerAddress('https://another-isolated.example');
      await tester.pumpAndSettle();
      expect(find.text(jsonEncode({'name': 'my conflict note'})), findsNothing);
      expect(find.text('账号已切换，此内容已隐藏。'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '复制内容'))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      app.dispose();
      await tester.runAsync(db.close);
    },
  );

  testWidgets(
    'backup difference view shows retained record then hides it on account switch',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db)..space = testSpace();
      await tester.pumpWidget(
        MaterialApp(
          home: RecoveryReviewPage(
            app: app,
            spaceId: app.space!.id,
            differences: [
              {
                'difference': 'missing',
                'entity_type': 'bill',
                'local': {
                  'note': 'after-backup confirmed bill',
                  'money': {
                    'currency': 'CNY',
                    'currency_scale': 2,
                    'amount_minor': '9007199254740993',
                  },
                },
              },
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('服务器中缺少此记录'), findsOneWidget);
      expect(find.textContaining('90071992547409.93'), findsOneWidget);
      await app.setServerAddress('https://another-isolated.example');
      await tester.pumpAndSettle();
      expect(find.textContaining('after-backup confirmed bill'), findsNothing);
      expect(find.text('账号已切换，请返回当前账号。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      app.dispose();
      await tester.runAsync(db.close);
    },
  );
}
