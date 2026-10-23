import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/ledger/ledger_reporting.dart';
import 'package:flowtrace/data/ledger/ledger_repository.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';

import '../identity/identity_controller_test.dart' show MemoryVault;

/// Carries only synthetic test observations across closing/reopening SQLite.
final class _Probe {
  bool drop = true;
  bool offline = false;
  int drops = 0;
  int pushes = 0;
  String? droppedBody;
  String? publicationId;
  Map<String, Object?>? base;
  final units = <int, Map<String, Object?>>{};
  final pageBodies = <String, int>{};

  Map<String, Object?> get beforePublication {
    final selected = units.values.singleWhere(
      (unit) => unit['group_id'] == publicationId,
    );
    final index = selected['unit_index'] as int;
    if (index > 0) {
      return syncObject(units[index - 1]!['end_cursors']);
    }
    return {
      for (final key in syncObject(selected['end_cursors']).keys)
        key: base?[key] ?? '0',
    };
  }
}

/// Real TCP response loss, after the server returned a successful data page.
/// It retains ApiClient's production 1MiB / 8s group transport boundaries.
final class _DropPage extends http.BaseClient {
  _DropPage(this.probe);
  final _Probe probe;
  final inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (probe.offline) throw const SocketException('Synthetic offline reopen');
    if (request.url.path.endsWith('/sync/push')) probe.pushes++;
    final group = request.url.path.contains('/sync/group-pulls');
    final response = await inner.send(request);
    if (!group || response.statusCode < 200 || response.statusCode >= 300) {
      return response;
    }
    final bytes = <int>[];
    await for (final part in response.stream) {
      if (bytes.length + part.length > 1024 * 1024) {
        throw StateError('Group HTTP exceeded unchanged transport bound');
      }
      bytes.addAll(part);
    }
    final raw = syncObject(jsonDecode(utf8.decode(bytes)));
    if (raw['status'] == 'ready') {
      probe.base = syncObject(syncObject(raw['manifest'])['base_cursors']);
    }
    if (raw['kind'] == 'index') {
      for (final value in raw['units'] as List) {
        final unit = syncObject(value);
        probe.units[unit['unit_index'] as int] = unit;
      }
    }
    if (request.url.path.endsWith('/pages') && request is http.Request) {
      probe.pageBodies.update(
        request.body,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      final publication = probe.units.values.any(
        (unit) =>
            unit['kind'] == 'publication' &&
            unit['group_id'] == raw['group_id'],
      );
      if (probe.drop && raw['kind'] == 'data' && publication) {
        probe.drop = false;
        probe.drops++;
        probe.droppedBody = request.body;
        probe.publicationId = raw['group_id'] as String;
        throw const SocketException('Synthetic successful group page loss');
      }
    }
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
      contentLength: bytes.length,
      request: request,
    );
  }

  @override
  void close() => inner.close();
}

final class _Client {
  _Client(this.directory, this.vault, this.probe) {
    database = AppDatabase(
      NativeDatabase(File(p.join(directory.path, 'local.sqlite'))),
    );
    local = LocalRepository(database);
    transport = _DropPage(probe);
    identity = IdentityController(
      repository: local,
      api: ApiClient(transport),
      vault: vault,
      isWeb: false,
      allowLocalHttp: true,
      deviceName: 'synthetic-group-http',
    );
    store = SyncStore(local);
    engine = SyncEngine(store);
    ledger = LedgerRepository(local);
  }
  final Directory directory;
  final MemoryVault vault;
  final _Probe probe;
  late final AppDatabase database;
  late final LocalRepository local;
  late final _DropPage transport;
  late final IdentityController identity;
  late final SyncStore store;
  late final SyncEngine engine;
  late final LedgerRepository ledger;
  bool closed = false;
  DataSpace get space => identity.accountSpace!;

  Future<void> close({bool logout = true}) async {
    if (closed) return;
    try {
      if (logout) {
        probe.offline = false;
        if (!identity.online && identity.account != null) {
          await identity.configure(identity.server!);
        }
        if (identity.online) await identity.signOut();
      }
    } finally {
      closed = true;
      identity.dispose();
      transport.close();
      await database.close();
    }
  }
}

Future<Map<String, Object?>> _scenario(
  Map<String, Object?> fixture,
  String role,
) async {
  final account = syncObject(syncObject(fixture['accounts'])[role]);
  final directory = Directory(p.join(fixture['run_directory'] as String, role));
  await directory.create(recursive: true);
  final probe = _Probe();
  final vault = MemoryVault();
  var client = _Client(directory, vault, probe);
  final address = ServerAddress.parse(fixture['server'] as String);
  try {
    await client.identity.configure(address);
    await client.identity.signIn(
      username: account['username'] as String,
      password: account['password'] as String,
    );
    expect(client.identity.online, isTrue);
    expect(client.identity.serverIdentity!.supportsGroupPull, isTrue);
    expect(client.space.userId, account['id']);
    expect(client.space.serverInstanceId, fixture['instance_id']);
    expect(client.identity.serverIdentity!.syncEpoch, fixture['sync_epoch']);
    await client.local.registerSpace(client.space);
    final lease = SyncLease.capture(client.identity);
    await client.store.configure(
      lease.space,
      lease.clientId,
      lease.epoch,
      isCurrent: lease.isCurrent,
    );
    await client.engine.refreshScopes(SyncLease.capture(client.identity));
    final command = QueuedCommand(
      operationId: const Uuid().v4(),
      scopeId: account['book_id'] as String,
      entityType: 'category',
      entityId: const Uuid().v4(),
      action: 'create',
      baseRevision: '0',
      payload: {
        'name': '冻结未发送原输入',
        'kind': 'expense',
        'icon': 'food',
        'parent_id': null,
        'sort_order': 0,
      },
    );
    await client.local.saveEntityAndQueue(client.space, command);
    final frozen = await client.store.nextPush(client.space);
    expect(frozen, isNotNull);
    final pending = (await client.local.pending(client.space)).single.toJson();
    final draftBody = jsonEncode({
      'note': '离线重开原草稿',
      'time': '01:02:03.123456',
      'money': '9007199254740993',
      'discount': '1',
      'tags': ['本机'],
      'flags': ['未确认'],
    });
    await client.local.saveDraft(client.space, draftBody);
    final oldClient = client.identity.clientId;
    final oldSession = client.identity.account!.sessionId;
    ApiFailure? dropped;
    for (var attempt = 0; attempt < 10 && probe.drops == 0; attempt++) {
      try {
        await client.engine.pullLatest(SyncLease.capture(client.identity));
      } on ApiFailure catch (error) {
        if (error.code == 'group_pending') continue;
        dropped = error;
        break;
      }
    }
    expect(probe.drops, 1);
    expect(dropped?.offline, isTrue);
    expect(probe.pushes, 0);
    final before = await client.store.state(client.space);
    expect(
      syncObject(jsonDecode(before!.cursorsJson)),
      probe.beforePublication,
    );
    expect(
      (await client.ledger.read(
        client.space,
      )).bills.where((bill) => bill.scopeId == fixture['book_id']),
      isEmpty,
    );
    final partial =
        (await client.database.select(client.database.groupPulls).get()).single;
    expect(partial.nextToken, isNotNull);
    final requestId = partial.requestId;
    final pageToken = partial.nextToken;
    await client.close(logout: false);

    probe.offline = true;
    client = _Client(directory, vault, probe);
    await client.identity.configure(address);
    expect(client.identity.online, isFalse);
    expect(client.identity.clientId, oldClient);
    expect((await client.local.pending(client.space)).single.toJson(), pending);
    expect((await client.local.drafts(client.space)).single.body, draftBody);
    final reopened =
        (await client.database.select(client.database.groupPulls).get()).single;
    expect(reopened.requestId, requestId);
    expect(reopened.nextToken, pageToken);
    expect(
      (await client.store.state(client.space))!.cursorsJson,
      before.cursorsJson,
    );
    probe.offline = false;
    await client.identity.configure(address);
    expect(client.identity.online, isTrue);
    expect(client.identity.clientId, oldClient);
    expect(client.identity.account!.sessionId, oldSession);
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        await client.engine.pullLatest(SyncLease.capture(client.identity));
        break;
      } on ApiFailure catch (error) {
        if (error.code != 'group_pending') rethrow;
      }
    }
    expect(probe.pageBodies[probe.droppedBody], greaterThanOrEqualTo(2));
    expect(probe.pushes, 0);
    expect((await client.local.pending(client.space)).single.toJson(), pending);
    expect((await client.local.drafts(client.space)).single.body, draftBody);
    final completed =
        (await client.database.select(client.database.groupPulls).get()).single;
    expect(completed.requestId, requestId);
    expect(syncObject(jsonDecode(completed.receiveStateJson))['phase'], 'done');
    final manifest = syncObject(
      syncObject(jsonDecode(completed.statusJson!))['manifest'],
    );
    expect(
      syncObject(
        jsonDecode((await client.store.state(client.space))!.cursorsJson),
      ),
      syncObject(manifest['checkpoint']),
    );
    final receipts = await client.database
        .select(client.database.groupReceipts)
        .get();
    expect(receipts.length, completed.installedUnits);
    expect(
      receipts
          .map((receipt) => '${receipt.requestId}:${receipt.unitIndex}')
          .toSet()
          .length,
      receipts.length,
    );
    expect(
      receipts
          .where((receipt) => receipt.groupId == probe.publicationId)
          .length,
      1,
    );
    final view = await client.ledger.read(client.space);
    final bills = view.bills
        .where((bill) => bill.scopeId == fixture['book_id'])
        .toList();
    expect(bills.length, fixture['bill_count']);
    final report = await LedgerReportingService(client.local).read(
      client.space,
      ReportQuery(
        bookId: fixture['book_id'] as String,
        reportCurrency: 'CNY',
        reportScale: 2,
        startDate: '2026-10-23',
        endDateExclusive: '2026-10-24',
      ),
    );
    expect(report.available, isTrue);
    expect(report.totals!.expense.minor.toString(), fixture['expense_minor']);
    final image = syncObject(fixture['private_image']);
    if (role == 'owner') {
      expect(
        view.balances[fixture['cash_id']]!.value!.minor.toString(),
        fixture['balance_minor'],
      );
      final bytes = await client.identity.authorizedDownload(
        '/attachments/${image['attachment_id']}/content',
        maxBytes: 1024 * 1024,
      );
      expect(sha256.convert(bytes).toString(), image['sha256']);
      expect(base64Encode(bytes), image['base64']);
    } else {
      expect(
        view.accounts.any((item) => item.id == fixture['cash_id']),
        isFalse,
      );
      expect(bills.every((bill) => bill.payload['account_id'] == null), isTrue);
      await expectLater(
        client.identity.authorizedDownload(
          '/attachments/${image['attachment_id']}/content',
          maxBytes: 1024 * 1024,
        ),
        throwsA(
          isA<ApiFailure>().having((error) => error.status, 'status', 403),
        ),
      );
      final shadows = await client.database
          .select(client.database.serverShadows)
          .get();
      expect(
        shadows.any(
          (row) =>
              row.scopeId ==
              syncObject(syncObject(fixture['accounts'])['owner'])['id'],
        ),
        isFalse,
      );
    }
    return {
      'role': role,
      'client_id': oldClient,
      'session_id': oldSession,
      'request_id': requestId,
      'pull_id': completed.pullId,
      'page_drop_count': probe.drops,
      'same_page_retried': true,
      'offline_disk_reopen': true,
      'frozen_body_sha256': sha256
          .convert(utf8.encode(frozen!.body))
          .toString(),
      'frozen_row_unchanged': true,
      'no_push': probe.pushes == 0,
      'receipt_count': receipts.length,
      'publication_receipt_count': 1,
      'bill_count': bills.length,
      'expense_minor': report.totals!.expense.minor.toString(),
      'private_cash_visible': role == 'owner',
      'private_image_authorization': true,
    };
  } finally {
    await client.close();
  }
}

void main() {
  final file = Platform.environment['FLOWTRACE_GROUP_QA_FILE'];
  test(
    'real group HTTP lost page offline disk reopen owner viewer and frozen outbox',
    () async {
      final fixture = syncObject(jsonDecode(await File(file!).readAsString()));
      final server = Uri.parse(fixture['server'] as String);
      final run = Directory(fixture['run_directory'] as String);
      final root = await Directory(
        '../../work/flowtrace-group/live',
      ).resolveSymbolicLinks();
      final resolved = await run.resolveSymbolicLinks();
      if (server.scheme != 'http' ||
          server.host != '127.0.0.1' ||
          server.port != 18093 ||
          server.userInfo.isNotEmpty ||
          server.path.isNotEmpty ||
          server.hasQuery ||
          server.hasFragment ||
          !RegExp(
            r'^flowtrace_test_p5_jobs_[0-9a-f]{16}$',
          ).hasMatch(fixture['database'] as String) ||
          !p.isWithin(root, resolved) ||
          fixture['group_main_mounted'] != true) {
        throw StateError(
          'Group live test requires owned source harness and genuine main capability',
        );
      }
      final results = <Map<String, Object?>>[];
      for (final role in ['owner', 'viewer']) {
        results.add(await _scenario(fixture, role));
      }
      expect(results.map((row) => row['expense_minor']).toSet(), {
        fixture['expense_minor'],
      });
      await File(fixture['receipt'] as String).writeAsString(
        jsonEncode({
          'verified': true,
          'fixture_stage_id': fixture['stage_id'],
          'clients': results,
          'group_capability_from_production_main': true,
          'session_logout_requested': true,
        }),
      );
    },
    skip: file == null
        ? 'Run only through the isolated owned group harness'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
