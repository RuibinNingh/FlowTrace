import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import 'local_repository_test.dart' show testSpace;

const scope = '22222222-2222-4222-8222-222222222222';
const entity = '33333333-3333-4333-8333-333333333333';
const client = '44444444-4444-4444-8444-444444444444';
const epoch = '55555555-5555-4555-8555-555555555555';
String operationId(int n) =>
    '11111111-1111-4111-8111-${n.toString().padLeft(12, '0')}';
QueuedCommand edit(
  int n,
  String name, {
  String action = 'update',
  String base = '0',
}) => QueuedCommand(
  operationId: operationId(n),
  scopeId: scope,
  entityType: 'tag',
  entityId: entity,
  action: action,
  baseRevision: base,
  payload: {'name': name},
);
SyncEvent event(String name, String revision, {String id = entity}) =>
    SyncEvent(
      scopeId: scope,
      entityType: 'tag',
      entityId: id,
      revision: revision,
      deleted: false,
      data: {'name': name},
    );

void main() {
  late AppDatabase db;
  late LocalRepository repo;
  late SyncStore store;
  final space = testSpace();
  test(
    'late identity configuration cannot create or back up another session state',
    () async {
      final other = testSpace(user: 'another-identity');
      await repo.registerSpace(other);
      await expectLater(
        store.configure(other, client, epoch, isCurrent: () => false),
        throwsStateError,
      );
      expect(await store.state(other), isNull);
      expect(await store.recoveryBackups(other), isEmpty);
      expect((await store.state(space))!.epoch, epoch);
    },
  );
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = LocalRepository(db);
    store = SyncStore(repo);
    await repo.registerSpace(space);
    await store.configure(space, client, epoch);
  });
  tearDown(() => db.close());

  test(
    'continuous offline edits survive earlier ACK and retry unchanged bytes',
    () async {
      await repo.saveEntityAndQueue(space, edit(1, 'first', action: 'create'));
      final first = (await store.nextPush(space))!;
      await repo.saveEntityAndQueue(space, edit(2, 'latest'));
      final retry = (await store.nextPush(space))!;
      expect(retry.body, first.body);
      expect(retry.attempt, 2);
      await store.acknowledge(space, operationId(1), '1');
      expect(
        jsonDecode(
          (await db.select(db.localEntities).getSingle()).dataJson,
        )['name'],
        'latest',
      );
      final second = (await store.nextPush(space))!;
      final body = (jsonDecode(second.body)['operations'] as List).single;
      expect(body['base_revision'], '1');
      expect(body['depends_on'], operationId(1));
      await store.applyPullPage(
        space,
        epoch,
        [
          [event('first', '1')],
        ],
        finalPage: true,
        checkpoint: {scope: '1'},
      );
      expect(
        jsonDecode(
          (await db.select(db.localEntities).getSingle()).dataJson,
        )['name'],
        'latest',
      );
      await store.acknowledge(space, operationId(2), '2');
      expect(await repo.pending(space), isEmpty);
      await store.acknowledge(space, operationId(1), '1');
      expect(
        (await db.select(db.localEntities).getSingle()).serverRevision,
        '2',
      );
    },
  );

  test(
    'server update pulled before an older ACK remains visible once pending is clear',
    () async {
      await repo.saveEntityAndQueue(space, edit(1, 'first', action: 'create'));
      await store.nextPush(space);
      await store.applyPullPage(
        space,
        epoch,
        [
          [event('newer server', '5')],
        ],
        finalPage: true,
        checkpoint: {scope: '5'},
      );
      await store.acknowledge(space, operationId(1), '1');
      final local = await db.select(db.localEntities).getSingle();
      expect(local.serverRevision, '5');
      expect(jsonDecode(local.dataJson)['name'], 'newer server');
    },
  );

  test(
    'rejected operation blocks dependent edits and needs a fresh explicit resolution',
    () async {
      await store.applyPullPage(
        space,
        epoch,
        [
          [event('base', '1')],
        ],
        finalPage: true,
        checkpoint: {scope: '1'},
      );
      await repo.saveEntityAndQueue(space, edit(1, 'first edit', base: '1'));
      final frozen = (await store.nextPush(space))!.body;
      await repo.saveEntityAndQueue(space, edit(2, 'latest edit', base: '1'));
      await store.reject(
        space,
        operationId(1),
        'revision_conflict',
        authorizedServer: {
          'revision': '2',
          'data': {'name': 'remote'},
        },
      );
      expect(await store.nextPush(space), isNull);
      final conflict = (await store.conflicts(space)).single;
      expect(jsonDecode(conflict.baseJson!)['name'], 'base');
      expect(jsonDecode(conflict.localJson)['name'], 'latest edit');
      await store.resolveWithNewCommand(
        space,
        operationId(1),
        edit(3, 'merged', base: '2'),
      );
      final next = (await store.nextPush(space))!;
      expect(next.operationId, operationId(3));
      final originals = await db.select(db.pendingOperations).get();
      expect(originals.first.frozenRequestJson, frozen);
      expect(originals[1].state, 'discarded');
      expect(await store.conflicts(space), isEmpty);
    },
  );

  test(
    'pull page transaction rolls back all events and cursor when local write fails',
    () async {
      const other = '66666666-6666-4666-8666-666666666666';
      await db.customStatement(
        "CREATE TRIGGER reject_second BEFORE INSERT ON server_shadows WHEN NEW.entity_id = '$other' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END",
      );
      await expectLater(
        store.applyPullPage(
          space,
          epoch,
          [
            [event('first', '1'), event('second', '1', id: other)],
          ],
          finalPage: true,
          checkpoint: {scope: '1'},
        ),
        throwsA(anything),
      );
      expect(await db.select(db.serverShadows).get(), isEmpty);
      expect(await db.select(db.localEntities).get(), isEmpty);
      expect((await store.state(space))!.cursorsJson, '{}');
    },
  );

  test(
    'only final page advances cursor and repeated pages are idempotent',
    () async {
      await store.applyPullPage(space, epoch, [
        [event('first', '1')],
      ], finalPage: false);
      expect((await store.state(space))!.cursorsJson, '{}');
      await store.applyPullPage(
        space,
        epoch,
        [
          [event('first', '1')],
        ],
        finalPage: true,
        checkpoint: {scope: '1'},
      );
      expect(await db.select(db.serverShadows).get(), hasLength(1));
      await expectLater(
        store.applyPullPage(
          space,
          epoch,
          [
            [event('stale', '0')],
          ],
          finalPage: true,
          checkpoint: {scope: '0'},
        ),
        throwsStateError,
      );
      expect(
        jsonDecode(
          (await db.select(db.localEntities).getSingle()).dataJson,
        )['name'],
        'first',
      );
    },
  );

  test(
    'epoch change preserves acknowledged data, pending intents and drafts',
    () async {
      await repo.saveEntityAndQueue(
        space,
        edit(1, 'acknowledged', action: 'create'),
      );
      await store.nextPush(space);
      await store.acknowledge(space, operationId(1), '1');
      await repo.saveDraft(space, 'unsent local note');
      await expectLater(
        store.configure(space, client, '77777777-7777-4777-8777-777777777777'),
        throwsStateError,
      );
      final backup = jsonDecode(
        (await db.select(db.syncRecoveryBackups).getSingle()).dataJson,
      );
      expect(backup['entities'], hasLength(1));
      expect(backup['shadows'], hasLength(1));
      expect(backup['operations'].single['state'], 'applied');
      expect(backup['drafts'].single['body'], 'unsent local note');
      expect(await store.nextPush(space), isNull);
      expect(await db.select(db.localEntities).get(), hasLength(1));
      expect((await store.state(space))!.epoch, epoch);
    },
  );

  test(
    'revocation clears controlled cache while retaining isolated unsent input',
    () async {
      await store.applyPullPage(
        space,
        epoch,
        [
          [event('server', '1')],
        ],
        finalPage: true,
        checkpoint: {scope: '1'},
      );
      await repo.saveEntityAndQueue(
        space,
        edit(1, 'my unsent edit', base: '1'),
      );
      await store.nextPush(space);
      await store.reject(
        space,
        operationId(1),
        'revision_conflict',
        authorizedServer: {'name': 'private server copy'},
      );
      await store.revokeScope(space, scope);
      expect(await db.select(db.serverShadows).get(), isEmpty);
      expect(await db.select(db.localEntities).get(), isEmpty);
      final conflict = (await store.conflicts(space)).single;
      expect(conflict.serverJson, isNull);
      expect(conflict.baseJson, isNull);
      expect(jsonDecode(conflict.localJson)['name'], 'my unsent edit');
      expect(await store.nextPush(space), isNull);
      await store.restoreScopeAccess(space, {scope});
      expect(await store.nextPush(space), isNull);
    },
  );

  test('frozen retry and full backup survive file database reopen', () async {
    final folder = await Directory.systemTemp.createTemp(
      'flowtrace-sync-test-',
    );
    final file = File('${folder.path}/isolated.sqlite');
    final disk = AppDatabase(NativeDatabase(file));
    final diskRepo = LocalRepository(disk);
    final diskStore = SyncStore(diskRepo);
    await diskRepo.registerSpace(space);
    await diskStore.configure(space, client, epoch);
    await diskRepo.saveEntityAndQueue(
      space,
      edit(1, 'persist', action: 'create'),
    );
    final first = (await diskStore.nextPush(space))!.body;
    await disk.close();
    final reopened = AppDatabase(NativeDatabase(file));
    try {
      final reopenedStore = SyncStore(LocalRepository(reopened));
      expect((await reopenedStore.nextPush(space))!.body, first);
      await reopenedStore.requireRebuild(space, 'cursor_expired');
      expect(
        await reopened.select(reopened.syncRecoveryBackups).get(),
        hasLength(1),
      );
      expect(await reopenedStore.nextPush(space), isNull);
    } finally {
      await reopened.close();
      await folder.delete(recursive: true);
    }
  });

  test(
    'conflict stays current during further editing and server choice uses latest confirmed revision',
    () async {
      await repo.saveEntityAndQueue(space, edit(1, 'first', base: '1'));
      await store.nextPush(space);
      await store.reject(space, operationId(1), 'revision_conflict');
      await repo.saveEntityAndQueue(space, edit(2, 'newer local', base: '1'));
      expect(
        jsonDecode((await store.conflicts(space)).single.localJson)['name'],
        'newer local',
      );
      await store.applyPullPage(space, epoch, [
        [event('server newest', '4')],
      ], finalPage: false);
      await store.acceptServerVersion(
        space,
        operationId(1),
        event('dialog older read', '3'),
      );
      final current = await db.select(db.localEntities).getSingle();
      expect(current.serverRevision, '4');
      expect(jsonDecode(current.dataJson)['name'], 'server newest');
      expect(await store.conflicts(space), isEmpty);
      expect(await store.nextPush(space), isNull);
    },
  );

  test(
    'recovery blocks new formal edits while preserving new drafts and upload metadata',
    () async {
      await repo.saveEntityAndQueue(space, edit(1, 'before', action: 'create'));
      await repo.writeSetting(
        'attachments.v1.${space.id}.queue.fixture',
        '{"local_key":"fixture-original"}',
      );
      await repo.writeSetting(
        'attachments.v1.${space.id}.cache.fixture.original',
        '{"local_key":"controlled-cache"}',
      );
      await repo.writeSetting(
        'ledger.postings.v1.${space.id}.fixture',
        '{"amount_minor":"9007199254740993"}',
      );
      await store.requireRebuild(space, 'resync_required');
      await expectLater(
        repo.saveEntityAndQueue(space, edit(2, 'must not overwrite')),
        throwsStateError,
      );
      await repo.saveDraft(space, 'New draft during recovery');
      expect(
        (await repo.drafts(space)).single.body,
        'New draft during recovery',
      );
      final backup = jsonDecode(
        (await store.recoveryBackups(space)).single.dataJson,
      );
      expect(backup['attachment_queue'], hasLength(1));
      expect(backup['attachment_queue'][0]['key'], contains('.queue.'));
      expect(backup['ledger_postings'], hasLength(1));
      expect(
        jsonDecode(backup['ledger_postings'][0]['value'])['amount_minor'],
        '9007199254740993',
      );
      expect(
        jsonDecode(
          (await db.select(db.localEntities).getSingle()).dataJson,
        )['name'],
        'before',
      );
    },
  );

  test(
    'ACK keeps an equal revision canonical projection already pulled',
    () async {
      await repo.saveEntityAndQueue(
        space,
        edit(1, 'original', action: 'create'),
      );
      await store.nextPush(space);
      final canonical = {
        'projection_kind': 'tag',
        'payload': {'name': 'original', 'color': '#2279d7'},
      };
      await store.applyPullPage(space, epoch, [
        [
          SyncEvent(
            scopeId: scope,
            entityType: 'tag',
            entityId: entity,
            revision: '1',
            deleted: false,
            data: canonical,
          ),
        ],
      ], finalPage: false);
      await store.acknowledge(space, operationId(1), '1');
      expect(
        jsonDecode((await db.select(db.serverShadows).getSingle()).dataJson),
        canonical,
      );
      expect(
        jsonDecode((await db.select(db.localEntities).getSingle()).dataJson),
        canonical,
      );
    },
  );

  test(
    'book create acknowledgement stores the entity in its own scope',
    () async {
      final command = QueuedCommand(
        operationId: operationId(1),
        scopeId: scope,
        entityType: 'book',
        entityId: entity,
        action: 'create',
        baseRevision: '0',
        payload: {'name': 'My book'},
      );
      await repo.saveEntityAndQueue(space, command);
      await store.nextPush(space);
      await store.acknowledge(space, operationId(1), '1');
      expect((await db.select(db.localEntities).getSingle()).scopeId, entity);
      expect((await db.select(db.serverShadows).getSingle()).scopeId, entity);
    },
  );
}
