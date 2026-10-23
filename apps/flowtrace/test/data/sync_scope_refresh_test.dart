import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import 'local_repository_test.dart' show testSpace;

const _source = '28000000-0000-4000-8000-000000000001';
const _target = '28000000-0000-4000-8000-000000000002';
const _user = '28000000-0000-4000-8000-000000000003';
const _bill = '38000000-0000-4000-8000-000000000001';
const _otherBill = '38000000-0000-4000-8000-000000000002';
const _client = '48000000-0000-4000-8000-000000000001';
const _epoch = '58000000-0000-4000-8000-000000000001';
const _newEpoch = '58000000-0000-4000-8000-000000000002';
const _operation = '68000000-0000-4000-8000-000000000001';
const _instance = '78000000-0000-4000-8000-000000000001';

Map<String, Object?> _payload(String scope, String note) => {
  'book_id': scope,
  'note': note,
  'attachment_ids': <String>[],
};

SyncEvent _public(String scope, String id) => SyncEvent(
  scopeId: scope,
  entityType: 'bill',
  entityId: id,
  revision: '1',
  deleted: false,
  data: {
    'projection_kind': 'bill_public',
    'payload': _payload(scope, '受控服务器正文'),
  },
);

Map<String, Object?> _scopes({
  bool source = true,
  String sourceRole = 'editor',
  bool recovery = false,
  String epoch = _epoch,
}) => {
  'sync_epoch': epoch,
  'control_version': '2',
  'requires_rebuild': recovery,
  'revoked_scope_ids': [if (!source) _source],
  'scopes': [
    {
      'scope_id': _user,
      'kind': 'user',
      'role': 'owner',
      'revision': '0',
      'permission_version': '1',
    },
    if (source)
      {
        'scope_id': _source,
        'kind': 'book',
        'role': sourceRole,
        'revision': '1',
        'permission_version': sourceRole == 'editor' ? '1' : '2',
      },
    {
      'scope_id': _target,
      'kind': 'book',
      'role': 'owner',
      'revision': '1',
      'permission_version': '1',
    },
  ],
};

Matcher _failure(String code) =>
    throwsA(isA<ApiFailure>().having((error) => error.code, 'code', code));

void main() {
  late AppDatabase database;
  late LocalRepository repository;
  late SyncStore store;
  late SyncEngine engine;
  late StoredOperation operation;
  var currentIdentity = true;
  final space = testSpace(user: _user, instance: _instance);

  SyncLease lease(SyncRequest request) => SyncLease(
    space: space,
    clientId: _client,
    epoch: _epoch,
    request: request,
    isCurrent: () => currentIdentity,
  );

  Future<Map<String, Object?>> snapshot() async => {
    'entities': (await database.select(database.localEntities).get())
        .map((row) => row.toJson())
        .toList(),
    'shadows': (await database.select(database.serverShadows).get())
        .map((row) => row.toJson())
        .toList(),
    'operations': (await database.select(database.pendingOperations).get())
        .map((row) => row.toJson())
        .toList(),
    'conflicts': (await store.conflicts(
      space,
    )).map((row) => row.toJson()).toList(),
    'drafts': (await repository.drafts(
      space,
    )).map((row) => row.toJson()).toList(),
  };

  setUp(() async {
    currentIdentity = true;
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
        [_public(_source, _bill), _public(_target, _otherBill)],
      ],
      finalPage: true,
      checkpoint: {_user: '0', _source: '1', _target: '1'},
    );
    await repository.writeSetting(
      'sync.scopes.${space.id}',
      jsonEncode({_user: '1', _source: '1', _target: '1'}),
    );
    await repository.writeSetting(
      'sync.scope-details.${space.id}',
      jsonEncode({
        'version': 1,
        'epoch': _epoch,
        'scopes': _scopes()['scopes'],
      }),
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
        payload: _payload(_source, '未发送的本机输入'),
      ),
    );
    await store.nextPush(space);
    await store.reject(
      space,
      _operation,
      'revision_conflict',
      authorizedServer: _public(_source, _bill).data,
    );
    await repository.saveDraft(space, '恢复必须保留的草稿');
    operation = await database.select(database.pendingOperations).getSingle();
  });
  tearDown(() => database.close());

  test(
    'authorization refresh clears revoked public and conflict caches before cleanup while preserving local intent',
    () async {
      final cleanups = <String>[];
      engine = SyncEngine(
        store,
        onScopeRevoked: (captured, scope) async {
          expect(captured.id, space.id);
          expect(
            (await database.select(database.serverShadows).get()).where(
              (row) => row.scopeId == scope,
            ),
            isEmpty,
          );
          expect((await store.conflicts(space)).single.serverJson, isNull);
          cleanups.add(scope);
        },
      );
      final calls = <String>[];
      final versions = await engine.refreshScopes(
        lease((method, path, {body, bodyJson}) async {
          calls.add('$method $path');
          return _scopes(source: false);
        }),
      );
      expect(calls, ['GET /sync/scopes']);
      expect(versions.keys, unorderedEquals([_user, _target]));
      expect(cleanups, [_source]);
      final retained = await database
          .select(database.localEntities)
          .getSingle();
      expect(retained.entityId, _otherBill);
      expect(retained.scopeId, _target);
      final conflict = (await store.conflicts(space)).single;
      expect(conflict.code, 'scope_revoked');
      expect(jsonDecode(conflict.localJson)['note'], '未发送的本机输入');
      expect(conflict.serverJson, isNull);
      expect(conflict.baseJson, isNull);
      final journal = await database
          .select(database.pendingOperations)
          .getSingle();
      expect(journal.operationJson, operation.operationJson);
      expect(journal.frozenRequestJson, operation.frozenRequestJson);
      expect(journal.state, 'discarded');
      expect(await store.nextPush(space), isNull);
      expect((await repository.drafts(space)).single.body, '恢复必须保留的草稿');
      expect(jsonDecode((await store.state(space))!.cursorsJson), {
        _user: '0',
        _target: '1',
      });
      expect(await store.recoveryBackups(space), isEmpty);
    },
  );

  test(
    'editor downgrade persists viewer role without sending or changing intent',
    () async {
      final before = await snapshot();
      final versions = await engine.refreshScopes(
        lease((method, path, {body, bodyJson}) async {
          expect(method, 'GET');
          expect(path, '/sync/scopes');
          return _scopes(sourceRole: 'viewer');
        }),
      );
      final cached =
          jsonDecode(
                (await repository.readSetting(
                  'sync.scope-details.${space.id}',
                ))!,
              )
              as Map;
      expect(cached['epoch'], _epoch);
      final source = (cached['scopes'] as List).cast<Map>().singleWhere(
        (row) => row['scope_id'] == _source,
      );
      expect(source['role'], 'viewer');
      expect(source['permission_version'], '2');
      expect(versions[_source], '2');
      expect(await snapshot(), before);
      expect((await store.state(space))!.status, 'active');
    },
  );

  for (final reason in ['resync_required', 'epoch_changed']) {
    test(
      'scope refresh $reason preserves one complete recovery backup',
      () async {
        final before = await snapshot();
        var requests = 0;
        await expectLater(
          engine.refreshScopes(
            lease((method, path, {body, bodyJson}) async {
              requests++;
              expect(path, '/sync/scopes');
              return reason == 'resync_required'
                  ? _scopes(recovery: true)
                  : _scopes(epoch: _newEpoch);
            }),
          ),
          _failure(reason),
        );
        expect(requests, 1);
        expect((await store.state(space))!.status, 'recovery_required');
        final backup = (await store.recoveryBackups(space)).single;
        expect(backup.reason, reason);
        expect(backup.oldEpoch, _epoch);
        final saved = jsonDecode(backup.dataJson) as Map;
        expect(saved['space_id'], space.id);
        expect(saved['server_instance_id'], _instance);
        expect(saved['sync_state']['epoch'], _epoch);
        for (final key in before.keys) {
          expect(saved[key], before[key], reason: 'Complete $key must survive');
        }
        expect(await snapshot(), before);
        await expectLater(
          engine.refreshScopes(
            lease((method, path, {body, bodyJson}) async {
              fail('Recovery-required state must not request the server');
            }),
          ),
          _failure('resync_required'),
        );
        expect(await store.recoveryBackups(space), hasLength(1));
      },
    );
  }

  test(
    'missing state requests no network creates no empty backup and releases refresh lock',
    () async {
      await database.delete(database.syncStates).go();
      final before = await snapshot();
      await expectLater(
        engine.refreshScopes(
          lease((method, path, {body, bodyJson}) async {
            fail('An unconfigured space must not request permissions');
          }),
        ),
        _failure('resync_required'),
      );
      expect(await store.state(space), isNull);
      expect(await store.recoveryBackups(space), isEmpty);
      expect(await snapshot(), before);
      await store.configure(space, _client, _epoch);
      expect(
        await engine.refreshScopes(
          lease((method, path, {body, bodyJson}) async => _scopes()),
        ),
        {_user: '1', _source: '1', _target: '1'},
      );
    },
  );

  test(
    'in-flight permission refresh excludes sync conflict reads recovery and another refresh',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      final captured = lease((method, path, {body, bodyJson}) async {
        requests++;
        expect(path, '/sync/scopes');
        entered.complete();
        await release.future;
        return _scopes();
      });
      final before = await snapshot();
      final running = engine.refreshScopes(captured);
      try {
        await entered.future;
        expect(() => engine.synchronize(captured), _failure('sync_busy'));
        await expectLater(
          engine.currentForConflict(captured, operation),
          _failure('sync_busy'),
        );
        await expectLater(engine.rebuildFromServer(captured), throwsStateError);
        await expectLater(
          engine.refreshScopes(captured),
          _failure('sync_busy'),
        );
      } finally {
        release.complete();
        await running;
      }
      expect(requests, 1);
      expect(await snapshot(), before);
    },
  );

  test(
    'late permission response after identity change cannot install roles revoke caches or create backup',
    () async {
      final before = await snapshot();
      final stateBefore = (await store.state(space))!.toJson();
      final detailsBefore = await repository.readSetting(
        'sync.scope-details.${space.id}',
      );
      final cleanups = <String>[];
      engine = SyncEngine(
        store,
        onScopeRevoked: (_, scope) async => cleanups.add(scope),
      );
      await expectLater(
        engine.refreshScopes(
          lease((method, path, {body, bodyJson}) async {
            currentIdentity = false;
            return _scopes(source: false, recovery: true);
          }),
        ),
        _failure('identity_changed'),
      );
      expect(cleanups, isEmpty);
      expect(await snapshot(), before);
      expect((await store.state(space))!.toJson(), stateBefore);
      expect(
        await repository.readSetting('sync.scope-details.${space.id}'),
        detailsBefore,
      );
      expect(await store.recoveryBackups(space), isEmpty);
      currentIdentity = true;
      expect(
        await engine.refreshScopes(
          lease((method, path, {body, bodyJson}) async => _scopes()),
        ),
        {_user: '1', _source: '1', _target: '1'},
      );
    },
  );
}
