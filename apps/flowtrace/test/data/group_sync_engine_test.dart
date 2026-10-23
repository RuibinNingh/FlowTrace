import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/data/data_tools/data_tools_repository.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import 'group_store_test.dart' show publication, copy, id;

void main() {
  for (final throughImport in [false, true]) {
    test(
      'negotiated pullLatest uses atomic groups from empty cursors and leaves frozen outbox untouched (import bridge: $throughImport)',
      () async {
        final data = publication();
        final space = DataSpace(
          server: ServerAddress.parse('https://isolated.example'),
          serverInstanceId: data.manifest.instanceId,
          userId: data.manifest.userId,
        );
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repository = LocalRepository(db);
        final store = SyncStore(repository);
        final engine = SyncEngine(store);
        await repository.registerSpace(space);
        await store.configure(
          space,
          data.manifest.clientId,
          data.manifest.epoch,
        );
        await repository.saveDraft(space, '保留的完整草稿');
        await repository.saveEntityAndQueue(
          space,
          QueuedCommand(
            operationId: id(9000),
            scopeId: id(1),
            entityType: 'account',
            entityId: id(1000),
            action: 'create',
            baseRevision: '0',
            payload: {'name': '待同步账户'},
          ),
        );
        final frozen = (await store.nextPush(space))!.body;
        final calls = <String>[];
        final lease = SyncLease(
          space: space,
          clientId: data.manifest.clientId,
          epoch: data.manifest.epoch,
          supportsGroupPull: true,
          isCurrent: () => true,
          request: (method, path, {body, bodyJson}) async {
            calls.add('$method $path');
            if (path == '/sync/scopes') {
              return {
                'sync_epoch': data.manifest.epoch,
                'control_version': '0',
                'scopes': [
                  {
                    'scope_id': id(1),
                    'kind': 'user',
                    'role': 'owner',
                    'revision': '2',
                    'permission_version': '0',
                  },
                ],
                'revoked_scope_ids': [],
                'requires_rebuild': false,
              };
            }
            if (path == '/sync/group-pulls' && method == 'POST') {
              final intent = syncObject(jsonDecode(bodyJson!));
              data.status['request_id'] = intent['request_id'];
              final manifest = syncObject(data.status['manifest'])
                ..['request_id'] = intent['request_id'];
              data.status['manifest_sha256'] = syncContentHash(manifest);
              return copy(data.status);
            }
            if (path ==
                '/sync/group-pulls/${data.manifest.id}?client_id=${data.manifest.clientId}') {
              return copy(data.status);
            }
            if (path == '/sync/group-pulls/${data.manifest.id}/pages') {
              final index = List.generate(
                data.pages.length,
                data.token,
              ).indexOf(body!['page_token'] as String);
              expect(index, greaterThanOrEqualTo(0));
              return copy(data.pages[index]);
            }
            if (path == '/sync/group-pulls/${data.manifest.id}/discard') {
              return {'pull_id': data.manifest.id, 'status': 'collected'};
            }
            throw StateError(
              'Unexpected route; group refresh must never push or use legacy pages',
            );
          },
        );
        final effective = throughImport
            ? DataToolsLease(
                space: lease.space,
                clientId: lease.clientId,
                epoch: lease.epoch,
                supportsGroupPull: lease.supportsGroupPull,
                isCurrent: lease.isCurrent,
                request:
                    (method, path, {body, bodyJson, bodyBytes, contentType}) =>
                        lease.send(
                          method,
                          path,
                          body: body,
                          bodyJson: bodyJson,
                        ),
                download:
                    (path, {method = 'GET', body, maxBytes = 1024}) async =>
                        throw StateError(
                          'A pull does not download attachments',
                        ),
              ).toSyncLease()
            : lease;
        await engine.pullLatest(effective);
        expect(
          (await store.state(space))!.cursorsJson,
          canonicalSyncJson({id(1): '2'}),
        );
        expect(await db.select(db.serverShadows).get(), hasLength(2));
        expect(await db.select(db.groupReceipts).get(), hasLength(1));
        final pending = (await repository.pending(space)).single;
        expect(pending.frozenRequestJson, frozen);
        expect(pending.attemptCount, 1);
        expect(pending.state, 'sending');
        expect((await repository.drafts(space)).single.body, '保留的完整草稿');
        expect(
          calls.where(
            (path) =>
                path.contains('/push') ||
                path.contains('/snapshots') ||
                path.contains('/sync/pull'),
          ),
          isEmpty,
        );
        expect(calls.where((path) => path.endsWith('/discard')), hasLength(1));
      },
    );
  }
}
