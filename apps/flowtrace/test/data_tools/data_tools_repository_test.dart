import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/data_tools_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import '../ledger/query_fixtures.dart';
import 'data_tools_models_test.dart' show documentJson;

void main() {
  late QueryFixture fixture;
  late DataToolsRepository repository;
  var current = true;
  final sent = <String>[];
  Future<Map<String, Object?>> Function(String path, String? body)? receive;

  DataToolsLease lease({int generation = 1}) => DataToolsLease(
    space: fixture.space,
    clientId: qid(90),
    epoch: qEpoch,
    generation: generation,
    isCurrent: () => current,
    request: (method, path, {body, bodyJson, bodyBytes, contentType}) async {
      if (bodyJson != null) sent.add(bodyJson);
      return receive!(
        path,
        bodyJson ?? (body == null ? null : jsonEncode(body)),
      );
    },
    download:
        (path, {method = 'GET', body, maxBytes = 10 * 1024 * 1024}) async =>
            Uint8List(0),
  );

  Map<String, Object?> previewFor(String raw) {
    final body = jsonDecode(raw) as Map;
    final document = body['document'] as Map;
    return {
      'batch_id': body['batch_id'],
      'content_hash': 'a' * 64,
      'can_apply': true,
      'fingerprint_scan_complete': true,
      'errors': [],
      'rows': [
        for (final row in document['rows'] as List)
          {
            'row': 1,
            'source_id': row['source_id'],
            'entity_id': const Uuid().v5(
              fixture.space.userId,
              '${document['source_namespace']}:${row['source_id']}',
            ),
            'status': 'new',
            'warning': null,
          },
      ],
    };
  }

  Map<String, Object?> appliedFor(String raw, {bool replayed = false}) {
    final preview = previewFor(raw);
    return {
      'batch_id': preview['batch_id'],
      'status': 'applied',
      'created': [for (final row in preview['rows'] as List) row['entity_id']],
      'duplicates': [],
      'commit_id': qb,
      'scope_revisions': {qBook: '1'},
      'replayed': replayed,
      'attachment_transfers': [],
    };
  }

  Map<String, Object?> remoteHistory(String id, String status) => {
    'batches': [
      {
        'batch_id': id,
        'status': status,
        'source_namespace': 'synthetic',
        'created_at': '2026-10-23T00:00:00+08:00',
        'created_count': 1,
        'duplicate_count': 0,
      },
    ],
    'limit': 1,
    'has_more': false,
    'next_cursor': null,
  };

  Future<StoredDataImport> appliedDraft() async {
    receive = (path, raw) async =>
        path.endsWith('/preview') ? previewFor(raw!) : appliedFor(raw!);
    final captured = lease();
    final draft = await repository.stage(
      captured,
      DataImportDocument.fromJson(documentJson()),
    );
    final preview = await repository.preview(captured, draft.batchId);
    await repository.apply(captured, draft.batchId, preview);
    return (await repository.read(fixture.space, draft.batchId))!;
  }

  setUp(() async {
    fixture = QueryFixture();
    await fixture.local.registerSpace(fixture.space);
    repository = DataToolsRepository(fixture.local);
    current = true;
    sent.clear();
    receive = null;
  });
  tearDown(() async {
    await fixture.db.close();
  });

  test(
    'timeout keeps durable frozen request and retry uses identical bytes and IDs',
    () async {
      var attempts = 0;
      receive = (path, raw) async {
        if (path.endsWith('/preview')) return previewFor(raw!);
        attempts++;
        if (attempts == 1) {
          throw const ApiFailure(
            'network_unavailable',
            'synthetic',
            offline: true,
          );
        }
        return appliedFor(raw!, replayed: true);
      };
      final captured = lease();
      final draft = await repository.stage(
        captured,
        DataImportDocument.fromJson(documentJson()),
      );
      final preview = await repository.preview(captured, draft.batchId);
      await expectLater(
        repository.apply(captured, draft.batchId, preview),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        (await repository.read(fixture.space, draft.batchId))!.phase,
        'uncertain',
      );
      repository = DataToolsRepository(fixture.local);
      final result = await repository.retryPending(captured, draft.batchId);
      expect(result.replayed, isTrue);
      expect(sent.toSet(), {draft.bodyJson});
      expect(
        (await repository.read(fixture.space, draft.batchId))!.phase,
        'applied',
      );
      expect((await repository.list(fixture.space)).length, 1);
    },
  );

  test('retry cannot promote an unconfirmed prepared request', () async {
    receive = (path, raw) async => previewFor(raw!);
    final captured = lease();
    final draft = await repository.stage(
      captured,
      DataImportDocument.fromJson(documentJson()),
    );
    await repository.preview(captured, draft.batchId);
    final sentBefore = sent.length;
    await expectLater(
      repository.retryPending(captured, draft.batchId),
      throwsA(
        isA<ApiFailure>().having(
          (e) => e.code,
          'code',
          'import_retry_unavailable',
        ),
      ),
    );
    expect(sent.length, sentBefore);
  });

  test(
    'late apply receipt cannot overwrite another tab confirmed undo',
    () async {
      final began = Completer<void>(), release = Completer<void>();
      receive = (path, raw) async {
        if (path.endsWith('/preview')) return previewFor(raw!);
        if (path.endsWith('/undo')) {
          final id = path.split('/')[3];
          return {'batch_id': id, 'status': 'undone', 'replayed': false};
        }
        began.complete();
        await release.future;
        return appliedFor(raw!);
      };
      final captured = lease();
      final draft = await repository.stage(
        captured,
        DataImportDocument.fromJson(documentJson()),
      );
      final preview = await repository.preview(captured, draft.batchId);
      final late = repository.apply(captured, draft.batchId, preview);
      await began.future;
      final secondTab = DataToolsRepository(fixture.local);
      await secondTab.undo(captured, draft.batchId);
      expect(
        (await secondTab.read(fixture.space, draft.batchId))!.phase,
        'undone',
      );
      release.complete();
      final result = await late;
      final retained = (await repository.read(fixture.space, draft.batchId))!;
      expect(retained.phase, 'undone');
      expect(
        result.status,
        'applied',
      ); // The formal wire receipt remains intact.
      expect(retained.bodyJson, draft.bodyJson);
      expect(retained.result!.toJson()['status'], 'applied');
    },
  );

  test(
    'remote undo is metadata GET only and preserves receipt, body and terminal phase',
    () async {
      final original = await appliedDraft();
      final receipt = jsonEncode(original.result!.toJson());
      var remoteStatus = 'undone';
      var reads = 0;
      receive = (path, raw) async {
        reads++;
        expect(raw, isNull);
        final uri = Uri.parse(path);
        expect(uri.path, '/data-tools/imports/history');
        expect(uri.queryParameters, {
          'limit': '1',
          'batch_id': original.batchId,
        });
        return remoteHistory(original.batchId, remoteStatus);
      };
      expect(
        await repository.refreshRemoteUndo(lease(), original.batchId),
        isTrue,
      );
      final changed = (await repository.read(fixture.space, original.batchId))!;
      expect(changed.phase, 'undone');
      expect(changed.bodyJson, original.bodyJson);
      expect(jsonEncode(changed.result!.toJson()), receipt);
      expect(
        await repository.refreshRemoteUndo(lease(), original.batchId),
        isFalse,
      );
      expect(reads, 1);
      remoteStatus = 'applied';
      expect(
        (await repository.remoteBatchStatus(lease(), original.batchId))!.status,
        'applied',
      );
      expect(
        await repository.refreshRemoteUndo(lease(), original.batchId),
        isFalse,
      );
      expect(
        (await repository.read(fixture.space, original.batchId))!.phase,
        'undone',
      );
    },
  );

  test(
    'remote undo rejects a mismatched batch and leaves missing metadata unchanged',
    () async {
      final original = await appliedDraft();
      receive = (path, raw) async => {
        'batches': [],
        'limit': 1,
        'has_more': false,
        'next_cursor': null,
      };
      expect(
        await repository.refreshRemoteUndo(lease(), original.batchId),
        isFalse,
      );
      receive = (path, raw) async => remoteHistory(qid(999), 'undone');
      await expectLater(
        repository.refreshRemoteUndo(lease(), original.batchId),
        throwsFormatException,
      );
      expect(
        (await repository.read(fixture.space, original.batchId))!.phase,
        'applied',
      );
    },
  );

  test(
    'remote undo cannot mutate old epoch/client or a late changed identity',
    () async {
      final original = await appliedDraft();
      var reads = 0;
      final captured = lease();
      for (final wrongEpoch in [true, false]) {
        final wrong = DataToolsLease(
          space: captured.space,
          clientId: wrongEpoch ? captured.clientId : qid(999),
          epoch: wrongEpoch ? qid(999) : captured.epoch,
          isCurrent: () => true,
          request: captured.request,
          download: captured.download,
        );
        receive = (path, raw) async {
          reads++;
          return remoteHistory(original.batchId, 'undone');
        };
        await expectLater(
          repository.refreshRemoteUndo(wrong, original.batchId),
          throwsA(
            isA<ApiFailure>().having(
              (e) => e.code,
              'code',
              'recovery_required',
            ),
          ),
        );
      }
      expect(reads, 0);
      receive = (path, raw) async {
        current = false;
        return remoteHistory(original.batchId, 'undone');
      };
      await expectLater(
        repository.refreshRemoteUndo(captured, original.batchId),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      expect(
        (await repository.read(fixture.space, original.batchId))!.phase,
        'applied',
      );
    },
  );

  test(
    'late server commit after identity change does not publish local success',
    () async {
      final began = Completer<void>(), release = Completer<void>();
      receive = (path, raw) async {
        if (path.endsWith('/preview')) return previewFor(raw!);
        began.complete();
        await release.future;
        return appliedFor(raw!);
      };
      final captured = lease();
      final draft = await repository.stage(
        captured,
        DataImportDocument.fromJson(documentJson()),
      );
      final preview = await repository.preview(captured, draft.batchId);
      final applying = repository.apply(captured, draft.batchId, preview);
      final failed = expectLater(
        applying,
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      await began.future;
      current = false;
      release.complete();
      await failed;
      final stored = (await repository.read(fixture.space, draft.batchId))!;
      expect(stored.phase, 'sending');
      expect(stored.result, isNull);
      expect(stored.bodyJson, draft.bodyJson);
    },
  );

  test('failed preview invalidates an older positive preview', () async {
    var allowed = true;
    receive = (path, raw) async {
      if (!path.endsWith('/preview')) throw StateError('must not apply');
      final response = previewFor(raw!);
      if (!allowed) {
        response['can_apply'] = false;
        response['errors'] = [
          {'row': 1, 'field': 'payload', 'code': 'source_modified'},
        ];
      }
      return response;
    };
    final captured = lease();
    final draft = await repository.stage(
      captured,
      DataImportDocument.fromJson(documentJson()),
    );
    final positive = await repository.preview(captured, draft.batchId);
    allowed = false;
    await repository.preview(captured, draft.batchId);
    expect(
      (await repository.read(fixture.space, draft.batchId))!.previewHash,
      isNull,
    );
    await expectLater(
      repository.apply(captured, draft.batchId, positive),
      throwsA(
        isA<ApiFailure>().having(
          (e) => e.code,
          'code',
          'import_preview_required',
        ),
      ),
    );
  });

  test(
    'old epoch record is retained and cannot be replayed into new recovery timeline',
    () async {
      final captured = lease();
      final draft = await repository.stage(
        captured,
        DataImportDocument.fromJson(documentJson()),
      );
      final restored = DataToolsLease(
        space: fixture.space,
        clientId: captured.clientId,
        epoch: qid(999),
        isCurrent: () => true,
        request: captured.request,
        download: captured.download,
      );
      await expectLater(
        repository.preview(restored, draft.batchId),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'recovery_required'),
        ),
      );
      expect(sent, isEmpty);
      expect(
        (await repository.read(fixture.space, draft.batchId))!.bodyJson,
        draft.bodyJson,
      );
    },
  );
}
