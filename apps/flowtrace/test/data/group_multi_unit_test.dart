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
import 'package:flowtrace/data/sync/group_store.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import 'group_protocol_test.dart' show rehash;
import 'group_store_test.dart' show copy, id, publication;

final class MultiGroupFixture {
  MultiGroupFixture(this.status, this.pages);

  final Map<String, Object?> status;
  final List<Map<String, Object?>> pages;

  GroupManifest get manifest => GroupManifest.fromStatus(status);
  String get requestId => manifest.requestId;
  String token(int index) => index == 0
      ? status['first_page_token'] as String
      : pages[index - 1]['next_page_token'] as String;
}

/// Split the existing two-commit publication into two independently installable
/// commit units. Each has its own index page and two manifest parts: commit
/// metadata first, then its data descriptor. Event bodies retain exact raw JSON.
MultiGroupFixture multiUnitFixture() {
  final original = publication();
  final status = copy(original.status);
  final sourceUnit = syncObject((original.pages[0]['units'] as List).single);
  final sourceCommits = original.pages[1]['commits'] as List;
  final indexes = <Map<String, Object?>>[];
  final bodies = <Map<String, Object?>>[];

  for (var unitIndex = 0; unitIndex < 2; unitIndex++) {
    final groupId = id(2000 + unitIndex);
    final data = copy(original.pages[2 + unitIndex])
      ..['group_id'] = groupId
      ..['page_index'] = 0;
    final fragment = syncObject((data['fragments'] as List).single)
      ..['commit_index'] = 0;
    rehash(data);

    final commit = copy(sourceCommits[unitIndex])
      ..['commit_index'] = 0
      ..['events_sha256'] = syncContentHash(fragment['events']);
    final part0 = copy(original.pages[1])
      ..['group_id'] = groupId
      ..['page_index'] = 0
      ..['commits'] = [commit]
      ..['data_pages'] = [];
    final part1 = copy(original.pages[1])
      ..['group_id'] = groupId
      ..['page_index'] = 1
      ..['commits'] = []
      ..['data_pages'] = [
        {'page_index': 0, 'item_count': 1, 'sha256': data['page_sha256']},
      ];
    rehash(part0);
    rehash(part1);

    final unit = copy(sourceUnit)
      ..['unit_index'] = unitIndex
      ..['group_id'] = groupId
      ..['kind'] = 'commit'
      ..['commit_count'] = 1
      ..['event_count'] = 1
      ..['end_cursors'] = {id(1): '${unitIndex + 1}'}
      ..['manifest_parts'] = [
        for (final part in [part0, part1])
          {
            'page_index': part['page_index'],
            'item_count': 1,
            'sha256': part['page_sha256'],
          },
      ];
    final hashedUnit = {...unit}..remove('manifest_sha256');
    unit['manifest_sha256'] = syncContentHash({
      'pull_id': status['pull_id'],
      ...hashedUnit,
    });
    final index = copy(original.pages[0])
      ..['page_index'] = unitIndex
      ..['units'] = [unit];
    rehash(index);
    indexes.add(index);
    bodies.addAll([part0, part1, data]);
  }

  final pages = [...indexes, ...bodies];
  String token(int index) =>
      'flowtrace-multi-unit-token-${index.toString().padLeft(3, '0')}';
  for (var i = 0; i < pages.length; i++) {
    pages[i]['next_page_token'] = i + 1 < pages.length ? token(i + 1) : null;
  }
  status['first_page_token'] = token(0);
  final manifest = syncObject(status['manifest'])
    ..['unit_count'] = 2
    ..['index_pages'] = [
      for (final index in indexes)
        {
          'page_index': index['page_index'],
          'item_count': 1,
          'sha256': index['page_sha256'],
        },
    ];
  status['manifest_sha256'] = syncContentHash(manifest);
  return MultiGroupFixture(status, pages);
}

void main() {
  late AppDatabase db;
  late LocalRepository repository;
  late SyncStore sync;
  late GroupPullStore groups;
  late MultiGroupFixture data;
  late DataSpace space;
  late Directory ownedDirectory;
  late File databaseFile;

  void attach() {
    db = AppDatabase(NativeDatabase(databaseFile));
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

  Future<void> receive(int first, int end) async {
    for (var i = first; i < end; i++) {
      await groups.receive(
        space,
        data.requestId,
        data.token(i),
        data.pages[i],
        isCurrent: () => true,
      );
    }
  }

  Future<void> install() => groups.installNext(
    space,
    data.requestId,
    authorizedManifest: data.manifest,
    permissionVersions: data.manifest.permissions,
    isCurrent: () => true,
  );

  Future<void> firstUnitRemains() async {
    expect(
      (await sync.state(space))!.cursorsJson,
      canonicalSyncJson({id(1): '1'}),
    );
    expect(await db.select(db.serverShadows).get(), hasLength(1));
    final entities = await db.select(db.localEntities).get();
    expect(entities, hasLength(1));
    expect(entities.single.entityId, id(1000));
    final receipts = await db.select(db.groupReceipts).get();
    expect(receipts, hasLength(1));
    expect(receipts.single.unitIndex, 0);
    expect(receipts.single.endCursorsJson, canonicalSyncJson({id(1): '1'}));
    expect((await groups.read(space, data.requestId))!.installedUnits, 1);
  }

  Future<void> checkAccounting() async {
    final pull = (await groups.read(space, data.requestId))!;
    final pageBytes = (await db.select(db.groupPages).get()).fold<int>(
      0,
      (sum, row) => sum + row.sizeBytes,
    );
    final receiptBytes = (await db.select(db.groupReceipts).get()).fold<int>(
      0,
      (sum, row) => sum + row.sizeBytes,
    );
    expect(
      pull.reservedBytes,
      utf8.encode(pull.intentJson).length +
          utf8.encode(pull.statusJson!).length +
          pageBytes +
          receiptBytes,
    );
  }

  Future<void> completed() async {
    expect(
      (await sync.state(space))!.cursorsJson,
      canonicalSyncJson({id(1): '2'}),
    );
    expect(await db.select(db.serverShadows).get(), hasLength(2));
    expect(await db.select(db.localEntities).get(), hasLength(2));
    final receipts = await (db.select(
      db.groupReceipts,
    )..orderBy([(row) => OrderingTerm.asc(row.unitIndex)])).get();
    expect(receipts.map((row) => row.unitIndex).toList(), [0, 1]);
    expect(await db.select(db.groupPages).get(), isEmpty);
    final pull = (await groups.read(space, data.requestId))!;
    expect(syncObject(jsonDecode(pull.receiveStateJson))['phase'], 'done');
    expect(pull.installedUnits, 2);
    await checkAccounting();
  }

  setUp(() async {
    data = multiUnitFixture();
    space = DataSpace(
      server: ServerAddress.parse('https://multi-unit.isolated.example'),
      serverInstanceId: data.manifest.instanceId,
      userId: data.manifest.userId,
    );
    ownedDirectory = await Directory.systemTemp.createTemp(
      'flowtrace-group-multi-',
    );
    databaseFile = File('${ownedDirectory.path}/client.sqlite');
    attach();
    await repository.registerSpace(space);
    await sync.configure(space, data.manifest.clientId, data.manifest.epoch);
  });

  tearDown(() async {
    await db.close();
    final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
    final target = await ownedDirectory.resolveSymbolicLinks();
    if (!target.startsWith(
      '$temporaryRoot${Platform.pathSeparator}flowtrace-group-multi-',
    )) {
      throw StateError('Unexpected multi-unit test cleanup target');
    }
    await ownedDirectory.delete(recursive: true);
  });

  test(
    'two index pages and split manifests allow a complete prefix before the last token',
    () async {
      expect(data.manifest.indexPages, hasLength(2));
      for (final page in data.pages.take(2)) {
        final index = GroupWirePage.parse(page);
        index.checkDescriptor(data.manifest.indexPages[index.index]);
        expect(
          GroupUnit.parse(
            data.manifest.id,
            (index.body['units'] as List).single,
          ).parts,
          hasLength(2),
        );
      }
      await start();
      for (var i = 0; i < 4; i++) {
        await receive(i, i + 1);
        await expectLater(install(), throwsStateError);
        expect(await db.select(db.serverShadows).get(), isEmpty);
        expect(await db.select(db.groupReceipts).get(), isEmpty);
        expect((await sync.state(space))!.cursorsJson, '{}');
      }
      await receive(4, 5);
      expect(data.pages[4]['next_page_token'], isNotNull);
      expect(await db.select(db.serverShadows).get(), isEmpty);
      await install();
      await firstUnitRemains();
      await checkAccounting();
      expect(
        (await groups.read(space, data.requestId))!.nextToken,
        data.token(5),
      );
      expect(await db.select(db.groupPages).get(), hasLength(2));

      await receive(5, 7);
      await expectLater(install(), throwsStateError);
      await firstUnitRemains();
      await receive(7, 8);
      await install();
      await completed();
      await install();
      await completed();
    },
  );

  test(
    'file SQLite reopen resumes from the committed first receipt and immutable original request',
    () async {
      await start();
      await receive(0, 5);
      await install();
      await firstUnitRemains();
      final firstReceipt = (await db.select(db.groupReceipts).get()).single;
      final original = (await groups.read(space, data.requestId))!;
      await db.close();
      attach();
      await firstUnitRemains();
      expect((await db.select(db.groupReceipts).get()).single, firstReceipt);
      final reopened = (await groups.read(space, data.requestId))!;
      expect(reopened.nextToken, original.nextToken);
      expect(reopened.reservedBytes, original.reservedBytes);
      expect(reopened.intentJson, original.intentJson);
      // The request's base remains empty even though installed prefix is now1.
      // Lost-response recovery must return that request before a new-base check.
      final retried = await groups.begin(
        space,
        data.requestId,
        clientId: data.manifest.clientId,
        epoch: data.manifest.epoch,
        cursors: {},
        isCurrent: () => true,
      );
      expect(retried.intentJson, original.intentJson);
      await groups.acceptReady(
        space,
        data.requestId,
        data.status,
        isCurrent: () => true,
      );
      await firstUnitRemains();
      await receive(5, 8);
      await install();
      await completed();
      final receipts = await (db.select(
        db.groupReceipts,
      )..where((row) => row.unitIndex.equals(0))).get();
      expect(receipts.single, firstReceipt);
    },
  );

  test(
    'late failure of the second receipt rolls back only unit two and retry keeps prefix one',
    () async {
      await start();
      await receive(0, 5);
      await install();
      await receive(5, 8);
      final firstReceipt = (await db.select(db.groupReceipts).get()).single;
      final before = (await groups.read(space, data.requestId))!;
      final staged = await db.select(db.groupPages).get();
      await db.customStatement(
        'CREATE TRIGGER isolated_second_receipt_failure BEFORE INSERT ON group_receipts '
        "WHEN NEW.unit_index=1 BEGIN SELECT RAISE(ABORT,'isolated second receipt failure'); END",
      );
      await expectLater(install(), throwsA(anything));
      await firstUnitRemains();
      expect((await db.select(db.groupReceipts).get()).single, firstReceipt);
      expect(await db.select(db.groupPages).get(), staged);
      final after = (await groups.read(space, data.requestId))!;
      expect(after.reservedBytes, before.reservedBytes);
      expect(after.receiveStateJson, before.receiveStateJson);
      expect(after.nextToken, before.nextToken);
      await checkAccounting();
      await db.customStatement('DROP TRIGGER isolated_second_receipt_failure');
      await install();
      await completed();
      expect(
        (await (db.select(
          db.groupReceipts,
        )..where((row) => row.unitIndex.equals(0))).get()).single,
        firstReceipt,
      );
    },
  );
}
