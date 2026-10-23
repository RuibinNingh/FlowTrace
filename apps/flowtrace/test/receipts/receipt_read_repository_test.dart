import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/receipts/receipt_read_repository.dart';
import 'package:flowtrace/data/sync/receipt_ack_proof.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/domain/receipts/receipt_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart';

final class _PausedSnapshotDatabase extends AppDatabase {
  _PausedSnapshotDatabase() : super(NativeDatabase.memory());
  Completer<void>? pauseNext;
  Completer<void>? captured;

  @override
  Future<T> readSnapshot<T>(Future<T> Function() action) async {
    final release = pauseNext;
    pauseNext = null;
    final result = await super.readSnapshot(action);
    if (release != null) {
      captured!.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  late QueryFixture f;
  late ReceiptReadRepository reader;
  late StreamController<void> authority;
  var current = true;
  late ReceiptReadLease lease;
  final query = ReceiptSourceQuery(scopeId: qBook, sourceId: qa);
  final receipt = qid(8001);
  var operationSequence = 8100;

  Future<void> checkpoint(String value, {String? other}) async {
    await (f.db.update(
      f.db.syncStates,
    )..where((row) => row.spaceId.equals(f.space.id))).write(
      SyncStatesCompanion(
        cursorsJson: Value(
          jsonEncode({qBook: value, qOtherBook: other ?? '2', qUser: '1'}),
        ),
      ),
    );
  }

  Future<Map<String, Object?>> source({
    String id = '',
    String? scope,
    String revision = '7',
    bool summary = true,
    Object? remaining = '5000',
    bool tracking = false,
  }) async {
    final actualId = id.isEmpty ? qa : id;
    final book = scope ?? qBook;
    await f.putBill(
      actualId,
      {
        'bill_type': 'expense',
        'money': qmoney('10000'),
        'reimbursement_tracking': tracking,
      },
      scope: book,
      revision: revision,
    );
    final row =
        await (f.db.select(f.db.serverShadows)..where(
              (row) =>
                  row.spaceId.equals(f.space.id) &
                  row.scopeId.equals(book) &
                  row.entityId.equals(actualId),
            ))
            .getSingle();
    final raw = (jsonDecode(row.dataJson) as Map).cast<String, Object?>();
    raw['remaining_allocatable_minor'] = remaining;
    if (summary) {
      raw['source_summary'] = {
        'refund_source_minor': '3000',
        'reimbursement_source_minor': '2000',
        'remaining_source_minor': '5000',
        'settlement_reason': 'open',
      };
    }
    await f.put('bill', actualId, book, raw, revision: revision);
    return raw;
  }

  Map<String, Object?> allocation(String id) => {
    'source_bill_id': id,
    'source_money': qmoney('1000'),
    'receipt_money': qmoney('1000'),
    'fx': null,
  };

  Map<String, Object?> receiptPayload({
    List<String>? sources,
    String type = 'refund',
  }) => {
    'book_id': qOtherBook,
    'bill_type': type,
    'money': qmoney('1000'),
    'business_date': '2026-10-22',
    'business_timezone': 'Asia/Shanghai',
    'account_id': null,
    'allocations': [
      for (final id in sources ?? [qa]) allocation(id),
    ],
  };

  Future<String> queue({
    String? entity,
    String? scope,
    String action = 'create',
    required Map<String, Object?> payload,
    String base = '0',
  }) async {
    final id = qid(operationSequence++);
    await f.local.saveEntityAndQueue(
      f.space,
      QueuedCommand(
        operationId: id,
        scopeId: scope ?? qOtherBook,
        entityType: 'bill',
        entityId: entity ?? receipt,
        action: action,
        baseRevision: base,
        payload: payload,
      ),
    );
    return id;
  }

  Future<ReceiptSourceRead> read() => reader.read(lease, query);

  void hidden(ReceiptSourceRead result, {String? reason}) {
    expect(result.canonical, isNull);
    expect(result.canonicalState, isNull);
    if (reason != null) expect(result.reason, reason);
  }

  setUp(() async {
    current = true;
    operationSequence = 8100;
    authority = StreamController<void>.broadcast(sync: true);
    f = QueryFixture();
    await f.seed();
    await f.local.writeSetting(
      'sync.scopes.${f.space.id}',
      jsonEncode({qBook: '1', qOtherBook: '1', qUser: '1'}),
    );
    await checkpoint('3');
    await source();
    reader = ReceiptReadRepository(f.local);
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

  test(
    'authorized canonical keeps entity revision separate from scope checkpoint',
    () async {
      await source(revision: '9007199254740994');
      final result = await read();
      expect(result.disposition, ReceiptReadDisposition.ready);
      expect(result.canonical!.sourceId, qa);
      expect(result.canonical!.scopeId, qBook);
      expect(result.canonical!.entityRevision, '9007199254740994');
      expect(result.canonical!.checkpoint.scopeId, qBook);
      expect(result.canonical!.checkpoint.value, '3');
      expect(result.canonical!.permissionVersion, '1');
      expect(result.canonicalState!.refundSourceMinor, BigInt.from(3000));
      expect(
        result.canonicalState!.reimbursementSourceMinor,
        BigInt.from(2000),
      );
      expect(
        result.canonicalState!.remainingAllocatableMinor,
        BigInt.from(5000),
      );
      expect(result.localTracking!.enabled, isFalse);
      expect(result.hasPending, isFalse);
      expect(result.hasConflict, isFalse);
    },
  );

  test('legacy summary absence preserves unknown components', () async {
    await source(summary: false);
    final state = (await read()).canonicalState!;
    expect(state.breakdownKnown, isFalse);
    expect(state.refundSourceMinor, isNull);
    expect(state.reimbursementSourceMinor, isNull);
    expect(state.remainingAllocatableMinor, BigInt.from(5000));
    expect(state.allocatedSourceMinor, BigInt.from(5000));
  });

  test(
    'legacy null remaining stays unknown instead of assuming no receipts',
    () async {
      await source(summary: false, remaining: null);
      final state = (await read()).canonicalState!;
      expect(state.remainingAllocatableMinor, isNull);
      expect(state.settlementProgress, ReceiptSettlementProgress.unknown);
      expect(state.refundProgress, ReceiptComponentProgress.unknown);
    },
  );

  for (final role in ['owner', 'editor', 'viewer']) {
    test(
      'confirmed $role may read public source without financial write rights',
      () async {
        await f.roles(role: role);
        expect((await read()).canonical!.role, role);
      },
    );
  }

  test(
    'role cannot be inferred from a new book create or local public shape',
    () async {
      final book = qid(9000);
      await f.local.saveEntityAndQueue(
        f.space,
        QueuedCommand(
          operationId: qid(9001),
          scopeId: qUser,
          entityType: 'book',
          entityId: book,
          action: 'create',
          baseRevision: '0',
          payload: {'name': 'local'},
        ),
      );
      await source(scope: book);
      final result = await reader.read(
        lease,
        ReceiptSourceQuery(scopeId: book, sourceId: qa),
      );
      hidden(result, reason: 'scope_unconfirmed');
    },
  );

  for (final missing in ['sync.scope-details', 'sync.scopes']) {
    test('$missing missing cannot authorize canonical parsing', () async {
      await (f.db.delete(
        f.db.appSettings,
      )..where((row) => row.key.equals('$missing.${f.space.id}'))).go();
      hidden(await read(), reason: 'scope_unconfirmed');
    });
  }

  test(
    'permission vector and role details must describe the same version',
    () async {
      await f.roles(version: '2');
      hidden(await read(), reason: 'scope_unconfirmed');
    },
  );

  test('role cache from another epoch is not an authorization proof', () async {
    await f.local.writeSetting(
      'sync.scope-details.${f.space.id}',
      jsonEncode({
        'version': 1,
        'epoch': qid(9900),
        'scopes': [
          {
            'scope_id': qBook,
            'kind': 'book',
            'role': 'owner',
            'permission_version': '1',
          },
        ],
      }),
    );
    hidden(await read(), reason: 'scope_unconfirmed');
  });

  for (final field in ['clientId', 'epoch', 'status']) {
    test(
      'changed $field hides all controlled output and local intent',
      () async {
        await (f.db.update(
          f.db.syncStates,
        )..where((row) => row.spaceId.equals(f.space.id))).write(
          SyncStatesCompanion(
            clientId: field == 'clientId'
                ? Value(qid(9900))
                : const Value.absent(),
            epoch: field == 'epoch' ? Value(qid(9900)) : const Value.absent(),
            status: field == 'status'
                ? const Value('needs_rebuild')
                : const Value.absent(),
          ),
        );
        final result = await read();
        hidden(result);
        expect(result.localTracking, isNull);
        expect(result.intents, isEmpty);
      },
    );
  }

  test(
    'revocation wins over still present canonical and confirmed role',
    () async {
      await (f.db.update(
        f.db.syncStates,
      )..where((row) => row.spaceId.equals(f.space.id))).write(
        SyncStatesCompanion(revokedScopesJson: Value(jsonEncode([qBook]))),
      );
      final result = await read();
      hidden(result, reason: 'scope_revoked');
      expect(result.localTracking, isNull);
    },
  );

  test(
    'missing formal source checkpoint cannot be replaced by entity revision',
    () async {
      await (f.db.update(f.db.syncStates)
            ..where((row) => row.spaceId.equals(f.space.id)))
          .write(const SyncStatesCompanion(cursorsJson: Value('{}')));
      hidden(await read(), reason: 'scope_checkpoint_missing');
    },
  );

  test(
    'raw ACK shadow with valid expense payload is not public canonical',
    () async {
      final raw = await source();
      await f.shadow(
        'bill',
        qa,
        qBook,
        (raw['payload'] as Map).cast<String, Object?>(),
        revision: '8',
      );
      hidden(await read(), reason: 'source_public_required');
    },
  );

  test('private finance cannot supply source body or summary', () async {
    await (f.db.delete(
      f.db.serverShadows,
    )..where((row) => row.entityId.equals(qa))).go();
    await f.shadow('bill', qa, qUser, {
      'projection_kind': 'bill_private_finance',
      'book_id': qBook,
      'bill_type': 'expense',
      'money': qmoney('10000'),
      'source_summary': {'refund_source_minor': '0'},
    });
    hidden(await read(), reason: 'source_unavailable');
  });

  test(
    'source tombstone cannot be resurrected by leftover local payload',
    () async {
      await (f.db.update(f.db.serverShadows)..where(
            (row) => row.entityId.equals(qa) & row.scopeId.equals(qBook),
          ))
          .write(const ServerShadowsCompanion(deleted: Value(true)));
      hidden(await read(), reason: 'source_unavailable');
    },
  );

  test('foreign book id in a public payload is rejected', () async {
    final raw = await source();
    raw['payload'] = {
      ...(raw['payload'] as Map).cast<String, Object?>(),
      'book_id': qOtherBook,
    };
    await f.put('bill', qa, qBook, raw, revision: '7');
    hidden(await read(), reason: 'source_public_required');
  });

  test(
    'metadata tracking is distinct from canonical state and conflicted intent',
    () async {
      final raw = await source();
      final payload = {
        ...(raw['payload'] as Map).cast<String, Object?>(),
        'reimbursement_tracking': true,
      };
      final op = await queue(
        entity: qa,
        scope: qBook,
        action: 'update',
        payload: payload,
        base: '7',
      );
      var result = await read();
      expect(result.disposition, ReceiptReadDisposition.ready);
      expect(result.canonicalState!.tracking.enabled, isFalse);
      expect(result.localTracking!.enabled, isTrue);
      expect(result.intents.single.kind, ReceiptIntentKind.metadata);
      expect(result.hasPending, isTrue);
      await (f.db.update(f.db.pendingOperations)
            ..where((row) => row.operationId.equals(op)))
          .write(const PendingOperationsCompanion(state: Value('rejected')));
      result = await read();
      expect(result.canonicalState!.tracking.enabled, isFalse);
      expect(result.localTracking!.enabled, isTrue);
      expect(result.hasConflict, isTrue);
      expect(result.hasPending, isFalse);
    },
  );

  test(
    'financial source pending does not attach old summary to local new amount',
    () async {
      final raw = await source();
      await queue(
        entity: qa,
        scope: qBook,
        action: 'update',
        base: '7',
        payload: {
          ...(raw['payload'] as Map).cast<String, Object?>(),
          'money': qmoney('12000'),
          'reimbursement_tracking': true,
        },
      );
      final result = await read();
      hidden(result, reason: 'awaiting_source_sync');
      expect(result.disposition, ReceiptReadDisposition.awaitingSourceSync);
      expect(result.localTracking!.enabled, isTrue);
      expect(result.intents.single.kind, ReceiptIntentKind.sourceFinancial);
      final stored = await f.local.pending(f.space);
      expect(
        (jsonDecode(stored.single.operationJson)['payload'] as Map)['money'],
        qmoney('12000'),
      );
    },
  );

  test(
    'financial conflict is explicit unavailable rather than waiting for auto sync',
    () async {
      final raw = await source();
      final op = await queue(
        entity: qa,
        scope: qBook,
        action: 'update',
        base: '7',
        payload: {
          ...(raw['payload'] as Map).cast<String, Object?>(),
          'money': qmoney('12000'),
        },
      );
      await (f.db.update(f.db.pendingOperations)
            ..where((row) => row.operationId.equals(op)))
          .write(const PendingOperationsCompanion(state: Value('blocked')));
      final result = await read();
      hidden(result, reason: 'receipt_local_conflict');
      expect(result.disposition, ReceiptReadDisposition.unavailable);
      expect(result.hasConflict, isTrue);
    },
  );

  test(
    'pending receipt create waits for its source rather than receipt scope',
    () async {
      await queue(payload: receiptPayload());
      final result = await read();
      hidden(result, reason: 'awaiting_source_sync');
      expect(result.intents.single.kind, ReceiptIntentKind.linkedReceipt);
    },
  );

  test('complete unrelated receipt create does not block a source', () async {
    await queue(payload: receiptPayload(sources: [qb]));
    expect((await read()).disposition, ReceiptReadDisposition.ready);
  });

  test('receipt A to B waits for both removed and new sources', () async {
    await source(id: qb);
    await f.putBill(
      receipt,
      receiptPayload(),
      scope: qOtherBook,
      revision: '4',
    );
    await queue(
      action: 'update',
      base: '4',
      payload: receiptPayload(sources: [qb]),
    );
    hidden(await read(), reason: 'awaiting_source_sync');
    final other = await reader.read(
      lease,
      ReceiptSourceQuery(scopeId: qBook, sourceId: qb),
    );
    hidden(other, reason: 'awaiting_source_sync');
  });

  test(
    'receipt delete empty payload still waits for its before source',
    () async {
      await f.putBill(
        receipt,
        receiptPayload(),
        scope: qOtherBook,
        revision: '4',
      );
      await queue(action: 'delete', base: '4', payload: {});
      hidden(await read(), reason: 'awaiting_source_sync');
    },
  );

  test(
    'unprovable old receipt update is conservative without guessing hidden ids',
    () async {
      await queue(
        action: 'update',
        base: '4',
        payload: receiptPayload(sources: [qb], type: 'income'),
      );
      final result = await read();
      hidden(result, reason: 'awaiting_source_sync');
      expect(result.intents.single.kind, ReceiptIntentKind.unproven);
    },
  );

  test(
    'strict hidden metadata does not invent foreign source dependencies',
    () async {
      await f.putBill(
        receipt,
        receiptPayload(sources: []),
        scope: qOtherBook,
        revision: '4',
      );
      final existing =
          await (f.db.select(f.db.serverShadows)..where(
                (row) =>
                    row.entityId.equals(receipt) &
                    row.scopeId.equals(qOtherBook),
              ))
              .getSingle();
      final raw = (jsonDecode(existing.dataJson) as Map)
          .cast<String, Object?>();
      raw['hidden_allocation_count'] = 2;
      await f.put('bill', receipt, qOtherBook, raw, revision: '4');
      await queue(
        action: 'update',
        base: '4',
        payload: {
          ...(raw['payload'] as Map).cast<String, Object?>(),
          'preserve_hidden_financial_links': true,
          'note': 'metadata only',
        },
      );
      expect((await read()).disposition, ReceiptReadDisposition.ready);
    },
  );

  test(
    'newer raw local revision cannot borrow an older public summary',
    () async {
      await (f.db.update(f.db.localEntities)
            ..where((row) => row.entityId.equals(qa)))
          .write(const LocalEntitiesCompanion(serverRevision: Value('8')));
      hidden(await read(), reason: 'source_cut_not_installed');
    },
  );

  Future<FrozenPush> freezeReceipt() async {
    await queue(payload: receiptPayload());
    return (await f.sync.nextPush(f.space))!;
  }

  Future<void> applied(FrozenPush frozen, {String requiredCursor = '9'}) =>
      f.sync.acknowledgeApplied(
        f.space,
        frozen,
        {
          'status': 'applied',
          'replayed': false,
          'operation_id': frozen.operationId,
          'entity_id': receipt,
          'revision': '1',
          'commit_id': qid(8888),
          'scope_revisions': {qBook: requiredCursor, qOtherBook: '4'},
        },
        clientId: qid(5),
        epoch: qEpoch,
        isCurrent: () => current,
      );

  Future<void> pullReceipt({
    required String requiredCursor,
    required bool finalPage,
    String otherCursor = '4',
  }) async {
    final old =
        await (f.db.select(f.db.serverShadows)..where(
              (row) =>
                  row.spaceId.equals(f.space.id) &
                  row.scopeId.equals(qBook) &
                  row.entityId.equals(qa),
            ))
            .getSingle();
    final raw = (jsonDecode(old.dataJson) as Map).cast<String, Object?>();
    raw['remaining_allocatable_minor'] = '4000';
    raw['source_summary'] = {
      'refund_source_minor': '4000',
      'reimbursement_source_minor': '2000',
      'remaining_source_minor': '4000',
      'settlement_reason': 'open',
    };
    await f.sync.applyPullPage(
      f.space,
      qEpoch,
      [
        [
          SyncEvent(
            scopeId: qBook,
            entityType: 'bill',
            entityId: qa,
            revision: '8',
            deleted: false,
            data: raw,
          ),
          SyncEvent(
            scopeId: qOtherBook,
            entityType: 'bill',
            entityId: receipt,
            revision: '1',
            deleted: false,
            data: {
              'projection_kind': 'bill_public',
              'payload': receiptPayload(),
              'hidden_account_fields': [],
              'hidden_allocation_count': 0,
            },
          ),
        ],
      ],
      finalPage: finalPage,
      checkpoint: finalPage
          ? {qBook: requiredCursor, qOtherBook: otherCursor, qUser: '1'}
          : null,
    );
  }

  test(
    'formal ACK and single receipt canonical cannot release source checkpoint barrier',
    () async {
      final frozen = await freezeReceipt();
      await applied(frozen, requiredCursor: '9007199254740994');
      // A single-entity read may install this receipt; it is no source proof.
      await f.put('bill', receipt, qOtherBook, {
        'projection_kind': 'bill_public',
        'payload': receiptPayload(),
        'hidden_allocation_count': 0,
      });
      final result = await read();
      hidden(result, reason: 'awaiting_source_sync');
      expect(result.requiredCursors, {qBook: '9007199254740994'});
      expect(result.causalOperationIds, [frozen.operationId]);
      expect(result.disposition, ReceiptReadDisposition.awaitingSourceSync);
    },
  );

  test(
    'whole non-final commit updates source but only final checkpoint releases it',
    () async {
      final frozen = await freezeReceipt();
      await applied(frozen);
      await pullReceipt(requiredCursor: '9', finalPage: false);
      hidden(await read(), reason: 'awaiting_source_sync');
      await f.sync.applyPullPage(
        f.space,
        qEpoch,
        [],
        finalPage: true,
        checkpoint: {qBook: '9', qOtherBook: '4', qUser: '1'},
      );
      final result = await read();
      expect(result.disposition, ReceiptReadDisposition.ready);
      expect(result.canonical!.entityRevision, '8');
      expect(result.canonical!.checkpoint.value, '9');
      expect(result.canonicalState!.refundSourceMinor, BigInt.from(4000));
      expect(
        result.canonicalState!.remainingAllocatableMinor,
        BigInt.from(4000),
      );
    },
  );

  test(
    'pull before ACK immediately satisfies persisted source barrier',
    () async {
      final frozen = await freezeReceipt();
      await pullReceipt(requiredCursor: '9', finalPage: true);
      hidden(await read(), reason: 'awaiting_source_sync');
      await applied(frozen);
      final result = await read();
      expect(result.disposition, ReceiptReadDisposition.ready);
      expect(result.canonicalState!.refundSourceMinor, BigInt.from(4000));
      await applied(frozen);
      expect((await read()).canonical!.checkpoint.value, '9');
      final proofs =
          await (f.db.select(f.db.appSettings)..where(
                (row) => row.key.like('${receiptAckProofPrefix(f.space)}%'),
              ))
              .get();
      expect(proofs, hasLength(1));
    },
  );

  test(
    'legacy revision-only ACK stays unavailable until exact formal replay',
    () async {
      final frozen = await freezeReceipt();
      await f.sync.acknowledge(f.space, frozen.operationId, '1');
      await pullReceipt(requiredCursor: '9', finalPage: true);
      hidden(await read(), reason: 'receipt_ack_missing');
      await applied(frozen);
      expect((await read()).disposition, ReceiptReadDisposition.ready);
    },
  );

  test(
    'exact big scope checkpoint comparison never rounds through double',
    () async {
      final frozen = await freezeReceipt();
      await applied(frozen, requiredCursor: '9007199254740993');
      await checkpoint('9007199254740992', other: '9007199254740999');
      hidden(await read(), reason: 'awaiting_source_sync');
      await pullReceipt(
        requiredCursor: '9007199254740993',
        finalPage: true,
        otherCursor: '9007199254740999',
      );
      expect((await read()).canonical!.checkpoint.value, '9007199254740993');
    },
  );

  test(
    'unfrozen A to B to C chain still waits for the true pending before B',
    () async {
      await source(id: qb);
      await source(id: qf);
      await f.putBill(
        receipt,
        receiptPayload(),
        scope: qOtherBook,
        revision: '4',
      );
      await queue(
        action: 'update',
        base: '4',
        payload: receiptPayload(sources: [qb]),
      );
      final second = await queue(
        action: 'update',
        base: '4',
        payload: receiptPayload(sources: [qf]),
      );
      final first = (await f.sync.nextPush(f.space))!;
      await f.sync.acknowledgeApplied(
        f.space,
        first,
        {
          'status': 'applied',
          'replayed': false,
          'operation_id': first.operationId,
          'entity_id': receipt,
          'revision': '5',
          'commit_id': qid(8888),
          'scope_revisions': {qBook: '9', qOtherBook: '4'},
        },
        clientId: qid(5),
        epoch: qEpoch,
        isCurrent: () => current,
      );
      final sourceEvents = <SyncEvent>[];
      for (final (id, refund, remaining) in [
        (qa, '2000', '6000'),
        (qb, '4000', '4000'),
      ]) {
        final old =
            await (f.db.select(f.db.serverShadows)..where(
                  (row) => row.entityId.equals(id) & row.scopeId.equals(qBook),
                ))
                .getSingle();
        final raw = (jsonDecode(old.dataJson) as Map).cast<String, Object?>();
        raw['remaining_allocatable_minor'] = remaining;
        raw['source_summary'] = {
          'refund_source_minor': refund,
          'reimbursement_source_minor': '2000',
          'remaining_source_minor': remaining,
          'settlement_reason': 'open',
        };
        sourceEvents.add(
          SyncEvent(
            scopeId: qBook,
            entityType: 'bill',
            entityId: id,
            revision: '8',
            deleted: false,
            data: raw,
          ),
        );
      }
      await f.sync.applyPullPage(
        f.space,
        qEpoch,
        [
          [
            ...sourceEvents,
            SyncEvent(
              scopeId: qOtherBook,
              entityType: 'bill',
              entityId: receipt,
              revision: '5',
              deleted: false,
              data: {
                'projection_kind': 'bill_public',
                'payload': receiptPayload(sources: [qb]),
                'hidden_allocation_count': 0,
              },
            ),
          ],
        ],
        finalPage: true,
        checkpoint: {qBook: '9', qOtherBook: '4', qUser: '1'},
      );
      final pending = await (f.db.select(
        f.db.pendingOperations,
      )..where((row) => row.operationId.equals(second))).getSingle();
      expect(pending.frozenRequestJson, isNull);
      expect(
        (jsonDecode(pending.baseDataJson!)['payload']['allocations'] as List)
            .single['source_bill_id'],
        qa,
        reason: 'entry-time base really is stale A',
      );
      final result = await reader.read(
        lease,
        ReceiptSourceQuery(scopeId: qBook, sourceId: qb),
      );
      hidden(result, reason: 'awaiting_source_sync');
      expect(
        result.intents.any((intent) => intent.operationId == second),
        isTrue,
      );
    },
  );

  test('false lease before snapshot hides every controlled field', () async {
    current = false;
    hidden(await read(), reason: 'identity_changed');
  });

  test(
    'lease invalidated while snapshot loads cannot deliver its old cut',
    () async {
      var checks = 0;
      final changing = ReceiptReadLease(
        space: f.space,
        clientId: qid(5),
        epoch: qEpoch,
        invalidations: authority.stream,
        isCurrent: () => ++checks == 1,
      );
      hidden(await reader.read(changing, query), reason: 'identity_changed');
    },
  );

  Future<void> until(bool Function() predicate) async {
    for (var i = 0; i < 100 && !predicate(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      predicate(),
      isTrue,
      reason: 'watch did not deliver its expected cut',
    );
  }

  test(
    'watch hides identity immediately even with no database mutation',
    () async {
      final values = <ReceiptSourceRead>[];
      final sub = reader.watch(lease, query).listen(values.add);
      await until(() => values.any((value) => value.canonical != null));
      current = false;
      authority.add(null);
      await until(() => values.last.reason == 'identity_changed');
      hidden(values.last);
      expect(values.last.localTracking, isNull);
      await sub.cancel();
    },
  );

  test(
    'authority invalidation hides the old cut before rereading a still current lease',
    () async {
      final values = <ReceiptSourceRead>[];
      final sub = reader.watch(lease, query).listen(values.add);
      await until(() => values.any((value) => value.canonical != null));
      final previous = values.length;
      authority.add(null);
      await until(() => values.length > previous);
      hidden(values[previous], reason: 'authority_changed');
      await until(() => values.last.canonical != null);
      await sub.cancel();
    },
  );

  test(
    'database revocation notification prevents a delayed old read from republishing',
    () async {
      final db = _PausedSnapshotDatabase();
      final local = LocalRepository(db);
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
      final values = <ReceiptSourceRead>[];
      final reader = ReceiptReadRepository(local);
      final sub = reader.watch(lease, query).listen(values.add);
      final observerEvents = <int>[];
      final observer = db
          .customSelect('SELECT 1', readsFrom: {db.syncStates})
          .watch()
          .listen((_) => observerEvents.add(1));
      final release = Completer<void>();
      try {
        await until(() => values.any((value) => value.canonical != null));
        await until(() => observerEvents.isNotEmpty);
        db.pauseNext = release;
        db.captured = Completer<void>();
        await (db.update(db.serverShadows)
              ..where((row) => row.entityId.equals(qa)))
            .write(const ServerShadowsCompanion(revision: Value('8')));
        await db.captured!.future.timeout(const Duration(seconds: 3));
        final previous = values.length;
        final notifications = observerEvents.length;
        await (db.update(
          db.syncStates,
        )..where((row) => row.spaceId.equals(f.space.id))).write(
          SyncStatesCompanion(revokedScopesJson: Value(jsonEncode([qBook]))),
        );
        await until(() => observerEvents.length > notifications);
        await Future<void>.delayed(Duration.zero);
        release.complete();
        await until(() => values.last.reason == 'scope_revoked');
        expect(
          values.skip(previous).where((value) => value.canonical != null),
          isEmpty,
          reason: 'no old canonical may follow a known revocation notification',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await sub.cancel();
        await observer.cancel();
        await db.close();
      }
    },
  );

  for (final end in ['done', 'error']) {
    test('authority $end removes old output and ends watch', () async {
      final values = <ReceiptSourceRead>[];
      final done = Completer<void>();
      final sub = reader
          .watch(lease, query)
          .listen(values.add, onDone: done.complete);
      await until(() => values.any((value) => value.canonical != null));
      if (end == 'done') {
        await authority.close();
      } else {
        authority.addError(StateError('authority unavailable'));
      }
      await done.future.timeout(const Duration(seconds: 3));
      hidden(
        values.last,
        reason: 'authority_stream_${end == 'done' ? 'ended' : 'error'}',
      );
      await sub.cancel();
    });
  }

  test(
    'watch observes settings and revocation with no controlled residue',
    () async {
      final values = <ReceiptSourceRead>[];
      final sub = reader.watch(lease, query).listen(values.add);
      await until(() => values.any((value) => value.canonical != null));
      await f.roles(version: '2');
      await until(() => values.last.reason == 'scope_unconfirmed');
      hidden(values.last);
      await f.roles();
      await until(() => values.last.canonical != null);
      await f.sync.revokeScope(f.space, qBook);
      await until(() => values.last.reason == 'scope_revoked');
      hidden(values.last);
      await sub.cancel();
    },
  );

  test(
    'watch observes entity, shadow and operation changes independently',
    () async {
      final values = <ReceiptSourceRead>[];
      final sub = reader.watch(lease, query).listen(values.add);
      await until(() => values.any((value) => value.canonical != null));
      await (f.db.update(f.db.localEntities)
            ..where((row) => row.entityId.equals(qa)))
          .write(const LocalEntitiesCompanion(serverRevision: Value('8')));
      await until(() => values.last.reason == 'source_cut_not_installed');
      await source(revision: '8');
      await until(() => values.last.canonical?.entityRevision == '8');
      await (f.db.update(f.db.serverShadows)..where(
            (row) => row.entityId.equals(qa) & row.scopeId.equals(qBook),
          ))
          .write(const ServerShadowsCompanion(deleted: Value(true)));
      await until(() => values.last.reason == 'source_unavailable');
      await source(revision: '9');
      await until(() => values.last.canonical?.entityRevision == '9');
      await queue(payload: receiptPayload());
      await until(() => values.last.reason == 'awaiting_source_sync');
      hidden(values.last);
      await sub.cancel();
    },
  );
}
