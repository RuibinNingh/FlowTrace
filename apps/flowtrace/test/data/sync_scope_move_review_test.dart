import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import 'local_repository_test.dart' show testSpace;

const _source = '26000000-0000-4000-8000-000000000001';
const _target = '26000000-0000-4000-8000-000000000002';
const _third = '26000000-0000-4000-8000-000000000003';
const _user = '26000000-0000-4000-8000-000000000004';
const _bill = '36000000-0000-4000-8000-000000000001';
const _client = '46000000-0000-4000-8000-000000000001';
const _epoch = '56000000-0000-4000-8000-000000000001';
const _operation = '66000000-0000-4000-8000-000000000001';
const _instance = '76000000-0000-4000-8000-000000000001';

Map<String, Object?> _payload(String book, String note) => {
  'book_id': book,
  'note': note,
  'attachment_ids': <String>[],
};

SyncEvent _event(
  String book,
  String revision, {
  bool deleted = false,
  String note = '服务器已确认版本',
}) => SyncEvent(
  scopeId: book,
  entityType: 'bill',
  entityId: _bill,
  revision: revision,
  deleted: deleted,
  data: deleted
      ? <String, Object?>{}
      : {'projection_kind': 'bill_public', 'payload': _payload(book, note)},
);

QueuedCommand _edit({bool move = false}) => QueuedCommand(
  operationId: _operation,
  scopeId: _source,
  entityType: 'bill',
  entityId: _bill,
  action: 'update',
  baseRevision: '1',
  payload: _payload(move ? _target : _source, '保留的本机未发送输入'),
  move: move
      ? {'target_scope_id': _target, 'attachment_replacements': <Object?>[]}
      : null,
);

Map<String, Object?> _wire(SyncEvent event) => {
  'scope_id': event.scopeId,
  'scope_revision': '5',
  'event_index': 0,
  'entity_type': event.entityType,
  'entity_id': event.entityId,
  'revision': event.revision,
  'deleted': event.deleted,
  'data': event.deleted ? null : event.data,
};

SnapshotManifest _manifest(List<Object?> items) {
  const snapshot = '86000000-0000-4000-8000-000000000001';
  final vector = {_source: '5', _target: '5', _user: '5'};
  final permissions = {_source: '1', _target: '1', _user: '1'};
  final body = <String, Object?>{
    'snapshot_id': snapshot,
    'instance_id': _instance,
    'sync_epoch': _epoch,
    'checkpoint': vector,
    'permission_versions': permissions,
    'pages': [
      {
        'page_index': 0,
        'item_count': items.length,
        'sha256': syncContentHash(items),
      },
    ],
  };
  return SnapshotManifest.fromStatus({
    'snapshot_id': snapshot,
    'status': 'ready',
    'expires_at': DateTime.now()
        .toUtc()
        .add(const Duration(minutes: 15))
        .toIso8601String(),
    'sync_epoch': _epoch,
    'checkpoint': vector,
    'permission_versions': permissions,
    'first_page_token': 'synthetic-review-page',
    'manifest': body,
    'manifest_sha256': syncContentHash(body),
  });
}

void main() {
  late AppDatabase database;
  late LocalRepository repository;
  late SyncStore store;
  final space = testSpace(user: _user, instance: _instance);

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = LocalRepository(database);
    store = SyncStore(repository);
    await repository.registerSpace(space);
    await store.configure(space, _client, _epoch);
    await store.applyPullPage(space, _epoch, [
      [_event(_source, '1', note: '原来源正文')],
    ], finalPage: false);
  });
  tearDown(() => database.close());

  Future<void> pull(List<SyncEvent> commit) =>
      store.applyPullPage(space, _epoch, [commit], finalPage: false);

  Future<void> expectPublic(String scope, String revision, String note) async {
    final row = await database.select(database.localEntities).getSingle();
    expect(row.scopeId, scope);
    expect(row.serverRevision, revision);
    expect(row.deleted, isFalse);
    final data = jsonDecode(row.dataJson) as Map;
    expect(data['projection_kind'], 'bill_public');
    expect((data['payload'] as Map)['book_id'], scope);
    expect((data['payload'] as Map)['note'], note);
  }

  test(
    'source revocation removes optimistic target and preserves only quarantined intent',
    () async {
      final command = _edit(move: true);
      await repository.saveEntityAndQueue(space, command);
      final frozen = (await store.nextPush(space))!.body;
      await store.revokeScope(space, _source);
      expect(await database.select(database.localEntities).get(), isEmpty);
      expect(await store.nextPush(space), isNull);
      final conflict = (await store.conflicts(space)).single;
      expect(conflict.code, 'scope_revoked');
      expect(jsonDecode(conflict.localJson)['note'], '保留的本机未发送输入');
      expect(conflict.baseJson, isNull);
      expect(conflict.serverJson, isNull);
      await store.acknowledge(space, _operation, '2');
      expect(await database.select(database.localEntities).get(), isEmpty);
      final journal = await database
          .select(database.pendingOperations)
          .getSingle();
      expect(journal.state, 'discarded');
      expect(journal.frozenRequestJson, frozen);
    },
  );

  test(
    'entity moved conflict accepts an authenticated current target projection',
    () async {
      await repository.saveEntityAndQueue(space, _edit());
      await store.nextPush(space);
      final target = _event(_target, '2', note: '当前目标版本');
      await pull([target]);
      expect((await store.conflicts(space)).single.code, 'entity_moved');
      await store.acceptServerVersion(space, _operation, target);
      await expectPublic(_target, '2', '当前目标版本');
      expect(await store.conflicts(space), isEmpty);
      expect(await store.nextPush(space), isNull);
    },
  );

  test(
    'direct conflict resolution rejects a move appended during confirmation without changing the chain',
    () async {
      await repository.saveEntityAndQueue(space, _edit());
      final frozen = (await store.nextPush(space))!.body;
      await store.reject(space, _operation, 'revision_conflict');

      // A page captured an ordinary source edit before confirmation. Further
      // local edits must be checked again inside the resolution transaction.
      final replacement = QueuedCommand(
        operationId: '66000000-0000-4000-8000-000000000004',
        scopeId: _source,
        entityType: 'bill',
        entityId: _bill,
        action: 'update',
        baseRevision: '2',
        payload: _payload(_source, '确认前选择的普通重基'),
      );
      await repository.saveEntityAndQueue(
        space,
        QueuedCommand(
          operationId: '66000000-0000-4000-8000-000000000002',
          scopeId: _source,
          entityType: 'bill',
          entityId: _bill,
          action: 'update',
          baseRevision: '1',
          dependsOn: _operation,
          payload: _payload(_target, '确认期间新增移动'),
          move: {
            'target_scope_id': _target,
            'attachment_replacements': <Object?>[],
          },
        ),
      );
      await repository.saveEntityAndQueue(
        space,
        QueuedCommand(
          operationId: '66000000-0000-4000-8000-000000000003',
          scopeId: _target,
          entityType: 'bill',
          entityId: _bill,
          action: 'update',
          baseRevision: '1',
          dependsOn: '66000000-0000-4000-8000-000000000002',
          payload: _payload(_target, '确认期间新增的目标账本输入'),
        ),
      );

      final before = await repository.pending(space);
      expect(before.map((row) => row.state), ['rejected', 'queued', 'queued']);
      expect(before.first.frozenRequestJson, frozen);
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
        _target,
      );
      final localBefore = await database
          .select(database.localEntities)
          .getSingle();
      final conflictsBefore = await store.conflicts(space);
      expect(localBefore.scopeId, _target);
      expect(jsonDecode(localBefore.dataJson)['note'], '确认期间新增的目标账本输入');
      expect(conflictsBefore.single.localJson, localBefore.dataJson);

      await expectLater(
        store.resolveWithNewCommand(space, _operation, replacement),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('账本移动需要重新预览'),
          ),
        ),
      );

      // Check every journal field, including frozen bytes, dependencies and
      // states; a rejected resolution cannot discard or replace any intent.
      final after = await repository.pending(space);
      expect(
        after.map((row) => row.toJson()),
        before.map((row) => row.toJson()),
      );
      expect(
        (await database.select(database.pendingOperations).get()).length,
        3,
      );
      expect(
        (await database.select(database.localEntities).getSingle()).toJson(),
        localBefore.toJson(),
      );
      expect(
        (await store.conflicts(space)).map((row) => row.toJson()),
        conflictsBefore.map((row) => row.toJson()),
      );
    },
  );

  test(
    'accepting old source tombstone cannot overwrite a newer known live target',
    () async {
      await repository.saveEntityAndQueue(space, _edit());
      await store.nextPush(space);
      final oldSource = _event(_source, '2', deleted: true);
      await pull([oldSource, _event(_target, '3', note: '目标随后修改的版本')]);
      await store.acceptServerVersion(space, _operation, oldSource);
      await expectPublic(_target, '3', '目标随后修改的版本');
      expect(await store.conflicts(space), isEmpty);
    },
  );

  for (final ownMove in [true, false]) {
    test(
      'late ACK rev2 keeps newer moved public rev3 with ownMove=$ownMove',
      () async {
        await repository.saveEntityAndQueue(space, _edit(move: ownMove));
        await store.nextPush(space);
        if (ownMove) {
          // Our move committed as rev2; its response was lost. A second device
          // then moved the same UUID from target to third as rev3.
          await pull([
            _event(_source, '2', deleted: true),
            _event(_target, '2', note: '本机移动已在服务端完成'),
          ]);
          await pull([
            _event(_target, '3', deleted: true),
            _event(_third, '3', note: '第三账本的最新版本'),
          ]);
        } else {
          // An ordinary edit committed as rev2 before a peer's subsequent move.
          await pull([_event(_source, '2', note: '本机编辑的正式回执版本')]);
          await pull([
            _event(_source, '3', deleted: true),
            _event(_target, '3', note: '其他设备移动后的最新版本'),
          ]);
        }
        // Pending input intentionally prevented replacing the optimistic local
        // row, but the current live destination is already in server shadows.
        final shadows = await database.select(database.serverShadows).get();
        expect(
          shadows.any(
            (row) =>
                row.scopeId == (ownMove ? _third : _target) &&
                row.revision == '3' &&
                !row.deleted,
          ),
          isTrue,
        );
        expect((await store.conflicts(space)).single.code, 'entity_moved');
        await store.acknowledge(space, _operation, '2');
        await expectPublic(
          ownMove ? _third : _target,
          '3',
          ownMove ? '第三账本的最新版本' : '其他设备移动后的最新版本',
        );
        expect(await repository.pending(space), isEmpty);
        final journal = await database
            .select(database.pendingOperations)
            .getSingle();
        expect(journal.state, 'applied');
        expect(journal.appliedRevision, '2');
      },
    );
  }

  for (final targetFirst in [true, false]) {
    test(
      'pending source conflict converges with targetFirst=$targetFirst',
      () async {
        await repository.saveEntityAndQueue(space, _edit());
        final target = _event(_target, '2', note: '授权目标当前正文');
        final tombstone = _event(_source, '2', deleted: true);
        for (final event
            in targetFirst ? [target, tombstone] : [tombstone, target]) {
          await pull([event]);
        }
        final conflict = (await store.conflicts(space)).single;
        expect(conflict.code, 'entity_moved');
        expect(jsonDecode(conflict.localJson)['note'], '保留的本机未发送输入');
        final server = jsonDecode(conflict.serverJson!) as Map;
        expect((server['payload'] as Map)['book_id'], _target);
        expect((server['payload'] as Map)['note'], '授权目标当前正文');
        expect(await store.nextPush(space), isNull);
      },
    );
  }

  test(
    'complete target snapshot immediately quarantines ordinary source pending',
    () async {
      await repository.saveEntityAndQueue(space, _edit());
      final items = <Object?>[_wire(_event(_target, '2', note: '快照中的实际目标'))];
      final manifest = _manifest(items);
      await store.stageSnapshotPage(
        space,
        manifest,
        0,
        items,
        syncContentHash(items),
      );
      await store.installSnapshot(
        space,
        manifest,
        clientId: _client,
        permissionVersions: manifest.permissionVersions,
      );
      final conflict = (await store.conflicts(space)).single;
      expect(conflict.code, 'entity_moved');
      expect(jsonDecode(conflict.localJson)['note'], '保留的本机未发送输入');
      expect(await store.nextPush(space), isNull);
      final shadow =
          (await database.select(database.serverShadows).get()).single;
      expect(shadow.scopeId, _target);
      expect(shadow.revision, '2');
    },
  );

  for (final canonicalRevision in ['1', '2']) {
    test(
      'own frozen move survives source snapshot revision $canonicalRevision without rebasing',
      () async {
        await repository.saveEntityAndQueue(space, _edit(move: true));
        final frozen = (await store.nextPush(space))!;
        final items = <Object?>[
          _wire(_event(_source, canonicalRevision, note: '仍位于来源的正式记录')),
        ];
        final manifest = _manifest(items);
        await store.stageSnapshotPage(
          space,
          manifest,
          0,
          items,
          syncContentHash(items),
        );
        await store.installSnapshot(
          space,
          manifest,
          clientId: _client,
          permissionVersions: manifest.permissionVersions,
        );
        expect(await store.conflicts(space), isEmpty);
        final journal = await database
            .select(database.pendingOperations)
            .getSingle();
        expect(journal.state, 'sending');
        expect(journal.frozenRequestJson, frozen.body);
        final retry = (await store.nextPush(space))!;
        expect(retry.operationId, frozen.operationId);
        expect(retry.body, frozen.body);
        final command = (jsonDecode(retry.body)['operations'] as List).single;
        expect(command['scope_id'], _source);
        expect(command['move']['target_scope_id'], _target);
        expect(command['base_revision'], '1');
      },
    );
  }
}
