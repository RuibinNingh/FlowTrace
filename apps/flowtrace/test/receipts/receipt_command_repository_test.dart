import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/data/ledger/ledger_projection.dart';
import 'package:flowtrace/data/ledger/ledger_repository.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/receipts/receipt_command_repository.dart';
import 'package:flowtrace/data/receipts/receipt_preview.dart';
import 'package:flowtrace/data/receipts/receipt_read_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show AllowedArgumentCount;

import '../ledger/query_fixtures.dart';

final class _DelayedCommitDatabase extends AppDatabase {
  _DelayedCommitDatabase() : super(NativeDatabase.memory());
  int _depth = 0;
  bool delayNext = false;
  final committed = Completer<void>();
  final release = Completer<void>();

  @override
  Future<T> atomicWrite<T>(Future<T> Function() action) async {
    final outermost = _depth++ == 0;
    late T result;
    try {
      result = await super.atomicWrite(action);
    } finally {
      _depth--;
    }
    if (outermost && delayNext) {
      delayNext = false;
      committed.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  late QueryFixture f;
  late ReceiptReadRepository reader;
  late ReceiptCommandRepository commands;
  late StreamController<void> authority;
  late ReceiptReadLease lease;
  var current = true;
  final sourceId = qid(9000), otherSourceId = qid(9001), receiptId = qid(9002);

  Money money(String value, {String currency = 'CNY'}) =>
      Money(currency, 2, BigInt.parse(value));

  Future<void> seedSource({
    String? id,
    String currency = 'CNY',
    String? remaining = '5000',
  }) async {
    final entity = id ?? sourceId;
    await f.putBill(entity, {
      'bill_type': 'expense',
      'money': qmoney('10000', currency: currency),
    }, revision: '7');
    final row =
        await (f.db.select(f.db.serverShadows)..where(
              (row) => row.entityId.equals(entity) & row.scopeId.equals(qBook),
            ))
            .getSingle();
    final raw = syncObject(jsonDecode(row.dataJson));
    raw['remaining_allocatable_minor'] = remaining;
    if (remaining == '5000') {
      raw['source_summary'] = {
        'refund_source_minor': '3000',
        'reimbursement_source_minor': '2000',
        'remaining_source_minor': '5000',
        'settlement_reason': 'open',
      };
    }
    await f.put('bill', entity, qBook, raw, revision: '7');
  }

  Future<ReceiptPreview> preview({
    ReceiptPreviewKind kind = ReceiptPreviewKind.refund,
    List<String>? sources,
    List<String>? amounts,
    List<String>? received,
    String total = '1000',
    String income = '0',
    String sourceCurrency = 'CNY',
    String? rate,
  }) async {
    final selections = <ReceiptPreviewSelection>[];
    for (final (index, id) in (sources ?? [sourceId]).indexed) {
      final query = ReceiptSourceQuery(scopeId: qBook, sourceId: id);
      selections.add(
        ReceiptPreviewSelection(
          lease: lease,
          query: query,
          read: await reader.read(lease, query),
          sourceMoney: money(
            amounts?[index] ?? '1000',
            currency: sourceCurrency,
          ),
          receiptMoney: money(received?[index] ?? amounts?[index] ?? '1000'),
          rate: rate,
        ),
      );
    }
    return ReceiptPreview.create(
      kind: kind,
      receiptMoney: money(total),
      incomeComponent: money(income),
      selections: selections,
    );
  }

  Map<String, Object?> payload(ReceiptPreview preview, {String? account}) =>
      normalizeLedgerPayload('bill', {
        'bill_type': preview.kind.name,
        'book_id': qOtherBook,
        'money': preview.receiptMoney.toJson(),
        'account_id': account ?? qCash,
        'business_date': '2026-10-22',
        'business_timezone': 'Asia/Shanghai',
        'allocations': preview.allocationPayloads,
        'income_component_minor': preview.incomeComponent.minor.toString(),
        'transfer_fx': null,
      });

  Future<ReceiptCreateResult> create(
    ReceiptPreview preview, {
    String? id,
    Map<String, Object?>? completePayload,
    ReceiptReadLease? currentLease,
  }) => commands.create(
    currentLease ?? lease,
    preview: preview,
    entityId: id ?? receiptId,
    receiptScopeId: qOtherBook,
    payload: completePayload ?? payload(preview),
  );

  Future<String> databaseState() async => canonicalSyncJson({
    'entities': [
      for (final row in await f.db.select(f.db.localEntities).get())
        {
          'type': row.entityType,
          'id': row.entityId,
          'scope': row.scopeId,
          'data': row.dataJson,
          'revision': row.serverRevision,
          'deleted': row.deleted,
        },
    ],
    'shadows': [
      for (final row in await f.db.select(f.db.serverShadows).get())
        {
          'scope': row.scopeId,
          'type': row.entityType,
          'id': row.entityId,
          'data': row.dataJson,
          'revision': row.revision,
          'deleted': row.deleted,
        },
    ],
    'operations': [
      for (final row in await f.db.select(f.db.pendingOperations).get())
        {
          'id': row.operationId,
          'entity': row.entityId,
          'intent': row.operationJson,
          'frozen': row.frozenRequestJson,
          'state': row.state,
          'predecessor': row.predecessorId,
          'revision': row.appliedRevision,
          'base': row.baseDataJson,
          'attempts': row.attemptCount,
        },
    ],
    'settings': {
      for (final row in await f.db.select(f.db.appSettings).get())
        row.key: row.value,
    },
  });

  Matcher error(String code) =>
      throwsA(isA<DomainError>().having((error) => error.code, 'code', code));

  setUp(() async {
    current = true;
    authority = StreamController<void>.broadcast(sync: true);
    f = QueryFixture(
      executor: NativeDatabase.memory(
        setup: (database) {
          database.createFunction(
            functionName: 'receipt_test_invalidate',
            argumentCount: const AllowedArgumentCount(0),
            directOnly: false,
            function: (_) {
              current = false;
              return 0;
            },
          );
        },
      ),
    );
    await f.seed();
    await (f.db.delete(
      f.db.localEntities,
    )..where((row) => row.entityType.equals('bill'))).go();
    await (f.db.delete(
      f.db.serverShadows,
    )..where((row) => row.entityType.equals('bill'))).go();
    await f.local.writeSetting(
      'sync.scopes.${f.space.id}',
      canonicalSyncJson({qBook: '1', qOtherBook: '1', qUser: '1'}),
    );
    await f.sync.applyPullPage(
      f.space,
      qEpoch,
      [],
      finalPage: true,
      checkpoint: {qBook: '3', qOtherBook: '2', qUser: '1'},
    );
    await seedSource();
    reader = ReceiptReadRepository(f.local);
    commands = ReceiptCommandRepository(reader: reader, ledger: f.ledger);
    lease = ReceiptReadLease(
      space: f.space,
      clientId: qid(5),
      epoch: qEpoch,
      isCurrent: () => current,
      invalidations: authority.stream,
    );
  });
  tearDown(() async {
    await authority.close();
    await f.close();
  });

  for (final kind in ReceiptPreviewKind.values) {
    test(
      'one ${kind.name} creates exactly one normal ledger bill and one monetary delta',
      () async {
        final prepared = await preview(kind: kind);
        final original = await databaseState();
        final result = await create(prepared);
        expect(result.entityId, receiptId);
        expect(result.alreadySaved, isFalse);
        final operations = await f.local.pending(f.space);
        expect(operations, hasLength(1));
        expect(operations.single.operationId, result.operationId);
        expect(
          syncObject(jsonDecode(operations.single.operationJson))['action'],
          'create',
        );
        expect(
          syncObject(jsonDecode(operations.single.operationJson))['payload'],
          payload(prepared),
        );
        final view = await f.ledger.read(f.space);
        expect(view.find('bill', receiptId)!.payload['bill_type'], kind.name);
        expect(view.balances[qCash]!.value!.minor, BigInt.from(101000));
        expect(await databaseState(), isNot(original));
      },
    );
  }

  test(
    'multi-source receipt preserves all exact allocations in one create',
    () async {
      await seedSource(id: otherSourceId);
      final prepared = await preview(
        sources: [sourceId, otherSourceId],
        amounts: ['500', '1500'],
        total: '2000',
      );
      await create(prepared);
      final operation = (await f.local.pending(f.space)).single;
      expect(
        syncObject(jsonDecode(operation.operationJson))['payload'],
        payload(prepared),
      );
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.value!.minor,
        BigInt.from(102000),
      );
    },
  );

  test(
    'cross-currency source and excess refund income retain frozen exact values',
    () async {
      await seedSource(currency: 'USD');
      final prepared = await preview(
        sourceCurrency: 'USD',
        amounts: ['1000'],
        received: ['7200'],
        rate: '7.200000000000000000',
        total: '7400',
        income: '200',
      );
      await create(prepared);
      final original = syncObject(
        jsonDecode((await f.local.pending(f.space)).single.operationJson),
      );
      expect((original['payload'] as Map)['allocations'], [
        {
          'source_bill_id': sourceId,
          'source_amount_minor': '1000',
          'receipt_amount_minor': '7200',
          'rate': '7.200000000000000000',
        },
      ]);
      expect((original['payload'] as Map)['income_component_minor'], '200');
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.value!.minor,
        BigInt.from(107400),
      );
    },
  );

  test('a reader and ledger from different databases are rejected', () async {
    final other = QueryFixture();
    try {
      expect(
        () => ReceiptCommandRepository(reader: reader, ledger: other.ledger),
        throwsArgumentError,
      );
    } finally {
      await other.close();
    }
  });

  for (final change in ['kind', 'money', 'allocations', 'income', 'book']) {
    test(
      'payload $change mismatch leaves all financial state unchanged',
      () async {
        final prepared = await preview();
        final changed = payload(prepared);
        switch (change) {
          case 'kind':
            changed['bill_type'] = 'reimbursement';
          case 'money':
            changed['money'] = qmoney('1001');
          case 'allocations':
            changed['allocations'] = [];
          case 'income':
            changed['income_component_minor'] = '1';
          case 'book':
            changed['book_id'] = qBook;
        }
        final before = await databaseState();
        await expectLater(
          create(prepared, completePayload: changed),
          error('receipt.payload_preview_mismatch'),
        );
        expect(await databaseState(), before);
      },
    );
  }

  test(
    'partial payload is not silently completed at the confirmation boundary',
    () async {
      final prepared = await preview();
      final changed = payload(prepared)..remove('flags');
      final before = await databaseState();
      await expectLater(
        create(prepared, completePayload: changed),
        error('receipt.incomplete_payload'),
      );
      expect(await databaseState(), before);
    },
  );

  for (final field in ['revision', 'checkpoint', 'remaining', 'permission']) {
    test('changed source $field invalidates preview before any save', () async {
      final prepared = await preview();
      switch (field) {
        case 'revision':
          await (f.db.update(f.db.serverShadows)
                ..where((row) => row.entityId.equals(sourceId)))
              .write(const ServerShadowsCompanion(revision: Value('8')));
        case 'checkpoint':
          await f.sync.applyPullPage(
            f.space,
            qEpoch,
            [],
            finalPage: true,
            checkpoint: {qBook: '4', qOtherBook: '2', qUser: '1'},
          );
        case 'remaining':
          await seedSource(remaining: '4000');
        case 'permission':
          await f.roles(version: '2');
          await f.local.writeSetting(
            'sync.scopes.${f.space.id}',
            canonicalSyncJson({qBook: '2', qOtherBook: '2', qUser: '1'}),
          );
      }
      final before = await databaseState();
      await expectLater(create(prepared), error('receipt.preview_changed'));
      expect(await databaseState(), before);
    });
  }

  for (final scope in ['source', 'receipt']) {
    test('$scope viewer cannot confirm a new receipt', () async {
      final prepared = await preview();
      await f.roles(
        role: scope == 'source' ? 'viewer' : 'owner',
        otherRole: scope == 'receipt' ? 'viewer' : 'owner',
      );
      final before = await databaseState();
      await expectLater(create(prepared), error('receipt.scope_unavailable'));
      expect(await databaseState(), before);
    });
  }

  test(
    'source revoke hides an old preview and preserves original payload',
    () async {
      final prepared = await preview();
      final complete = payload(prepared);
      await f.sync.revokeScope(f.space, qBook);
      final before = await databaseState();
      await expectLater(
        create(prepared, completePayload: complete),
        error('receipt.scope_unavailable'),
      );
      expect(await databaseState(), before);
      expect(complete, payload(prepared));
    },
  );

  test(
    'metadata pending is refused even when its public progress cut stays ready',
    () async {
      final prepared = await preview();
      final source = (await f.ledger.read(f.space)).find('bill', sourceId)!;
      await f.ledger.save(
        f.space,
        entityType: 'bill',
        scopeId: qBook,
        entityId: sourceId,
        payload: {...source.editablePayload!, 'reimbursement_tracking': true},
      );
      final before = await databaseState();
      await expectLater(create(prepared), error('receipt.pending_source'));
      expect(await databaseState(), before);
    },
  );

  for (final change in ['epoch', 'client', 'status', 'lease']) {
    test('$change changed after preview cannot write', () async {
      final prepared = await preview();
      if (change == 'lease') {
        current = false;
      } else {
        await (f.db.update(
          f.db.syncStates,
        )..where((row) => row.spaceId.equals(f.space.id))).write(
          SyncStatesCompanion(
            epoch: change == 'epoch' ? Value(qid(9999)) : const Value.absent(),
            clientId: change == 'client'
                ? Value(qid(9999))
                : const Value.absent(),
            status: change == 'status'
                ? const Value('recovery_required')
                : const Value.absent(),
          ),
        );
      }
      final before = await databaseState();
      await expectLater(create(prepared), error('receipt.identity_changed'));
      expect(await databaseState(), before);
    });
  }

  test(
    'unknown legacy remaining cannot replace a previously available source',
    () async {
      final prepared = await preview();
      await seedSource(remaining: null);
      final before = await databaseState();
      await expectLater(create(prepared), error('receipt.preview_changed'));
      expect(await databaseState(), before);
    },
  );

  test(
    'raw ACK or missing source cannot substitute canonical at confirmation',
    () async {
      final prepared = await preview();
      await f.shadow('bill', sourceId, qBook, {
        'bill_type': 'expense',
        'money': qmoney('10000'),
      }, revision: '8');
      final before = await databaseState();
      await expectLater(create(prepared), error('receipt.preview_changed'));
      expect(await databaseState(), before);
    },
  );

  test(
    'queued repeat finds original result and never posts a second amount',
    () async {
      final prepared = await preview();
      final first = await create(prepared);
      final before = await databaseState();
      final second = await create(prepared);
      expect(second.operationId, first.operationId);
      expect(second.alreadySaved, isTrue);
      expect(await databaseState(), before);
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.value!.minor,
        BigInt.from(101000),
      );
    },
  );

  test(
    'frozen retry repeat keeps original request bytes and single journal row',
    () async {
      final prepared = await preview();
      final first = await create(prepared);
      final frozen = (await f.sync.nextPush(f.space))!;
      final before = await databaseState();
      final second = await create(prepared);
      expect(second.operationId, first.operationId);
      expect(second.alreadySaved, isTrue);
      expect(await databaseState(), before);
      expect(
        (await f.local.pending(f.space)).single.frozenRequestJson,
        frozen.body,
      );
    },
  );

  test(
    'concurrent identical clicks share exactly one stable create operation',
    () async {
      final prepared = await preview();
      final results = await Future.wait([create(prepared), create(prepared)]);
      expect(results.map((result) => result.operationId).toSet(), hasLength(1));
      expect(results.where((result) => result.alreadySaved), hasLength(1));
      expect(await f.local.pending(f.space), hasLength(1));
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.value!.minor,
        BigInt.from(101000),
      );
    },
  );

  test(
    'applied receipt lookup returns known id after canonical redaction and source catchup',
    () async {
      final prepared = await preview();
      final complete = payload(prepared);
      final first = await create(prepared);
      final frozen = (await f.sync.nextPush(f.space))!;
      await f.sync.acknowledgeApplied(
        f.space,
        frozen,
        {
          'status': 'applied',
          'replayed': false,
          'operation_id': first.operationId,
          'entity_id': receiptId,
          'revision': '1',
          'commit_id': qid(9991),
          'scope_revisions': {qBook: '9', qOtherBook: '4', qUser: '2'},
        },
        clientId: lease.clientId,
        epoch: lease.epoch,
        isCurrent: () => current,
      );
      final oldSource =
          await (f.db.select(f.db.serverShadows)..where(
                (row) =>
                    row.scopeId.equals(qBook) & row.entityId.equals(sourceId),
              ))
              .getSingle();
      final updatedSource = syncObject(jsonDecode(oldSource.dataJson));
      updatedSource['remaining_allocatable_minor'] = '4000';
      updatedSource['source_summary'] = {
        'refund_source_minor': '4000',
        'reimbursement_source_minor': '2000',
        'remaining_source_minor': '4000',
        'settlement_reason': 'open',
      };
      final oldAccount =
          await (f.db.select(f.db.serverShadows)..where(
                (row) => row.scopeId.equals(qUser) & row.entityId.equals(qCash),
              ))
              .getSingle();
      final updatedAccount = syncObject(jsonDecode(oldAccount.dataJson))
        ..['balance'] = qmoney('101000');
      await f.sync.applyPullPage(
        f.space,
        qEpoch,
        [
          [
            SyncEvent(
              scopeId: qBook,
              entityType: 'bill',
              entityId: sourceId,
              revision: '8',
              deleted: false,
              data: updatedSource,
            ),
            SyncEvent(
              scopeId: qOtherBook,
              entityType: 'bill',
              entityId: receiptId,
              revision: '1',
              deleted: false,
              data: {
                'projection_kind': 'bill_public',
                'payload': {...complete, 'account_id': null},
                'hidden_account_fields': ['account_id'],
                'hidden_allocation_count': 0,
                'paid_by_user_ids': [qUser],
                'remaining_allocatable_minor': null,
              },
            ),
            SyncEvent(
              scopeId: qUser,
              entityType: 'bill',
              entityId: receiptId,
              revision: '1',
              deleted: false,
              data: {
                'projection_kind': 'bill_private_finance',
                'book_id': qOtherBook,
                'bill_type': 'refund',
                'business_date': '2026-10-22',
                'business_timezone': 'Asia/Shanghai',
                'occurred_at': null,
                'account_links': {
                  'account_id': qCash,
                  'from_account_id': null,
                  'to_account_id': null,
                  'fee_account_id': null,
                },
                'entries': [
                  {
                    'account_id': qCash,
                    'component': 'principal',
                    'money': qmoney('1000'),
                  },
                ],
              },
            ),
            SyncEvent(
              scopeId: qUser,
              entityType: 'account',
              entityId: qCash,
              revision: '2',
              deleted: false,
              data: updatedAccount,
            ),
          ],
        ],
        finalPage: true,
        checkpoint: {qBook: '9', qOtherBook: '4', qUser: '2'},
      );
      final before = await databaseState();
      final result = await create(prepared);
      expect(result.alreadySaved, isTrue);
      expect(result.operationId, first.operationId);
      expect(await databaseState(), before);
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.value!.minor,
        BigInt.from(101000),
      );
    },
  );

  test(
    'a second distinct receipt cannot reuse preview after first creates pending allocation',
    () async {
      final prepared = await preview();
      await create(prepared);
      final before = await databaseState();
      await expectLater(
        create(prepared, id: qid(9003)),
        error('receipt.pending_source'),
      );
      expect(await databaseState(), before);
    },
  );

  test(
    'same stable id with changed metadata is not an implicit update',
    () async {
      final prepared = await preview();
      await create(prepared);
      final before = await databaseState();
      final changed = payload(prepared)
        ..['note'] = 'Different input is a different confirmation';
      await expectLater(
        create(prepared, completePayload: changed),
        error('receipt.entity_in_use'),
      );
      expect(await databaseState(), before);
    },
  );

  test(
    'a later edit prevents treating an older create as a repeat click',
    () async {
      final prepared = await preview();
      await create(prepared);
      await f.ledger.save(
        f.space,
        entityType: 'bill',
        scopeId: qOtherBook,
        entityId: receiptId,
        payload: {...payload(prepared), 'note': 'later edit'},
      );
      final before = await databaseState();
      await expectLater(create(prepared), error('receipt.entity_in_use'));
      expect(await databaseState(), before);
    },
  );

  test(
    'a repeat click after source revocation does not expose or recreate anything',
    () async {
      final prepared = await preview();
      await create(prepared);
      await f.sync.revokeScope(f.space, qBook);
      final before = await databaseState();
      await expectLater(create(prepared), error('receipt.scope_unavailable'));
      expect(await databaseState(), before);
    },
  );

  test(
    'a repeat cannot bypass another local pending source mutation',
    () async {
      final prepared = await preview();
      await create(prepared);
      final source = (await f.ledger.read(f.space)).find('bill', sourceId)!;
      await f.ledger.save(
        f.space,
        entityType: 'bill',
        scopeId: qBook,
        entityId: sourceId,
        payload: {...source.editablePayload!, 'note': 'another local intent'},
      );
      final before = await databaseState();
      await expectLater(create(prepared), error('receipt.source_unavailable'));
      expect(await databaseState(), before);
    },
  );

  for (final state in ['rejected', 'blocked', 'discarded']) {
    test('$state create cannot be silently reused or recreated', () async {
      final prepared = await preview();
      final first = await create(prepared);
      await (f.db.update(f.db.pendingOperations)
            ..where((row) => row.operationId.equals(first.operationId)))
          .write(PendingOperationsCompanion(state: Value(state)));
      final before = await databaseState();
      await expectLater(create(prepared), error('receipt.entity_in_use'));
      expect(await databaseState(), before);
    });
  }

  test(
    'existing unrelated or later modified entity cannot be overwritten',
    () async {
      final prepared = await preview();
      await f.putBill(receiptId, {
        'bill_type': 'income',
        'money': qmoney('1000'),
      }, scope: qOtherBook);
      final before = await databaseState();
      await expectLater(create(prepared), error('receipt.entity_in_use'));
      expect(await databaseState(), before);
    },
  );

  test(
    'failure during outbox insert rolls back prior entity and posting writes',
    () async {
      final prepared = await preview();
      await f.db.customStatement('''CREATE TRIGGER receipt_test_abort
      BEFORE INSERT ON pending_operations WHEN NEW.entity_id = '$receiptId'
      BEGIN SELECT RAISE(ABORT, 'receipt_test_failure'); END''');
      final before = await databaseState();
      await expectLater(create(prepared), throwsA(isA<Exception>()));
      expect(await databaseState(), before);
    },
  );

  test(
    'identity lost after commit suppresses late success while preserving the committed bill',
    () async {
      final prepared = await preview();
      final db = _DelayedCommitDatabase();
      for (final row in await f.db.select(f.db.localSpaces).get()) {
        await db.into(db.localSpaces).insert(row.toCompanion(true));
      }
      for (final row in await f.db.select(f.db.localEntities).get()) {
        await db.into(db.localEntities).insert(row.toCompanion(true));
      }
      for (final row in await f.db.select(f.db.serverShadows).get()) {
        await db.into(db.serverShadows).insert(row.toCompanion(true));
      }
      for (final row in await f.db.select(f.db.syncStates).get()) {
        await db.into(db.syncStates).insert(row.toCompanion(true));
      }
      for (final row in await f.db.select(f.db.appSettings).get()) {
        await db.into(db.appSettings).insert(row.toCompanion(true));
      }
      final local = LocalRepository(db);
      final ledger = LedgerRepository(local);
      final adapter = ReceiptCommandRepository(
        reader: ReceiptReadRepository(local),
        ledger: ledger,
      );
      db.delayNext = true;
      final result = adapter.create(
        lease,
        preview: prepared,
        entityId: receiptId,
        receiptScopeId: qOtherBook,
        payload: payload(prepared),
      );
      try {
        await db.committed.future.timeout(const Duration(seconds: 3));
        current = false;
        db.release.complete();
        await expectLater(result, error('receipt.identity_changed'));
        expect((await local.pending(f.space)), hasLength(1));
        expect((await ledger.read(f.space)).find('bill', receiptId), isNotNull);
        expect(
          (await ledger.read(f.space)).balances[qCash]!.value!.minor,
          BigInt.from(101000),
          reason:
              'a committed old-space bill is preserved, not falsely called rolled back',
        );
      } finally {
        if (!db.release.isCompleted) db.release.complete();
        await db.close();
      }
    },
  );

  test(
    'remote edit restored to identical payload is not the original create revision',
    () async {
      final prepared = await preview();
      final complete = payload(prepared)..['account_id'] = null;
      final result = await create(prepared, completePayload: complete);
      final frozen = (await f.sync.nextPush(f.space))!;
      await f.sync.acknowledgeApplied(
        f.space,
        frozen,
        {
          'status': 'applied',
          'replayed': false,
          'operation_id': result.operationId,
          'entity_id': receiptId,
          'revision': '1',
          'commit_id': qid(9991),
          'scope_revisions': {qBook: '9', qOtherBook: '4'},
        },
        clientId: lease.clientId,
        epoch: lease.epoch,
        isCurrent: () => current,
      );
      final oldSource =
          await (f.db.select(f.db.serverShadows)..where(
                (row) =>
                    row.scopeId.equals(qBook) & row.entityId.equals(sourceId),
              ))
              .getSingle();
      final source = syncObject(jsonDecode(oldSource.dataJson));
      source['remaining_allocatable_minor'] = '4000';
      source['source_summary'] = {
        'refund_source_minor': '4000',
        'reimbursement_source_minor': '2000',
        'remaining_source_minor': '4000',
        'settlement_reason': 'open',
      };
      for (final (
            entityRevision,
            sourceRevision,
            sourceCursor,
            receiptCursor,
            note,
          )
          in [
            ('1', '8', '9', '4', ''),
            ('2', '9', '10', '5', 'remote edit'),
            ('3', '10', '11', '6', ''),
          ]) {
        await f.sync.applyPullPage(
          f.space,
          qEpoch,
          [
            [
              SyncEvent(
                scopeId: qBook,
                entityType: 'bill',
                entityId: sourceId,
                revision: sourceRevision,
                deleted: false,
                data: source,
              ),
              SyncEvent(
                scopeId: qOtherBook,
                entityType: 'bill',
                entityId: receiptId,
                revision: entityRevision,
                deleted: false,
                data: {
                  'projection_kind': 'bill_public',
                  'payload': {...complete, 'note': note},
                  'hidden_account_fields': [],
                  'hidden_allocation_count': 0,
                  'remaining_allocatable_minor': null,
                },
              ),
            ],
          ],
          finalPage: true,
          checkpoint: {
            qBook: sourceCursor,
            qOtherBook: receiptCursor,
            qUser: '1',
          },
        );
      }
      expect(
        (await f.ledger.read(f.space)).find('bill', receiptId)!.editablePayload,
        complete,
      );
      final before = await databaseState();
      await expectLater(
        create(prepared, completePayload: complete),
        error('receipt.entity_in_use'),
      );
      expect(await databaseState(), before);
    },
  );

  test(
    'lease lost after ledger insert rolls back entity outbox and postings together',
    () async {
      final prepared = await preview();
      await f.db.customStatement('''CREATE TRIGGER receipt_test_identity
      AFTER INSERT ON pending_operations WHEN NEW.entity_id = '$receiptId'
      BEGIN SELECT receipt_test_invalidate(); END''');
      final before = await databaseState();
      await expectLater(create(prepared), error('receipt.identity_changed'));
      expect(current, isFalse);
      expect(await databaseState(), before);
    },
  );
}
