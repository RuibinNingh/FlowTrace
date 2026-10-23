import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import 'local_repository_test.dart' show testSpace;
import 'snapshot_test.dart' show instance;
import 'sync_engine_test.dart' show user, scopeResponse;
import 'sync_store_test.dart' show scope, client, epoch, edit, event;

void main() {
  for (final code in ['permission_changed', 'scope_forbidden']) {
    test(
      'pull-only $code rechecks authority, clears controlled cache and preserves frozen input without push',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final repo = LocalRepository(db),
            space = testSpace(user: user, instance: instance);
        final store = SyncStore(repo);
        final paths = <String>[], revoked = <String>[];
        try {
          await repo.registerSpace(space);
          await store.configure(space, client, epoch);
          await store.applyPullPage(
            space,
            epoch,
            [
              [event('受控服务器分类', '1')],
            ],
            finalPage: true,
            checkpoint: {user: '0', scope: '1'},
          );
          final cacheKey = 'assets.read.v1.${space.id}.authority-probe';
          await repo.writeSetting(
            cacheKey,
            jsonEncode({'scope_id': scope, 'note': '受控分录缓存'}),
          );
          await repo.saveDraft(space, '12+ 尚未完成的本机输入');
          await repo.saveEntityAndQueue(space, edit(1, '原离线修改', base: '1'));
          final frozen = (await store.nextPush(space))!;
          final before = (await db.select(db.pendingOperations).getSingle());
          var scopes = 0;
          final engine = SyncEngine(
            store,
            onScopeRevoked: (captured, id) async {
              expect(captured.id, space.id);
              revoked.add(id);
              expect(
                await repo.readSetting(cacheKey),
                isNull,
                reason:
                    'Controlled SQLite caches must already be cleared before attachment cleanup.',
              );
            },
          );
          final lease = SyncLease(
            space: space,
            clientId: client,
            epoch: epoch,
            isCurrent: () => true,
            request: (method, path, {body, bodyJson}) async {
              paths.add('$method $path');
              if (method == 'GET' && path == '/sync/scopes') {
                return scopeResponse(shared: scopes++ == 0);
              }
              if (method == 'POST' && path == '/sync/pull') {
                throw ApiFailure(
                  code,
                  'Permission changed during pull',
                  status: 403,
                );
              }
              throw StateError(
                'Pull-only refresh must not send outbox or repeat import.',
              );
            },
          );
          await expectLater(
            engine.pullLatest(lease),
            throwsA(isA<ApiFailure>().having((e) => e.code, 'code', code)),
          );
          expect(paths, [
            'GET /sync/scopes',
            'POST /sync/pull',
            'GET /sync/scopes',
          ]);
          expect(revoked, [scope]);
          expect(
            jsonDecode((await store.state(space))!.revokedScopesJson),
            contains(scope),
          );
          expect(await db.select(db.serverShadows).get(), isEmpty);
          expect(await db.select(db.localEntities).get(), isEmpty);
          expect(await repo.readSetting(cacheKey), isNull);
          final retained = await db.select(db.pendingOperations).getSingle();
          expect(retained.operationJson, before.operationJson);
          expect(retained.frozenRequestJson, frozen.body);
          expect(retained.attemptCount, before.attemptCount);
          expect(
            retained.state,
            'discarded',
            reason: 'Revoked input is quarantined, never published.',
          );
          final conflict = (await store.conflicts(space)).single;
          expect(conflict.localJson, contains('原离线修改'));
          expect(conflict.serverJson, isNull);
          expect((await repo.drafts(space)).single.body, '12+ 尚未完成的本机输入');
          expect(engine.busy, isFalse);
        } finally {
          await db.close();
        }
      },
    );
  }
}
