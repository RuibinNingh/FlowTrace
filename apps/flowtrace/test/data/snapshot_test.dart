import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import 'local_repository_test.dart' show testSpace;
import 'sync_store_test.dart'
    show scope, entity, client, epoch, edit, operationId;

const snapshotId = '66666666-6666-4666-8666-666666666666';
const instance = '77777777-7777-4777-8777-777777777777';
const nextEpoch = '88888888-8888-4888-8888-888888888888';
const nextClient = '99999999-9999-4999-8999-999999999999';

Map<String, Object?> item(String name, {String id = entity}) => {
  'scope_id': scope,
  'scope_revision': '5',
  'event_index': 0,
  'entity_type': 'tag',
  'entity_id': id,
  'revision': '3',
  'deleted': false,
  'data': {
    'projection_kind': 'tag',
    'payload': {'name': name},
  },
};

Map<String, Object?> statusFor(
  List<List<Object?>> pages, {
  String syncEpoch = epoch,
}) {
  final manifest = <String, Object?>{
    'snapshot_id': snapshotId,
    'instance_id': instance,
    'sync_epoch': syncEpoch,
    'checkpoint': {scope: '5'},
    'permission_versions': {scope: '1'},
    'pages': [
      for (var i = 0; i < pages.length; i++)
        {
          'page_index': i,
          'item_count': pages[i].length,
          'sha256': syncContentHash(pages[i]),
        },
    ],
  };
  return {
    'snapshot_id': snapshotId,
    'status': 'ready',
    'expires_at': DateTime.now()
        .toUtc()
        .add(const Duration(minutes: 15))
        .toIso8601String(),
    'sync_epoch': syncEpoch,
    'checkpoint': {scope: '5'},
    'permission_versions': {scope: '1'},
    'first_page_token': 'synthetic-page-token',
    'manifest': manifest,
    'manifest_sha256': syncContentHash(manifest),
  };
}

void main() {
  test(
    'canonical checksum matches independent Python Unicode and exact integer vector',
    () {
      expect(
        syncContentHash({
          'z': [true, null, 2147483647],
          'memo': '流迹🧾\n\\"\u2028',
          'amount': '9007199254740993',
          'a': {'e': 'e\u0301'},
        }),
        '065dd6c811d4f54b0b5acc78fe333bc9362b93b2544e106fd6c04dc7cb646440',
      );
      for (final invalid in [
        1.2,
        -1,
        2147483648,
        '\ud800',
        {'非ASCII': 1},
      ]) {
        expect(() => canonicalSyncJson(invalid), throwsFormatException);
      }
    },
  );

  test('manifest identity, checksum, bounds and page contents fail closed', () {
    final pages = <List<Object?>>[
      [item('confirmed')],
    ];
    final status = statusFor(pages);
    final manifest = SnapshotManifest.fromStatus(status);
    expect(() => manifest.checkIdentity(instance, nextEpoch), throwsStateError);
    expect(
      () => manifest.checkIdentity(
        instance,
        epoch,
        now: DateTime.now().toUtc().add(const Duration(days: 1)),
      ),
      throwsStateError,
    );
    expect(
      () =>
          manifest.checkPage(0, [item('tampered')], syncContentHash(pages[0])),
      throwsFormatException,
    );
    status['manifest_sha256'] = '0' * 64;
    expect(() => SnapshotManifest.fromStatus(status), throwsFormatException);
  });

  group('durable snapshot replacement', () {
    late AppDatabase db;
    late LocalRepository repo;
    late SyncStore store;
    final space = testSpace(instance: instance, user: scope);
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = LocalRepository(db);
      store = SyncStore(repo);
      await repo.registerSpace(space);
      await store.configure(space, client, epoch);
    });
    tearDown(() => db.close());

    test(
      'first snapshot preserves a new offline book and sends its children only after book ACK',
      () async {
        final child = QueuedCommand(
          operationId: operationId(1),
          scopeId: nextClient,
          entityType: 'tag',
          entityId: entity,
          action: 'create',
          baseRevision: '0',
          payload: {'name': 'offline child'},
        );
        final book = QueuedCommand(
          operationId: operationId(2),
          scopeId: scope,
          entityType: 'book',
          entityId: nextClient,
          action: 'create',
          baseRevision: '0',
          payload: {'name': 'offline book'},
        );
        await repo.saveEntityAndQueue(space, child);
        await repo.saveEntityAndQueue(space, book);
        final pages = <List<Object?>>[[]];
        final manifest = SnapshotManifest.fromStatus(statusFor(pages));
        await store.stageSnapshotPage(
          space,
          manifest,
          0,
          pages[0],
          syncContentHash(pages[0]),
        );
        await store.installSnapshot(
          space,
          manifest,
          clientId: client,
          permissionVersions: {scope: '1'},
        );
        expect(await db.select(db.localEntities).get(), hasLength(2));
        expect(
          jsonDecode(
            (await store.state(space))!.cursorsJson,
          ).containsKey(nextClient),
          isFalse,
        );
        expect((await store.nextPush(space))!.operationId, book.operationId);
        await store.acknowledge(space, book.operationId, '1');
        expect((await store.nextPush(space))!.operationId, child.operationId);
      },
    );

    test(
      'recovery review includes derived account balance and private finance shadows',
      () async {
        Map<String, Object?> account(String amount) => {
          'projection_kind': 'account',
          'payload': {'name': 'My account'},
          'balance': {
            'currency': 'CNY',
            'currency_scale': 2,
            'amount_minor': amount,
          },
        };
        await store.applyPullPage(space, epoch, [
          [
            SyncEvent(
              scopeId: scope,
              entityType: 'account',
              entityId: entity,
              revision: '1',
              deleted: false,
              data: account('500'),
            ),
            SyncEvent(
              scopeId: scope,
              entityType: 'bill',
              entityId: nextClient,
              revision: '1',
              deleted: false,
              data: {
                'projection_kind': 'bill_private_finance',
                'book_id': snapshotId,
                'bill_type': 'expense',
                'entries': [
                  {
                    'account_id': entity,
                    'component': 'principal',
                    'money': {
                      'currency': 'CNY',
                      'currency_scale': 2,
                      'amount_minor': '-200',
                    },
                  },
                ],
              },
            ),
          ],
        ], finalPage: false);
        await store.requireRebuild(space, 'resync_required');
        final changed = item('unused')
          ..['entity_type'] = 'account'
          ..['data'] = account('700');
        final pages = <List<Object?>>[
          [changed],
        ];
        final manifest = SnapshotManifest.fromStatus(statusFor(pages));
        await store.stageSnapshotPage(
          space,
          manifest,
          0,
          pages[0],
          syncContentHash(pages[0]),
        );
        await store.installSnapshot(
          space,
          manifest,
          clientId: nextClient,
          permissionVersions: {scope: '1'},
          allowRecovery: true,
        );
        final differences = await store.recoveryDifferences(
          space,
          (await store.recoveryBackups(space)).single,
        );
        expect(differences, hasLength(2));
        final balance = differences.singleWhere(
          (r) => r['entity_type'] == 'account',
        );
        expect(
          ((balance['local'] as Map)['balance'] as Map)['amount_minor'],
          '500',
        );
        expect(
          ((balance['server'] as Map)['balance'] as Map)['amount_minor'],
          '700',
        );
        final finance = differences.singleWhere(
          (r) => r['entity_type'] == 'bill',
        );
        expect(finance['difference'], 'missing');
        expect(
          (finance['local'] as Map)['projection_kind'],
          'bill_private_finance',
        );
      },
    );

    test(
      'incomplete snapshot changes no live rows; complete install overlays pending input',
      () async {
        await repo.saveEntityAndQueue(
          space,
          edit(1, 'local edit', action: 'create'),
        );
        final frozen = (await store.nextPush(space))!.body;
        final pages = <List<Object?>>[
          [item('server')],
          [item('other', id: nextClient)],
        ];
        final manifest = SnapshotManifest.fromStatus(statusFor(pages));
        await store.stageSnapshotPage(
          space,
          manifest,
          0,
          pages[0],
          syncContentHash(pages[0]),
        );
        await expectLater(
          store.installSnapshot(
            space,
            manifest,
            clientId: client,
            permissionVersions: {scope: '1'},
          ),
          throwsStateError,
        );
        expect(
          jsonDecode(
            (await db.select(db.localEntities).getSingle()).dataJson,
          )['name'],
          'local edit',
        );
        expect((await store.state(space))!.cursorsJson, '{}');
        await store.stageSnapshotPage(
          space,
          manifest,
          1,
          pages[1],
          syncContentHash(pages[1]),
        );
        await expectLater(
          store.installSnapshot(
            space,
            manifest,
            clientId: client,
            permissionVersions: {scope: '2'},
          ),
          throwsStateError,
        );
        await store.installSnapshot(
          space,
          manifest,
          clientId: client,
          permissionVersions: {scope: '1'},
        );
        final entities = await db.select(db.localEntities).get();
        expect(entities, hasLength(2));
        expect(
          jsonDecode(
            entities.singleWhere((e) => e.entityId == entity).dataJson,
          )['name'],
          'local edit',
        );
        expect((await store.nextPush(space))!.body, frozen);
        expect(jsonDecode((await store.state(space))!.cursorsJson), {
          scope: '5',
        });
        expect(await db.select(db.snapshotPages).get(), isEmpty);
      },
    );

    test(
      'write failure rolls back snapshot, checkpoint and preserves all staging',
      () async {
        await repo.saveDraft(space, 'Keep this draft');
        await repo.saveEntityAndQueue(space, edit(1, 'keep', action: 'create'));
        final pages = <List<Object?>>[
          [item('one'), item('two', id: nextClient)],
        ];
        final manifest = SnapshotManifest.fromStatus(statusFor(pages));
        await store.stageSnapshotPage(
          space,
          manifest,
          0,
          pages[0],
          syncContentHash(pages[0]),
        );
        await db.customStatement(
          "CREATE TRIGGER fail_second BEFORE INSERT ON local_entities WHEN NEW.entity_id = '$nextClient' BEGIN SELECT RAISE(ABORT, 'injected'); END",
        );
        await expectLater(
          store.installSnapshot(
            space,
            manifest,
            clientId: client,
            permissionVersions: {scope: '1'},
          ),
          throwsA(anything),
        );
        expect(
          jsonDecode(
            (await db.select(db.localEntities).getSingle()).dataJson,
          )['name'],
          'keep',
        );
        expect((await store.state(space))!.cursorsJson, '{}');
        expect(await db.select(db.snapshotPages).get(), hasLength(1));
        expect(await repo.drafts(space), hasLength(1));
      },
    );

    test(
      'epoch recovery preserves full backup and never automatically replays old operations',
      () async {
        await repo.saveEntityAndQueue(
          space,
          edit(1, 'acknowledged', action: 'create'),
        );
        await store.nextPush(space);
        await store.acknowledge(space, operationId(1), '1');
        await repo.saveEntityAndQueue(
          space,
          edit(2, 'offline later', base: '1'),
        );
        await repo.saveDraft(space, 'Recovery draft');
        await expectLater(
          store.configure(space, client, nextEpoch),
          throwsStateError,
        );
        await expectLater(
          store.configure(space, client, nextEpoch),
          throwsStateError,
        );
        expect(await db.select(db.syncRecoveryBackups).get(), hasLength(1));
        final pages = <List<Object?>>[
          [item('restored server')],
        ];
        final manifest = SnapshotManifest.fromStatus(
          statusFor(pages, syncEpoch: nextEpoch),
        );
        await store.stageSnapshotPage(
          space,
          manifest,
          0,
          pages[0],
          syncContentHash(pages[0]),
        );
        await expectLater(
          store.installSnapshot(
            space,
            manifest,
            clientId: nextClient,
            permissionVersions: {scope: '1'},
          ),
          throwsStateError,
        );
        await expectLater(
          store.installSnapshot(
            space,
            manifest,
            clientId: client,
            permissionVersions: {scope: '1'},
            allowRecovery: true,
          ),
          throwsStateError,
        );
        await store.installSnapshot(
          space,
          manifest,
          clientId: nextClient,
          permissionVersions: {scope: '1'},
          allowRecovery: true,
        );
        expect(await store.nextPush(space), isNull);
        expect((await store.state(space))!.epoch, nextEpoch);
        expect((await store.state(space))!.clientId, nextClient);
        final backup =
            jsonDecode(
                  (await db.select(db.syncRecoveryBackups).getSingle())
                      .dataJson,
                )
                as Map;
        expect(
          (backup['operations'] as List).map((e) => e['state']),
          containsAll(['applied', 'queued']),
        );
        expect((backup['drafts'] as List).single['body'], 'Recovery draft');
        expect(await repo.drafts(space), hasLength(1));
        final differences = await store.recoveryDifferences(
          space,
          (await store.recoveryBackups(space)).single,
        );
        expect(differences.single['difference'], 'changed');
        expect((differences.single['local'] as Map)['name'], 'offline later');
        expect(
          ((differences.single['server'] as Map)['payload'] as Map)['name'],
          'restored server',
        );
      },
    );
  });
}
