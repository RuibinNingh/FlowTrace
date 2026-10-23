import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';

import '../identity/identity_controller_test.dart' show MemoryVault;

final class DropOneReply extends http.BaseClient {
  final inner = http.Client();
  bool dropNextPush = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    if (dropNextPush &&
        request.url.path.endsWith('/sync/push') &&
        response.statusCode == 200) {
      dropNextPush = false;
      await response.stream.drain<void>();
      throw const SocketException(
        'Synthetic response loss after real server commit',
      );
    }
    return response;
  }

  @override
  void close() => inner.close();
}

/// Opt-in only, against synthetic credentials and a loopback development
/// service. These are real HTTP/database checks, not an Android UI test.
void main() {
  final file = Platform.environment['FLOWTRACE_SYNC_QA_FILE'];
  test(
    'two independent clients: lost receipt, conflict, explicit resolution and tombstone',
    () async {
      final config = jsonDecode(await File(file!).readAsString()) as Map;
      final uri = Uri.parse(config['server'] as String);
      if (uri.host != '127.0.0.1' || uri.port != 18080) {
        throw StateError('Live test requires isolated loopback service');
      }
      final db1 = AppDatabase(NativeDatabase.memory());
      final db2 = AppDatabase(NativeDatabase.memory());
      final repo1 = LocalRepository(db1), repo2 = LocalRepository(db2);
      final transport = DropOneReply();
      final one = IdentityController(
        repository: repo1,
        api: ApiClient(transport),
        vault: MemoryVault(),
        isWeb: false,
        allowLocalHttp: true,
        deviceName: 'sync-http-fixture-one',
      );
      final two = IdentityController(
        repository: repo2,
        api: ApiClient(http.Client()),
        vault: MemoryVault(),
        isWeb: false,
        allowLocalHttp: true,
        deviceName: 'sync-http-fixture-two',
      );
      final store1 = SyncStore(repo1), store2 = SyncStore(repo2);
      final engine1 = SyncEngine(store1), engine2 = SyncEngine(store2);
      final bookId = const Uuid().v4(), tagId = const Uuid().v4();
      Future<void> pushOne() => engine1.synchronize(SyncLease.capture(one));
      Future<void> pushTwo() => engine2.synchronize(SyncLease.capture(two));
      try {
        for (final identity in [one, two]) {
          await identity.configure(ServerAddress.parse(uri.toString()));
          await identity.signIn(
            username: config['username'] as String,
            password: config['password'] as String,
          );
          expect(identity.online, isTrue);
        }
        expect(one.clientId, isNot(two.clientId));
        final space1 = one.accountSpace!, space2 = two.accountSpace!;
        await repo1.registerSpace(space1);
        await repo2.registerSpace(space2);
        await repo1.saveEntityAndQueue(
          space1,
          QueuedCommand(
            operationId: const Uuid().v4(),
            scopeId: space1.userId,
            entityType: 'book',
            entityId: bookId,
            action: 'create',
            baseRevision: '0',
            payload: {
              'name': 'HTTP同步隔离验收',
              'currency': 'CNY',
              'timezone': 'Asia/Shanghai',
              'month_start_day': 1,
            },
          ),
        );
        await pushOne();
        expect(await repo1.pending(space1), isEmpty);
        QueuedCommand tag(String name, String action, String revision) =>
            QueuedCommand(
              operationId: const Uuid().v4(),
              scopeId: bookId,
              entityType: 'tag',
              entityId: tagId,
              action: action,
              baseRevision: revision,
              payload: action == 'delete'
                  ? {}
                  : {'name': name, 'color': '#2279d7'},
            );
        final create = tag('initial', 'create', '0');
        await repo1.saveEntityAndQueue(space1, create);
        transport.dropNextPush = true;
        await expectLater(
          pushOne(),
          throwsA(isA<ApiFailure>().having((e) => e.offline, 'offline', true)),
        );
        final frozen = (await repo1.pending(space1)).single.frozenRequestJson;
        await pushOne();
        final journal = await db1.select(db1.pendingOperations).get();
        final repeated = journal.singleWhere(
          (op) => op.operationId == create.operationId,
        );
        expect(repeated.attemptCount, 2);
        expect(repeated.frozenRequestJson, frozen);
        expect(repeated.appliedRevision, '1');
        await pushTwo();
        await repo1.saveEntityAndQueue(space1, tag('device A', 'update', '1'));
        final concurrent = tag('device B', 'update', '1');
        await repo2.saveEntityAndQueue(space2, concurrent);
        await pushOne();
        await pushTwo();
        final conflict = (await store2.conflicts(space2)).single;
        expect(conflict.code, 'revision_conflict');
        expect(jsonDecode(conflict.localJson)['name'], 'device B');
        final current = syncObject(jsonDecode(conflict.serverJson!));
        final serverEvent = decodeSyncEvent(current['event']);
        expect(serverEvent.revision, '2');
        await store2.resolveWithNewCommand(
          space2,
          concurrent.operationId,
          tag('device B', 'update', '2'),
        );
        await pushTwo();
        await pushOne();
        final rows = await db1.select(db1.localEntities).get();
        final tagRow = rows.singleWhere((row) => row.entityId == tagId);
        expect(tagRow.serverRevision, '3');
        expect(syncObject(jsonDecode(tagRow.dataJson))['payload'], {
          'name': 'device B',
          'color': '#2279d7',
        });
        await repo1.saveEntityAndQueue(space1, tag('', 'delete', '3'));
        await pushOne();
        await pushTwo();
        expect(
          (await db2.select(db2.localEntities).get())
              .singleWhere((row) => row.entityId == tagId)
              .deleted,
          isTrue,
        );
        await repo1.saveEntityAndQueue(
          space1,
          QueuedCommand(
            operationId: const Uuid().v4(),
            scopeId: bookId,
            entityType: 'book',
            entityId: bookId,
            action: 'delete',
            baseRevision: '1',
            payload: {},
          ),
        );
        await pushOne();
        expect(await repo1.pending(space1), isEmpty);
      } finally {
        // Only revoke the two sessions created here. Test entities use fresh
        // IDs; successful paths delete their tag/book through normal tombstones.
        if (one.online) await one.signOut();
        if (two.online) await two.signOut();
        one.dispose();
        two.dispose();
        await db1.close();
        await db2.close();
      }
    },
    skip: file == null
        ? 'Set FLOWTRACE_SYNC_QA_FILE to an ignored synthetic loopback fixture'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
