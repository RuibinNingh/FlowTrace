import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/data_tools_repository.dart';
import 'package:flowtrace/data/data_tools/local_refresh.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import '../data_tools/data_tools_models_test.dart' show documentJson;
import '../ledger/query_fixtures.dart' show qUser, qBook, qEpoch, qid;
import 'local_repository_test.dart' show testSpace;
import 'snapshot_test.dart'
    show instance, nextEpoch, nextClient, item, statusFor;
import 'sync_store_test.dart' show scope;

final _space = testSpace(user: qUser, instance: instance);

Future<Map<String, String>> _seed(AppDatabase db) async {
  final local = LocalRepository(db),
      data = DataToolsRepository(LocalRepository(db));
  await local.registerSpace(_space);
  await SyncStore(local).configure(_space, qid(5), qEpoch);
  final lease = DataToolsLease(
    space: _space,
    clientId: qid(5),
    epoch: qEpoch,
    isCurrent: () => true,
    request: (method, path, {body, bodyJson, bodyBytes, contentType}) async =>
        throw StateError('No remote import during backup'),
    download: (path, {method = 'GET', body, maxBytes = 1024}) async =>
        throw StateError('No download during backup'),
  );
  final uncertain = (await data.stage(
    lease,
    DataImportDocument.fromJson(documentJson()),
  )).withState('uncertain', previewHash: 'a' * 64);
  final confirmed = await data.stage(
    lease,
    DataImportDocument.fromJson(documentJson(amount: '123')),
  );
  final receipt = DataImportApplied.fromJson({
    'batch_id': confirmed.batchId,
    'status': 'applied',
    'created': [qid(100)],
    'duplicates': [],
    'commit_id': qid(101),
    'scope_revisions': {qBook: '1'},
    'replayed': false,
    'attachment_transfers': [],
  });
  final applied = confirmed.withState('applied', result: receipt);
  final values = {
    'data_tools.v1.${_space.id}.batch.${uncertain.batchId}': jsonEncode(
      uncertain.toJson(),
    ),
    'data_tools.v1.${_space.id}.batch.${applied.batchId}': jsonEncode(
      applied.toJson(),
    ),
  };
  for (final pair in values.entries) {
    await local.writeSetting(pair.key, pair.value);
  }
  await DataToolsLocalRefresh(
    data,
  ).acknowledge(lease, receipt, undo: false, adopt: (_, _) async {});
  final marker = 'data_tools.local_refresh.v1.${_space.id}.${applied.batchId}';
  values[marker] = (await local.readSetting(marker))!;
  await local.writeSetting(
    'data_tools.v1.foreign-space.batch.${qid(9)}',
    'foreign evidence',
  );
  await local.writeSetting(
    'data_tools.local_refresh.v1.foreign-space.${qid(9)}',
    'foreign marker',
  );
  await local.writeSetting('unrelated.secret', 'must not enter backup');
  return values;
}

void main() {
  test(
    'recovery snapshot contains exact frozen imports, formal receipt and local marker for this space only',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final expected = await _seed(db),
            store = SyncStore(LocalRepository(db));
        await store.requireRebuild(_space, 'epoch_changed');
        final saved =
            jsonDecode((await store.recoveryBackups(_space)).single.dataJson)
                as Map;
        final rows = saved['data_tools'] as List;
        expect({
          for (final row in rows) (row as Map)['key']: row['value'],
        }, expected);
        expect(rows, hasLength(3));
        expect(saved.toString(), isNot(contains('foreign evidence')));
        expect(saved.toString(), isNot(contains('must not enter backup')));
        for (final pair in expected.entries) {
          expect(await LocalRepository(db).readSetting(pair.key), pair.value);
        }
        expect(saved.toString(), contains('9007199254740993'));
      } finally {
        await db.close();
      }
    },
  );

  test(
    'disk reopen and new-client epoch recovery retain old import evidence without replay or blob adoption',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'flowtrace-data-tools-recovery-',
      );
      final file = File('${directory.path}/isolated.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      try {
        final expected = await _seed(db);
        var store = SyncStore(LocalRepository(db));
        await store.requireRebuild(_space, 'epoch_changed');
        final originalBackup = (await store.recoveryBackups(
          _space,
        )).single.dataJson;
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        final local = LocalRepository(db);
        store = SyncStore(local);
        expect(
          (await store.recoveryBackups(_space)).single.dataJson,
          originalBackup,
        );
        final pages = <List<Object?>>[
          [item('new server projection')],
        ];
        final manifest = SnapshotManifest.fromStatus(
          statusFor(pages, syncEpoch: nextEpoch),
        );
        await store.stageSnapshotPage(
          _space,
          manifest,
          0,
          pages.single,
          syncContentHash(pages.single),
        );
        await store.installSnapshot(
          _space,
          manifest,
          clientId: nextClient,
          permissionVersions: {scope: '1'},
          allowRecovery: true,
        );
        var remote = 0, adopted = 0;
        final lease = DataToolsLease(
          space: _space,
          clientId: nextClient,
          epoch: nextEpoch,
          isCurrent: () => true,
          request:
              (method, path, {body, bodyJson, bodyBytes, contentType}) async {
                remote++;
                throw StateError('Old request must not be replayed');
              },
          download: (path, {method = 'GET', body, maxBytes = 1024}) async {
            remote++;
            throw StateError('Old request must not download');
          },
        );
        final data = DataToolsRepository(local);
        expect(
          await DataToolsLocalRefresh(data).reconcile(
            lease,
            adopt: (_, _) async {
              adopted++;
            },
          ),
          0,
        );
        for (final record in await data.list(_space)) {
          await expectLater(
            data.retryPending(lease, record.batchId),
            throwsA(
              isA<ApiFailure>().having(
                (error) => error.code,
                'code',
                'recovery_required',
              ),
            ),
          );
        }
        expect(remote, 0);
        expect(adopted, 0);
        expect(await store.nextPush(_space), isNull);
        for (final pair in expected.entries) {
          expect(await local.readSetting(pair.key), pair.value);
        }
        expect((await store.state(_space))!.epoch, nextEpoch);
        expect(
          (await store.recoveryBackups(_space)).single.dataJson,
          originalBackup,
        );
      } finally {
        await db.close();
        if (await directory.parent.resolveSymbolicLinks() !=
                await Directory.systemTemp.resolveSymbolicLinks() ||
            !directory.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('flowtrace-data-tools-recovery-')) {
          throw StateError('Unexpected recovery fixture directory');
        }
        await directory.delete(recursive: true);
      }
    },
  );
}
