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
import '../data/sync_store_test.dart'
    show client, epoch, scope, entity, edit, operationId;

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'database revocation hides cached server text without an app notification',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db)..space = testSpace();
      final repo = app.repository,
          space = app.space!,
          store = SyncStore(app.repository);
      await repo.registerSpace(space);
      await store.configure(space, client, epoch);
      await repo.saveEntityAndQueue(
        space,
        edit(1, '用户尚未发送的本机输入', action: 'create'),
      );
      await store.nextPush(space);
      await store.reject(
        space,
        operationId(1),
        'revision_conflict',
        authorizedServer: {'name': '撤权前已缓存的服务器文字'},
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: SyncPage(app: app, engine: SyncEngine(store)),
          ),
        );
        await _flush(tester);
        expect(find.textContaining('撤权前已缓存的服务器文字'), findsOneWidget);
        await tester.runAsync(() => store.revokeScope(space, scope));
        await _flush(tester);
        expect(find.textContaining('撤权前已缓存的服务器文字'), findsNothing);
        expect(find.textContaining('用户尚未发送的本机输入'), findsOneWidget);
        expect(find.text('账本访问已撤销，本机输入已保留'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _flush(tester);
        app.dispose();
        await tester.runAsync(db.close);
      }
    },
  );

  for (final ownMove in [true, false]) {
    testWidgets(
      'move conflict only offers fresh server acceptance with ownMove=$ownMove',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        final app = AppController(db)..space = testSpace();
        final repo = app.repository,
            space = app.space!,
            store = SyncStore(app.repository);
        const target = '22000000-0000-4000-8000-000000000099';
        await repo.registerSpace(space);
        await store.configure(space, client, epoch);
        final command = QueuedCommand(
          operationId: operationId(1),
          scopeId: scope,
          entityType: 'bill',
          entityId: entity,
          action: 'update',
          baseRevision: '1',
          payload: {'book_id': ownMove ? target : scope, 'note': '需核对的本机移动输入'},
          move: ownMove
              ? {
                  'target_scope_id': target,
                  'attachment_replacements': <Object?>[],
                }
              : null,
        );
        await repo.saveEntityAndQueue(space, command);
        await store.nextPush(space);
        await store.reject(
          space,
          operationId(1),
          ownMove ? 'revision_conflict' : 'entity_moved',
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: SyncPage(app: app, engine: SyncEngine(store)),
            ),
          );
          await _flush(tester);
          expect(find.widgetWithText(TextButton, '使用服务器版本'), findsOneWidget);
          expect(find.widgetWithText(TextButton, '保留我的修改'), findsNothing);
          expect(find.textContaining('再重新预览移动或编辑'), findsOneWidget);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await _flush(tester);
          app.dispose();
          await tester.runAsync(db.close);
        }
      },
    );
  }

  testWidgets(
    'edit then move then target edit keeps the full chain behind explicit repreview',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db)..space = testSpace();
      final repo = app.repository,
          space = app.space!,
          store = SyncStore(app.repository);
      const target = '22000000-0000-4000-8000-000000000099';
      await repo.registerSpace(space);
      await store.configure(space, client, epoch);
      await repo.saveEntityAndQueue(
        space,
        QueuedCommand(
          operationId: operationId(1),
          scopeId: scope,
          entityType: 'bill',
          entityId: entity,
          action: 'update',
          baseRevision: '1',
          payload: {'book_id': scope, 'note': '最初来源编辑'},
        ),
      );
      final frozen = (await store.nextPush(space))!.body;
      await repo.saveEntityAndQueue(
        space,
        QueuedCommand(
          operationId: operationId(2),
          scopeId: scope,
          entityType: 'bill',
          entityId: entity,
          action: 'update',
          baseRevision: '1',
          dependsOn: operationId(1),
          payload: {'book_id': target, 'note': '明确移动到目标'},
          move: {
            'target_scope_id': target,
            'attachment_replacements': <Object?>[],
          },
        ),
      );
      await repo.saveEntityAndQueue(
        space,
        QueuedCommand(
          operationId: operationId(3),
          scopeId: target,
          entityType: 'bill',
          entityId: entity,
          action: 'update',
          baseRevision: '1',
          dependsOn: operationId(2),
          payload: {'book_id': target, 'note': '目标账本中的最新用户输入'},
        ),
      );
      await store.reject(space, operationId(1), 'revision_conflict');
      final before = await repo.pending(space);
      expect(before.map((op) => op.state), ['rejected', 'blocked', 'blocked']);
      expect(
        jsonDecode(before.first.operationJson).containsKey('move'),
        isFalse,
      );
      expect(
        jsonDecode(before.last.operationJson).containsKey('move'),
        isFalse,
      );
      expect(
        jsonDecode(before[1].operationJson)['move']['target_scope_id'],
        target,
      );
      final conflict = (await store.conflicts(space)).single;
      expect(conflict.operationId, operationId(1));
      expect(jsonDecode(conflict.localJson)['book_id'], target);
      expect(jsonDecode(conflict.localJson)['note'], '目标账本中的最新用户输入');
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: SyncPage(app: app, engine: SyncEngine(store)),
          ),
        );
        await _flush(tester);
        expect(find.textContaining('目标账本中的最新用户输入'), findsOneWidget);
        expect(find.widgetWithText(TextButton, '使用服务器版本'), findsOneWidget);
        expect(find.widgetWithText(TextButton, '保留我的修改'), findsNothing);
        expect(find.textContaining('再重新预览移动或编辑'), findsOneWidget);
        final after = await tester.runAsync(() => repo.pending(space));
        expect(
          after!.map((op) => op.operationJson),
          before.map((op) => op.operationJson),
        );
        expect(after.first.frozenRequestJson, frozen);
        expect(after.map((op) => op.state), ['rejected', 'blocked', 'blocked']);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _flush(tester);
        app.dispose();
        await tester.runAsync(db.close);
      }
    },
  );
}
