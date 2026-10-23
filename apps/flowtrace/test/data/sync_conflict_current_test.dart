import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import 'local_repository_test.dart' show testSpace;

const _source = '27000000-0000-4000-8000-000000000001';
const _target = '27000000-0000-4000-8000-000000000002';
const _third = '27000000-0000-4000-8000-000000000003';
const _user = '27000000-0000-4000-8000-000000000004';
const _bill = '37000000-0000-4000-8000-000000000001';
const _client = '47000000-0000-4000-8000-000000000001';
const _epoch = '57000000-0000-4000-8000-000000000001';
const _operation = '67000000-0000-4000-8000-000000000001';
const _instance = '77000000-0000-4000-8000-000000000001';
const _commit = '87000000-0000-4000-8000-000000000001';

Map<String, Object?> _payload(String scope, String note) => {
  'book_id': scope,
  'note': note,
  'attachment_ids': <String>[],
};

SyncEvent _event(String scope, String revision, {bool deleted = false}) =>
    SyncEvent(
      scopeId: scope,
      entityType: 'bill',
      entityId: _bill,
      revision: revision,
      deleted: deleted,
      data: deleted
          ? <String, Object?>{}
          : {
              'projection_kind': 'bill_public',
              'payload': _payload(scope, '当前授权正文'),
            },
    );

Map<String, Object?> _wire(SyncEvent event) => {
  'scope_id': event.scopeId,
  'scope_revision': '7',
  'event_index': 0,
  'entity_type': event.entityType,
  'entity_id': event.entityId,
  'revision': event.revision,
  'deleted': event.deleted,
  'data': event.deleted ? null : event.data,
};

Map<String, Object?> _response(SyncEvent event, {bool viewer = false}) => {
  'event': _wire(event),
  'editable_payload': event.deleted || viewer
      ? null
      : _payload(event.scopeId, '当前授权正文'),
};

Map<String, Object?> _scopes({
  Set<String> books = const {_source, _target, _third},
}) => {
  'sync_epoch': _epoch,
  'control_version': '1',
  'requires_rebuild': false,
  'revoked_scope_ids': <Object?>[],
  'scopes': [
    {
      'scope_id': _user,
      'kind': 'user',
      'role': 'owner',
      'revision': '0',
      'permission_version': '1',
    },
    for (final scope in books)
      {
        'scope_id': scope,
        'kind': 'book',
        'role': 'editor',
        'revision': '7',
        'permission_version': '1',
      },
  ],
};

Map<String, Object?> _pull(
  Map<String, Object?> body, [
  List<SyncEvent> events = const [],
]) {
  final cursors = Map<String, Object?>.from(body['cursors'] as Map);
  for (final event in events) {
    if (cursors.containsKey(event.scopeId)) cursors[event.scopeId] = '7';
  }
  return {
    'sync_epoch': _epoch,
    'commits': [
      if (events.isNotEmpty)
        {'commit_id': _commit, 'events': events.map(_wire).toList()},
    ],
    'next_page_token': null,
    'checkpoint': cursors,
  };
}

void main() {
  late AppDatabase database;
  late LocalRepository repository;
  late SyncStore store;
  late SyncEngine engine;
  late StoredOperation operation;
  var identityCurrent = true;
  final space = testSpace(user: _user, instance: _instance);
  SyncLease lease(SyncRequest request) => SyncLease(
    space: space,
    clientId: _client,
    epoch: _epoch,
    request: request,
    isCurrent: () => identityCurrent,
  );

  Future<void> seedMoved() => store.applyPullPage(space, _epoch, [
    [_event(_source, '2', deleted: true), _event(_target, '2')],
  ], finalPage: false);

  Future<void> expectFrozenIntentUnchanged() async {
    final saved = await database.select(database.pendingOperations).getSingle();
    expect(saved.operationJson, operation.operationJson);
    expect(saved.frozenRequestJson, operation.frozenRequestJson);
    expect(jsonDecode(saved.operationJson)['base_revision'], '1');
    expect(jsonDecode(saved.operationJson)['payload']['note'], '原本机输入，不自动重基');
    expect(saved.state, 'rejected');
  }

  setUp(() async {
    identityCurrent = true;
    database = AppDatabase(NativeDatabase.memory());
    repository = LocalRepository(database);
    store = SyncStore(repository);
    engine = SyncEngine(store);
    await repository.registerSpace(space);
    await store.configure(space, _client, _epoch);
    await store.applyPullPage(
      space,
      _epoch,
      [
        [_event(_source, '1')],
      ],
      finalPage: true,
      checkpoint: {_user: '0', _source: '1', _target: '0', _third: '0'},
    );
    await repository.saveEntityAndQueue(
      space,
      QueuedCommand(
        operationId: _operation,
        scopeId: _source,
        entityType: 'bill',
        entityId: _bill,
        action: 'update',
        baseRevision: '1',
        payload: _payload(_source, '原本机输入，不自动重基'),
      ),
    );
    await store.nextPush(space);
    await store.reject(space, _operation, 'revision_conflict');
    operation = await database.select(database.pendingOperations).getSingle();
  });
  tearDown(() => database.close());

  test(
    'fresh scopes precede a moved target GET and preserve viewer response and frozen input',
    () async {
      await seedMoved();
      final calls = <String>[];
      final expected = _response(_event(_target, '3'), viewer: true);
      final result = await engine.currentForConflict(
        lease((method, path, {body, bodyJson}) async {
          calls.add(path);
          if (path == '/sync/scopes') return _scopes();
          expect(method, 'GET');
          expect(path, endsWith('scope_id=$_target'));
          return expected;
        }),
        operation,
      );
      expect(calls.first, '/sync/scopes');
      expect(calls, hasLength(2));
      expect(result, expected);
      expect(result['editable_payload'], isNull);
      await expectFrozenIntentUnchanged();
    },
  );

  for (final sourceFirst in [false, true]) {
    test(
      '404 relocates once to a newly confirmed scope with sourceFirst=$sourceFirst',
      () async {
        if (!sourceFirst) await seedMoved();
        final original = sourceFirst ? _source : _target;
        final destination = sourceFirst ? _target : _third;
        var scopesRead = 0, pulls = 0;
        final gets = <String>[];
        final result = await engine.currentForConflict(
          lease((method, path, {body, bodyJson}) async {
            if (path == '/sync/scopes') {
              scopesRead++;
              return _scopes();
            }
            if (path == '/sync/pull') {
              pulls++;
              return _pull(body!, [
                _event(original, '3', deleted: true),
                _event(destination, '3'),
              ]);
            }
            gets.add(path);
            if (gets.length == 1) {
              expect(path, endsWith('scope_id=$original'));
              throw ApiFailure.server('not_found', 404);
            }
            expect(path, endsWith('scope_id=$destination'));
            return _response(_event(destination, '3'));
          }),
          operation,
        );
        expect(scopesRead, 2);
        expect(pulls, 1);
        expect(gets, hasLength(2));
        expect((result['event'] as Map)['scope_id'], destination);
        await expectFrozenIntentUnchanged();
      },
    );
  }

  test(
    '403 revocation clears foreign current cache and cannot fall back to historical source',
    () async {
      await seedMoved();
      var scopeReads = 0;
      final gets = <String>[];
      await expectLater(
        engine.currentForConflict(
          lease((method, path, {body, bodyJson}) async {
            if (path == '/sync/scopes') {
              return ++scopeReads == 1
                  ? _scopes()
                  : _scopes(books: {_source, _third});
            }
            if (path == '/sync/pull') {
              expect((body!['cursors'] as Map).containsKey(_target), isFalse);
              return _pull(body);
            }
            gets.add(path);
            expect(path, endsWith('scope_id=$_target'));
            throw ApiFailure.server('scope_forbidden', 403);
          }),
          operation,
        ),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.code,
            'code',
            'conflict_current_unavailable',
          ),
        ),
      );
      expect(gets, hasLength(1));
      expect(
        (await database.select(database.serverShadows).get()).any(
          (row) => row.scopeId == _target,
        ),
        isFalse,
      );
      final conflict = (await store.conflicts(space)).single;
      expect(conflict.serverJson, isNull);
      expect(jsonDecode(conflict.localJson)['note'], '原本机输入，不自动重基');
      await expectFrozenIntentUnchanged();
    },
  );

  test(
    'repeated 404 in the same confirmed location is bounded and asks for synchronization',
    () async {
      await seedMoved();
      var reads = 0, pulls = 0;
      await expectLater(
        engine.currentForConflict(
          lease((method, path, {body, bodyJson}) async {
            if (path == '/sync/scopes') return _scopes();
            if (path == '/sync/pull') {
              pulls++;
              return _pull(body!);
            }
            reads++;
            throw ApiFailure.server('not_found', 404);
          }),
          operation,
        ),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.code,
            'code',
            'conflict_current_unavailable',
          ),
        ),
      );
      expect(reads, 1);
      expect(pulls, 1);
      await expectFrozenIntentUnchanged();
    },
  );

  test(
    'highest private finance is never requested as a public current bill',
    () async {
      await seedMoved();
      await store.applyPullPage(space, _epoch, [
        [
          SyncEvent(
            scopeId: _user,
            entityType: 'bill',
            entityId: _bill,
            revision: '99',
            deleted: false,
            data: {
              'projection_kind': 'bill_private_finance',
              'book_id': _target,
              'entries': <Object?>[],
            },
          ),
        ],
      ], finalPage: false);
      final result = await engine.currentForConflict(
        lease((method, path, {body, bodyJson}) async {
          if (path == '/sync/scopes') return _scopes();
          expect(path, endsWith('scope_id=$_target'));
          return _response(_event(_target, '2'));
        }),
        operation,
      );
      expect((result['event'] as Map)['scope_id'], _target);
      await expectFrozenIntentUnchanged();
    },
  );

  test(
    'identity change while GET is in flight rejects its body without mutating the journal',
    () async {
      await seedMoved();
      await expectLater(
        engine.currentForConflict(
          lease((method, path, {body, bodyJson}) async {
            if (path == '/sync/scopes') return _scopes();
            identityCurrent = false;
            return _response(_event(_target, '3'));
          }),
          operation,
        ),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      final target = (await database.select(database.serverShadows).get())
          .singleWhere((row) => row.scopeId == _target);
      expect(target.revision, '2');
      await expectFrozenIntentUnchanged();
    },
  );

  test(
    'epoch failure during GET propagates and preserves complete recovery backup',
    () async {
      await seedMoved();
      await expectLater(
        engine.currentForConflict(
          lease((method, path, {body, bodyJson}) async {
            if (path == '/sync/scopes') return _scopes();
            throw const ApiFailure(
              'epoch_changed',
              'synthetic epoch reset',
              status: 409,
            );
          }),
          operation,
        ),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'epoch_changed'),
        ),
      );
      expect((await store.state(space))!.status, 'recovery_required');
      expect(await store.recoveryBackups(space), hasLength(1));
      await expectFrozenIntentUnchanged();
    },
  );

  test(
    'missing sync state preserves resync error and releases conflict reader',
    () async {
      await database.delete(database.syncStates).go();
      var requested = false;
      await expectLater(
        engine.currentForConflict(
          lease((method, path, {body, bodyJson}) async {
            requested = true;
            throw StateError('Unconfigured space must not perform network I/O');
          }),
          operation,
        ),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.code,
            'code',
            'resync_required',
          ),
        ),
      );
      expect(requested, isFalse);
      expect(await store.recoveryBackups(space), isEmpty);
      await expectFrozenIntentUnchanged();
      await store.configure(space, _client, _epoch);
      final result = await engine.currentForConflict(
        lease((method, path, {body, bodyJson}) async {
          if (path == '/sync/scopes') return _scopes();
          expect(path, endsWith('scope_id=$_source'));
          return _response(_event(_source, '1'));
        }),
        operation,
      );
      expect((result['event'] as Map)['scope_id'], _source);
      await expectFrozenIntentUnchanged();
    },
  );

  for (final invalid in [
    'entity',
    'scope',
    'private',
    'revision',
    'editable',
  ]) {
    test(
      'invalid $invalid current response fails closed without accepting or rebasing',
      () async {
        await seedMoved();
        final malformed = _response(_event(_target, '2'));
        final event = malformed['event'] as Map<String, Object?>;
        switch (invalid) {
          case 'entity':
            event['entity_id'] = _operation;
          case 'scope':
            event['scope_id'] = _third;
          case 'private':
            event['data'] = {'projection_kind': 'bill_private_finance'};
          case 'revision':
            event['revision'] = '1';
          case 'editable':
            malformed['editable_payload'] = 'not a payload';
        }
        await expectLater(
          engine.currentForConflict(
            lease((method, path, {body, bodyJson}) async {
              if (path == '/sync/scopes') return _scopes();
              return malformed;
            }),
            operation,
          ),
          throwsFormatException,
        );
        await expectFrozenIntentUnchanged();
      },
    );
  }

  test(
    'ordinary deleted current uses minimal server tombstone and can discard old intent',
    () async {
      final deleted = _event(_source, '2', deleted: true);
      await store.applyPullPage(space, _epoch, [
        [deleted],
      ], finalPage: false);
      final result = await engine.currentForConflict(
        lease((method, path, {body, bodyJson}) async {
          if (path == '/sync/scopes') return _scopes();
          expect(path, endsWith('scope_id=$_source'));
          // Exact shape of the authorized soft-delete EntityReadResponse.
          return _response(deleted);
        }),
        operation,
      );
      expect((result['event'] as Map)['data'], isNull);
      expect(result['editable_payload'], isNull);
      await store.acceptServerVersion(
        space,
        _operation,
        decodeSyncEvent(result['event']),
      );
      final local = await database.select(database.localEntities).getSingle();
      expect(local.deleted, isTrue);
      expect(local.scopeId, _source);
      expect(jsonDecode(local.dataJson), isEmpty);
      expect(await store.conflicts(space), isEmpty);
      expect(await store.nextPush(space), isNull);
      final saved = await database
          .select(database.pendingOperations)
          .getSingle();
      expect(saved.state, 'discarded');
      expect(saved.frozenRequestJson, operation.frozenRequestJson);
    },
  );
}
