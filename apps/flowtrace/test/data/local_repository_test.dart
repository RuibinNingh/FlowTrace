import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:sqlite3/sqlite3.dart' as native_sqlite;

DataSpace testSpace({String user = 'alice', String instance = 'instance-a'}) =>
    DataSpace(
      server: ServerAddress.parse('https://isolated.example'),
      serverInstanceId: instance,
      userId: user,
    );

QueuedCommand command({
  String amount = '9007199254740993',
  String? dependsOn,
}) => QueuedCommand(
  operationId: '11111111-1111-4111-8111-111111111111',
  scopeId: '22222222-2222-4222-8222-222222222222',
  entityType: 'bill',
  entityId: '33333333-3333-4333-8333-333333333333',
  action: 'create',
  baseRevision: '0',
  dependsOn: dependsOn,
  payload: {'amount_minor': amount, 'currency': 'CNY', 'currency_scale': 2},
);

void main() {
  test(
    'entity and outbox roll back together when queue insertion fails',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final space = testSpace();
      await repo.registerSpace(space);
      await db.customStatement(
        "CREATE TRIGGER isolated_queue_failure BEFORE INSERT ON pending_operations BEGIN SELECT RAISE(ABORT, 'isolated queue failure'); END",
      );
      await expectLater(
        repo.saveEntityAndQueue(space, command()),
        throwsA(anything),
      );
      expect(await db.select(db.localEntities).get(), isEmpty);
      expect(await repo.pending(space), isEmpty);
    },
  );

  test(
    'same operation is idempotent and its first sent request stays frozen',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      final space = testSpace();
      await repo.registerSpace(space);
      final original = command();
      expect(jsonDecode(original.serialized)['depends_on'], isNull);
      await repo.saveEntityAndQueue(space, original);
      await repo.saveEntityAndQueue(space, original);
      expect(await repo.pending(space), hasLength(1));
      await repo.markAttempted(
        space,
        original.operationId,
        original.serialized,
      );
      await repo.markAttempted(
        space,
        original.operationId,
        original.serialized,
      );
      expect((await repo.pending(space)).single.attemptCount, 2);
      await expectLater(
        repo.markAttempted(space, original.operationId, '{}'),
        throwsStateError,
      );
      await expectLater(
        repo.saveEntityAndQueue(space, command(amount: '1')),
        throwsStateError,
      );
      final stored = (await db.select(db.localEntities).get()).single;
      expect(jsonDecode(stored.dataJson)['amount_minor'], '9007199254740993');
    },
  );

  test('payload snapshot cannot be changed after command construction', () {
    final nested = <String, Object?>{'amount_minor': '1230'};
    final operation = QueuedCommand(
      operationId: '11111111-1111-4111-8111-111111111111',
      scopeId: '22222222-2222-4222-8222-222222222222',
      entityType: 'bill',
      entityId: '33333333-3333-4333-8333-333333333333',
      action: 'create',
      baseRevision: '0',
      payload: {'money': nested},
    );
    nested['amount_minor'] = '9999';
    expect((operation.payload['money'] as Map)['amount_minor'], '1230');
    expect(
      () => QueuedCommand(
        operationId: '11111111-1111-4111-8111-111111111111',
        scopeId: '22222222-2222-4222-8222-222222222222',
        entityType: 'bill',
        entityId: '33333333-3333-4333-8333-333333333333',
        action: 'create',
        baseRevision: '0',
        payload: {'amount_minor': 0.1},
      ),
      throwsArgumentError,
    );
  });

  test(
    'database reopen preserves drafts and outbox with user partitions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'flowtrace-sqlite-test-',
      );
      final file = File('${directory.path}/isolated.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      final alice = testSpace();
      final bob = testSpace(user: 'bob');
      var repo = LocalRepository(db);
      await repo.registerSpace(alice);
      await repo.registerSpace(bob);
      await repo.saveDraft(alice, 'Alice isolated draft');
      await repo.saveDraft(bob, 'Bob isolated draft');
      await repo.saveEntityAndQueue(alice, command());
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      repo = LocalRepository(db);
      try {
        expect((await repo.drafts(alice)).single.body, 'Alice isolated draft');
        expect((await repo.drafts(bob)).single.body, 'Bob isolated draft');
        expect(await repo.pending(alice), hasLength(1));
        expect(await repo.pending(bob), isEmpty);
        final unverified = DataSpace.provisional(alice.server);
        await repo.registerSpace(unverified);
        await expectLater(
          repo.saveEntityAndQueue(unverified, command()),
          throwsStateError,
        );
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('settings-only schema 1 upgrades without dropping settings', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flowtrace-migration-test-',
    );
    final file = File('${directory.path}/legacy.sqlite');
    final legacy = native_sqlite.sqlite3.open(file.path);
    legacy.execute(
      'CREATE TABLE app_settings (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)',
    );
    legacy.execute("INSERT INTO app_settings VALUES ('theme_mode', 'light')");
    legacy.execute('PRAGMA user_version = 1');
    legacy.close();
    final db = AppDatabase(NativeDatabase(file));
    try {
      final repo = LocalRepository(db);
      expect(await repo.readSetting('theme_mode'), 'light');
      final space = testSpace();
      await repo.registerSpace(space);
      await repo.saveDraft(space, 'After migration');
      expect((await repo.drafts(space)).single.body, 'After migration');
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], 5);
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });

  test(
    'schema 2 upgrade preserves draft and frozen command byte for byte',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'flowtrace-v2-test-',
      );
      final file = File('${directory.path}/v2.sqlite');
      final legacy = native_sqlite.sqlite3.open(file.path);
      final space = testSpace();
      final original = command();
      final frozen = '{"preserved": "fixture with spaces"}';
      legacy.execute('''
      CREATE TABLE app_settings (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE local_spaces (id TEXT NOT NULL PRIMARY KEY, server_address TEXT NOT NULL,
        server_instance_id TEXT NOT NULL, user_id TEXT NOT NULL, created_at INTEGER NOT NULL);
      CREATE TABLE local_drafts (id TEXT NOT NULL, space_id TEXT NOT NULL REFERENCES local_spaces(id),
        body TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY(space_id,id));
      CREATE TABLE local_entities (space_id TEXT NOT NULL REFERENCES local_spaces(id), entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL, data_json TEXT NOT NULL, server_revision TEXT NOT NULL DEFAULT '0',
        deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1)), updated_at INTEGER NOT NULL,
        PRIMARY KEY(space_id,entity_type,entity_id));
      CREATE TABLE pending_operations (sequence INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        space_id TEXT NOT NULL REFERENCES local_spaces(id), operation_id TEXT NOT NULL,
        entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, operation_json TEXT NOT NULL,
        frozen_request_json TEXT, state TEXT NOT NULL DEFAULT 'queued', attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error_code TEXT, created_at INTEGER NOT NULL, UNIQUE(space_id,operation_id));
      PRAGMA user_version = 2;
    ''');
      legacy.execute('INSERT INTO local_spaces VALUES (?,?,?,?,?)', [
        space.id,
        space.server.toString(),
        space.serverInstanceId,
        space.userId,
        1,
      ]);
      legacy.execute('INSERT INTO local_drafts VALUES (?,?,?,?,?)', [
        'legacy-draft',
        space.id,
        'Keep v2',
        1,
        1,
      ]);
      legacy.execute('INSERT INTO local_entities VALUES (?,?,?,?,?,?,?)', [
        space.id,
        original.entityType,
        original.entityId,
        jsonEncode(original.payload),
        '0',
        0,
        1,
      ]);
      legacy.execute(
        'INSERT INTO pending_operations (space_id,operation_id,entity_type,entity_id,operation_json,frozen_request_json,state,attempt_count,created_at) VALUES (?,?,?,?,?,?,?,?,?)',
        [
          space.id,
          original.operationId,
          original.entityType,
          original.entityId,
          original.serialized,
          frozen,
          'sending',
          3,
          1,
        ],
      );
      legacy.close();
      final db = AppDatabase(NativeDatabase(file));
      try {
        final repo = LocalRepository(db);
        expect((await repo.drafts(space)).single.body, 'Keep v2');
        final pending = (await repo.pending(space)).single;
        expect(pending.operationJson, original.serialized);
        expect(pending.frozenRequestJson, frozen);
        expect(pending.attemptCount, 3);
        expect(
          (await db.select(db.localEntities).getSingle()).scopeId,
          original.scopeId,
        );
        expect(await db.select(db.serverShadows).get(), isEmpty);
        expect(await db.select(db.snapshotPages).get(), isEmpty);
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
