import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/attachments/attachment_transfer.dart';
import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/stage_import_commands.dart';
import 'package:flowtrace/data/data_tools/stage_import_coordinator.dart';
import 'package:flowtrace/data/data_tools/stage_import_draft.dart';
import 'package:flowtrace/data/data_tools/stage_import_lease.dart';
import 'package:flowtrace/data/data_tools/stage_import_requirements.dart';
import 'package:flowtrace/data/data_tools/stage_import_source_books.dart';
import 'package:flowtrace/data/data_tools/stage_import_store.dart';
import 'package:flowtrace/data/ledger/ledger_reporting.dart';
import 'package:flowtrace/data/local/app_database.dart'
    hide StageImportCommands;
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';
import 'package:flowtrace/platform/windows/windows_runtime.dart';

import '../identity/identity_controller_test.dart' show MemoryVault;

final class _Probe {
  bool offline = false, dropChunk = true, dropApply = false;
  int chunkDrops = 0, applyDrops = 0, pushes = 0;
  final chunkRequests = <String, int>{};
  final applyBodies = <String>[];
  final publicationIds = <String>{};
}

/// Discards actual successful TCP replies, never fabricates business responses.
final class _LossTransport extends http.BaseClient {
  _LossTransport(this.probe);
  final _Probe probe;
  final inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (probe.offline) throw const SocketException('Synthetic stage offline');
    final path = request.url.path;
    if (path.endsWith('/sync/push')) probe.pushes++;
    if (path.contains('/chunks/')) {
      probe.chunkRequests.update(path, (n) => n + 1, ifAbsent: () => 1);
    }
    if (path.endsWith('/apply') && request is http.Request) {
      probe.applyBodies.add(request.body);
    }
    final response = await inner.send(request);
    final group = path.contains('/sync/group-pulls');
    final loseChunk = probe.dropChunk && path.endsWith('/chunks/0');
    final loseApply = probe.dropApply && path.endsWith('/apply');
    if (response.statusCode != 200 || !(group || loseChunk || loseApply)) {
      return response;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final piece in response.stream) {
      if (bytes.length + piece.length > 1024 * 1024) {
        throw StateError('Production JSON response exceeded unchanged 1MiB');
      }
      bytes.add(piece);
    }
    final body = bytes.takeBytes();
    if (group) {
      final value = syncObject(jsonDecode(utf8.decode(body)));
      if (value['kind'] == 'index') {
        for (final raw in value['units'] as List) {
          final unit = syncObject(raw);
          if (unit['kind'] == 'publication') {
            probe.publicationIds.add(unit['group_id'] as String);
          }
        }
      }
    }
    if (loseChunk) {
      probe.dropChunk = false;
      probe.chunkDrops++;
      throw const SocketException('Synthetic successful chunk reply loss');
    }
    if (loseApply) {
      probe.dropApply = false;
      probe.applyDrops++;
      throw const SocketException('Synthetic successful apply reply loss');
    }
    return http.StreamedResponse(
      Stream.value(body),
      response.statusCode,
      headers: response.headers,
      contentLength: body.length,
      request: request,
    );
  }

  @override
  void close() => inner.close();
}

Future<void> _until(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Owned stage condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

final class _Client {
  _Client(this.directory, this.vault, this.probe) {
    db = AppDatabase(
      NativeDatabase(File(p.join(directory.path, 'local.sqlite'))),
    );
    transport = _LossTransport(probe);
    identity = IdentityController(
      repository: LocalRepository(db),
      api: ApiClient(transport),
      vault: vault,
      isWeb: false,
      allowLocalHttp: true,
      deviceName: 'stage-owned-live-client',
    );
    app = AppController(db, identity: identity);
  }
  final Directory directory;
  final MemoryVault vault;
  final _Probe probe;
  late final AppDatabase db;
  late final _LossTransport transport;
  late final IdentityController identity;
  late final AppController app;
  bool closed = false;
  StageImportLease get lease => StageImportLease.capture(identity);
  StageImportCommands get commands => StageImportCommands(
    app.stageImports,
    refreshProjection: (captured) => app.syncEngine.pullLatest(
      captured.toSyncLease(),
      requireFreshGroup: true,
    ),
  );
  Future<void> open(Map<String, Object?> fixture, {bool signIn = false}) async {
    await app.repository.writeSetting(
      'active_server',
      fixture['server'] as String,
    );
    await app.initialize();
    await _until(() async => !identity.busy && identity.server != null);
    if (signIn) {
      final account = syncObject(fixture['account']);
      await identity.signIn(
        username: account['username'] as String,
        password: account['password'] as String,
      );
    }
    await _until(
      () async => app.space?.verified == true && !app.switchingSpace,
    );
    if (!probe.offline) {
      await _until(() async => app.canSync);
      expect(identity.serverIdentity!.supportsGroupPull, isTrue);
      expect(identity.serverIdentity!.supportsStagedImports, isTrue);
      await app.syncEngine.refreshScopes(SyncLease.capture(identity));
    }
  }

  Future<void> reconnect(Map<String, Object?> fixture) async {
    probe.offline = false;
    await identity.configure(app.space!.server);
    await _until(() async => app.canSync);
    expect(identity.serverIdentity!.supportsStagedImports, isTrue);
  }

  Future<void> close({bool logout = false}) async {
    if (closed) return;
    try {
      if (logout) {
        probe.offline = false;
        if (!identity.online && identity.account != null) {
          await identity.configure(app.space!.server);
        }
        if (identity.online) await identity.signOut();
      }
    } finally {
      closed = true;
      app.dispose();
      transport.close();
      await db.close();
    }
  }
}

Future<Map<String, Object?>> _postgresql(
  String fixtureFile,
  String stageId,
) async {
  final root = Directory(
    p.normalize(p.join(Directory.current.path, '..', '..')),
  );
  final result = await Process.run(
    p.join(root.path, 'server', '.venv', 'Scripts', 'python.exe'),
    [
      p.join(root.path, 'tests', 'e2e', 'import_restore', 'stage_harness.py'),
      'verify',
      '--fixture',
      fixtureFile,
      '--stage-id',
      stageId,
    ],
  );
  if (result.exitCode != 0) {
    throw StateError(
      'Isolated PostgreSQL probe failed; private evidence retained',
    );
  }
  final response = syncObject(jsonDecode(result.stdout as String));
  return syncObject(
    jsonDecode(await File(response['receipt'] as String).readAsString()),
  );
}

Future<StageImportRecord> _phase(
  _Client client,
  String id,
  Set<String> statuses,
) async {
  StageImportRecord? result;
  await _until(() async {
    result = await client.commands.refresh(client.lease, id);
    if (statuses.contains(result!.remote!.status)) return true;
    final metadata = await client.commands.jobs(client.lease, id);
    if (metadata.jobs.any(
      (job) => {'failed', 'cancelled'}.contains(job.status),
    )) {
      throw StateError('Real stage job failed; inspect fixed job metadata');
    }
    return false;
  });
  return result!;
}

Future<StageImportRequirementsReader> _requirements(
  _Client client,
  StageImportRecord record,
  List<StageImportRequirement> items,
) async {
  final reader = StageImportRequirementsReader(client.app.stageImports, record);
  while (!reader.complete) {
    items.addAll((await reader.next(client.lease)).items);
  }
  return reader;
}

Future<Map<String, Object?>> _native(
  Map<String, Object?> fixture,
  String fixtureFile,
) async {
  final inputs = syncObject(fixture['inputs']);
  final native = syncObject(inputs['native']);
  final image = syncObject(inputs['image']);
  final ids = syncObject(inputs['source_ids']);
  final targets = syncObject(fixture['native_targets']);
  final account = syncObject(fixture['account']);
  final directory = Directory(
    p.join(fixture['run_directory'] as String, 'native-client'),
  );
  if (await directory.exists()) {
    throw StateError(
      'Prior native client evidence preserved; use a new fixture',
    );
  }
  await directory.create();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(WindowsRuntime.channel, (call) async {
        if (call.method != 'dataDirectory') {
          throw PlatformException(code: 'unsupported_fixture_bridge');
        }
        return {'path': directory.path, 'leaseHeld': true};
      });
  final probe = _Probe(), vault = MemoryVault();
  var client = _Client(directory, vault, probe);
  try {
    await client.open(fixture, signIn: true);
    final oldSession = client.identity.account!.sessionId;
    final oldClient = client.identity.clientId;
    final space = client.app.space!;
    await client.app.syncEngine.pullLatest(
      SyncLease.capture(client.identity),
      requireFreshGroup: true,
    );
    final command = QueuedCommand(
      operationId: const Uuid().v4(),
      scopeId: account['book_id'] as String,
      entityType: 'category',
      entityId: const Uuid().v4(),
      action: 'create',
      baseRevision: '0',
      payload: {
        'name': '未发送的原冻结分类',
        'kind': 'expense',
        'icon': 'food',
        'parent_id': null,
        'sort_order': 0,
      },
    );
    await client.app.repository.saveEntityAndQueue(space, command);
    final frozen = await SyncStore(client.app.repository).nextPush(space);
    final pending = (await client.app.repository.pending(
      space,
    )).single.toJson();
    await client.app.repository.saveDraft(space, '保留未提交合成草稿');
    final source = await File(native['path'] as String).readAsBytes();
    expect(source.length, 614400);
    expect(sha256.convert(source).toString(), native['sha256']);
    var record = await client.app.stageImports.stage(
      client.lease,
      bytes: source,
      format: ImportFileKind.parse('flowtrace_json'),
      fileName: 'native204.json',
    );
    final stageId = record.stageId;
    await expectLater(
      StageImportCoordinator(
        client.app.stageImports,
      ).uploadAndSeal(client.lease, stageId),
      throwsA(
        isA<ApiFailure>().having((error) => error.offline, 'offline', isTrue),
      ),
    );
    expect(probe.chunkDrops, 1);
    record = (await client.app.stageImports.read(space, stageId))!;
    expect(record.nextChunk, 0);
    final originalBody = record.stored.createBodyJson;
    probe.offline = true;
    await client.close();
    client = _Client(directory, vault, probe);
    await client.open(fixture);
    record = (await client.app.stageImports.read(space, stageId))!;
    await client.app.stageImports.verifySource(record);
    expect(record.stored.createBodyJson, originalBody);
    expect(client.identity.account!.sessionId, oldSession);
    await client.reconnect(fixture);
    expect(client.identity.clientId, oldClient);
    await StageImportCoordinator(
      client.app.stageImports,
    ).uploadAndSeal(client.lease, stageId);
    record = await _phase(client, stageId, {'parsed'});
    final parsedSql = await _postgresql(fixtureFile, stageId);
    expect(parsedSql['batch_status'], isNull);
    expect(parsedSql['native_cash_balance_minor'], isNull);
    expect(parsedSql['received_chunks'], 2);
    final items = <StageImportRequirement>[];
    final first = await _requirements(client, record, items);
    expect(
      items.any(
        (item) => item.kind == 'image' && item.sourceKey == image['source_id'],
      ),
      isTrue,
    );
    final books = await StageImportSourceBooksReader(
      client.app.stageImports,
      record,
    ).next(client.lease);
    expect(books.items.single.sourceId, ids['book']);
    final bytes = await File(image['path'] as String).readAsBytes();
    final transfer = await client.app.attachments();
    final attachment = await transfer.repository.stage(
      space,
      client.lease.data.epoch,
      account['id'] as String,
      bytes,
      mediaType: 'image/png',
    );
    await transfer.upload(
      AttachmentLease.capture(client.identity),
      attachment.id,
    );
    var draft = StageImportMappingDraft.create(
      version: record.version,
      requirementsHash: first.hash,
      mapping: record.createBody['mapping'] as Map<String, Object?>,
    );
    for (final item in items) {
      if (item.kind == 'image') {
        draft = draft.withImageChoice(
          item,
          uploadedId: attachment.id,
          targetBookId: books.items.single.sourceId,
          selectedBytes: bytes,
          mediaType: 'image/png',
        );
      } else {
        expect(item.kind, 'scope');
        expect(item.sourceKey, ids['source_user']);
        draft = draft.withChoice(item, account['id'] as String);
      }
    }
    await client.commands.changeMapping(
      client.lease,
      stageId,
      draft.mapping,
      first,
    );
    record = await _phase(client, stageId, {'parsed'});
    final second = await _requirements(
      client,
      record,
      <StageImportRequirement>[],
    );
    await client.commands.requestPreview(client.lease, stageId, second);
    record = await _phase(client, stageId, {'ready'});
    final previewSql = await _postgresql(fixtureFile, stageId);
    expect(previewSql['batch_status'], isNull);
    expect(previewSql['native_cash_balance_minor'], isNull);
    expect(previewSql['imported_items'], 0);
    final before = await client.app.ledger.read(space);
    expect(before.books.any((book) => book.id == targets['book']), isFalse);
    var after = 0;
    String? cursor;
    do {
      final page = await client.commands.rows(
        client.lease,
        stageId,
        version: record.version,
        cursor: cursor,
        after: after,
      );
      expect(page.rows.every((row) => row.status == 'new'), isTrue);
      after += page.rows.length;
      cursor = page.nextCursor;
    } while (cursor != null);
    expect(after, 204);
    final version = record.version, hash = record.remote!.previewHash!;
    probe.dropApply = true;
    await expectLater(
      client.commands.apply(
        client.lease,
        stageId,
        version: version,
        previewHash: hash,
      ),
      throwsA(
        isA<ApiFailure>().having((error) => error.offline, 'offline', isTrue),
      ),
    );
    expect(probe.applyDrops, 1);
    final body = probe.applyBodies.single;
    probe.offline = true;
    await client.close();
    client = _Client(directory, vault, probe);
    await client.open(fixture);
    expect(
      (await client.app.ledger.read(
        space,
      )).books.any((book) => book.id == targets['book']),
      isFalse,
    );
    record = (await client.app.stageImports.read(space, stageId))!;
    await client.app.stageImports.verifySource(record);
    final storedApply =
        (await client.db.select(client.db.stageImportCommands).get())
            .singleWhere((row) => row.kind == 'apply');
    expect(storedApply.bodyJson, body);
    expect(storedApply.responseJson, isNull);
    await client.reconnect(fixture);
    await client.commands.apply(
      client.lease,
      stageId,
      version: version,
      previewHash: hash,
    );
    record = await _phase(client, stageId, {'applied'});
    expect(probe.applyBodies, [body, body]);
    final view = await client.app.ledger.read(space);
    expect(
      view.categories.where((row) => row.scopeId == targets['book']).length,
      101,
    );
    expect(
      view.bills.where((row) => row.scopeId == targets['book']).length,
      101,
    );
    expect(
      view.balances[targets['cash']]!.value!.minor.toString(),
      native['balance_minor'],
    );
    final report = await LedgerReportingService(client.app.repository).read(
      space,
      ReportQuery(
        bookId: targets['book'] as String,
        reportCurrency: 'CNY',
        reportScale: 2,
        startDate: '2026-10-23',
        endDateExclusive: '2026-10-24',
      ),
    );
    expect(report.totals!.expense.minor.toString(), '12625');
    final metadata = await client.identity.authorizedRequest(
      'GET',
      '/attachments/${attachment.id}',
    );
    expect(metadata['scope_id'], targets['book']);
    final downloaded = await client.identity.authorizedDownload(
      '/attachments/${attachment.id}/content',
      maxBytes: 1024,
    );
    expect(sha256.convert(downloaded).toString(), image['sha256']);
    final finalSql = await _postgresql(fixtureFile, stageId);
    expect(finalSql['batch_status'], 'applied');
    expect(finalSql['imported_items'], 204);
    expect(finalSql['publication_chunks'] as int, greaterThan(1));
    expect(finalSql['native_cash_balance_minor'], native['balance_minor']);
    expect(finalSql['sync_push_receipts'], 2);
    expect(probe.pushes, 0);
    final remaining = (await client.app.repository.pending(space)).single;
    expect(remaining.toJson(), pending);
    expect(remaining.frozenRequestJson, frozen!.body);
    expect(
      (await client.app.repository.drafts(space)).single.body,
      '保留未提交合成草稿',
    );
    final receipts = await client.db.select(client.db.groupReceipts).get();
    expect(
      receipts
          .where((row) => probe.publicationIds.contains(row.groupId))
          .length,
      1,
    );
    return {
      'verified': true,
      'scenario': 'native204',
      'stage_id': stageId,
      'batch_id': record.batchId,
      'source_sha256': native['sha256'],
      'chunks': 2,
      'chunk_reply_losses': 1,
      'apply_reply_losses': 1,
      'same_apply_body': true,
      'offline_sqlite_reopens': 2,
      'source_and_frozen_outbox_preserved': true,
      'preview_persisted_financial_writes': false,
      'bill_count': 101,
      'category_count': 101,
      'expense_minor': '12625',
      'balance_minor': native['balance_minor'],
      'postgresql': finalSql,
      'fresh_group_single_publication_receipt': true,
      'image_id': attachment.id,
      'image_sha256': image['sha256'],
      'no_client_push': true,
      'sandbox_directory_platform_bridge': true,
      'windows_runner_lease_tested': false,
      'system_secure_vault_tested': false,
      'normal_ui_tested': false,
      'capacity_performance_tested': false,
    };
  } finally {
    await client.close(logout: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsRuntime.channel, null);
  }
}

void main() {
  final source = Platform.environment['FLOWTRACE_STAGE_QA_FILE'];
  if (source != null) {
    TestWidgetsFlutterBinding.ensureInitialized();
    // VM's widget binding normally substitutes HTTP 400. This opt-in live
    // target requires real TCP; no production transport is mocked.
    HttpOverrides.global = null;
  }
  test(
    'real AppController stage native chunks preview lost apply reply disk reopen and fresh group',
    () async {
      final path = File(source!);
      final fixture = syncObject(jsonDecode(await path.readAsString()));
      final uri = Uri.parse(fixture['server'] as String);
      final root = await Directory(
        '../../work/flowtrace-stage/live',
      ).resolveSymbolicLinks();
      final run = await Directory(
        fixture['run_directory'] as String,
      ).resolveSymbolicLinks();
      if (fixture['purpose'] !=
              'flowtrace-stage-tcp-normal-client-synthetic-v1' ||
          fixture['expected_head'] != '0016_backup_quarantine' ||
          fixture['genuine_main_stage_and_group'] != true ||
          !p.isWithin(root, run) ||
          p.dirname(await path.resolveSymbolicLinks()) != run ||
          uri.scheme != 'http' ||
          uri.host != '127.0.0.1' ||
          uri.port != 18094 ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.path.isNotEmpty) {
        throw StateError(
          'Owned head16 stage fixture and genuine main required',
        );
      }
      final result = await _native(fixture, path.absolute.path);
      await File(
        fixture['client_receipt'] as String,
      ).writeAsString(jsonEncode(result));
    },
    skip: source == null
        ? 'Explicit isolated stage TCP fixture and SDK window required'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
