import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/group_store.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'group_store_test.dart' show id, publication;
import 'local_repository_test.dart' show testSpace;

final _space = testSpace(user: id(1), instance: id(2));

Future<Uint8List> seed(AppDatabase db, DataSpace space) async {
  final local = LocalRepository(db);
  await local.registerSpace(space);
  await SyncStore(local).configure(space, id(3), id(4));
  final bytes = Uint8List.fromList(
    List.generate(524291, (index) => index % 251),
  );
  await db.atomicWrite(() async {
    await db
        .into(db.stageImportSources)
        .insert(
          StageImportSourcesCompanion.insert(
            spaceId: space.id,
            stageId: id(10),
            clientId: id(3),
            epoch: id(4),
            originSessionId: id(5),
            format: 'flowtrace_json',
            fileName: '原始数据.json',
            sourceSha256: sha256.convert(bytes).toString(),
            createBodyJson: jsonEncode({
              'stage_id': id(10),
              'amount_minor': '9007199254740993',
            }),
            stateJson: '{"phase":"uploaded"}',
            expectedBytes: bytes.length,
            reservedBytes: bytes.length,
            createdAt: DateTime.utc(2026, 10, 23),
          ),
        );
    for (var index = 0; index < 2; index++) {
      final part = Uint8List.sublistView(
        bytes,
        index * 524288,
        index == 0 ? 524288 : bytes.length,
      );
      await db
          .into(db.stageImportChunks)
          .insert(
            StageImportChunksCompanion.insert(
              spaceId: space.id,
              stageId: id(10),
              chunkIndex: index,
              body: part,
              sha256: sha256.convert(part).toString(),
              sizeBytes: part.length,
            ),
          );
    }
    await db
        .into(db.stageImportCommands)
        .insert(
          StageImportCommandsCompanion.insert(
            spaceId: space.id,
            stageId: id(10),
            commandId: id(11),
            kind: 'apply',
            stageVersion: 1,
            bodyJson: '{"preview_hash":"${'a' * 64}"}',
            phase: 'uncertain',
            createdAt: DateTime.utc(2026, 10, 23),
          ),
        );
  });
  return bytes;
}

void main() {
  test(
    'recovery keeps independent exact source BLOBs without embedding large JSON',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final bytes = await seed(db, _space);
      await seed(db, testSpace(user: id(99), instance: id(2)));
      final sync = SyncStore(LocalRepository(db));
      await sync.requireRebuild(_space, 'epoch_changed');
      final backup = (await sync.recoveryBackups(_space)).single;
      final saved =
          (jsonDecode(backup.dataJson) as Map)['stage_imports'] as Map;
      expect(saved['sources'], hasLength(1));
      expect(saved['commands'], hasLength(1));
      expect(saved['chunks'], hasLength(2));
      expect(saved['chunk_backup_id'], backup.id);
      expect(backup.dataJson, contains('9007199254740993'));
      expect(utf8.encode(backup.dataJson).length, lessThan(16000));
      expect(backup.dataJson, isNot(contains(base64Encode(bytes))));
      var copies = await db.select(db.stageImportRecoveryChunks).get();
      copies.sort((left, right) => left.chunkIndex.compareTo(right.chunkIndex));
      expect(copies, hasLength(2));
      expect(copies.every((row) => row.backupId == backup.id), isTrue);
      expect(copies.expand((row) => row.body).toList(), orderedEquals(bytes));
      for (final row in copies) {
        expect(row.sha256, sha256.convert(row.body).toString());
        expect(row.sizeBytes, row.body.length);
      }
      // Simulate cleanup of this fixture's active source, after confirmation.
      await db.atomicWrite(() async {
        await (db.delete(
          db.stageImportChunks,
        )..where((row) => row.spaceId.equals(_space.id))).go();
      });
      copies = await db.select(db.stageImportRecoveryChunks).get();
      expect(copies.expand((row) => row.body).length, bytes.length);
      expect(
        (await db.select(db.stageImportChunks).get()).length,
        2,
      ); // Foreign source kept.
      expect((await sync.state(_space))!.status, 'recovery_required');
    },
  );

  test(
    'late backup BLOB copy failure rolls back checkpoint and preserves original source',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final bytes = await seed(db, _space);
      await db.customStatement(
        "CREATE TRIGGER isolated_source_backup_failure BEFORE INSERT ON stage_import_recovery_chunks "
        "WHEN NEW.chunk_index=1 BEGIN SELECT RAISE(ABORT,'isolated backup disk full'); END",
      );
      final sync = SyncStore(LocalRepository(db));
      await expectLater(
        sync.requireRebuild(_space, 'epoch_changed'),
        throwsA(anything),
      );
      expect(await sync.recoveryBackups(_space), isEmpty);
      expect(await db.select(db.stageImportRecoveryChunks).get(), isEmpty);
      expect((await sync.state(_space))!.status, 'active');
      final original = await db.select(db.stageImportChunks).get();
      expect(original.expand((row) => row.body).length, bytes.length);
      expect(await db.select(db.stageImportCommands).get(), hasLength(1));
    },
  );

  test('exact schema4 upgrade keeps frozen work and partial group pages', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flowtrace-test-schema5-',
    );
    final file = File('${directory.path}/client.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    try {
      final data = publication();
      final space = testSpace(
        user: data.manifest.userId,
        instance: data.manifest.instanceId,
      );
      final local = LocalRepository(db), sync = SyncStore(LocalRepository(db));
      await local.registerSpace(space);
      await sync.configure(space, data.manifest.clientId, data.manifest.epoch);
      await local.saveDraft(space, '原完整草稿😀');
      await local.writeSetting('schema4-sentinel', 'keep');
      final groups = GroupPullStore(sync);
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
      await groups.receive(
        space,
        data.requestId,
        data.token(0),
        data.pages[0],
        isCurrent: () => true,
      );
      final previous = (await groups.read(space, data.requestId))!.toJson();
      await db.close();
      final old = sqlite.sqlite3.open(file.path);
      old.execute(
        'DROP TABLE stage_import_recovery_chunks; DROP TABLE stage_import_commands; '
        'DROP TABLE stage_import_chunks; DROP TABLE stage_import_sources; PRAGMA user_version=4;',
      );
      old.close();
      db = AppDatabase(NativeDatabase(file));
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        5,
      );
      final reopened = LocalRepository(db);
      expect(await reopened.readSetting('schema4-sentinel'), 'keep');
      expect((await reopened.drafts(space)).single.body, '原完整草稿😀');
      expect(
        (await GroupPullStore(
          SyncStore(reopened),
        ).read(space, data.requestId))!.toJson(),
        previous,
      );
      expect(await db.select(db.groupPages).get(), hasLength(1));
      expect(await db.select(db.stageImportSources).get(), isEmpty);
      expect(await db.select(db.stageImportRecoveryChunks).get(), isEmpty);
    } finally {
      await db.close();
      // Only this newly-created temporary directory may be removed.
      final resolvedTarget = await directory.resolveSymbolicLinks();
      final resolvedTemp = await Directory.systemTemp.resolveSymbolicLinks();
      if (resolvedTarget.startsWith('$resolvedTemp${Platform.pathSeparator}') &&
          resolvedTarget
              .split(Platform.pathSeparator)
              .last
              .startsWith('flowtrace-test-schema5-')) {
        await directory.delete(recursive: true);
      }
    }
  });
}
