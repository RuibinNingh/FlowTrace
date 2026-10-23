import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../identity/identity_controller_test.dart' show MemoryVault;

final class RecoveryTransport extends http.BaseClient {
  final inner = http.Client();
  final pushedOperationIds = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/sync/push') && request is http.Request) {
      final body = syncObject(jsonDecode(request.body));
      for (final raw in body['operations'] as List) {
        pushedOperationIds.add(syncObject(raw)['operation_id'] as String);
      }
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

/// Started only by recovery_harness.py after its exact database/port guards.
/// Uses Flutter identity and synchronization code over real HTTP, a disk SQLite
/// client and a synthetic in-memory vault. It is not an Android/production test.
void main() {
  final fixture = Platform.environment['FLOWTRACE_RECOVERY_QA_FILE'];
  test(
    'real database rollback preserves acknowledged expense, unsent input and draft for review',
    () async {
      final config = syncObject(
        jsonDecode(await File(fixture!).readAsString()),
      );
      final uri = Uri.parse(config['server'] as String);
      if (uri.scheme != 'http' ||
          uri.host != '127.0.0.1' ||
          uri.port != 18083 ||
          uri.userInfo.isNotEmpty ||
          uri.path.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw StateError('Recovery test requires its dedicated loopback port');
      }
      final run = Directory(config['run_dir'] as String);
      final runPath = await run.resolveSymbolicLinks();
      final allowed = await Directory(
        '../../work/flowtrace-recovery',
      ).resolveSymbolicLinks();
      if (!runPath.toLowerCase().startsWith(
            '${allowed.toLowerCase()}${Platform.pathSeparator}',
          ) ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(config['run_id'] as String)) {
        throw StateError('Recovery handshake directory guard failed');
      }
      Future<Map<String, Object?>> handshake(
        String action,
        Map<String, Object?> values,
      ) async {
        if (!{'dump', 'restore', 'verify'}.contains(action)) {
          throw StateError('Unknown recovery handshake');
        }
        final request = File('$runPath/$action.request.json');
        final temporary = File('${request.path}.tmp');
        await temporary.writeAsString(
          jsonEncode({'run_id': config['run_id'], ...values}),
          flush: true,
        );
        await temporary.rename(request.path);
        final response = File('$runPath/$action.response.json');
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (DateTime.now().isBefore(deadline)) {
          if (await response.exists()) {
            final result = syncObject(
              jsonDecode(await response.readAsString()),
            );
            if (result['ok'] != true) {
              throw StateError('Isolated recovery harness failed');
            }
            return result;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        throw TimeoutException('Isolated recovery handshake timed out');
      }

      const uuid = Uuid();
      final databaseFile = File('$runPath/client.sqlite');
      final db = AppDatabase(NativeDatabase(databaseFile));
      final repository = LocalRepository(db);
      final transport = RecoveryTransport();
      final identity = IdentityController(
        repository: repository,
        api: ApiClient(transport),
        vault: MemoryVault(),
        isWeb: false,
        allowLocalHttp: true,
        deviceName: 'dedicated-recovery-http-fixture',
      );
      final store = SyncStore(repository), engine = SyncEngine(store);
      final accountId = uuid.v4(), billId = uuid.v4(), tagId = uuid.v4();
      final accountOperation = uuid.v4();
      final expenseOperation = uuid.v4(), tagOperation = uuid.v4();
      final bookId = syncIdentifier(config['book_id']);
      final evidence = <String, Object?>{};
      try {
        await identity.configure(ServerAddress.parse(uri.toString()));
        await identity.signIn(
          username: config['username'] as String,
          password: config['password'] as String,
        );
        expect(identity.online, isTrue);
        final space = identity.accountSpace!;
        expect(space.userId, config['user_id']);
        await repository.registerSpace(space);
        await engine.synchronize(SyncLease.capture(identity));
        final oldClient = identity.clientId!;
        final oldEpoch = identity.serverIdentity!.syncEpoch;
        await repository.saveEntityAndQueue(
          space,
          QueuedCommand(
            operationId: accountOperation,
            scopeId: space.userId,
            entityType: 'account',
            entityId: accountId,
            action: 'create',
            baseRevision: '0',
            payload: {
              'name': '恢复演练合成现金',
              'kind': 'cash',
              'opening': {
                'currency': 'CNY',
                'currency_scale': 2,
                'amount_minor': '100000',
              },
              'include_in_net_assets': true,
              'hidden': false,
            },
          ),
        );
        expect(
          (await engine.synchronize(SyncLease.capture(identity))).applied,
          1,
        );
        final baseline = await handshake('dump', {
          'account_id': accountId,
          'session_id': identity.account!.sessionId,
        });
        expect(baseline['epoch'], oldEpoch);

        await repository.saveEntityAndQueue(
          space,
          QueuedCommand(
            operationId: expenseOperation,
            scopeId: bookId,
            entityType: 'bill',
            entityId: billId,
            action: 'create',
            baseRevision: '0',
            payload: {
              'bill_type': 'expense',
              'book_id': bookId,
              'account_id': accountId,
              'money': {
                'currency': 'CNY',
                'currency_scale': 2,
                'amount_minor': '12500',
              },
              'business_date': '2026-10-21',
              'business_timezone': 'Asia/Shanghai',
              'note': '已确认但晚于数据库恢复点的合成支出',
            },
          ),
        );
        expect(
          (await engine.synchronize(SyncLease.capture(identity))).applied,
          1,
        );
        final acknowledged = (await db.select(db.pendingOperations).get())
            .singleWhere((row) => row.operationId == expenseOperation);
        expect(acknowledged.state, 'applied');
        expect(acknowledged.appliedRevision, '1');
        await repository.saveEntityAndQueue(
          space,
          QueuedCommand(
            operationId: tagOperation,
            scopeId: bookId,
            entityType: 'tag',
            entityId: tagId,
            action: 'create',
            baseRevision: '0',
            payload: {'name': '尚未发送的合成标签', 'color': '#2279d7'},
          ),
        );
        final draftId = await repository.saveDraft(space, '恢复演练尚未发送的本地草稿');
        expect(
          (await repository.pending(space)).single.operationId,
          tagOperation,
        );
        expect(
          (await repository.pending(space)).single.frozenRequestJson,
          isNull,
        );
        final beforeRecoveryPushes = transport.pushedOperationIds.length;
        final restored = await handshake('restore', {
          'account_id': accountId,
          'bill_id': billId,
          'tag_id': tagId,
        });
        expect(restored['instance_id'], space.serverInstanceId);
        final newEpoch = syncIdentifier(restored['new_epoch']);
        expect(newEpoch, isNot(oldEpoch));

        await expectLater(
          engine.synchronize(SyncLease.capture(identity)),
          throwsA(
            isA<ApiFailure>().having(
              (error) => error.code,
              'code',
              'epoch_changed',
            ),
          ),
        );
        expect((await store.state(space))!.status, 'recovery_required');
        final backups = await store.recoveryBackups(space);
        expect(backups, hasLength(1));
        final backup = syncObject(jsonDecode(backups.single.dataJson));
        expect(
          (backup['entities'] as List).any(
            (row) => syncObject(row)['entityId'] == billId,
          ),
          isTrue,
        );
        final savedOperations = (backup['operations'] as List).map(syncObject);
        expect(
          savedOperations.singleWhere(
            (row) => row['operationId'] == expenseOperation,
          )['state'],
          'applied',
        );
        expect(
          savedOperations.singleWhere(
            (row) => row['operationId'] == tagOperation,
          )['state'],
          'queued',
        );
        expect(
          (backup['drafts'] as List).map(syncObject).single['id'],
          draftId,
        );
        expect(transport.pushedOperationIds.length, beforeRecoveryPushes);
        await identity.rotateClientForRecovery(
          expectedSpaceId: space.id,
          expectedGeneration: identity.sessionGeneration,
        );
        expect(identity.clientId, isNot(oldClient));
        await identity.signIn(
          username: config['username'] as String,
          password: config['password'] as String,
        );
        expect(identity.accountSpace!.id, space.id);
        expect(identity.serverIdentity!.syncEpoch, newEpoch);
        await engine.rebuildFromServer(SyncLease.capture(identity));
        final current = (await store.state(space))!;
        expect(current.status, 'active');
        expect(current.epoch, newEpoch);
        expect(current.clientId, identity.clientId);
        expect(await repository.pending(space), isEmpty);
        expect((await repository.drafts(space)).single.id, draftId);
        final journal = await db.select(db.pendingOperations).get();
        final oldExpense = journal.singleWhere(
          (row) => row.operationId == expenseOperation,
        );
        expect(oldExpense.operationJson, acknowledged.operationJson);
        expect(oldExpense.frozenRequestJson, acknowledged.frozenRequestJson);
        expect(oldExpense.state, 'discarded');
        expect(
          journal.singleWhere((row) => row.operationId == tagOperation).state,
          'discarded',
        );
        final differences = await store.recoveryDifferences(
          space,
          backups.single,
        );
        expect(
          differences.singleWhere(
            (row) => row['entity_id'] == billId && row['scope_id'] == bookId,
          )['difference'],
          'missing',
        );
        expect(
          differences.singleWhere(
            (row) => row['entity_id'] == tagId,
          )['difference'],
          'missing',
        );
        expect(
          differences.singleWhere(
            (row) => row['entity_id'] == accountId,
          )['difference'],
          'changed',
        );
        final rows = await db.select(db.localEntities).get();
        expect(rows.where((row) => row.entityId == billId), isEmpty);
        expect(rows.where((row) => row.entityId == tagId), isEmpty);
        final restoredAccount = syncObject(
          jsonDecode(
            rows.singleWhere((row) => row.entityId == accountId).dataJson,
          ),
        );
        expect(
          syncObject(restoredAccount['balance'])['amount_minor'],
          '100000',
        );
        expect(transport.pushedOperationIds.length, beforeRecoveryPushes);
        final report = await engine.synchronize(SyncLease.capture(identity));
        expect(report.applied, 0);
        expect(report.pending, 0);
        expect(transport.pushedOperationIds.length, beforeRecoveryPushes);
        await handshake('verify', {
          'account_id': accountId,
          'bill_id': billId,
          'tag_id': tagId,
          'old_operation_ids': [expenseOperation, tagOperation],
        });
        evidence.addAll({
          'passed': true,
          'acknowledged_expense_missing_in_server_found_in_backup': true,
          'unsent_tag_preserved_in_backup_and_discarded_journal': true,
          'draft_preserved': true,
          'balance_difference_found': true,
          'new_client_authenticated': identity.clientId != oldClient,
          'instance_preserved': true,
          'old_operations_automatically_replayed': 0,
          'difference_count': differences.length,
          'database': 'disk SQLite',
          'vault': 'synthetic MemoryVault',
          'platform': 'Flutter VM on Windows, real HTTP',
        });
      } finally {
        if (identity.online) await identity.signOut();
        identity.dispose();
        await db.close();
      }
      final reopened = AppDatabase(NativeDatabase(databaseFile));
      try {
        expect(
          await reopened.select(reopened.syncRecoveryBackups).get(),
          hasLength(1),
        );
        expect(await reopened.select(reopened.localDrafts).get(), hasLength(1));
        expect(
          (await reopened.select(reopened.syncStates).getSingle()).status,
          'active',
        );
        evidence['disk_reopen_preserved_backup_and_draft'] = true;
      } finally {
        await reopened.close();
      }
      await File('$runPath/client-evidence.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(evidence),
        flush: true,
      );
    },
    skip: fixture == null
        ? 'Run the guarded recovery harness with synthetic credentials'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
