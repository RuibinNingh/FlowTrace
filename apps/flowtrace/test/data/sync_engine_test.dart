import 'dart:async';
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
import 'snapshot_test.dart' show instance, nextClient, statusFor, item;
import 'sync_store_test.dart'
    show scope, entity, client, epoch, edit, operationId;

const user = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
Map<String, Object?> scopeResponse({bool shared = true}) => {
  'sync_epoch': epoch,
  'control_version': '1',
  'requires_rebuild': false,
  'revoked_scope_ids': <Object?>[],
  'scopes': [
    {
      'scope_id': user,
      'kind': 'user',
      'role': 'owner',
      'revision': '0',
      'permission_version': '1',
    },
    if (shared)
      {
        'scope_id': scope,
        'kind': 'book',
        'role': 'editor',
        'revision': '5',
        'permission_version': '1',
      },
  ],
};
Map<String, Object?> emptyPull(Map<String, Object?> request) => {
  'sync_epoch': epoch,
  'commits': <Object?>[],
  'next_page_token': null,
  'checkpoint': request['cursors'],
};
Map<String, Object?> receipt() => {
  'results': [
    {
      'operation_id': operationId(1),
      'status': 'applied',
      'entity_id': entity,
      'revision': '1',
      'commit_id': nextClient,
      'scope_revisions': {scope: '1'},
      'replayed': true,
    },
  ],
};

void main() {
  late AppDatabase db;
  late LocalRepository repo;
  late SyncStore store;
  late SyncEngine engine;
  final space = testSpace(user: user, instance: instance);
  var currentIdentity = true;
  SyncLease lease(SyncRequest request) => SyncLease(
    space: space,
    clientId: client,
    epoch: epoch,
    request: request,
    isCurrent: () => currentIdentity,
  );
  setUp(() async {
    currentIdentity = true;
    db = AppDatabase(NativeDatabase.memory());
    repo = LocalRepository(db);
    store = SyncStore(repo);
    engine = SyncEngine(store);
    await repo.registerSpace(space);
    await store.configure(space, client, epoch);
    await store.applyPullPage(
      space,
      epoch,
      [],
      finalPage: true,
      checkpoint: {user: '0', scope: '0'},
    );
  });
  tearDown(() => db.close());

  test(
    'import refresh receives confirmed projection without sending frozen outbox',
    () async {
      await repo.saveEntityAndQueue(
        space,
        edit(1, 'original offline', action: 'create'),
      );
      await store.nextPush(space);
      final pendingBefore = (await db.select(db.pendingOperations).getSingle())
          .toJson();
      const imported = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      final paths = <String>[];
      await engine.pullLatest(
        lease((method, path, {body, bodyJson}) async {
          paths.add(path);
          if (path == '/sync/scopes') return scopeResponse();
          if (path == '/sync/pull') {
            return {
              'sync_epoch': epoch,
              'commits': [
                {
                  'commit_id': nextClient,
                  'events': [
                    {...item('imported on server'), 'entity_id': imported},
                  ],
                },
              ],
              'next_page_token': null,
              'checkpoint': {user: '0', scope: '5'},
            };
          }
          throw StateError('Import refresh must not publish outbox');
        }),
      );
      expect(paths, ['/sync/scopes', '/sync/pull']);
      expect(
        (await db.select(db.pendingOperations).getSingle()).toJson(),
        pendingBefore,
      );
      final received = await db.select(db.serverShadows).getSingle();
      expect(received.entityId, imported);
      expect(jsonDecode(received.dataJson)['payload']['name'], 'imported on server');
      expect(engine.busy, isFalse);
    },
  );

  test(
    'pull-only refresh holds sync coordinator and rejects a late identity response',
    () async {
      final reached = Completer<void>(), release = Completer<void>();
      final request = lease((method, path, {body, bodyJson}) async {
        expect(path, '/sync/scopes');
        reached.complete();
        await release.future;
        return scopeResponse();
      });
      final pending = engine.pullLatest(request);
      final failed = expectLater(pending, throwsA(isA<ApiFailure>()));
      await reached.future;
      expect(engine.busy, isTrue);
      expect(() => engine.synchronize(request), throwsA(isA<ApiFailure>()));
      currentIdentity = false;
      release.complete();
      await failed;
      expect(await db.select(db.serverShadows).get(), isEmpty);
      expect(engine.busy, isFalse);
    },
  );

  test(
    'lost acknowledgement retries identical serialized bytes and applies one receipt',
    () async {
      await repo.saveEntityAndQueue(
        space,
        edit(1, 'offline', action: 'create'),
      );
      final bodies = <String>[];
      Future<Map<String, Object?>> request(
        String method,
        String path, {
        Map<String, Object?>? body,
        String? bodyJson,
      }) async {
        if (path == '/sync/scopes') return scopeResponse();
        if (path == '/sync/pull') return emptyPull(body!);
        if (path == '/sync/push') {
          bodies.add(bodyJson!);
          if (bodies.length == 1) {
            throw const ApiFailure(
              'network_unavailable',
              'offline',
              offline: true,
            );
          }
          return receipt();
        }
        throw StateError('Unexpected request');
      }

      await expectLater(
        engine.synchronize(lease(request)),
        throwsA(isA<ApiFailure>()),
      );
      expect((await repo.pending(space)).single.state, 'retry');
      final report = await engine.synchronize(lease(request));
      expect(bodies, hasLength(2));
      expect(bodies[0], bodies[1]);
      expect(report.applied, 1);
      expect(report.pending, 0);
      final permissions =
          jsonDecode(
                (await repo.readSetting('sync.scope-details.${space.id}'))!,
              )
              as Map;
      expect(permissions['epoch'], epoch);
      expect(
        (permissions['scopes'] as List).map((value) => (value as Map)['role']),
        ['owner', 'editor'],
      );
      expect(
        (await db.select(db.pendingOperations).getSingle()).attemptCount,
        2,
      );
    },
  );

  test(
    'scope difference cleans cache even if a previous revocation response was lost',
    () async {
      await repo.writeSetting(
        'sync.scopes.${space.id}',
        jsonEncode({user: '1', scope: '1'}),
      );
      await repo.saveEntityAndQueue(space, edit(1, 'unsent', action: 'create'));
      var pushed = false;
      final report = await engine.synchronize(
        lease((method, path, {body, bodyJson}) async {
          if (path == '/sync/scopes') return scopeResponse(shared: false);
          if (path == '/sync/pull') return emptyPull(body!);
          pushed = true;
          throw StateError('Revoked input must not be sent');
        }),
      );
      expect(pushed, isFalse);
      expect(report.pending, 0);
      expect(await db.select(db.localEntities).get(), isEmpty);
      expect((await store.conflicts(space)).single.code, 'scope_revoked');
      expect(jsonDecode((await store.state(space))!.cursorsJson), {user: '0'});
    },
  );

  test(
    'switching account while a pull is in flight rejects its result',
    () async {
      await expectLater(
        engine.synchronize(
          lease((method, path, {body, bodyJson}) async {
            if (path == '/sync/scopes') return scopeResponse();
            if (path == '/sync/pull') {
              currentIdentity = false;
              return {
                'sync_epoch': epoch,
                'commits': [
                  {
                    'commit_id': nextClient,
                    'events': [item('should not appear')],
                  },
                ],
                'next_page_token': null,
                'checkpoint': {user: '0', scope: '5'},
              };
            }
            throw StateError('Unexpected write');
          }),
        ),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      expect(await db.select(db.localEntities).get(), isEmpty);
      expect(jsonDecode((await store.state(space))!.cursorsJson), {
        user: '0',
        scope: '0',
      });
    },
  );

  test(
    'middle page can persist complete commits but failure does not advance final cursor',
    () async {
      var attempt = 0;
      final requests = <Map<String, Object?>>[];
      Future<Map<String, Object?>> request(
        String method,
        String path, {
        Map<String, Object?>? body,
        String? bodyJson,
      }) async {
        if (path == '/sync/scopes') return scopeResponse();
        if (path == '/sync/pull') {
          requests.add(body!);
          if (body['page_token'] == null && requests.length < 4) {
            return {
              'sync_epoch': epoch,
              'commits': [
                {
                  'commit_id': nextClient,
                  'events': [item('committed page')],
                },
              ],
              'next_page_token': 'second-page-token',
              'checkpoint': null,
            };
          }
          if (body['page_token'] != null && attempt++ == 0) {
            throw const ApiFailure(
              'network_unavailable',
              'offline',
              offline: true,
            );
          }
          return {
            'sync_epoch': epoch,
            'commits': <Object?>[],
            'next_page_token': null,
            'checkpoint': {user: '0', scope: '5'},
          };
        }
        throw StateError('Unexpected request');
      }

      await expectLater(
        engine.synchronize(lease(request)),
        throwsA(isA<ApiFailure>()),
      );
      expect(await db.select(db.localEntities).get(), hasLength(1));
      expect(jsonDecode((await store.state(space))!.cursorsJson), {
        user: '0',
        scope: '0',
      });
      await engine.synchronize(lease(request));
      expect(requests[0]['cursors'], requests[1]['cursors']);
      expect(requests[2]['cursors'], requests[0]['cursors']);
      expect(jsonDecode((await store.state(space))!.cursorsJson), {
        user: '0',
        scope: '5',
      });
    },
  );

  test(
    'conflict fetches only authorized editor projection and retains local intent',
    () async {
      await repo.saveEntityAndQueue(space, edit(1, 'unsent', base: '1'));
      final report = await engine.synchronize(
        lease((method, path, {body, bodyJson}) async {
          if (path == '/sync/scopes') return scopeResponse();
          if (path == '/sync/pull') return emptyPull(body!);
          if (path == '/sync/push') {
            throw ApiFailure.server('revision_conflict', 409);
          }
          if (path.startsWith('/sync/entities/')) {
            return {
              'event': item('authorized server'),
              'editable_payload': {'name': 'authorized server'},
            };
          }
          throw StateError('Unexpected request');
        }),
      );
      expect(report.conflicts, 1);
      expect(report.applied, 0);
      final conflict = (await store.conflicts(space)).single;
      expect(jsonDecode(conflict.localJson)['name'], 'unsent');
      expect(
        jsonDecode(conflict.serverJson!)['editable_payload']['name'],
        'authorized server',
      );
      expect((await repo.pending(space)).single.state, 'rejected');
    },
  );

  test(
    'initial snapshot verifies complete scopes and pages before enabling pull',
    () async {
      await db.customStatement('UPDATE sync_states SET cursors_json = ?', [
        '{}',
      ]);
      final items = <Object?>[item('from snapshot')];
      final status = statusFor([items]);
      final manifest = syncObject(status['manifest']);
      manifest['checkpoint'] = {user: '0', scope: '5'};
      manifest['permission_versions'] = {user: '1', scope: '1'};
      status['checkpoint'] = manifest['checkpoint'];
      status['permission_versions'] = manifest['permission_versions'];
      status['manifest_sha256'] = syncContentHash(manifest);
      final paths = <String>[];
      await engine.synchronize(
        lease((method, path, {body, bodyJson}) async {
          paths.add(path);
          if (path == '/sync/scopes') return scopeResponse();
          if (path == '/sync/snapshots') return status;
          if (path.endsWith('/pages')) {
            return {
              'snapshot_id': status['snapshot_id'],
              'items': items,
              'page_index': 0,
              'page_sha256': syncContentHash(items),
              'next_page_token': null,
            };
          }
          if (path == '/sync/pull') return emptyPull(body!);
          throw StateError('Unexpected request');
        }),
      );
      expect(
        paths.indexOf('/sync/snapshots'),
        lessThan(paths.indexOf('/sync/pull')),
      );
      expect(await db.select(db.localEntities).get(), hasLength(1));
      expect(await db.select(db.snapshotPages).get(), isEmpty);
    },
  );

  test(
    'permission change on a later page immediately purges revoked earlier page content',
    () async {
      var revoked = false;
      await repo.saveEntityAndQueue(
        space,
        edit(1, 'unsent shared input', base: '1'),
      );
      await expectLater(
        engine.synchronize(
          lease((method, path, {body, bodyJson}) async {
            if (path == '/sync/scopes') return scopeResponse(shared: !revoked);
            if (path == '/sync/pull' && body!['page_token'] == null) {
              return {
                'sync_epoch': epoch,
                'commits': [
                  {
                    'commit_id': nextClient,
                    'events': [item('shared server content')],
                  },
                ],
                'next_page_token': 'later-page',
                'checkpoint': null,
              };
            }
            if (path == '/sync/pull') {
              revoked = true;
              throw ApiFailure.server('permission_changed', 410);
            }
            throw StateError('Revoked writes must never be pushed');
          }),
        ),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'permission_changed'),
        ),
      );
      expect(await db.select(db.localEntities).get(), isEmpty);
      expect(await db.select(db.serverShadows).get(), isEmpty);
      expect((await store.conflicts(space)).single.code, 'scope_revoked');
      expect(jsonDecode((await store.state(space))!.cursorsJson), {user: '0'});
    },
  );

  test(
    'attachment preflight failure retains retryable frozen bill intent',
    () async {
      await repo.saveEntityAndQueue(
        space,
        edit(1, 'pending upload', action: 'create'),
      );
      var fail = true;
      String? firstBody;
      engine = SyncEngine(
        store,
        beforePush: (captured, command) async {
          expect(captured.space.id, space.id);
          expect(command['operation_id'], operationId(1));
          if (fail) throw ApiFailure.server('attachment_not_ready', 409);
        },
      );
      Future<Map<String, Object?>> request(
        String method,
        String path, {
        Map<String, Object?>? body,
        String? bodyJson,
      }) async {
        if (path == '/sync/scopes') return scopeResponse();
        if (path == '/sync/pull') return emptyPull(body!);
        if (path == '/sync/push') {
          expect(fail, isFalse);
          firstBody = bodyJson;
          return receipt();
        }
        throw StateError('Unexpected request');
      }

      await expectLater(
        engine.synchronize(lease(request)),
        throwsA(isA<ApiFailure>()),
      );
      final pending = (await repo.pending(space)).single;
      expect(pending.state, 'retry');
      expect(await store.conflicts(space), isEmpty);
      fail = false;
      await engine.synchronize(lease(request));
      expect(firstBody, pending.frozenRequestJson);
      expect(await repo.pending(space), isEmpty);
    },
  );

  test(
    'interrupted attachment cache cleanup retries from persisted revoked scopes',
    () async {
      await repo.writeSetting(
        'sync.scopes.${space.id}',
        jsonEncode({user: '1', scope: '1'}),
      );
      var cleanupAttempts = 0;
      engine = SyncEngine(
        store,
        onScopeRevoked: (captured, id) async {
          expect(captured.id, space.id);
          expect(id, scope);
          if (++cleanupAttempts == 1) {
            throw StateError('Injected filesystem failure');
          }
        },
      );
      Future<Map<String, Object?>> request(
        String method,
        String path, {
        Map<String, Object?>? body,
        String? bodyJson,
      }) async {
        if (path == '/sync/scopes') return scopeResponse(shared: false);
        if (path == '/sync/pull') return emptyPull(body!);
        throw StateError('Unexpected request');
      }

      await expectLater(engine.synchronize(lease(request)), throwsStateError);
      expect(
        jsonDecode((await store.state(space))!.revokedScopesJson),
        contains(scope),
      );
      await engine.synchronize(lease(request));
      expect(cleanupAttempts, greaterThanOrEqualTo(2));
      expect(jsonDecode((await store.state(space))!.cursorsJson), {user: '0'});
    },
  );

  test(
    'diagnostic storage failure cannot change a committed acknowledgement',
    () async {
      await db.customStatement(
        "CREATE TRIGGER diagnostic_failure BEFORE INSERT ON app_settings WHEN NEW.key LIKE 'diagnostics.%' BEGIN SELECT RAISE(ABORT, 'diagnostic fixture failure'); END",
      );
      await repo.saveEntityAndQueue(
        space,
        edit(1, 'private note must not enter diagnostics', action: 'create'),
      );
      final report = await engine.synchronize(
        lease((method, path, {body, bodyJson}) async {
          if (path == '/sync/scopes') return scopeResponse();
          if (path == '/sync/pull') return emptyPull(body!);
          if (path == '/sync/push') return receipt();
          throw StateError('Unexpected request');
        }),
      );
      expect(report.applied, 1);
      expect(
        (await db.select(db.pendingOperations).getSingle()).state,
        'applied',
      );
      expect(await repo.pending(space), isEmpty);
    },
  );
}
