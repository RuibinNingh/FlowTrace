// Isolated browser storage diagnostic. Never opens the application's database.
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:web/web.dart' as web;

import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/data/ledger/ledger_repository.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

final _events = <String>[];
void record(String message) {
  _events.add(message);
  web.document.body!.textContent = jsonEncode(_events);
}

String uid(int n) => '77777777-7777-4777-8777-${n.toString().padLeft(12, '0')}';

Future<void> main() async {
  record('start');
  try {
    final mode = Uri.base.queryParameters['mode'] ?? 'nested';
    final run = Uri.base.queryParameters['run'];
    if (run == null || !RegExp(r'^[a-z0-9-]{8,60}$').hasMatch(run)) {
      throw StateError('A synthetic run identifier is required.');
    }
    final opened = await WasmDatabase.open(
      databaseName: 'flowtrace-probe-$run',
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.js'),
    );
    record('storage:${opened.chosenImplementation.name}');
    final db = AppDatabase(opened.resolvedExecutor);
    final local = LocalRepository(db);
    final ledger = LedgerRepository(local);
    await local.writeSetting('probe', 'opened');
    record('opened');
    if (mode == 'nested') {
      await db.transaction(() async {
        record('outer-entered');
        await local.writeSetting('probe', 'outer');
        await db.transaction(() async {
          record('inner-entered');
          await local.writeSetting('probe', 'inner');
          record('inner-written');
        });
        record('inner-completed');
      });
      record('outer-completed');
    } else {
      final space = DataSpace(
        server: ServerAddress.parse('http://127.0.0.1:18099'),
        serverInstanceId: uid(9),
        userId: uid(1),
      );
      if (mode == 'reopen') {
        final entities = await db.select(db.localEntities).get();
        final operations = await local.pending(space);
        final budget = entities.where((e) => e.entityType == 'budget').single;
        final payload = jsonDecode(budget.dataJson) as Map;
        if ((payload['total'] as Map)['amount_minor'] != '10000' ||
            operations.length != 1) {
          throw StateError('Reopened exact amount / outbox mismatch');
        }
        record('reopened-exact-budget:10000;outbox:1');
        await db.close();
        record('passed');
        return;
      }
      await local.registerSpace(space);
      await db
          .into(db.syncStates)
          .insert(
            SyncStatesCompanion.insert(
              spaceId: space.id,
              clientId: uid(5),
              epoch: uid(6),
            ),
          );
      await local.writeSetting(
        'sync.scope-details.${space.id}',
        jsonEncode({
          'version': 1,
          'epoch': uid(6),
          'scopes': [
            {
              'scope_id': uid(2),
              'kind': 'book',
              'role': 'owner',
              'permission_version': '1',
            },
          ],
        }),
      );
      await db
          .into(db.localEntities)
          .insert(
            LocalEntitiesCompanion.insert(
              spaceId: space.id,
              scopeId: Value(uid(2)),
              entityType: 'book',
              entityId: uid(2),
              serverRevision: const Value('1'),
              dataJson: jsonEncode({
                'name': '合成诊断账本',
                'currency': 'CNY',
                'timezone': 'Asia/Shanghai',
                'month_start_day': 1,
              }),
              updatedAt: DateTime.now().toUtc(),
            ),
          );
      if (mode == 'rollback') {
        final account = <String, Object?>{
          'projection_kind': 'account',
          'payload': {
            'name': '合成回滚账户',
            'kind': 'cash',
            'opening': {
              'currency': 'CNY',
              'currency_scale': 2,
              'amount_minor': '20000',
            },
            'include_in_net_assets': true,
            'hidden': false,
          },
          'balance': {
            'currency': 'CNY',
            'currency_scale': 2,
            'amount_minor': '20000',
          },
        };
        await db
            .into(db.localEntities)
            .insert(
              LocalEntitiesCompanion.insert(
                spaceId: space.id,
                scopeId: Value(space.userId),
                entityType: 'account',
                entityId: uid(10),
                serverRevision: const Value('1'),
                dataJson: jsonEncode(account),
                updatedAt: DateTime.now().toUtc(),
              ),
            );
        await db
            .into(db.serverShadows)
            .insert(
              ServerShadowsCompanion.insert(
                spaceId: space.id,
                scopeId: space.userId,
                entityType: 'account',
                entityId: uid(10),
                revision: '1',
                dataJson: jsonEncode(account),
                deleted: false,
              ),
            );
      }
      final subscriptions = <StreamSubscription<Object?>>[];
      if (mode == 'watch') {
        for (var i = 0; i < 4; i++) {
          subscriptions.add(
            ledger.watch(space).listen((_) => record('watch:$i')),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      record('seeded');
      final payload = <String, Object?>{
        'period_start': '2026-10-01',
        'period_end_exclusive': '2026-11-01',
        'total': {
          'currency': 'CNY',
          'currency_scale': 2,
          'amount_minor': '10000',
        },
        'categories': [],
        'carry_forward': false,
      };
      if (mode == 'rollback') {
        var failed = false;
        try {
          await db.atomicWrite(() async {
            await local.writeSetting('probe-rollback-only', 'outer');
            try {
              await db.atomicWrite(() async {
                await local.writeSetting('probe-rollback-only', 'inner');
                throw StateError('synthetic joined helper failure');
              });
            } catch (_) {
              /* Deliberately swallowed: outer must still fail. */
            }
          });
        } catch (_) {
          failed = true;
        }
        if (!failed || await local.readSetting('probe-rollback-only') != null) {
          throw StateError('Caught inner failure partially committed');
        }
        record('caught-inner-failure-rolled-back');
        failed = false;
        try {
          await ledger.saveBatch(space, [
            LedgerWrite(
              entityType: 'bill',
              scopeId: uid(2),
              entityId: uid(11),
              payload: {
                'bill_type': 'expense',
                'money': {
                  'currency': 'CNY',
                  'currency_scale': 2,
                  'amount_minor': '125',
                },
                'book_id': uid(2),
                'account_id': uid(10),
                'business_date': '2026-10-21',
                'business_timezone': 'Asia/Shanghai',
                'note': '合成回滚账单',
              },
            ),
            LedgerWrite(
              entityType: 'tag',
              scopeId: uid(2),
              entityId: uid(4),
              payload: {'name': '无效', 'color': 'invalid'},
            ),
          ]);
        } catch (_) {
          failed = true;
        }
        final hints = (await db.select(db.appSettings).get()).where(
          (s) => s.key.startsWith('ledger.postings.'),
        );
        if (!failed ||
            (await db.select(db.localEntities).get()).length != 2 ||
            (await local.pending(space)).isNotEmpty ||
            hints.isNotEmpty) {
          throw StateError('Whole batch did not roll back');
        }
        final balance = (await ledger.read(
          space,
        )).balances[uid(10)]!.value!.minor;
        if (balance != BigInt.from(20000)) {
          throw StateError('Rollback changed account balance');
        }
        record('batch-rolled-back:entities:2;outbox:0;hints:0;balance:20000');
      }
      await ledger.save(
        space,
        entityType: 'budget',
        scopeId: uid(2),
        entityId: uid(3),
        payload: payload,
      );
      record('budget-saved');
      final entities = await db.select(db.localEntities).get();
      final operations = await local.pending(space);
      record('rows:${entities.length};outbox:${operations.length}');
      if (entities.length != (mode == 'rollback' ? 3 : 2) ||
          operations.length != 1) {
        throw StateError('Saved entity/outbox mismatch');
      }
      await db.transaction(() async {
        final view = await ledger.read(space);
        if (view.budgets.length != 1) throw StateError('Snapshot mismatch');
      });
      record('existing-snapshot-read-completed');
      if (mode == 'conflict') {
        final sync = SyncStore(local);
        final old = operations.single.operationId;
        final frozen = (await sync.nextPush(space))!.body;
        await sync.reject(
          space,
          old,
          'revision_conflict',
          authorizedServer: {'revision': '2', 'data': payload},
        );
        await sync.resolveWithNewCommand(
          space,
          old,
          QueuedCommand(
            operationId: uid(20),
            scopeId: uid(2),
            entityType: 'budget',
            entityId: uid(3),
            action: 'update',
            baseRevision: '2',
            payload: payload,
          ),
        );
        final pending = await local.pending(space);
        final history = await db.select(db.pendingOperations).get();
        if (pending.length != 1 ||
            pending.single.operationId != uid(20) ||
            history.first.state != 'discarded' ||
            history.first.frozenRequestJson != frozen ||
            (await sync.conflicts(space)).isNotEmpty) {
          throw StateError('Conflict replacement or frozen history mismatch');
        }
        record(
          'conflict-resolved:fresh-operation;frozen-history-preserved;outbox:1',
        );
      }
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
    await db.close();
    record('passed');
  } catch (error, trace) {
    record('error:${error.runtimeType}:$error');
    record(trace.toString().split('\n').take(5).join('\n'));
  }
}
