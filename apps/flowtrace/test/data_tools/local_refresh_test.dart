import 'dart:convert';

import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/data_tools_repository.dart';
import 'package:flowtrace/data/data_tools/local_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart';
import 'data_tools_models_test.dart' show documentJson;

void main() {
  late QueryFixture fixture;
  late DataToolsRepository repository;
  late DataToolsLease lease;
  late StoredDataImport confirmed;
  var current = true;

  Future<void> persist(StoredDataImport value) => fixture.local.writeSetting(
    'data_tools.v1.${fixture.space.id}.batch.${value.batchId}',
    jsonEncode(value.toJson()),
  );

  setUp(() async {
    fixture = QueryFixture();
    await fixture.local.registerSpace(fixture.space);
    repository = DataToolsRepository(fixture.local);
    current = true;
    lease = DataToolsLease(
      space: fixture.space,
      clientId: qid(90),
      epoch: qEpoch,
      isCurrent: () => current,
      request: (method, path, {body, bodyJson, bodyBytes, contentType}) async =>
          throw StateError('Local refresh must never repeat remote writes'),
      download: (path, {method = 'GET', body, maxBytes = 1024}) async =>
          throw StateError('Unexpected download'),
    );
    final draft = await repository.stage(
      lease,
      DataImportDocument.fromJson(documentJson()),
    );
    final receipt = DataImportApplied.fromJson({
      'batch_id': draft.batchId,
      'status': 'applied',
      'created': [qa],
      'duplicates': [],
      'commit_id': qb,
      'scope_revisions': {qBook: '1'},
      'replayed': false,
      'attachment_transfers': [],
    });
    confirmed = draft.withState('applied', result: receipt);
    await persist(confirmed);
  });
  tearDown(() => fixture.db.close());

  test(
    'failed local materialization is durable and reopens without reissuing import',
    () async {
      final original = confirmed.bodyJson;
      var calls = 0;
      Future<void> offline(DataImportApplied receipt, bool undo) async {
        calls++;
        expect(receipt.batchId, confirmed.batchId);
        expect(undo, isFalse);
        throw const ApiFailure('network_unavailable', 'offline');
      }

      expect(
        await DataToolsLocalRefresh(
          repository,
        ).reconcile(lease, adopt: offline),
        1,
      );
      final reopened = DataToolsRepository(fixture.local);
      final stored = (await reopened.read(fixture.space, confirmed.batchId))!;
      expect(stored.phase, 'applied');
      expect(stored.bodyJson, original);
      expect(stored.result!.toJson(), confirmed.result!.toJson());
      Future<void> online(DataImportApplied receipt, bool undo) async {
        calls++;
      }

      expect(
        await DataToolsLocalRefresh(reopened).reconcile(lease, adopt: online),
        0,
      );
      expect(calls, 2);
      expect(
        await DataToolsLocalRefresh(reopened).reconcile(lease, adopt: online),
        0,
      );
      expect(calls, 2);
      expect(
        (await reopened.read(fixture.space, confirmed.batchId))!.bodyJson,
        original,
      );
    },
  );

  test(
    'undo invalidates prior local marker while retaining original formal receipt',
    () async {
      final phases = <bool>[];
      Future<void> adopt(DataImportApplied receipt, bool undo) async {
        phases.add(undo);
        expect(receipt.toJson(), confirmed.result!.toJson());
      }

      await DataToolsLocalRefresh(
        repository,
      ).acknowledge(lease, confirmed.result!, undo: false, adopt: adopt);
      await persist(confirmed.withState('undone'));
      expect(
        await DataToolsLocalRefresh(repository).reconcile(lease, adopt: adopt),
        0,
      );
      expect(phases, [false, true]);
      expect(
        (await repository.read(fixture.space, confirmed.batchId))!.phase,
        'undone',
      );
    },
  );

  test(
    'late identity cannot acknowledge completion or suppress subsequent retry',
    () async {
      await expectLater(
        DataToolsLocalRefresh(repository).reconcile(
          lease,
          adopt: (_, _) async {
            current = false;
          },
        ),
        throwsA(isA<ApiFailure>()),
      );
      current = true;
      var calls = 0;
      expect(
        await DataToolsLocalRefresh(repository).reconcile(
          lease,
          adopt: (_, _) async {
            calls++;
          },
        ),
        0,
      );
      expect(calls, 1);
    },
  );

  test('concurrent phase change cannot publish stale applied marker', () async {
    expect(
      await DataToolsLocalRefresh(repository).reconcile(
        lease,
        adopt: (_, _) async {
          await persist(confirmed.withState('undone'));
        },
      ),
      1,
    );
    var reverse = false;
    expect(
      await DataToolsLocalRefresh(repository).reconcile(
        lease,
        adopt: (_, undo) async {
          reverse = undo;
        },
      ),
      0,
    );
    expect(reverse, isTrue);
  });

  test(
    'a replacement epoch or client cannot acknowledge historical receipts',
    () async {
      var calls = 0;
      Future<void> adopt(DataImportApplied receipt, bool undo) async {
        calls++;
      }

      for (final changedEpoch in [true, false]) {
        final replacement = DataToolsLease(
          space: lease.space,
          epoch: changedEpoch ? qid(94) : lease.epoch,
          clientId: changedEpoch ? lease.clientId : qid(95),
          isCurrent: () => true,
          request: lease.request,
          download: lease.download,
        );
        expect(
          await DataToolsLocalRefresh(
            repository,
          ).reconcile(replacement, adopt: adopt),
          0,
        );
        await expectLater(
          DataToolsLocalRefresh(repository).acknowledge(
            replacement,
            confirmed.result!,
            undo: false,
            adopt: adopt,
          ),
          throwsStateError,
        );
      }
      expect(calls, 0);
      expect(
        await DataToolsLocalRefresh(repository).reconcile(lease, adopt: adopt),
        0,
      );
      expect(calls, 1);
    },
  );
}
