import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/group_engine.dart';
import 'package:flowtrace/data/sync/group_protocol.dart';
import 'package:flowtrace/data/sync/group_store.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import 'group_multi_unit_test.dart' show multiUnitFixture;
import 'group_store_test.dart' show copy, id, publication;

Matcher failure(String code) =>
    isA<ApiFailure>().having((error) => error.code, 'code', code);

Matcher collectedPending() => isA<ApiFailure>()
    .having((error) => error.code, 'code', 'group_pending')
    .having((error) => error.message, 'message', '旧同步缓存已回收，再次同步获取最新资料。');

final class _Server {
  _Server(this.ready, this.pages);
  final Map<String, Object?> ready;
  final List<Map<String, Object?>> pages;
  final calls =
      <
        ({String method, String path, Map<String, Object?>? body, String? json})
      >[];
  final createBytes = <String>[];
  final discarded = <String>[];
  int remainingSteps = 0;
  bool created = false;
  bool collected = false;
  bool loseCreate = false;
  bool loseDiscard = false;
  int? failPage;
  String? statusError;
  String? currentClient;
  bool listOtherDevice = false;

  String get handle => ready['pull_id'] as String;
  String get requestId => ready['request_id'] as String;
  String get clientId => syncObject(ready['manifest'])['client_id'] as String;
  String get epoch => ready['sync_epoch'] as String;
  String token(int index) => index == 0
      ? ready['first_page_token'] as String
      : pages[index - 1]['next_page_token'] as String;

  Map<String, Object?> progress() {
    if (remainingSteps == 0) return copy(ready);
    return copy(ready)
      ..['status'] = 'materializing'
      ..['progress_code'] = 'materializing'
      ..['next_step_token'] =
          'group-step-token-${remainingSteps.toString().padLeft(4, '0')}'
      ..['manifest'] = null
      ..['manifest_sha256'] = null
      ..['first_page_token'] = null;
  }

  Map<String, Object?> summary({bool other = false}) => {
    'pull_id': other ? id(8000) : handle,
    'request_id': other ? id(8001) : requestId,
    'client_id': other ? id(8002) : clientId,
    'sync_epoch': epoch,
    'status': remainingSteps == 0 ? 'ready' : 'materializing',
    'expires_at': ready['expires_at'],
  };

  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? bodyJson,
  }) async {
    calls.add((
      method: method,
      path: path,
      body: body == null ? null : copy(body),
      json: bodyJson,
    ));
    expect(path, startsWith('/sync/group-pulls'));
    if (path == '/sync/group-pulls' && method == 'POST') {
      expect(body, isNull);
      expect(bodyJson, isNotNull);
      final intent = syncObject(jsonDecode(bodyJson!));
      expect(intent['request_id'], requestId);
      expect(intent['client_id'], clientId);
      expect(intent['sync_epoch'], epoch);
      if (createBytes.isNotEmpty) expect(bodyJson, createBytes.first);
      createBytes.add(bodyJson);
      created = true;
      if (loseCreate) {
        loseCreate = false;
        throw const ApiFailure('offline', '测试丢失创建回复。', offline: true);
      }
      return progress();
    }
    if (path == '/sync/group-pulls' && method == 'GET') {
      return {
        'pulls': [
          if (listOtherDevice) summary(other: true),
          if (created && !collected) summary(),
        ],
      };
    }
    if (path == '/sync/group-pulls/$handle/discard') {
      expect(method, 'POST');
      expect(body, {'client_id': currentClient ?? clientId});
      discarded.add(handle);
      collected = true;
      if (loseDiscard) {
        loseDiscard = false;
        throw const ApiFailure('offline', '测试丢失回收回复。', offline: true);
      }
      return {'pull_id': handle, 'status': 'collected'};
    }
    if (path == '/sync/group-pulls/$handle?client_id=$clientId') {
      expect(method, 'GET');
      if (statusError != null) throw ApiFailure.server(statusError!, 410);
      if (collected) throw ApiFailure.server('group_pull_collected', 410);
      return progress();
    }
    if (path == '/sync/group-pulls/$handle/steps') {
      expect(method, 'POST');
      expect(body, {
        'client_id': clientId,
        'step_token': progress()['next_step_token'],
      });
      remainingSteps--;
      return progress();
    }
    if (path == '/sync/group-pulls/$handle/pages') {
      expect(method, 'POST');
      expect(body?['client_id'], clientId);
      final index = List.generate(
        pages.length,
        token,
      ).indexOf(body?['page_token'] as String);
      expect(index, greaterThanOrEqualTo(0));
      if (failPage == index) {
        failPage = null;
        throw const ApiFailure('offline', '测试读取页离线。', offline: true);
      }
      return copy(pages[index]);
    }
    throw StateError('Unexpected group-only test route');
  }
}

void main() {
  late AppDatabase db;
  late LocalRepository repository;
  late SyncStore sync;
  late GroupPullStore store;
  late GroupPullCoordinator coordinator;
  late _Server server;
  late DataSpace space;
  late Directory ownedDirectory;
  late File databaseFile;
  late String frozen;
  bool isCurrent = true;
  int refreshCount = 0;

  void attach() {
    db = AppDatabase(NativeDatabase(databaseFile));
    repository = LocalRepository(db);
    sync = SyncStore(repository);
    store = GroupPullStore(sync);
    coordinator = GroupPullCoordinator(
      store,
      newRequestId: () => server.requestId,
    );
  }

  Future<void> run({
    int maxSteps = 64,
    int maxPages = 128,
    Future<Map<String, String>> Function()? refresh,
  }) => coordinator.run(
    space: space,
    clientId: server.clientId,
    epoch: server.epoch,
    isCurrent: () => isCurrent,
    request: server.request,
    refreshPermissions:
        refresh ??
        () async {
          refreshCount++;
          return GroupManifest.fromStatus(server.ready).permissions;
        },
    maxSteps: maxSteps,
    maxPages: maxPages,
  );

  Future<void> expectFrozen() async {
    final pending = await repository.pending(space);
    expect(pending, hasLength(1));
    expect(pending.single.frozenRequestJson, frozen);
    expect(pending.single.state, 'sending');
    expect(pending.single.attemptCount, 1);
    expect((await repository.drafts(space)).single.body, '原完整草稿😀');
    expect(server.calls.any((call) => call.path.contains('/push')), isFalse);
  }

  Future<void> expectDone() async {
    final pull = (await store.read(space, server.requestId))!;
    expect(syncObject(jsonDecode(pull.receiveStateJson)), {
      'phase': 'done',
      'server_collected': true,
    });
    expect(await db.select(db.groupPages).get(), isEmpty);
    expect(await db.select(db.groupReceipts).get(), isNotEmpty);
    expect(server.collected, isTrue);
    expect(await store.listCleanup(space), isEmpty);
    await expectFrozen();
  }

  setUp(() async {
    isCurrent = true;
    refreshCount = 0;
    final data = publication();
    server = _Server(data.status, data.pages);
    space = DataSpace(
      server: ServerAddress.parse('https://group-engine.isolated.example'),
      serverInstanceId: data.manifest.instanceId,
      userId: data.manifest.userId,
    );
    ownedDirectory = await Directory.systemTemp.createTemp(
      'flowtrace-group-engine-',
    );
    databaseFile = File('${ownedDirectory.path}/client.sqlite');
    attach();
    await repository.registerSpace(space);
    await sync.configure(space, server.clientId, server.epoch);
    await repository.saveDraft(space, '原完整草稿😀');
    await repository.saveEntityAndQueue(
      space,
      QueuedCommand(
        operationId: id(9900),
        scopeId: id(1),
        entityType: 'account',
        entityId: id(1000),
        action: 'create',
        baseRevision: '0',
        payload: {'name': '原金融输入'},
      ),
    );
    frozen = (await sync.nextPush(space))!.body;
  });

  tearDown(() async {
    await db.close();
    final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
    final target = await ownedDirectory.resolveSymbolicLinks();
    if (!target.startsWith(
      '$temporaryRoot${Platform.pathSeparator}flowtrace-group-engine-',
    )) {
      throw StateError('Unexpected group engine test cleanup target');
    }
    await ownedDirectory.delete(recursive: true);
  });

  test(
    'complete finite-step chain uses frozen intent, fresh authority and explicit remote discard',
    () async {
      server.remainingSteps = 2;
      await run();
      expect(server.createBytes, hasLength(1));
      expect(
        server.calls.where((call) => call.path.endsWith('/steps')),
        hasLength(2),
      );
      expect(
        server.calls.where((call) => call.path.endsWith('/pages')),
        hasLength(4),
      );
      expect(server.discarded, [server.handle]);
      expect(refreshCount, 1);
      expect(
        (await store.read(space, server.requestId))!.intentJson,
        server.createBytes.single,
      );
      expect(
        (await sync.state(space))!.cursorsJson,
        canonicalSyncJson({id(1): '2'}),
      );
      await expectDone();
    },
  );

  test(
    'step and page budgets report group_pending and next run GETs the saved handle',
    () async {
      server.remainingSteps = 3;
      await expectLater(run(maxSteps: 1), throwsA(failure('group_pending')));
      final saved = (await store.read(space, server.requestId))!;
      expect(saved.pullId, server.handle);
      expect(
        syncObject(jsonDecode(saved.receiveStateJson))['step_token'],
        server.progress()['next_step_token'],
      );
      expect(await db.select(db.groupPages).get(), isEmpty);
      await expectLater(run(maxPages: 2), throwsA(failure('group_pending')));
      expect(server.createBytes, hasLength(1));
      expect(await db.select(db.groupPages).get(), hasLength(2));
      expect(
        (await store.read(space, server.requestId))!.nextToken,
        server.token(2),
      );
      await run();
      expect(server.createBytes, hasLength(1));
      expect(
        server.calls.where((call) => call.path.endsWith('/steps')),
        hasLength(3),
      );
      await expectDone();
    },
  );

  test(
    'lost create reply and file reopen recover only exact request client epoch from safe listing',
    () async {
      server.loseCreate = true;
      server.listOtherDevice = true;
      await expectLater(run(), throwsA(failure('offline')));
      expect((await store.read(space, server.requestId))!.pullId, isNull);
      final originalIntent = (await store.read(
        space,
        server.requestId,
      ))!.intentJson;
      await db.close();
      attach();
      await run();
      expect(server.createBytes, [originalIntent]);
      expect(
        server.calls.any(
          (call) => call.method == 'GET' && call.path == '/sync/group-pulls',
        ),
        isTrue,
      );
      expect(server.discarded, [server.handle]);
      expect(server.calls.any((call) => call.path.contains(id(8000))), isFalse);
      await expectDone();
    },
  );

  test(
    'cold reopen continues partial pages without replaying create or publishing local finance',
    () async {
      await expectLater(run(maxPages: 3), throwsA(failure('group_pending')));
      final saved = (await store.read(space, server.requestId))!;
      final pagesBefore = await db.select(db.groupPages).get();
      await db.close();
      attach();
      expect(await db.select(db.groupPages).get(), pagesBefore);
      expect(
        (await store.read(space, server.requestId))!.nextToken,
        saved.nextToken,
      );
      await run();
      expect(server.createBytes, hasLength(1));
      expect(
        server.calls.where((call) => call.path.endsWith('/pages')),
        hasLength(4),
      );
      await expectDone();
    },
  );

  test(
    'first complete unit installs before the remaining page budget and second resumes later',
    () async {
      final multi = multiUnitFixture();
      server = _Server(multi.status, multi.pages);
      await expectLater(run(maxPages: 5), throwsA(failure('group_pending')));
      expect(
        (await sync.state(space))!.cursorsJson,
        canonicalSyncJson({id(1): '1'}),
      );
      expect((await store.read(space, server.requestId))!.installedUnits, 1);
      expect(await db.select(db.groupReceipts).get(), hasLength(1));
      expect(refreshCount, 1);
      expect(server.discarded, isEmpty);
      await run();
      expect(refreshCount, 2);
      expect(await db.select(db.groupReceipts).get(), hasLength(2));
      await expectDone();
    },
  );

  test(
    'offline page request preserves exact persisted pages and token for retry',
    () async {
      server.failPage = 2;
      await expectLater(run(), throwsA(failure('offline')));
      expect(await db.select(db.groupPages).get(), hasLength(2));
      final pull = (await store.read(space, server.requestId))!;
      expect(pull.nextToken, server.token(2));
      expect(server.discarded, isEmpty);
      await run();
      expect(server.createBytes, hasLength(1));
      expect(
        server.calls.where(
          (call) =>
              call.path.endsWith('/pages') &&
              call.body?['page_token'] == server.token(2),
        ),
        hasLength(2),
      );
      await expectDone();
    },
  );

  test(
    'permission cache-clear plus offline cleanup survives reopen in a UUID-only marker',
    () async {
      server.loseDiscard = true;
      await expectLater(
        run(
          refresh: () async {
            await sync.clearGroupCache(space);
            return {};
          },
        ),
        throwsA(failure('offline')),
      );
      expect(await store.read(space, server.requestId), isNull);
      expect((await sync.state(space))!.cursorsJson, '{}');
      expect(await db.select(db.serverShadows).get(), isEmpty);
      final bindings = await store.listCleanup(space);
      expect(bindings, hasLength(1));
      expect(bindings.single.pullId, server.handle);
      final markers = await db.select(db.appSettings).get();
      final marker = markers.singleWhere(
        (row) => row.key.startsWith('sync.group-cleanup.v1.'),
      );
      expect(syncObject(jsonDecode(marker.value)).keys.toSet(), {
        'space_id',
        'request_id',
        'client_id',
        'sync_epoch',
        'pull_id',
      });
      expect(marker.value, isNot(contains('scope')));
      await db.close();
      attach();
      await expectLater(run(), throwsA(collectedPending()));
      expect(server.discarded, [server.handle, server.handle]);
      expect(server.createBytes, hasLength(1));
      expect(await store.listCleanup(space), isEmpty);
      expect(await db.select(db.serverShadows).get(), isEmpty);
      await expectFrozen();
    },
  );

  test(
    'permission version mismatch discards and abandons instead of installing a stale unit',
    () async {
      await expectLater(
        run(refresh: () async => {id(1): '1'}),
        throwsA(failure('permission_changed')),
      );
      final pull = (await store.read(space, server.requestId))!;
      expect(syncObject(jsonDecode(pull.receiveStateJson)), {
        'phase': 'abandoned',
        'server_collected': true,
      });
      expect(pull.statusJson, isNull);
      expect(await db.select(db.groupPages).get(), isEmpty);
      expect(await db.select(db.serverShadows).get(), isEmpty);
      expect((await sync.state(space))!.cursorsJson, '{}');
      expect(server.discarded, [server.handle]);
      await expectFrozen();
    },
  );

  test(
    'origin failure retains an abandoned handle until offline cleanup succeeds without a new create',
    () async {
      await expectLater(run(maxPages: 1), throwsA(failure('group_pending')));
      server.statusError = 'group_origin_changed';
      server.loseDiscard = true;
      await expectLater(run(), throwsA(failure('offline')));
      final pull = (await store.read(space, server.requestId))!;
      expect(
        syncObject(jsonDecode(pull.receiveStateJson))['phase'],
        'abandoned',
      );
      expect(pull.pullId, server.handle);
      expect(server.createBytes, hasLength(1));
      // A different UUID would be needed for a future new pull. This invocation
      // only completes the old cleanup and does not reuse its request tombstone.
      await expectLater(run(), throwsA(collectedPending()));
      expect(
        syncObject(
          jsonDecode(
            (await store.read(space, server.requestId))!.receiveStateJson,
          ),
        )['server_collected'],
        isTrue,
      );
      expect(server.createBytes, hasLength(1));
      await expectFrozen();
    },
  );

  test(
    'lost discard reply retries the locally done original handle and retains receipts',
    () async {
      server.loseDiscard = true;
      await expectLater(run(), throwsA(failure('offline')));
      final original = (await db.select(db.groupReceipts).get()).single;
      expect(
        syncObject(
          jsonDecode(
            (await store.read(space, server.requestId))!.receiveStateJson,
          ),
        )['phase'],
        'done',
      );
      await db.close();
      attach();
      await expectLater(run(), throwsA(collectedPending()));
      expect((await db.select(db.groupReceipts).get()).single, original);
      expect(server.createBytes, hasLength(1));
      expect(server.discarded, [server.handle, server.handle]);
      await expectDone();
    },
  );

  test(
    'identity change after a response prevents progress application and financial replay',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      final future = coordinator.run(
        space: space,
        clientId: server.clientId,
        epoch: server.epoch,
        isCurrent: () => isCurrent,
        request: (method, path, {body, bodyJson}) async {
          final result = await server.request(
            method,
            path,
            body: body,
            bodyJson: bodyJson,
          );
          started.complete();
          await release.future;
          return result;
        },
        refreshPermissions: () async =>
            GroupManifest.fromStatus(server.ready).permissions,
      );
      final assertion = expectLater(
        future,
        throwsA(failure('identity_changed')),
      );
      await started.future;
      isCurrent = false;
      release.complete();
      await assertion;
      expect((await store.read(space, server.requestId))!.pullId, isNull);
      expect(await db.select(db.groupPages).get(), isEmpty);
      expect(server.discarded, isEmpty);
      await expectFrozen();
    },
  );

  test(
    'cleanup marker survives a new client epoch and uses the current client only for collection',
    () async {
      await expectLater(run(maxPages: 1), throwsA(failure('group_pending')));
      final pull = (await store.read(space, server.requestId))!;
      await store.stageCleanup(space, pull, isCurrent: () => true);
      await sync.clearGroupCache(space);
      final nextClient = id(9010);
      final nextEpoch = id(9011);
      // Represent an already reviewed/rebuilt active identity; this test does not
      // pretend to perform the separate snapshot recovery protocol.
      await db.customStatement('UPDATE sync_states SET client_id=?,epoch=?', [
        nextClient,
        nextEpoch,
      ]);
      server.currentClient = nextClient;
      await expectLater(
        coordinator.run(
          space: space,
          clientId: nextClient,
          epoch: nextEpoch,
          isCurrent: () => true,
          request: server.request,
          refreshPermissions: () async => {},
        ),
        throwsA(collectedPending()),
      );
      expect(server.discarded, [server.handle]);
      expect(await store.listCleanup(space), isEmpty);
      expect(server.createBytes, hasLength(1));
      await expectFrozen();
    },
  );

  test(
    'cleanup markers are bounded and never silently evict an unfinished old handle',
    () async {
      for (var i = 0; i < 33; i++) {
        final requestId = id(10000 + i);
        await store.begin(
          space,
          requestId,
          clientId: server.clientId,
          epoch: server.epoch,
          cursors: {},
          isCurrent: () => true,
        );
        await store.rememberHandle(
          space,
          requestId,
          pullId: id(11000 + i),
          clientId: server.clientId,
          epoch: server.epoch,
          isCurrent: () => true,
        );
        final pull = (await store.read(space, requestId))!;
        if (i == 32) {
          await expectLater(
            store.stageCleanup(space, pull, isCurrent: () => true),
            throwsStateError,
          );
        } else {
          await store.stageCleanup(space, pull, isCurrent: () => true);
          await store.stageCleanup(
            space,
            pull,
            isCurrent: () => true,
          ); // Exact replay is one marker.
        }
        await store.abandon(space, requestId, isCurrent: () => true);
      }
      final bindings = await store.listCleanup(space);
      expect(bindings, hasLength(32));
      expect(bindings.map((row) => row.requestId), contains(id(10000)));
      expect(bindings.map((row) => row.requestId), isNot(contains(id(10032))));
      await expectFrozen();
    },
  );

  test(
    'trusted call budgets cannot exceed the finite step and page limits',
    () async {
      await expectLater(run(maxSteps: 65), throwsArgumentError);
      await expectLater(run(maxPages: 129), throwsArgumentError);
      await expectLater(run(maxSteps: -1), throwsArgumentError);
      expect(server.calls, isEmpty);
    },
  );
}
