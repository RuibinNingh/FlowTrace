import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/data_tools/stage_import_commands.dart';
import 'package:flowtrace/data/data_tools/stage_import_lease.dart';
import 'package:flowtrace/data/local/app_database.dart'
    hide StageImportCommands;
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';
import 'package:flowtrace/platform/windows/windows_runtime.dart';

import '../identity/identity_controller_test.dart' show MemoryVault;

/// Counts genuine TCP requests; no business response is substituted.
final class _Transport extends http.BaseClient {
  final inner = http.Client();
  int pushes = 0, uploads = 0, chunks = 0, applies = 0;
  final undoBodies = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final path = request.url.path;
    if (path.endsWith('/sync/push')) pushes++;
    if (path.contains('/attachments/uploads')) uploads++;
    if (path.contains('/chunks/')) chunks++;
    if (path.endsWith('/apply')) applies++;
    if (path.endsWith('/undo') && request is http.Request) {
      undoBodies.add(request.body);
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

Future<void> _until(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Owned stage followup condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<Map<String, Object?>> _postgresql(String fixture, String stage) async {
  final root = p.normalize(p.join(Directory.current.path, '..', '..'));
  final result = await Process.run(
    p.join(root, 'server', '.venv', 'Scripts', 'python.exe'),
    [
      p.join(root, 'tests', 'e2e', 'import_restore', 'stage_harness.py'),
      'verify',
      '--fixture',
      fixture,
      '--stage-id',
      stage,
    ],
  );
  if (result.exitCode != 0) {
    throw StateError(
      'Owned PostgreSQL followup proof failed; private evidence retained',
    );
  }
  final response = syncObject(jsonDecode(result.stdout as String));
  return syncObject(
    jsonDecode(await File(response['receipt'] as String).readAsString()),
  );
}

Future<Map<String, Object?>> _run(
  Map<String, Object?> fixture,
  String fixturePath,
  Map<String, Object?> original,
) async {
  final stageId = original['stage_id'] as String;
  final account = syncObject(fixture['account']);
  final targets = syncObject(fixture['native_targets']);
  final native = syncObject(syncObject(fixture['inputs'])['native']);
  final directory = Directory(
    p.join(fixture['run_directory'] as String, 'native-client'),
  );
  if (!await File(p.join(directory.path, 'local.sqlite')).exists()) {
    throw StateError('The original real native client SQLite is required');
  }
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(WindowsRuntime.channel, (call) async {
        if (call.method != 'dataDirectory') {
          throw PlatformException(code: 'unsupported_fixture_bridge');
        }
        return {'path': directory.path, 'leaseHeld': true};
      });
  final transport = _Transport();
  final db = AppDatabase(
    NativeDatabase(File(p.join(directory.path, 'local.sqlite'))),
  );
  final identity = IdentityController(
    repository: LocalRepository(db),
    api: ApiClient(transport),
    vault: MemoryVault(),
    isWeb: false,
    allowLocalHttp: true,
    deviceName: 'stage-owned-followup-new-session',
  );
  final app = AppController(db, identity: identity);
  try {
    await app.repository.writeSetting(
      'active_server',
      fixture['server'] as String,
    );
    await app.initialize();
    await _until(() async => !identity.busy && identity.server != null);
    await identity.signIn(
      username: account['username'] as String,
      password: account['password'] as String,
    );
    await _until(() async => app.canSync && !app.switchingSpace);
    final lease = StageImportLease.capture(identity);
    final commands = StageImportCommands(
      app.stageImports,
      refreshProjection: (captured) => app.syncEngine.pullLatest(
        captured.toSyncLease(),
        requireFreshGroup: true,
      ),
    );
    final space = lease.data.space;
    var record = (await app.stageImports.read(space, stageId))!;
    expect(record.batchId, original['batch_id']);
    expect(record.remote!.status, 'applied');
    expect(record.remote!.sourceReleased, isFalse);
    expect(record.binding['session_id'], isNot(identity.account!.sessionId));
    final originalCreate = record.stored.createBodyJson;
    final originalSourceSession = record.stored.originSessionId;
    final originalPending = (await app.repository.pending(space)).single;
    final frozen = originalPending.frozenRequestJson!;
    final pending = originalPending.toJson();
    final draft = (await app.repository.drafts(space)).single.body;
    final oldCommands = {
      for (final command in await db.select(db.stageImportCommands).get())
        command.commandId: command.bodyJson,
    };
    final before = await _postgresql(fixturePath, stageId);
    expect(before['batch_status'], 'applied');
    expect(before['actual_source_chunks'], 2);
    expect(before['actual_preview_rows'], 204);
    expect(before['source_release_audit'], isNull);
    final formal = before['formal_apply_metadata_sha256'];

    // Ordinary continuation remains origin-bound until the explicit action.
    await expectLater(
      commands.refresh(lease, stageId),
      throwsA(
        isA<ApiFailure>().having(
          (error) => error.code,
          'code',
          'stage_reauthorization_required',
        ),
      ),
    );
    final plan = await commands.inspectReauthorization(lease, stageId);
    expect(plan.metadata.status, 'applied');
    expect(plan.metadata.sourceSha256, original['source_sha256']);
    final previousVersion = record.version;
    record = await commands.confirmReauthorization(lease, plan);
    expect(record.version, previousVersion + 1);
    expect(record.batchId, original['batch_id']);
    expect(record.remote!.status, 'applied');
    expect(record.binding['session_id'], identity.account!.sessionId);
    expect(record.stored.originSessionId, originalSourceSession);
    expect(record.stored.createBodyJson, originalCreate);
    final rebound = await _postgresql(fixturePath, stageId);
    expect(rebound['formal_apply_metadata_sha256'], formal);

    record = await commands.releaseSource(lease, stageId);
    expect(record.remote!.sourceReleased, isTrue);
    final released = await _postgresql(fixturePath, stageId);
    expect(released['status'], 'applied');
    expect(released['received_bytes'], 614400);
    expect(released['received_chunks'], 2);
    expect(released['actual_source_chunks'], 0);
    expect(released['actual_preview_rows'], 0);
    expect(released['actual_requirement_rows'], 0);
    expect(released['formal_apply_metadata_sha256'], formal);
    final audit = syncObject(released['source_release_audit']);
    expect(audit['deleted_source_bytes'], 614400);
    expect(audit['deleted_source_chunks'], 2);
    expect(audit['deleted_preview_rows'], 204);
    expect(audit['deleted_requirement_rows'], greaterThan(0));
    expect(audit['reserved_bytes_released'], 614400);
    await expectLater(
      commands.rows(lease, stageId, version: record.version),
      throwsA(isA<ApiFailure>().having((error) => error.status, 'status', 410)),
    );
    // A successful desired state does not create another release audit.
    record = await commands.releaseSource(lease, stageId);
    final releaseReplay = await _postgresql(fixturePath, stageId);
    expect(releaseReplay['source_release_audit'], audit);
    expect(record.localReleased, isFalse);
    await app.stageImports.verifySource(record);

    record = await commands.undo(
      lease,
      stageId,
      version: record.version,
      batchId: record.batchId!,
    );
    await _until(() async {
      record = await commands.refresh(lease, stageId);
      if (record.remote!.status == 'undone') return true;
      final jobs = await commands.jobs(lease, stageId);
      if (jobs.jobs.any(
        (job) => {'failed', 'cancelled'}.contains(job.status),
      )) {
        throw StateError(
          'Real followup undo job failed; fixed metadata retained',
        );
      }
      return false;
    });
    final view = await app.ledger.read(space);
    expect(view.books.any((row) => row.id == targets['book']), isFalse);
    expect(view.bills.any((row) => row.scopeId == targets['book']), isFalse);
    expect(
      view.categories.any((row) => row.scopeId == targets['book']),
      isFalse,
    );
    expect(view.accounts.any((row) => row.id == targets['cash']), isFalse);
    final baseline = syncObject(fixture['csv_resources'])['cash_id'];
    expect(view.balances[baseline]!.value!.minor.toString(), '10000');
    final imageId = original['image_id'] as String;
    final metadata = await identity.authorizedRequest(
      'GET',
      '/attachments/$imageId',
    );
    expect(metadata['scope_id'], account['id']);
    final bytes = await identity.authorizedDownload(
      '/attachments/$imageId/content',
      maxBytes: 1024,
    );
    expect(sha256.convert(bytes).toString(), original['image_sha256']);
    final undone = await _postgresql(fixturePath, stageId);
    expect(undone['batch_status'], 'undone');
    expect(undone['imported_items'], 204);
    expect(undone['formal_apply_metadata_sha256'], formal);
    expect(undone['source_release_audit'], audit);
    expect(undone['undo_publication_chunks'] as int, greaterThan(1));
    expect(undone['native_cash_deleted'], isTrue);
    expect(
      undone['native_cash_balance_minor'],
      native['initial_balance_minor'],
    );
    expect(undone['ledger_entries'], 0);
    expect(undone['sync_push_receipts'], 2);
    expect(transport.undoBodies, hasLength(1));
    expect(transport.pushes, 0);
    expect(transport.chunks, 0);
    expect(transport.uploads, 0);
    expect(transport.applies, 0);

    // Separate explicit local action: remove actual active BLOBs after proof.
    expect(await db.select(db.stageImportChunks).get(), hasLength(2));
    final local = await app.stageImports.releaseLocalSource(lease, stageId);
    expect(local.localReleased, isTrue);
    expect(local.stored.reservedBytes, 0);
    expect(await db.select(db.stageImportChunks).get(), isEmpty);
    expect(local.stored.createBodyJson, originalCreate);
    expect(local.stored.originSessionId, originalSourceSession);
    expect(local.stored.sourceSha256, original['source_sha256']);
    final currentCommands = {
      for (final command in await db.select(db.stageImportCommands).get())
        command.commandId: command.bodyJson,
    };
    for (final previous in oldCommands.entries) {
      expect(currentCommands[previous.key], previous.value);
    }
    final remaining = (await app.repository.pending(space)).single;
    expect(remaining.frozenRequestJson, frozen);
    expect(remaining.toJson(), pending);
    expect((await app.repository.drafts(space)).single.body, draft);
    return {
      'verified': true,
      'scenario': 'native204-new-session-release-undo',
      'stage_id': stageId,
      'batch_id': record.batchId,
      'new_session_explicit_reauthorization': true,
      'released_source_before_undo': true,
      'undo_uses_formal_published_context': true,
      'source_retransmitted': false,
      'client_pushes': 0,
      'formal_apply_metadata_preserved': true,
      'source_release_audit_preserved': true,
      'received_historical_bytes': 614400,
      'image_returned_to_private_scope_and_hash_verified': true,
      'separate_explicit_local_release': true,
      'local_frozen_history_outbox_and_draft_preserved': true,
      'postgresql_before': before,
      'postgresql_released': released,
      'postgresql_undone': undone,
      'sandbox_directory_platform_bridge': true,
      'windows_runner_lease_tested': false,
      'system_secure_vault_tested': false,
      'normal_ui_tested': false,
      'capacity_performance_tested': false,
    };
  } finally {
    try {
      if (identity.online) await identity.signOut();
    } finally {
      app.dispose();
      transport.close();
      await db.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(WindowsRuntime.channel, null);
    }
  }
}

void main() {
  final source = Platform.environment['FLOWTRACE_STAGE_QA_FILE'];
  final mode = Platform.environment['FLOWTRACE_STAGE_FOLLOWUP_MODE'];
  if (source != null && mode == 'undo_release') {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
  }
  test(
    'real new session published reauthorization source release then undo with preserved history',
    () async {
      final file = File(source!);
      final originalConfig = await file.readAsBytes();
      final fixture = syncObject(jsonDecode(utf8.decode(originalConfig)));
      final root = await Directory(
        '../../work/flowtrace-stage/live',
      ).resolveSymbolicLinks();
      final run = await Directory(
        fixture['run_directory'] as String,
      ).resolveSymbolicLinks();
      final uri = Uri.parse(fixture['server'] as String);
      if (fixture['purpose'] !=
              'flowtrace-stage-tcp-normal-client-synthetic-v1' ||
          fixture['expected_head'] != '0016_backup_quarantine' ||
          fixture['genuine_main_stage_and_group'] != true ||
          !p.isWithin(root, run) ||
          p.dirname(await file.resolveSymbolicLinks()) != run ||
          file.uri.pathSegments.last != 'client-config.json' ||
          uri.scheme != 'http' ||
          uri.host != '127.0.0.1' ||
          uri.port != 18094 ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.path.isNotEmpty) {
        throw StateError('Existing owned head16 genuine fixture required');
      }
      final originalFile = File(fixture['client_receipt'] as String);
      final originalBytes = await originalFile.readAsBytes();
      final original = syncObject(jsonDecode(utf8.decode(originalBytes)));
      if (original['verified'] != true ||
          original['scenario'] != 'native204' ||
          p.dirname(await originalFile.resolveSymbolicLinks()) != run) {
        throw StateError('Original applied real client receipt required');
      }
      final receipt = File(p.join(run, 'followup-client-receipt.json'));
      if (await receipt.exists()) {
        throw StateError(
          'Prior followup evidence preserved; do not repeat financial scenario',
        );
      }
      final result = await _run(fixture, file.absolute.path, original);
      expect(await file.readAsBytes(), originalConfig);
      expect(await originalFile.readAsBytes(), originalBytes);
      await receipt.writeAsString(jsonEncode(result));
    },
    skip: source == null || mode != 'undo_release'
        ? 'Explicit existing stage fixture, undo_release mode and SDK window required'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
