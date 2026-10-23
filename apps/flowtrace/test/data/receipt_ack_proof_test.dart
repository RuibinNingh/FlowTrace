import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/receipt_ack_proof.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import 'local_repository_test.dart' show testSpace;

const _a = 'aa000000-0000-4000-8000-000000000001';
const _b = 'aa000000-0000-4000-8000-000000000002';
const _c = 'aa000000-0000-4000-8000-000000000003';
const _sourceA = 'bb000000-0000-4000-8000-000000000001';
const _sourceB = 'bb000000-0000-4000-8000-000000000002';
const _receipt = 'bb000000-0000-4000-8000-000000000003';
const _client = 'cc000000-0000-4000-8000-000000000001';
const _epoch = 'dd000000-0000-4000-8000-000000000001';
const _op1 = 'ee000000-0000-4000-8000-000000000001';
const _op2 = 'ee000000-0000-4000-8000-000000000002';
const _commit = 'ff000000-0000-4000-8000-000000000001';
const _large = '9007199254740995';

void main() {
  final space = testSpace(
    user: 'fa000000-0000-4000-8000-000000000001',
    instance: 'fa000000-0000-4000-8000-000000000002',
  );
  late AppDatabase db;
  late LocalRepository local;
  late SyncStore store;
  var current = true;

  Map<String, Object?> payload(List<String> ids, {String type = 'refund'}) => {
    'bill_type': type,
    'book_id': _c,
    'money': {'amount_minor': '100', 'currency': 'CNY'},
    'note': '',
    'allocations': [
      for (final id in ids) {'source_bill_id': id},
    ],
  };
  SyncEvent public(
    String scope,
    String id,
    String revision,
    Map<String, Object?> body, {
    int hidden = 0,
  }) => SyncEvent(
    scopeId: scope,
    entityType: 'bill',
    entityId: id,
    revision: revision,
    deleted: false,
    data: {
      'projection_kind': 'bill_public',
      'payload': body,
      'hidden_allocation_count': hidden,
    },
  );
  Future<void> seed() => store.applyPullPage(
    space,
    _epoch,
    [
      [
        public(_a, _sourceA, '9007199254740999', payload([], type: 'expense')),
        public(_b, _sourceB, '1', payload([], type: 'expense')),
      ],
    ],
    finalPage: true,
    checkpoint: {_a: '5', _b: '2', _c: '0', space.userId: '0'},
  );
  Future<void> queue(
    String id,
    List<String> sources, {
    String action = 'create',
    String base = '0',
    Map<String, Object?>? body,
  }) => local.saveEntityAndQueue(
    space,
    QueuedCommand(
      operationId: id,
      scopeId: _c,
      entityType: 'bill',
      entityId: _receipt,
      action: action,
      baseRevision: base,
      payload: body ?? (action == 'delete' ? {} : payload(sources)),
    ),
  );
  Map<String, Object?> receipt(
    String id, {
    String revision = '1',
    Map<String, String>? vector,
    String commit = _commit,
    bool replayed = false,
  }) => {
    'operation_id': id,
    'status': 'applied',
    'entity_id': _receipt,
    'revision': revision,
    'commit_id': commit,
    'scope_revisions': vector ?? {_a: _large, _c: '1'},
    'replayed': replayed,
  };
  Future<void> ack(FrozenPush frozen, Map<String, Object?> response) =>
      store.acknowledgeApplied(
        space,
        frozen,
        response,
        clientId: _client,
        epoch: _epoch,
        isCurrent: () => current,
      );
  Future<Map<String, String>> settings() async => {
    for (final row in await db.select(db.appSettings).get()) row.key: row.value,
  };
  Future<ReceiptCausalStatus> status({
    String id = _sourceA,
    String scope = _a,
  }) async => receiptCausalStatus(
    space: space,
    state: await store.state(space),
    settings: await settings(),
    operations: await db.select(db.pendingOperations).get(),
    sourceId: id,
    sourceScopeId: scope,
  );
  Future<void> checkpoint(Map<String, String> vector) => store.applyPullPage(
    space,
    _epoch,
    [],
    finalPage: true,
    checkpoint: vector,
  );
  setUp(() async {
    current = true;
    db = AppDatabase(NativeDatabase.memory());
    local = LocalRepository(db);
    store = SyncStore(local);
    await local.registerSpace(space);
    await store.configure(space, _client, _epoch);
    await seed();
  });
  tearDown(() => db.close());

  test(
    'formal ACK persists bound scope vector; entity revision cannot release source cursor',
    () async {
      await queue(_op1, [_sourceA]);
      final frozen = (await store.nextPush(space))!;
      await ack(frozen, receipt(_op1));
      final value = await status();
      expect(value.disposition, ReceiptCausalDisposition.awaitingSourceSync);
      expect(value.requiredCursors, {_a: _large});
      expect(value.operationIds, [_op1]);
      expect(
        (await db.select(db.pendingOperations).getSingle()).state,
        'applied',
      );
      await checkpoint({_a: _large});
      expect((await status()).disposition, ReceiptCausalDisposition.satisfied);
    },
  );

  test(
    'pull before ACK is immediately satisfied and replayed flag alone changes no proof',
    () async {
      await queue(_op1, [_sourceA]);
      final frozen = (await store.nextPush(space))!;
      await checkpoint({_a: _large});
      await ack(frozen, receipt(_op1));
      final before = await settings();
      expect((await status()).disposition, ReceiptCausalDisposition.satisfied);
      await ack(frozen, receipt(_op1, replayed: true));
      expect(await settings(), before);
    },
  );

  test(
    'nonfinal complete commit and tail failure never advance formal cursor',
    () async {
      await queue(_op1, [_sourceA]);
      final frozen = (await store.nextPush(space))!;
      await ack(frozen, receipt(_op1));
      await store.applyPullPage(space, _epoch, [
        [
          public(
            _a,
            _sourceA,
            '9007199254741000',
            payload([], type: 'expense'),
          ),
        ],
      ], finalPage: false);
      expect(
        (await status()).disposition,
        ReceiptCausalDisposition.awaitingSourceSync,
      );
      expect(jsonDecode((await store.state(space))!.cursorsJson)[_a], '5');
      await expectLater(checkpoint({_a: '4'}), throwsStateError);
      expect(
        (await status()).disposition,
        ReceiptCausalDisposition.awaitingSourceSync,
      );
      await checkpoint({_a: _large});
      expect((await status()).disposition, ReceiptCausalDisposition.satisfied);
    },
  );

  for (final field in ['commit', 'revision', 'vector']) {
    test(
      'contradictory $field rejects without overwriting formal proof',
      () async {
        await queue(_op1, [_sourceA]);
        final frozen = (await store.nextPush(space))!;
        await ack(frozen, receipt(_op1));
        final before = await settings();
        final changed = receipt(
          _op1,
          commit: field == 'commit' ? _op2 : _commit,
          revision: field == 'revision' ? '2' : '1',
          vector: field == 'vector' ? {_a: '6', _c: '1'} : null,
        );
        await expectLater(ack(frozen, changed), throwsStateError);
        expect(await settings(), before);
      },
    );
  }

  test('legacy revision-only ACK cannot forge causal evidence', () async {
    await queue(_op1, [_sourceA]);
    await store.nextPush(space);
    await store.acknowledge(space, _op1, '1');
    expect((await status()).disposition, ReceiptCausalDisposition.missingProof);
    expect(
      (await settings()).keys.where(
        (key) => key.startsWith(receiptAckProofPrefix(space)),
      ),
      isEmpty,
    );
  });

  test(
    'changing captured identity at transaction end rolls back applied, shadow and proof',
    () async {
      await queue(_op1, [_sourceA]);
      final frozen = (await store.nextPush(space))!;
      var checks = 0;
      await expectLater(
        store.acknowledgeApplied(
          space,
          frozen,
          receipt(_op1),
          clientId: _client,
          epoch: _epoch,
          isCurrent: () => ++checks == 1,
        ),
        throwsStateError,
      );
      expect(
        (await db.select(db.pendingOperations).getSingle()).state,
        'sending',
      );
      expect(
        (await settings()).keys.where(
          (key) => key.startsWith(receiptAckProofPrefix(space)),
        ),
        isEmpty,
      );
      expect(
        await (db.select(
          db.serverShadows,
        )..where((row) => row.entityId.equals(_receipt))).get(),
        isEmpty,
      );
    },
  );

  test('replace A by B freezes both old and new source positions', () async {
    await store.applyPullPage(
      space,
      _epoch,
      [
        [
          public(_c, _receipt, '1', payload([_sourceA])),
        ],
      ],
      finalPage: true,
      checkpoint: {_c: '1'},
    );
    await queue(_op1, [_sourceB], action: 'update', base: '1');
    final frozen = (await store.nextPush(space))!;
    await ack(
      frozen,
      receipt(_op1, revision: '2', vector: {_a: '7', _b: '9', _c: '2'}),
    );
    expect((await status()).requiredCursors, {_a: '7'});
    expect((await status(id: _sourceB, scope: _b)).requiredCursors, {_b: '9'});
    await checkpoint({_a: '7'});
    expect((await status()).disposition, ReceiptCausalDisposition.satisfied);
    expect(
      (await status(id: _sourceB, scope: _b)).disposition,
      ReceiptCausalDisposition.awaitingSourceSync,
    );
  });

  test('delete with empty payload preserves prior complete sources', () async {
    await store.applyPullPage(
      space,
      _epoch,
      [
        [
          public(_c, _receipt, '1', payload([_sourceA, _sourceB])),
        ],
      ],
      finalPage: true,
      checkpoint: {_c: '1'},
    );
    await queue(_op1, [], action: 'delete', base: '1');
    final frozen = (await store.nextPush(space))!;
    await ack(
      frozen,
      receipt(_op1, revision: '2', vector: {_a: '7', _b: '9', _c: '2'}),
    );
    expect((await status()).requiredCursors, {_a: '7'});
    expect((await status(id: _sourceB, scope: _b)).requiredCursors, {_b: '9'});
  });

  test(
    'continuous offline predecessor chain uses earlier frozen after, not newest intent',
    () async {
      await queue(_op1, [_sourceA]);
      await queue(_op2, [_sourceB], action: 'update');
      final first = (await store.nextPush(space))!;
      await ack(first, receipt(_op1));
      final second = (await store.nextPush(space))!;
      final beforeRetry =
          (await settings())['${receiptBindingsPrefix(space)}$_op2'];
      await store.applyPullPage(space, _epoch, [
        [public(_c, _receipt, '5', payload([]))],
      ], finalPage: false);
      await store.retryLater(space, _op2, 'network_unavailable');
      final retry = (await store.nextPush(space))!;
      expect(retry.body, second.body);
      expect(
        (await settings())['${receiptBindingsPrefix(space)}$_op2'],
        beforeRetry,
      );
      await ack(
        retry,
        receipt(_op2, revision: '2', vector: {_a: '8', _b: '9', _c: '2'}),
      );
      expect((await status()).requiredCursors, {_a: _large});
      expect((await status(id: _sourceB, scope: _b)).requiredCursors, {
        _b: '9',
      });
    },
  );

  test(
    'redacted before uses finite conservative scope barrier without hidden IDs',
    () async {
      await store.applyPullPage(
        space,
        _epoch,
        [
          [
            public(_c, _receipt, '1', payload([_sourceA]), hidden: 1),
          ],
        ],
        finalPage: true,
        checkpoint: {_c: '1'},
      );
      await queue(_op1, [_sourceB], action: 'update', base: '1');
      final frozen = (await store.nextPush(space))!;
      await ack(
        frozen,
        receipt(_op1, revision: '2', vector: {_a: '7', _b: '9', _c: '2'}),
      );
      expect(
        (await status()).disposition,
        ReceiptCausalDisposition.awaitingSourceSync,
      );
      await checkpoint({_a: '7', _b: '9'});
      expect((await status()).disposition, ReceiptCausalDisposition.satisfied);
    },
  );

  test(
    'strict hidden-preserve metadata touches no source and does not invent hidden binding',
    () async {
      final before = payload([_sourceA]);
      await store.applyPullPage(
        space,
        _epoch,
        [
          [public(_c, _receipt, '1', before, hidden: 1)],
        ],
        finalPage: true,
        checkpoint: {_c: '1'},
      );
      await queue(
        _op1,
        [],
        action: 'update',
        base: '1',
        body: {
          ...before,
          'note': 'metadata',
          'preserve_hidden_financial_links': true,
        },
      );
      final frozen = (await store.nextPush(space))!;
      await ack(frozen, receipt(_op1, revision: '2', vector: {_c: '2'}));
      expect((await status()).disposition, ReceiptCausalDisposition.satisfied);
      final binding =
          jsonDecode(
                (await settings())['${receiptBindingsPrefix(space)}$_op1']!,
              )
              as Map;
      expect(binding['relevant'], isFalse);
      expect(binding['sources'], isEmpty);
    },
  );

  test(
    'claimed preserve with altered financial field cannot bypass source barrier',
    () async {
      final before = payload([_sourceA]);
      await store.applyPullPage(
        space,
        _epoch,
        [
          [public(_c, _receipt, '1', before, hidden: 1)],
        ],
        finalPage: true,
        checkpoint: {_c: '1'},
      );
      await queue(
        _op1,
        [],
        action: 'update',
        base: '1',
        body: {
          ...before,
          'money': {'amount_minor': '101', 'currency': 'CNY'},
          'preserve_hidden_financial_links': true,
        },
      );
      final frozen = (await store.nextPush(space))!;
      await ack(
        frozen,
        receipt(_op1, revision: '2', vector: {_a: '7', _c: '2'}),
      );
      expect(
        (await status()).disposition,
        ReceiptCausalDisposition.awaitingSourceSync,
      );
    },
  );

  test(
    'revision-only ACK cannot certify hidden-preserve metadata success',
    () async {
      final before = payload([_sourceA]);
      await store.applyPullPage(
        space,
        _epoch,
        [
          [public(_c, _receipt, '1', before, hidden: 1)],
        ],
        finalPage: true,
        checkpoint: {_c: '1'},
      );
      await queue(
        _op1,
        [],
        action: 'update',
        base: '1',
        body: {
          ...before,
          'note': 'metadata',
          'preserve_hidden_financial_links': true,
        },
      );
      await store.nextPush(space);
      await store.acknowledge(space, _op1, '2');
      expect(
        (await status()).disposition,
        ReceiptCausalDisposition.missingProof,
      );
    },
  );

  test(
    'complete known source absent from formal vector is a contradiction',
    () async {
      await queue(_op1, [_sourceA]);
      final frozen = (await store.nextPush(space))!;
      await ack(frozen, receipt(_op1, vector: {_c: '1'}));
      expect(
        (await status()).disposition,
        ReceiptCausalDisposition.missingProof,
      );
    },
  );

  test(
    'incomplete verified vector can prove an unrelated scope was untouched',
    () async {
      await store.applyPullPage(
        space,
        _epoch,
        [
          [
            public(_c, _receipt, '1', payload([_sourceA]), hidden: 1),
          ],
        ],
        finalPage: true,
        checkpoint: {_c: '1'},
      );
      await queue(_op1, [_sourceA], action: 'update', base: '1');
      final frozen = (await store.nextPush(space))!;
      await ack(
        frozen,
        receipt(_op1, revision: '2', vector: {_a: '7', _c: '2'}),
      );
      expect(
        (await status(id: _sourceB, scope: _b)).disposition,
        ReceiptCausalDisposition.satisfied,
      );
      expect(
        (await status()).disposition,
        ReceiptCausalDisposition.awaitingSourceSync,
      );
      await checkpoint({_a: '7'});
      expect((await status()).disposition, ReceiptCausalDisposition.satisfied);
    },
  );

  test(
    'formal bill ACK vector must include its actual destination scope',
    () async {
      await queue(_op1, [_sourceA]);
      final frozen = (await store.nextPush(space))!;
      await expectLater(
        ack(frozen, receipt(_op1, vector: {_a: '7'})),
        throwsFormatException,
      );
      expect(
        (await db.select(db.pendingOperations).getSingle()).state,
        'sending',
      );
    },
  );

  test(
    'permission-version invalidation clears matching proof and preserves other space',
    () async {
      await queue(_op1, [_sourceA]);
      final frozen = (await store.nextPush(space))!;
      await ack(frozen, receipt(_op1));
      await local.writeSetting(
        'sync.receipt-acks.v1.other-space.$_op1',
        'independent',
      );
      await store.invalidateReceiptEvidenceForScope(space, _a);
      expect(
        (await settings()).keys.where(
          (key) =>
              key.startsWith(receiptAckProofPrefix(space)) ||
              key.startsWith(receiptBindingsPrefix(space)),
        ),
        isEmpty,
      );
      expect(
        await local.readSetting('sync.receipt-acks.v1.other-space.$_op1'),
        'independent',
      );
      expect(
        (await db.select(db.pendingOperations).getSingle()).frozenRequestJson,
        frozen.body,
      );
    },
  );

  test(
    'vector and total evidence caps reject atomically without silent eviction',
    () async {
      await queue(_op1, [_sourceA]);
      final frozen = (await store.nextPush(space))!;
      final hugeVector = {
        for (var i = 0; i < 1001; i++)
          'ff000000-0000-4000-8000-${i.toString().padLeft(12, '0')}': '1',
      };
      await expectLater(
        ack(frozen, receipt(_op1, vector: hugeVector)),
        throwsFormatException,
      );
      expect(
        (await db.select(db.pendingOperations).getSingle()).state,
        'sending',
      );
      await local.writeSetting(
        '${receiptAckProofPrefix(space)}full',
        'x' * (32 * 1024 * 1024),
      );
      await expectLater(ack(frozen, receipt(_op1)), throwsStateError);
      expect(
        (await db.select(db.pendingOperations).getSingle()).state,
        'sending',
      );
      expect(
        await local.readSetting('${receiptAckProofPrefix(space)}$_op1'),
        isNull,
      );
      expect(
        (await local.readSetting(
          '${receiptAckProofPrefix(space)}full',
        ))!.length,
        32 * 1024 * 1024,
      );
    },
  );

  test(
    'revoke clears controlled proofs/bindings but keeps exact frozen request and backup includes evidence',
    () async {
      await queue(_op1, [_sourceA]);
      final frozen = (await store.nextPush(space))!;
      await ack(frozen, receipt(_op1));
      await store.requireRebuild(space, 'test_backup');
      final saved =
          jsonDecode((await store.recoveryBackups(space)).single.dataJson)
              as Map;
      expect(saved['receipt_evidence'], hasLength(2));
      await store.revokeScope(space, _a);
      expect(
        (await settings()).keys.where(
          (key) =>
              key.startsWith(receiptAckProofPrefix(space)) ||
              key.startsWith(receiptBindingsPrefix(space)),
        ),
        isEmpty,
      );
      expect(
        (await db.select(db.pendingOperations).getSingle()).frozenRequestJson,
        frozen.body,
      );
    },
  );

  test(
    'wrong epoch/client/frozen bytes and stale proof fail conservatively',
    () async {
      await queue(_op1, [_sourceA]);
      final frozen = (await store.nextPush(space))!;
      await expectLater(
        store.acknowledgeApplied(
          space,
          frozen,
          receipt(_op1),
          clientId: _op2,
          epoch: _epoch,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      await expectLater(
        ack(FrozenPush(_op1, '${frozen.body} ', 1), receipt(_op1)),
        throwsStateError,
      );
      await ack(frozen, receipt(_op1));
      final key = '${receiptAckProofPrefix(space)}$_op1';
      final corrupt =
          jsonDecode((await settings())[key]!) as Map<String, dynamic>;
      corrupt['epoch'] = _op2;
      await local.writeSetting(key, jsonEncode(corrupt));
      expect(
        (await status()).disposition,
        ReceiptCausalDisposition.missingProof,
      );
    },
  );

  test(
    'ACK and binding survive a disk reopen before final checkpoint',
    () async {
      await db.close();
      final directory = await Directory.systemTemp.createTemp('flowtrace-ack-');
      try {
        final file = File('${directory.path}/test.sqlite');
        db = AppDatabase(NativeDatabase(file));
        local = LocalRepository(db);
        store = SyncStore(local);
        await local.registerSpace(space);
        await store.configure(space, _client, _epoch);
        await seed();
        await queue(_op1, [_sourceA]);
        final frozen = (await store.nextPush(space))!;
        await ack(frozen, receipt(_op1));
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        local = LocalRepository(db);
        store = SyncStore(local);
        expect(
          (await status()).disposition,
          ReceiptCausalDisposition.awaitingSourceSync,
        );
        await checkpoint({_a: _large});
        expect(
          (await status()).disposition,
          ReceiptCausalDisposition.satisfied,
        );
      } finally {
        await db.close();
        db = AppDatabase(NativeDatabase.memory());
        await directory.delete(recursive: true);
      }
    },
  );

  Map<String, Object?> scopes() => {
    'sync_epoch': _epoch,
    'control_version': '1',
    'requires_rebuild': false,
    'revoked_scope_ids': <Object?>[],
    'scopes': [
      for (final scope in [space.userId, _a, _b, _c])
        {
          'scope_id': scope,
          'kind': scope == space.userId ? 'user' : 'book',
          'role': 'owner',
          'revision': '1',
          'permission_version': '1',
        },
    ],
  };
  test(
    'explicit legacy reconciliation uses read-only lookup with original bytes and finite cursor release',
    () async {
      await queue(_op1, [_sourceA]);
      final frozen = (await store.nextPush(space))!;
      await store.acknowledge(space, _op1, '1');
      expect(
        (await status()).disposition,
        ReceiptCausalDisposition.missingProof,
      );
      final paths = <String>[];
      final lease = SyncLease(
        space: space,
        clientId: _client,
        epoch: _epoch,
        isCurrent: () => true,
        request: (method, path, {body, bodyJson}) async {
          paths.add(path);
          if (path == '/sync/scopes') return scopes();
          expect(path, '/sync/receipts/lookup');
          expect(bodyJson, frozen.body);
          return {
            'results': [receipt(_op1, replayed: true)],
          };
        },
      );
      expect(
        await SyncEngine(store).reconcileAppliedReceipts(lease, [_op1]),
        1,
      );
      expect(paths, ['/sync/scopes', '/sync/receipts/lookup']);
      expect(
        (await status()).disposition,
        ReceiptCausalDisposition.awaitingSourceSync,
      );
      await checkpoint({_a: _large});
      expect((await status()).disposition, ReceiptCausalDisposition.satisfied);
      expect(
        (await db.select(db.pendingOperations).getSingle()).attemptCount,
        1,
      );
    },
  );

  test(
    'lookup unavailable does not fall back to push or change applied receipt',
    () async {
      await queue(_op1, [_sourceA]);
      final frozen = (await store.nextPush(space))!;
      await store.acknowledge(space, _op1, '1');
      final paths = <String>[];
      final lease = SyncLease(
        space: space,
        clientId: _client,
        epoch: _epoch,
        isCurrent: () => true,
        request: (method, path, {body, bodyJson}) async {
          paths.add(path);
          if (path == '/sync/scopes') return scopes();
          throw const ApiFailure('receipt_not_found', '回执不可用', status: 404);
        },
      );
      await expectLater(
        SyncEngine(store).reconcileAppliedReceipts(lease, [_op1]),
        throwsA(isA<ApiFailure>()),
      );
      expect(paths, ['/sync/scopes', '/sync/receipts/lookup']);
      expect(
        (await db.select(db.pendingOperations).getSingle()).frozenRequestJson,
        frozen.body,
      );
      expect(
        (await status()).disposition,
        ReceiptCausalDisposition.missingProof,
      );
    },
  );
}
