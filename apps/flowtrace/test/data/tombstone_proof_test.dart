import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/data/sync/tombstone_proof.dart';

import 'local_repository_test.dart' show testSpace;

const _scope = 'aa000000-0000-4000-8000-000000000001';
const _target = 'aa000000-0000-4000-8000-000000000002';
const _bill = 'bb000000-0000-4000-8000-000000000001';
const _client = 'cc000000-0000-4000-8000-000000000001';
const _epoch = 'dd000000-0000-4000-8000-000000000001';
const _operation = 'ee000000-0000-4000-8000-000000000001';
const _snapshot = 'ff000000-0000-4000-8000-000000000001';

void main() {
  final space = testSpace(
    user: 'fa000000-0000-4000-8000-000000000001',
    instance: 'fa000000-0000-4000-8000-000000000099',
  );
  late AppDatabase db;
  late LocalRepository local;
  late SyncStore sync;
  SyncEvent bill(String scope, String revision, {bool deleted = false}) =>
      SyncEvent(
        scopeId: scope,
        entityType: 'bill',
        entityId: _bill,
        revision: revision,
        deleted: deleted,
        data: deleted
            ? {}
            : {
                'projection_kind': 'bill_public',
                'payload': {'book_id': scope, 'note': '独立删除来源审查'},
              },
      );
  Future<Map<String, String>> settings() async => {
    for (final row in await db.select(db.appSettings).get()) row.key: row.value,
  };
  Future<ConfirmedEntity> shadow(String scope) =>
      (db.select(db.serverShadows)..where(
            (row) =>
                row.spaceId.equals(space.id) &
                row.scopeId.equals(scope) &
                row.entityType.equals('bill') &
                row.entityId.equals(_bill),
          ))
          .getSingle();
  Future<void> pull(
    SyncEvent event, {
    bool finalPage = false,
    Map<String, String>? checkpoint,
  }) => sync.applyPullPage(
    space,
    _epoch,
    [
      [event],
    ],
    finalPage: finalPage,
    checkpoint: checkpoint,
  );
  Future<void> queueDelete(String scope) async {
    await local.saveEntityAndQueue(
      space,
      QueuedCommand(
        operationId: _operation,
        scopeId: scope,
        entityType: 'bill',
        entityId: _bill,
        action: 'delete',
        baseRevision: scope == _target ? '2' : '1',
        payload: {},
      ),
    );
    expect(await sync.nextPush(space), isNotNull);
  }

  Future<void> installSnapshot(List<SyncEvent> events) async {
    final permissions = {_scope: '1', space.userId: '1'},
        checkpoint = {_scope: '2', space.userId: '0'};
    final page = <Object?>[
      for (var i = 0; i < events.length; i++)
        {
          'scope_id': events[i].scopeId,
          'scope_revision': '2',
          'event_index': i,
          'entity_type': events[i].entityType,
          'entity_id': events[i].entityId,
          'revision': events[i].revision,
          'deleted': events[i].deleted,
          'data': events[i].data,
        },
    ];
    final body = <String, Object?>{
      'snapshot_id': _snapshot,
      'instance_id': space.serverInstanceId,
      'sync_epoch': _epoch,
      'checkpoint': checkpoint,
      'permission_versions': permissions,
      'pages': [
        {
          'page_index': 0,
          'item_count': page.length,
          'sha256': syncContentHash(page),
        },
      ],
    };
    final manifest = SnapshotManifest.fromStatus({
      'snapshot_id': _snapshot,
      'status': 'ready',
      'expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 15))
          .toIso8601String(),
      'sync_epoch': _epoch,
      'checkpoint': checkpoint,
      'permission_versions': permissions,
      'first_page_token': 'independent-proof-review-page',
      'manifest': body,
      'manifest_sha256': syncContentHash(body),
    });
    await sync.stageSnapshotPage(
      space,
      manifest,
      0,
      page,
      syncContentHash(page),
    );
    await sync.installSnapshot(
      space,
      manifest,
      clientId: _client,
      permissionVersions: permissions,
    );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    local = LocalRepository(db);
    sync = SyncStore(local);
    await local.registerSpace(space);
    await sync.configure(space, _client, _epoch);
    await pull(bill(_scope, '1'), finalPage: true, checkpoint: {_scope: '1'});
  });
  tearDown(() => db.close());

  for (final pullFirst in [false, true]) {
    test(
      'actual pull proof survives equal revision ACK with pullFirst=$pullFirst and preserves raw hashes',
      () async {
        await queueDelete(_scope);
        if (pullFirst) await pull(bill(_scope, '2', deleted: true));
        final beforeAck = await settings();
        await sync.acknowledge(space, _operation, '2');
        final receipt = await shadow(_scope);
        expect(receipt.dataJson, '{}');
        expect(
          syncContentHash(jsonDecode(receipt.dataJson)),
          syncContentHash(<String, Object?>{}),
        );
        if (!pullFirst) {
          expect(
            isCanonicalBillTombstone(space, _epoch, receipt, await settings()),
            isFalse,
          );
          expect(
            await local.readSetting(tombstoneProofKey(space, _scope, _bill)),
            isNull,
          );
          await pull(bill(_scope, '2', deleted: true));
        } else {
          expect(await settings(), beforeAck);
        }
        final canonical = await shadow(_scope);
        expect(canonical.dataJson, receipt.dataJson);
        expect(
          isCanonicalBillTombstone(space, _epoch, canonical, await settings()),
          isTrue,
        );
        // A replay cannot replace the provenance with a raw receipt.
        final saved = await settings();
        await sync.acknowledge(space, _operation, '2');
        expect(await settings(), saved);
      },
    );
  }

  test(
    'proof rejects stale epoch, revision, hash, live rows and foreign space sources',
    () async {
      await pull(bill(_scope, '2', deleted: true));
      final row = await shadow(_scope), values = await settings();
      expect(isCanonicalBillTombstone(space, _epoch, row, values), isTrue);
      expect(isCanonicalBillTombstone(space, _client, row, values), isFalse);
      expect(isCanonicalBillTombstone(space, null, row, values), isFalse);
      for (final changed in [
        row.copyWith(revision: '3'),
        row.copyWith(dataJson: '{"unexpected":true}'),
        row.copyWith(deleted: false),
        row.copyWith(entityType: 'account'),
        row.copyWith(spaceId: 'foreign-space'),
      ]) {
        expect(
          isCanonicalBillTombstone(space, _epoch, changed, values),
          isFalse,
        );
      }
      final key = tombstoneProofKey(space, _scope, _bill);
      final proof = (jsonDecode(values[key]!) as Map).cast<String, Object?>();
      for (final encoded in [
        'invalid-json',
        jsonEncode({...proof, 'version': 2}),
        jsonEncode({...proof, 'extra': true}),
        jsonEncode({...proof, 'scope_id': _target}),
        jsonEncode({...proof, 'projection_hash': '0' * 64}),
      ]) {
        expect(
          isCanonicalBillTombstone(space, _epoch, row, {
            ...values,
            key: encoded,
          }),
          isFalse,
        );
      }
    },
  );

  test(
    'a valid old source tomb cannot authorize a target raw deletion or a private finance tomb',
    () async {
      await sync.applyPullPage(space, _epoch, [
        [bill(_scope, '2', deleted: true), bill(_target, '2')],
      ], finalPage: false);
      final origin = await shadow(_scope);
      expect(
        isCanonicalBillTombstone(space, _epoch, origin, await settings()),
        isTrue,
      );
      await queueDelete(_target);
      await sync.acknowledge(space, _operation, '3');
      final target = await shadow(_target);
      expect(target.deleted, isTrue);
      expect(target.dataJson, '{}');
      expect(
        isCanonicalBillTombstone(space, _epoch, target, await settings()),
        isFalse,
      );
      expect(
        await local.readSetting(tombstoneProofKey(space, _target, _bill)),
        isNull,
      );
      await pull(bill(_scope, '2', deleted: true));
      expect(
        isCanonicalBillTombstone(
          space,
          _epoch,
          await shadow(_target),
          await settings(),
        ),
        isFalse,
      );
      final visible = await db.select(db.localEntities).getSingle();
      expect(visible.scopeId, _target);
      expect(visible.serverRevision, '3');
      await pull(bill(space.userId, '3', deleted: true));
      expect(
        await local.readSetting(tombstoneProofKey(space, space.userId, _bill)),
        isNull,
      );
    },
  );

  test(
    'a failed checkpoint rolls back the new shadow and its provenance in the same transaction',
    () async {
      await expectLater(
        pull(
          bill(_scope, '2', deleted: true),
          finalPage: true,
          checkpoint: {_scope: '0'},
        ),
        throwsStateError,
      );
      expect(
        await local.readSetting(tombstoneProofKey(space, _scope, _bill)),
        isNull,
      );
      final row = await shadow(_scope);
      expect(row.revision, '1');
      expect(row.deleted, isFalse);
      expect((await db.select(db.localEntities).getSingle()).deleted, isFalse);
    },
  );

  test(
    'backup preserves only this space proof and revocation removes only the affected scope proof',
    () async {
      await pull(bill(_scope, '2', deleted: true));
      final originalKey = tombstoneProofKey(space, _scope, _bill),
          original = await local.readSetting(
            tombstoneProofKey(space, _scope, _bill),
          );
      await pull(bill(_target, '3', deleted: true));
      final otherSpace = testSpace(user: _client),
          foreignKey = tombstoneProofKey(
            testSpace(user: _client),
            _scope,
            _bill,
          );
      await local.writeSetting(foreignKey, 'other-user-proof');
      await sync.requireRebuild(space, 'independent-proof-review');
      final backup = (await db.select(db.syncRecoveryBackups).get()).single;
      final saved =
          (jsonDecode(backup.dataJson) as Map)['tombstone_proofs'] as List;
      expect(saved.map((row) => row['key']), contains(originalKey));
      expect(saved.any((row) => row['key'] == foreignKey), isFalse);
      expect(
        saved.singleWhere((row) => row['key'] == originalKey)['value'],
        original,
      );
      await sync.revokeScope(space, _scope);
      expect(await local.readSetting(originalKey), isNull);
      expect(
        await local.readSetting(tombstoneProofKey(space, _target, _bill)),
        isNotNull,
      );
      expect(
        await local.readSetting(tombstoneProofKey(otherSpace, _scope, _bill)),
        'other-user-proof',
      );
    },
  );

  test(
    'a complete ordinary snapshot clears tomb proofs absent from its authoritative cut',
    () async {
      await pull(bill(_scope, '2', deleted: true));
      expect(
        await local.readSetting(tombstoneProofKey(space, _scope, _bill)),
        isNotNull,
      );
      await installSnapshot([]);
      expect(
        await local.readSetting(tombstoneProofKey(space, _scope, _bill)),
        isNull,
      );
      expect(await db.select(db.serverShadows).get(), isEmpty);
    },
  );

  test(
    'validated snapshot tomb event creates canonical provenance without altering its raw projection',
    () async {
      // Exercise the client's canonical snapshot-event branch, rather than
      // writing a proof row or shadow directly from a fixture.
      await installSnapshot([bill(_scope, '2', deleted: true)]);
      final row = await shadow(_scope);
      expect(row.deleted, isTrue);
      expect(row.dataJson, '{}');
      expect(
        isCanonicalBillTombstone(space, _epoch, row, await settings()),
        isTrue,
      );
      expect((await db.select(db.localEntities).getSingle()).deleted, isTrue);
    },
  );

  test(
    'a lower revision live event cannot erase a later canonical tombstone or proof',
    () async {
      await pull(bill(_scope, '3', deleted: true));
      final key = tombstoneProofKey(space, _scope, _bill),
          original = await local.readSetting(
            tombstoneProofKey(space, _scope, _bill),
          );
      await pull(bill(_scope, '2'));
      final row = await shadow(_scope);
      expect(row.revision, '3');
      expect(row.deleted, isTrue);
      expect(await local.readSetting(key), original);
      expect(
        isCanonicalBillTombstone(space, _epoch, row, await settings()),
        isTrue,
      );
      expect((await db.select(db.localEntities).getSingle()).deleted, isTrue);
    },
  );
}
