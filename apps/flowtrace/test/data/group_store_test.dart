import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/group_protocol.dart';
import 'package:flowtrace/data/sync/group_progress.dart';
import 'package:flowtrace/data/sync/group_store.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'group_protocol_test.dart' show fixture, rehash;

String id(int n) =>
    '00000000-0000-0000-0000-${n.toRadixString(16).padLeft(12, '0')}';
Map<String, Object?> copy(Object? value) =>
    syncObject(jsonDecode(canonicalSyncJson(value)));

final class GroupFixture {
  GroupFixture(this.status, this.pages);
  final Map<String, Object?> status;
  final List<Map<String, Object?>> pages;
  GroupManifest get manifest => GroupManifest.fromStatus(status);
  String get requestId => manifest.requestId;
  String token(int index) => index == 0
      ? status['first_page_token'] as String
      : pages[index - 1]['next_page_token'] as String;
}

GroupFixture publication({bool splitCommit = false}) {
  final raw = fixture();
  final status = copy(raw['status'])..['expires_at'] = '2099-01-01T00:00:00Z';
  final data0 = copy(raw['data_page']);
  final data1 = copy(raw['data_page']);
  data0['next_page_token'] = 'second-data-page-token-000000000001';
  data1['page_index'] = 1;
  final fragment = syncObject((data1['fragments'] as List).single)
    ..['commit_index'] = splitCommit ? 0 : 1
    ..['event_offset'] = splitCommit ? 1 : 0;
  final event = syncObject((fragment['events'] as List).single)
    ..['scope_revision'] = splitCommit ? '1' : '2'
    ..['event_index'] = splitCommit ? 1 : 0
    ..['entity_id'] = id(1001);
  syncObject(syncObject(event['data'])['payload'])['name'] = '第二个账户';
  rehash(data0);
  rehash(data1);
  final metadata = copy(raw['unit_manifest_page']);
  final first = (metadata['commits'] as List).single;
  metadata['commits'] = splitCommit
      ? [
          {
            ...syncObject(first),
            'event_count': 2,
            'events_sha256': syncContentHash([
              ...(syncObject((data0['fragments'] as List).single)['events']
                  as List),
              ...(fragment['events'] as List),
            ]),
          },
        ]
      : [
          first,
          {
            'commit_index': 1,
            'commit_id': id(11),
            'event_count': 1,
            'events_sha256': syncContentHash(fragment['events']),
          },
        ];
  metadata['data_pages'] = [
    for (final page in [data0, data1])
      {
        'page_index': page['page_index'],
        'item_count': 1,
        'sha256': page['page_sha256'],
      },
  ];
  rehash(metadata);
  final index = copy(raw['index_page']);
  final unit = syncObject((index['units'] as List).single)
    ..['kind'] = splitCommit ? 'commit' : 'publication'
    ..['commit_count'] = splitCommit ? 1 : 2
    ..['event_count'] = 2
    ..['end_cursors'] = {id(1): splitCommit ? '1' : '2'}
    ..['manifest_parts'] = [
      {
        'page_index': 0,
        'item_count': splitCommit ? 3 : 4,
        'sha256': metadata['page_sha256'],
      },
    ];
  final hashedUnit = {...unit}..remove('manifest_sha256');
  unit['manifest_sha256'] = syncContentHash({
    'pull_id': status['pull_id'],
    ...hashedUnit,
  });
  rehash(index);
  final manifest = syncObject(status['manifest'])
    ..['checkpoint'] = {id(1): splitCommit ? '1' : '2'}
    ..['index_pages'] = [
      {'page_index': 0, 'item_count': 1, 'sha256': index['page_sha256']},
    ];
  status['manifest_sha256'] = syncContentHash(manifest);
  return GroupFixture(status, [index, metadata, data0, data1]);
}

void main() {
  late AppDatabase db;
  late LocalRepository repository;
  late SyncStore sync;
  late GroupPullStore groups;
  late GroupFixture data;
  late DataSpace space;
  Directory? ownedDirectory;

  void attach(AppDatabase database) {
    db = database;
    repository = LocalRepository(db);
    sync = SyncStore(repository);
    groups = GroupPullStore(sync);
  }

  Future<void> start() async {
    await groups.begin(
      space,
      data.requestId,
      clientId: data.manifest.clientId,
      epoch: data.manifest.epoch,
      cursors: {},
      isCurrent: () => true,
    );
    await groups.acceptReady(
      space,
      data.requestId,
      data.status,
      isCurrent: () => true,
    );
  }

  Future<void> receiveAll() async {
    for (var i = 0; i < data.pages.length; i++) {
      await groups.receive(
        space,
        data.requestId,
        data.token(i),
        data.pages[i],
        isCurrent: () => true,
      );
    }
  }

  Future<void> install({bool Function()? isCurrent}) => groups.installNext(
    space,
    data.requestId,
    authorizedManifest: data.manifest,
    permissionVersions: data.manifest.permissions,
    isCurrent: isCurrent ?? () => true,
  );

  Future<void> unchanged() async {
    expect(await db.select(db.serverShadows).get(), isEmpty);
    expect(await db.select(db.groupReceipts).get(), isEmpty);
    expect((await sync.state(space))!.cursorsJson, '{}');
  }

  setUp(() async {
    ownedDirectory = null;
    data = publication();
    space = DataSpace(
      server: ServerAddress.parse('https://isolated.example'),
      serverInstanceId: data.manifest.instanceId,
      userId: data.manifest.userId,
    );
    attach(AppDatabase(NativeDatabase.memory()));
    await repository.registerSpace(space);
    await sync.configure(space, data.manifest.clientId, data.manifest.epoch);
  });
  tearDown(() async {
    await db.close();
    final directory = ownedDirectory;
    if (directory != null) {
      final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await directory.resolveSymbolicLinks();
      if (!target.startsWith(
        '$temporaryRoot${Platform.pathSeparator}flowtrace-group-v3-',
      )) {
        throw StateError('Unexpected test cleanup target');
      }
      await directory.delete(recursive: true);
    }
  });

  test(
    'receiving both commit pages has no projection or cursor effect; one install commits all',
    () async {
      await start();
      for (var i = 0; i < data.pages.length; i++) {
        await groups.receive(
          space,
          data.requestId,
          data.token(i),
          data.pages[i],
          isCurrent: () => true,
        );
        await unchanged();
        if (i < data.pages.length - 1) {
          await expectLater(install(), throwsStateError);
        }
      }
      await install();
      expect(await db.select(db.serverShadows).get(), hasLength(2));
      expect(await db.select(db.localEntities).get(), hasLength(2));
      expect(
        (await sync.state(space))!.cursorsJson,
        canonicalSyncJson({id(1): '2'}),
      );
      expect(await db.select(db.groupReceipts).get(), hasLength(1));
      expect(await db.select(db.groupPages).get(), isEmpty);
      await install();
      expect(await db.select(db.groupReceipts).get(), hasLength(1));
    },
  );

  test(
    'crash and schema3 upgrade preserve frozen intent, draft and partially received group',
    () async {
      await db.close();
      final directory = await Directory.systemTemp.createTemp(
        'flowtrace-group-v3-',
      );
      ownedDirectory = directory;
      final file = File('${directory.path}/client.sqlite');
      attach(AppDatabase(NativeDatabase(file)));
      await repository.registerSpace(space);
      await sync.configure(space, data.manifest.clientId, data.manifest.epoch);
      await repository.writeSetting('preserved', 'before schema4');
      await repository.saveDraft(space, '中文😀完整草稿');
      await repository.saveEntityAndQueue(
        space,
        QueuedCommand(
          operationId: id(5000),
          scopeId: id(1),
          entityType: 'account',
          entityId: id(1000),
          action: 'create',
          baseRevision: '0',
          payload: {'name': '本机待同步输入'},
        ),
      );
      final frozen = (await sync.nextPush(space))!.body;
      await db.close();
      // Reconstruct the exact schema3 baseline: the ten existing tables are
      // unchanged. Remove the later additive group/import tables only.
      final legacy = sqlite.sqlite3.open(file.path);
      legacy.execute(
        'DROP TABLE stage_import_recovery_chunks; '
        'DROP TABLE stage_import_commands; DROP TABLE stage_import_chunks; '
        'DROP TABLE stage_import_sources; '
        'DROP TABLE group_pages; DROP TABLE group_receipts; DROP TABLE group_pulls; '
        'PRAGMA user_version=3;',
      );
      legacy.close();
      attach(AppDatabase(NativeDatabase(file)));
      expect(await repository.readSetting('preserved'), 'before schema4');
      expect((await repository.drafts(space)).single.body, '中文😀完整草稿');
      expect(
        (await repository.pending(space)).single.frozenRequestJson,
        frozen,
      );
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        5,
      );
      await start();
      for (var i = 0; i < 3; i++) {
        await groups.receive(
          space,
          data.requestId,
          data.token(i),
          data.pages[i],
          isCurrent: () => true,
        );
      }
      final saved = await groups.read(space, data.requestId);
      await db.close();
      attach(AppDatabase(NativeDatabase(file)));
      expect(
        (await groups.read(space, data.requestId))!.nextToken,
        saved!.nextToken,
      );
      await unchanged();
      await groups.receive(
        space,
        data.requestId,
        data.token(3),
        data.pages[3],
        isCurrent: () => true,
      );
      await install();
      expect(
        (await repository.pending(space)).single.frozenRequestJson,
        frozen,
      );
      final local = await (db.select(
        db.localEntities,
      )..where((t) => t.entityId.equals(id(1000)))).getSingle();
      expect(syncObject(jsonDecode(local.dataJson))['name'], '本机待同步输入');
      expect((await repository.drafts(space)).single.body, '中文😀完整草稿');
    },
  );

  test(
    'lost response replay and wrong token or changed immutable body preserve exact staging',
    () async {
      await start();
      await groups.receive(
        space,
        data.requestId,
        data.token(0),
        data.pages[0],
        isCurrent: () => true,
      );
      final before = (await groups.read(space, data.requestId))!;
      await groups.receive(
        space,
        data.requestId,
        data.token(0),
        data.pages[0],
        isCurrent: () => true,
      );
      expect(
        (await groups.read(space, data.requestId))!.reservedBytes,
        before.reservedBytes,
      );
      final tampered = copy(data.pages[0])
        ..['next_page_token'] = 'another-next-token-000000000000';
      await expectLater(
        groups.receive(
          space,
          data.requestId,
          data.token(0),
          tampered,
          isCurrent: () => true,
        ),
        throwsFormatException,
      );
      await expectLater(
        groups.receive(
          space,
          data.requestId,
          'unknown-token-00000000000000000',
          data.pages[1],
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      expect((await groups.read(space, data.requestId))!.receivedPages, 1);
      await unchanged();
    },
  );

  test(
    'late SQL receipt failure rolls back both commits and cursor; retry installs one receipt',
    () async {
      await start();
      await receiveAll();
      await db.customStatement(
        "CREATE TRIGGER isolated_receipt_failure BEFORE INSERT ON group_receipts BEGIN SELECT RAISE(ABORT,'isolated disk full'); END",
      );
      await expectLater(install(), throwsA(anything));
      await unchanged();
      expect(await db.select(db.localEntities).get(), isEmpty);
      expect(await db.select(db.groupPages).get(), hasLength(4));
      await db.customStatement('DROP TRIGGER isolated_receipt_failure');
      await install();
      expect(await db.select(db.groupReceipts).get(), hasLength(1));
    },
  );

  test(
    'second commit identity loss rolls back the first; authorization change removes all controlled staging',
    () async {
      await start();
      await receiveAll();
      var checks = 0;
      await expectLater(
        install(isCurrent: () => ++checks < 3),
        throwsStateError,
      );
      await unchanged();
      await sync.invalidateReceiptEvidenceForScope(space, id(1));
      expect(await db.select(db.groupPages).get(), isEmpty);
      expect(await db.select(db.groupPulls).get(), isEmpty);
      expect(await db.select(db.groupReceipts).get(), isEmpty);
      await expectLater(install(), throwsStateError);
    },
  );

  test(
    'storage exhaustion does not advance receive token or reserve nonexistent bytes',
    () async {
      await start();
      final before = (await groups.read(space, data.requestId))!;
      final bytes = GroupWirePage.parse(data.pages[0]).byteCount;
      final limited = GroupPullStore(
        sync,
        maxBytes: before.reservedBytes + bytes - 1,
      );
      await expectLater(
        limited.receive(
          space,
          data.requestId,
          data.token(0),
          data.pages[0],
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      expect(
        (await groups.read(space, data.requestId))!.reservedBytes,
        before.reservedBytes,
      );
      expect(
        (await groups.read(space, data.requestId))!.nextToken,
        before.nextToken,
      );
      expect(await db.select(db.groupPages).get(), isEmpty);
      await unchanged();
    },
  );

  test(
    'corrupt final persisted page cannot leave a partially installed publication',
    () async {
      await start();
      await receiveAll();
      await (db.update(db.groupPages)..where((t) => t.ordinal.equals(3))).write(
        GroupPagesCompanion(bodyJson: Value(canonicalSyncJson(data.pages[2]))),
      );
      await expectLater(install(), throwsA(anything));
      await unchanged();
      expect(await db.select(db.localEntities).get(), isEmpty);
    },
  );

  test(
    'one commit can span transport pages without becoming two commits',
    () async {
      data = publication(splitCommit: true);
      await start();
      for (var i = 0; i < 3; i++) {
        await groups.receive(
          space,
          data.requestId,
          data.token(i),
          data.pages[i],
          isCurrent: () => true,
        );
      }
      await expectLater(install(), throwsStateError);
      await unchanged();
      await groups.receive(
        space,
        data.requestId,
        data.token(3),
        data.pages[3],
        isCurrent: () => true,
      );
      await install();
      expect(await db.select(db.serverShadows).get(), hasLength(2));
      expect(
        (await sync.state(space))!.cursorsJson,
        canonicalSyncJson({id(1): '1'}),
      );
    },
  );

  test(
    'empty pull installs only unchanged zero scopes and is replayable',
    () async {
      final status = copy(data.status);
      final manifest = syncObject(status['manifest'])
        ..['unit_count'] = 0
        ..['index_pages'] = []
        ..['checkpoint'] = {id(1): '0'};
      status['first_page_token'] = null;
      status['manifest_sha256'] = syncContentHash(manifest);
      data = GroupFixture(status, []);
      await start();
      await install();
      await install();
      expect(
        (await sync.state(space))!.cursorsJson,
        canonicalSyncJson({id(1): '0'}),
      );
      expect(await db.select(db.localEntities).get(), isEmpty);
      expect(await db.select(db.groupReceipts).get(), isEmpty);
    },
  );

  test(
    'fresh authority, cursor CAS and expiry are required even when all bytes are present',
    () async {
      await start();
      await receiveAll();
      await expectLater(
        groups.installNext(
          space,
          data.requestId,
          authorizedManifest: data.manifest,
          permissionVersions: {id(1): '1'},
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      await unchanged();
      await expectLater(
        groups.installNext(
          space,
          data.requestId,
          authorizedManifest: data.manifest,
          permissionVersions: data.manifest.permissions,
          isCurrent: () => true,
          now: DateTime.utc(2100),
        ),
        throwsStateError,
      );
      await unchanged();
      await sync.applyPullPage(
        space,
        data.manifest.epoch,
        [],
        finalPage: true,
        checkpoint: {id(1): '1'},
      );
      await expectLater(install(), throwsStateError);
      expect(await db.select(db.serverShadows).get(), isEmpty);
      expect(await db.select(db.groupReceipts).get(), isEmpty);
      expect(
        (await sync.state(space))!.cursorsJson,
        canonicalSyncJson({id(1): '1'}),
      );
    },
  );

  test(
    'a full staging budget can atomically replace verified pages with smaller receipts',
    () async {
      await start();
      await receiveAll();
      final full = (await groups.read(space, data.requestId))!;
      final limited = GroupPullStore(sync, maxBytes: full.reservedBytes);
      await limited.installNext(
        space,
        data.requestId,
        authorizedManifest: data.manifest,
        permissionVersions: data.manifest.permissions,
        isCurrent: () => true,
      );
      expect(
        (await groups.read(space, data.requestId))!.reservedBytes,
        lessThan(full.reservedBytes),
      );
      expect(await db.select(db.serverShadows).get(), hasLength(2));
      expect(await db.select(db.groupPages).get(), isEmpty);
    },
  );

  test(
    'two abandoned requests release actual bytes and slots while original requests cannot revive',
    () async {
      await start();
      await receiveAll();
      final before = (await groups.read(space, data.requestId))!;
      await groups.begin(
        space,
        id(6000),
        clientId: data.manifest.clientId,
        epoch: data.manifest.epoch,
        cursors: {},
        isCurrent: () => true,
      );
      await expectLater(
        groups.begin(
          space,
          id(6001),
          clientId: data.manifest.clientId,
          epoch: data.manifest.epoch,
          cursors: {},
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      await groups.abandon(space, data.requestId, isCurrent: () => true);
      await groups.abandon(space, data.requestId, isCurrent: () => true);
      await groups.abandon(space, id(6000), isCurrent: () => true);
      expect(await db.select(db.groupPages).get(), isEmpty);
      expect(
        (await groups.read(space, data.requestId))!.reservedBytes,
        lessThan(before.reservedBytes),
      );
      await expectLater(
        groups.acceptReady(
          space,
          data.requestId,
          data.status,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      await expectLater(
        groups.begin(
          space,
          data.requestId,
          clientId: data.manifest.clientId,
          epoch: data.manifest.epoch,
          cursors: {},
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      await groups.begin(
        space,
        id(6001),
        clientId: data.manifest.clientId,
        epoch: data.manifest.epoch,
        cursors: {},
        isCurrent: () => true,
      );
      await unchanged();
    },
  );

  test(
    'a self-consistent hash chain cannot advance cursor beyond its actual events',
    () async {
      final unit = syncObject((data.pages.first['units'] as List).single)
        ..['end_cursors'] = {id(1): '3'};
      final unsigned = {...unit}..remove('manifest_sha256');
      unit['manifest_sha256'] = syncContentHash({
        'pull_id': data.manifest.id,
        ...unsigned,
      });
      rehash(data.pages.first);
      final manifest = syncObject(data.status['manifest'])
        ..['checkpoint'] = {id(1): '3'}
        ..['index_pages'] = [
          {
            'page_index': 0,
            'item_count': 1,
            'sha256': data.pages.first['page_sha256'],
          },
        ];
      data.status['manifest_sha256'] = syncContentHash(manifest);
      await start();
      await receiveAll();
      await expectLater(install(), throwsFormatException);
      await unchanged();
      expect(await db.select(db.localEntities).get(), isEmpty);
    },
  );

  test(
    'planning handle and exact request survive before a ready manifest arrives',
    () async {
      await groups.begin(
        space,
        data.requestId,
        clientId: data.manifest.clientId,
        epoch: data.manifest.epoch,
        cursors: {},
        isCurrent: () => true,
      );
      final pending = copy(data.status)
        ..['status'] = 'planning'
        ..['progress_code'] = 'planning'
        ..['next_step_token'] = 'next-planning-token-000000000000'
        ..['manifest'] = null
        ..['manifest_sha256'] = null
        ..['first_page_token'] = null;
      await groups.rememberProgress(
        space,
        data.requestId,
        GroupProgress.parse(pending),
        isCurrent: () => true,
      );
      final saved = (await groups.read(space, data.requestId))!;
      expect(saved.pullId, data.manifest.id);
      expect(saved.statusJson, isNull);
      expect(
        syncObject(jsonDecode(saved.receiveStateJson))['step_token'],
        pending['next_step_token'],
      );
      await groups.acceptReady(
        space,
        data.requestId,
        data.status,
        isCurrent: () => true,
      );
      await receiveAll();
      await install();
      expect(await db.select(db.serverShadows).get(), hasLength(2));
    },
  );
}
