import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/group_engine.dart';
import 'package:flowtrace/data/sync/group_store.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import 'group_store_test.dart' show publication, copy, id;

void main() {
  for (final requireFresh in [false, true]) {
    test(
      'fresh=$requireFresh distinguishes two old fixed pulls from a new pull',
      () async {
        final sample = publication();
        final owner = sample.manifest;
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final local = LocalRepository(db);
        final sync = SyncStore(local);
        final store = GroupPullStore(sync);
        final space = DataSpace(
          server: ServerAddress.parse('https://fresh-group.isolated.example'),
          serverInstanceId: owner.instanceId,
          userId: owner.userId,
        );
        await local.registerSpace(space);
        await sync.configure(space, owner.clientId, owner.epoch);
        await db.customStatement(
          'UPDATE sync_states SET cursors_json=? WHERE space_id=?',
          [
            canonicalSyncJson({id(1): '0'}),
            space.id,
          ],
        );
        await local.saveDraft(space, '原草稿保留');
        final statuses = <String, Map<String, Object?>>{};
        Map<String, Object?> empty(String requestId, String handle) {
          final result = copy(sample.status);
          final manifest = syncObject(result['manifest'])
            ..['pull_id'] = handle
            ..['request_id'] = requestId
            ..['base_cursors'] = {id(1): '0'}
            ..['checkpoint'] = {id(1): '0'}
            ..['unit_count'] = 0
            ..['index_pages'] = <Object?>[];
          result['pull_id'] = handle;
          result['request_id'] = requestId;
          result['manifest_sha256'] = syncContentHash(manifest);
          result['first_page_token'] = null;
          return result;
        }

        for (var index = 0; index < 2; index++) {
          final requestId = id(9100 + index), handle = id(9200 + index);
          await store.begin(
            space,
            requestId,
            clientId: owner.clientId,
            epoch: owner.epoch,
            cursors: {id(1): '0'},
            isCurrent: () => true,
          );
          await store.rememberHandle(
            space,
            requestId,
            pullId: handle,
            clientId: owner.clientId,
            epoch: owner.epoch,
            isCurrent: () => true,
          );
          statuses[handle] = empty(requestId, handle);
        }
        final newRequestId = id(9300), newHandle = id(9400);
        final coordinator = GroupPullCoordinator(
          store,
          newRequestId: () => newRequestId,
        );
        final discarded = <String>[];
        var creates = 0;
        await coordinator.run(
          space: space,
          clientId: owner.clientId,
          epoch: owner.epoch,
          isCurrent: () => true,
          requireFresh: requireFresh,
          refreshPermissions: () async => owner.permissions,
          request: (method, path, {body, bodyJson}) async {
            if (method == 'POST' && path == '/sync/group-pulls') {
              creates++;
              expect(
                syncObject(jsonDecode(bodyJson!))['request_id'],
                newRequestId,
              );
              statuses[newHandle] = empty(newRequestId, newHandle);
              return copy(statuses[newHandle]);
            }
            final handle = Uri.parse(path).pathSegments[2];
            if (path.endsWith('/discard')) {
              discarded.add(handle);
              return {'pull_id': handle, 'status': 'collected'};
            }
            expect(method, 'GET');
            return copy(statuses[handle]);
          },
        );
        expect(creates, requireFresh ? 1 : 0);
        expect(
          discarded,
          requireFresh ? [id(9200), id(9201), newHandle] : [id(9200)],
        );
        expect((await local.drafts(space)).single.body, '原草稿保留');
        expect(await db.select(db.pendingOperations).get(), isEmpty);
      },
    );
  }

  test(
    'fresh mode preserves the total page budget across an older pull and a new one',
    () async {
      final sample = publication();
      final owner = sample.manifest;
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final local = LocalRepository(db);
      final sync = SyncStore(local);
      final store = GroupPullStore(sync);
      final space = DataSpace(
        server: ServerAddress.parse('https://fresh-budget.isolated.example'),
        serverInstanceId: owner.instanceId,
        userId: owner.userId,
      );
      await local.registerSpace(space);
      await sync.configure(space, owner.clientId, owner.epoch);
      await store.begin(
        space,
        sample.requestId,
        clientId: owner.clientId,
        epoch: owner.epoch,
        cursors: {},
        isCurrent: () => true,
      );
      await store.rememberHandle(
        space,
        sample.requestId,
        pullId: owner.id,
        clientId: owner.clientId,
        epoch: owner.epoch,
        isCurrent: () => true,
      );
      final newStatus = copy(sample.status);
      final newManifest = syncObject(newStatus['manifest'])
        ..['pull_id'] = id(9700)
        ..['request_id'] = id(9600)
        ..['base_cursors'] = {id(1): '2'};
      newStatus['request_id'] = id(9600);
      newStatus['pull_id'] = id(9700);
      newStatus['manifest_sha256'] = syncContentHash(newManifest);
      var pages = 0, creates = 0;
      final coordinator = GroupPullCoordinator(
        store,
        newRequestId: () => id(9600),
      );
      await expectLater(
        coordinator.run(
          space: space,
          clientId: owner.clientId,
          epoch: owner.epoch,
          isCurrent: () => true,
          requireFresh: true,
          maxPages: 4,
          refreshPermissions: () async => owner.permissions,
          request: (method, path, {body, bodyJson}) async {
            if (path == '/sync/group-pulls') {
              creates++;
              return copy(newStatus);
            }
            if (path.endsWith('/discard')) {
              return {'pull_id': owner.id, 'status': 'collected'};
            }
            if (path.endsWith('/pages')) {
              pages++;
              final index = List.generate(
                sample.pages.length,
                sample.token,
              ).indexOf(body!['page_token'] as String);
              return copy(sample.pages[index]);
            }
            return copy(creates == 0 ? sample.status : newStatus);
          },
        ),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.code,
            'code',
            'group_pending',
          ),
        ),
      );
      expect(pages, 4);
      expect(creates, 1);
      final saved = await store.read(space, id(9600));
      expect(saved, isNotNull);
      expect(saved!.installedUnits, 0);
      expect(syncObject(jsonDecode((await sync.state(space))!.cursorsJson)), {
        id(1): '2',
      });
    },
  );
}
