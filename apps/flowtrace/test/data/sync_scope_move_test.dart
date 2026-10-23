import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import 'local_repository_test.dart' show testSpace;

const _source = '22000000-0000-4000-8000-000000000001';
const _target = '22000000-0000-4000-8000-000000000002';
const _bill = '33000000-0000-4000-8000-000000000001';
const _client = '44000000-0000-4000-8000-000000000001';
const _epoch = '55000000-0000-4000-8000-000000000001';

SyncEvent _event(String scope, String revision, {bool deleted = false}) =>
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
              'payload': {
                'book_id': scope,
                'note': scope == _source ? '来源可见记录' : '目标可见记录',
              },
            },
    );

void main() {
  late AppDatabase db;
  late SyncStore store;
  late LocalRepository repository;
  final space = testSpace();
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repository = LocalRepository(db);
    await repository.registerSpace(space);
    store = SyncStore(repository);
    await store.configure(space, _client, _epoch);
    await store.applyPullPage(space, _epoch, [
      [_event(_source, '1')],
    ], finalPage: false);
  });
  tearDown(() => db.close());
  for (final targetFirst in [true, false]) {
    test(
      'same UUID move retains target with targetFirst=$targetFirst',
      () async {
        final target = _event(_target, '2'),
            tombstone = _event(_source, '2', deleted: true);
        for (final event
            in targetFirst ? [target, tombstone] : [tombstone, target]) {
          await store.applyPullPage(space, _epoch, [
            [event],
          ], finalPage: false);
        }
        final row = await db.select(db.localEntities).getSingle();
        expect(row.scopeId, _target);
        expect(row.deleted, isFalse);
        expect(row.serverRevision, '2');
        expect(await db.select(db.serverShadows).get(), hasLength(2));
      },
    );
  }
  test('older source event cannot replace newer target entity', () async {
    await store.applyPullPage(space, _epoch, [
      [_event(_target, '2')],
    ], finalPage: false);
    await store.applyPullPage(space, _epoch, [
      [_event(_source, '1')],
    ], finalPage: false);
    final row = await db.select(db.localEntities).getSingle();
    expect(row.scopeId, _target);
    expect(row.serverRevision, '2');
    expect(row.deleted, isFalse);
  });
  test('source-only member removes moved public record', () async {
    await store.applyPullPage(space, _epoch, [
      [_event(_source, '2', deleted: true)],
    ], finalPage: false);
    final row = await db.select(db.localEntities).getSingle();
    expect(row.scopeId, _source);
    expect(row.deleted, isTrue);
  });
  QueuedCommand move() => QueuedCommand(
    operationId: '66000000-0000-4000-8000-000000000001',
    scopeId: _source,
    entityType: 'bill',
    entityId: _bill,
    action: 'update',
    baseRevision: '1',
    payload: {'book_id': _target, 'attachment_ids': <String>[]},
    move: {'target_scope_id': _target, 'attachment_replacements': <Object?>[]},
  );
  for (final pullFirst in [true, false]) {
    test('move ACK installs target scope with pullFirst=$pullFirst', () async {
      final command = move();
      await repository.saveEntityAndQueue(space, command);
      final frozen = (await store.nextPush(space))!;
      expect(
        (jsonDecode(frozen.body)['operations'] as List)
            .single['move']['target_scope_id'],
        _target,
      );
      expect((await store.nextPush(space))!.body, frozen.body);
      Future<void> pull() => store.applyPullPage(space, _epoch, [
        [_event(_source, '2', deleted: true), _event(_target, '2')],
      ], finalPage: false);
      if (pullFirst) await pull();
      await store.acknowledge(space, command.operationId, '2');
      if (!pullFirst) await pull();
      final row = await db.select(db.localEntities).getSingle();
      expect(row.scopeId, _target);
      expect(row.deleted, isFalse);
      expect(jsonDecode(row.dataJson)['projection_kind'], 'bill_public');
      expect(await repository.pending(space), isEmpty);
    });
  }
  test(
    'target revocation quarantines move and a late ACK cannot restore it',
    () async {
      final command = move();
      await repository.saveEntityAndQueue(space, command);
      await store.nextPush(space);
      await store.revokeScope(space, _target);
      await store.acknowledge(space, command.operationId, '2');
      final restored = await db.select(db.localEntities).getSingle();
      expect(restored.scopeId, _source);
      expect(restored.serverRevision, '1');
      expect(jsonDecode(restored.dataJson)['payload']['note'], '来源可见记录');
      expect(await store.nextPush(space), isNull);
      final conflict = (await store.conflicts(space)).single;
      expect(conflict.code, 'scope_revoked');
      expect(jsonDecode(conflict.localJson)['book_id'], _target);
    },
  );
  test(
    'ordinary pending source edit becomes an explicit conflict after move',
    () async {
      final command = QueuedCommand(
        operationId: '66000000-0000-4000-8000-000000000002',
        scopeId: _source,
        entityType: 'bill',
        entityId: _bill,
        action: 'update',
        baseRevision: '1',
        payload: {'book_id': _source, 'note': '保留本机尚未发送的输入'},
      );
      expect(command.body.containsKey('move'), isFalse);
      await repository.saveEntityAndQueue(space, command);
      await store.applyPullPage(space, _epoch, [
        [_event(_target, '2')],
      ], finalPage: false);
      final conflict = (await store.conflicts(space)).single;
      expect(conflict.code, 'entity_moved');
      expect(jsonDecode(conflict.localJson)['note'], '保留本机尚未发送的输入');
      expect(await store.nextPush(space), isNull);
    },
  );
  test('move marker is immutable and rejects inconsistent target metadata', () {
    final marker = <String, Object?>{
      'target_scope_id': _target,
      'attachment_replacements': <Object?>[],
    };
    final command = QueuedCommand(
      operationId: '66000000-0000-4000-8000-000000000003',
      scopeId: _source,
      entityType: 'bill',
      entityId: _bill,
      action: 'update',
      baseRevision: '1',
      payload: {'book_id': _target},
      move: marker,
    );
    marker['target_scope_id'] = _source;
    command.move!['target_scope_id'] = _source;
    expect(command.move!['target_scope_id'], _target);
    expect(
      () => QueuedCommand(
        operationId: '66000000-0000-4000-8000-000000000004',
        scopeId: _source,
        entityType: 'bill',
        entityId: _bill,
        action: 'update',
        baseRevision: '1',
        payload: {'book_id': _source},
        move: command.move,
      ),
      throwsArgumentError,
    );
  });
}
