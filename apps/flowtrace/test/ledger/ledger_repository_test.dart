import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/data/ledger/ledger_projection.dart';
import 'package:flowtrace/data/ledger/ledger_repository.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

String uid(int n) => '11111111-1111-4111-8111-${n.toString().padLeft(12, '0')}';
final user = uid(1),
    book = uid(2),
    account = uid(3),
    bill = uid(4),
    epoch = uid(5),
    client = uid(6);
DataSpace spaceFor([int n = 1]) => DataSpace(
  server: ServerAddress.parse('http://127.0.0.1:18099'),
  serverInstanceId: uid(99),
  userId: uid(n),
);
Map<String, Object?> money(
  String minor, {
  String currency = 'CNY',
  int scale = 2,
}) => {'currency': currency, 'currency_scale': scale, 'amount_minor': minor};
Map<String, Object?> bookData([String name = '合成账本']) => {
  'name': name,
  'currency': 'CNY',
  'timezone': 'Asia/Shanghai',
  'month_start_day': 1,
};
Map<String, Object?> accountData([
  String opening = '10000',
  String kind = 'cash',
]) => {
  'name': '合成账户',
  'kind': kind,
  'opening': money(opening),
  'include_in_net_assets': true,
  'hidden': false,
};
Map<String, Object?> expense(String amount, {String? accountId}) => {
  'bill_type': 'expense',
  'money': money(amount),
  'book_id': book,
  'account_id': accountId ?? account,
  'business_date': '2026-10-21',
  'business_timezone': 'Asia/Shanghai',
  'note': '合成样本',
};
Map<String, Object?> publicBill(
  Map<String, Object?> payload, {
  List<String> hidden = const [],
}) => {
  'projection_kind': 'bill_public',
  'payload': normalizeLedgerPayload('bill', payload),
  'hidden_account_fields': hidden,
  'hidden_allocation_count': 0,
  'paid_by_user_ids': hidden.isEmpty ? [] : [user],
  'nonfinancial_editable_fields': [
    'note',
    'category_id',
    'tag_ids',
    'attachment_ids',
    'flags',
  ],
  'remaining_allocatable_minor': payload['bill_type'] == 'expense'
      ? ledgerObject(payload['money'])['amount_minor']
      : null,
};
Map<String, Object?> finance(Map<String, Object?> payload, String delta) => {
  'projection_kind': 'bill_private_finance',
  'book_id': book,
  'bill_type': payload['bill_type'],
  'business_date': '2026-10-21',
  'business_timezone': 'Asia/Shanghai',
  'occurred_at': null,
  'account_links': {
    'account_id': account,
    'from_account_id': null,
    'to_account_id': null,
    'fee_account_id': null,
  },
  'entries': [
    {'account_id': account, 'component': 'principal', 'money': money(delta)},
  ],
};

void main() {
  // Tests intentionally open independent in-memory and on-disk databases.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LocalRepository local;
  late LedgerRepository ledger;
  late SyncStore sync;
  final space = spaceFor();
  Future<void> roles(String role, {String? savedEpoch}) => local.writeSetting(
    'sync.scope-details.${space.id}',
    jsonEncode({
      'version': 1,
      'epoch': savedEpoch ?? epoch,
      'scopes': [
        {
          'scope_id': book,
          'kind': 'book',
          'role': role,
          'permission_version': '1',
        },
      ],
    }),
  );
  Future<void> put(
    String type,
    String id,
    String scope,
    Map<String, Object?> data, {
    String revision = '1',
    bool shadow = true,
  }) async {
    await db
        .into(db.localEntities)
        .insertOnConflictUpdate(
          LocalEntitiesCompanion.insert(
            spaceId: space.id,
            scopeId: Value(scope),
            entityType: type,
            entityId: id,
            dataJson: jsonEncode(data),
            serverRevision: Value(revision),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
    if (shadow) {
      await db
          .into(db.serverShadows)
          .insertOnConflictUpdate(
            ServerShadowsCompanion.insert(
              spaceId: space.id,
              scopeId: scope,
              entityType: type,
              entityId: id,
              revision: revision,
              dataJson: jsonEncode(data),
              deleted: false,
            ),
          );
    }
  }

  Future<void> seed({
    String opening = '10000',
    String? balance,
    String role = 'owner',
    bool sharedAccount = false,
  }) async {
    await roles(role);
    await put('book', book, book, {
      'projection_kind': 'book',
      'payload': bookData(),
    });
    await put('account', account, sharedAccount ? book : user, {
      'projection_kind': 'account',
      'payload': accountData(opening),
      'balance': money(balance ?? opening),
    });
  }

  Future<void> pullBill(
    Map<String, Object?> payload, {
    String revision = '1',
    String balance = '9000',
    bool private = true,
  }) async {
    await sync.applyPullPage(
      space,
      epoch,
      [
        [
          SyncEvent(
            scopeId: book,
            entityType: 'bill',
            entityId: bill,
            revision: revision,
            deleted: false,
            data: publicBill({
              ...payload,
              'account_id': private ? null : account,
            }, hidden: private ? ['account_id'] : []),
          ),
          if (private)
            SyncEvent(
              scopeId: user,
              entityType: 'bill',
              entityId: bill,
              revision: revision,
              deleted: false,
              data: finance(
                payload,
                '-${ledgerObject(payload['money'])['amount_minor']}',
              ),
            ),
          SyncEvent(
            scopeId: private ? user : book,
            entityType: 'account',
            entityId: account,
            revision: revision,
            deleted: false,
            data: {
              'projection_kind': 'account',
              'payload': accountData(),
              'balance': money(balance),
            },
          ),
        ],
      ],
      finalPage: true,
      checkpoint: {book: revision, user: revision},
    );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    local = LocalRepository(db);
    ledger = LedgerRepository(local);
    sync = SyncStore(local);
    await local.registerSpace(space);
    await sync.configure(space, client, epoch);
  });
  tearDown(() => db.close());

  test(
    'stable ID retry preserves one bill and original frozen operation',
    () async {
      await seed();
      final operation = await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: expense('1000'),
      );
      final frozen = await sync.nextPush(space);
      final repeated = await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: expense('1000'),
      );
      expect(repeated, operation);
      expect((await local.pending(space)).length, 1);
      expect((await sync.nextPush(space))!.body, frozen!.body);
      expect((await ledger.read(space)).bills.single.id, bill);
    },
  );
  test(
    'offline expense chain uses final delta, confirmed pull before ACK is not doubled',
    () async {
      await seed();
      final first = await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: expense('1000'),
      );
      await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: expense('1500'),
      );
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        BigInt.from(8500),
      );
      final operations = await local.pending(space);
      expect(operations.last.predecessorId, first);
      await sync.nextPush(space);
      await pullBill(expense('1000'));
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        BigInt.from(8500),
      );
      await sync.acknowledge(space, first, '1');
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        BigInt.from(8500),
      );
      await ledger.delete(space, (await ledger.read(space)).bills.single);
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        BigInt.from(10000),
      );
    },
  );
  test(
    'ACK without canonical account projection is unknown until its commit is pulled',
    () async {
      await seed();
      final op = await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: expense('1000'),
      );
      await sync.nextPush(space);
      await sync.acknowledge(space, op, '2');
      expect((await ledger.read(space)).balances[account]!.value, isNull);
      await pullBill(expense('1000'), revision: '2');
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        BigInt.from(9000),
      );
    },
  );
  for (final pullBeforeAck in [false, true]) {
    test(
      'deleted bill restores confirmed balance, pullBeforeAck=$pullBeforeAck',
      () async {
        await seed();
        final create = await ledger.save(
          space,
          entityType: 'bill',
          scopeId: book,
          entityId: bill,
          payload: expense('1000'),
        );
        await sync.nextPush(space);
        await sync.acknowledge(space, create, '1');
        await pullBill(expense('1000'));
        await ledger.delete(space, (await ledger.read(space)).bills.single);
        final deletion = (await local.pending(space)).last.operationId;
        await sync.nextPush(space);
        Future<void> pullDeletion() => sync.applyPullPage(
          space,
          epoch,
          [
            [
              SyncEvent(
                scopeId: book,
                entityType: 'bill',
                entityId: bill,
                revision: '2',
                deleted: true,
                data: {},
              ),
              SyncEvent(
                scopeId: user,
                entityType: 'bill',
                entityId: bill,
                revision: '2',
                deleted: true,
                data: {},
              ),
              SyncEvent(
                scopeId: user,
                entityType: 'account',
                entityId: account,
                revision: '2',
                deleted: false,
                data: {
                  'projection_kind': 'account',
                  'payload': accountData(),
                  'balance': money('10000'),
                },
              ),
            ],
          ],
          finalPage: true,
          checkpoint: {book: '2', user: '2'},
        );
        if (pullBeforeAck) {
          await pullDeletion();
        } else {
          await sync.acknowledge(space, deletion, '2');
          // A delete receipt alone does not prove the account balance commit.
          expect((await ledger.read(space)).balances[account]!.value, isNull);
        }
        if (pullBeforeAck) {
          await sync.acknowledge(space, deletion, '2');
        } else {
          await pullDeletion();
        }
        final balance = (await ledger.read(space)).balances[account]!;
        expect(balance.value?.minor, BigInt.from(10000));
        expect(balance.status, 'confirmed');
      },
    );
  }
  test(
    'BigInt balances stay exact and used opening corrections require adjustment',
    () async {
      await seed(opening: '9007199254740993');
      await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: expense('2'),
      );
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor.toString(),
        '9007199254740991',
      );
      await expectLater(
        ledger.save(
          space,
          entityType: 'account',
          scopeId: user,
          entityId: account,
          payload: accountData('9007199254740994'),
        ),
        throwsA(
          isA<DomainError>().having(
            (error) => error.code,
            'code',
            'account.definition_in_use',
          ),
        ),
      );
      await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: uid(44),
        payload: {
          ...expense('1'),
          'bill_type': 'balance_adjustment',
          'target_balance_minor': '9007199254740992',
        },
      );
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor.toString(),
        '9007199254740992',
      );
    },
  );
  test(
    'adjustment freezes signed delta across later historical expense edits',
    () async {
      await seed();
      await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: expense('1000'),
      );
      final adjustment = uid(7);
      await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: adjustment,
        payload: {
          ...expense('500'),
          'bill_type': 'balance_adjustment',
          'target_balance_minor': '9500',
        },
      );
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        BigInt.from(9500),
      );
      await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: expense('1500'),
      );
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        BigInt.from(9000),
      );
      await expectLater(
        ledger.save(
          space,
          entityType: 'bill',
          scopeId: book,
          payload: {
            ...expense('1'),
            'bill_type': 'balance_adjustment',
            'target_balance_minor': '9500',
          },
        ),
        throwsA(isA<DomainError>()),
      );
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        BigInt.from(9000),
      );
    },
  );
  test(
    'scope roles authorize editor creation, deny viewer, revoke beats local proof',
    () async {
      await seed(role: 'editor');
      var view = await ledger.read(space);
      expect(view.canCreate('category', book), isTrue);
      expect(view.find('book', book)!.canEdit, isFalse);
      await ledger.save(
        space,
        entityType: 'tag',
        scopeId: book,
        payload: {'name': '合成标签', 'color': '#2279D7'},
      );
      await roles('viewer');
      await expectLater(
        ledger.save(
          space,
          entityType: 'tag',
          scopeId: book,
          payload: {'name': '拒绝', 'color': '#2279D7'},
        ),
        throwsA(isA<DomainError>()),
      );
      await roles('owner', savedEpoch: uid(30));
      expect((await ledger.read(space)).canCreate('tag', book), isFalse);
      await roles('owner');
      await (db.update(
        db.syncStates,
      )..where((t) => t.spaceId.equals(space.id))).write(
        SyncStatesCompanion(revokedScopesJson: Value(jsonEncode([book]))),
      );
      view = await ledger.read(space);
      expect(view.books, isEmpty);
      expect(view.canCreate('tag', book), isFalse);
    },
  );
  test(
    'atomic template order creates explicit dependencies and no ledger records',
    () async {
      final parent = uid(10), child = uid(11), group = uid(12), tag = uid(13);
      final ids = await ledger.saveBatch(space, [
        LedgerWrite(
          entityType: 'book',
          scopeId: user,
          entityId: book,
          payload: bookData(),
        ),
        LedgerWrite(
          entityType: 'category',
          scopeId: book,
          entityId: parent,
          payload: {
            'name': '一级',
            'kind': 'expense',
            'parent_id': null,
            'icon': 'food',
            'sort_order': 0,
          },
        ),
        LedgerWrite(
          entityType: 'category',
          scopeId: book,
          entityId: child,
          payload: {
            'name': '二级',
            'kind': 'expense',
            'parent_id': parent,
            'icon': 'food',
            'sort_order': 0,
          },
        ),
        LedgerWrite(
          entityType: 'tag',
          scopeId: book,
          entityId: group,
          payload: {'name': '组', 'color': '#2279D7', 'kind': 'group'},
        ),
        LedgerWrite(
          entityType: 'tag',
          scopeId: book,
          entityId: tag,
          payload: {'name': '标签', 'color': '#2279D7', 'group_id': group},
        ),
      ]);
      final queue = await local.pending(space);
      expect(jsonDecode(queue[1].operationJson)['depends_on'], ids[0]);
      expect(jsonDecode(queue[2].operationJson)['depends_on'], ids[1]);
      expect(jsonDecode(queue[4].operationJson)['depends_on'], ids[3]);
      final copied = await ledger.copyBookConfiguration(
        space,
        book,
        name: '副本',
      );
      final view = await ledger.read(
        space,
        query: LedgerQuery(bookId: copied, includeArchived: true),
      );
      expect(view.categories.length, 2);
      expect(view.tags.length, 2);
      expect(view.accounts, isEmpty);
      expect(view.bills, isEmpty);
      final newParent = view.categories.singleWhere(
        (row) => row.payload['parent_id'] == null,
      );
      expect(
        view.categories
            .singleWhere((row) => row.payload['parent_id'] != null)
            .payload['parent_id'],
        newParent.id,
      );
      expect(
        view.categories.any((row) => {parent, child}.contains(row.id)),
        isFalse,
      );
      expect((await sync.nextPush(space))!.body, contains(ids[0]));
    },
  );
  test(
    'a failed batch rolls back definitions, journal and posting hints together',
    () async {
      await seed();
      final before = (await db.select(db.localEntities).get()).length;
      await expectLater(
        ledger.saveBatch(space, [
          LedgerWrite(
            entityType: 'bill',
            scopeId: book,
            entityId: bill,
            payload: expense('1000'),
          ),
          LedgerWrite(
            entityType: 'tag',
            scopeId: book,
            payload: {'name': '无效', 'color': 'invalid'},
          ),
        ]),
        throwsA(isA<DomainError>()),
      );
      expect((await db.select(db.localEntities).get()).length, before);
      expect(await local.pending(space), isEmpty);
      expect(
        (await db.select(db.appSettings).get()).where(
          (row) => row.key.startsWith('ledger.postings.'),
        ),
        isEmpty,
      );
    },
  );
  test(
    'private finance enables own full edit without entering public display data',
    () async {
      await seed();
      await pullBill(expense('1000'));
      final view = await ledger.read(space);
      final entity = view.bills.single;
      expect(entity.payload['account_id'], isNull);
      expect(entity.editablePayload!['account_id'], account);
      expect(entity.canEdit, isTrue);
      await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: {...entity.editablePayload!, 'money': money('2000')},
      );
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        BigInt.from(8000),
      );
    },
  );
  test(
    'another payer stays redacted; financial edit denied, strict metadata edit allowed',
    () async {
      await seed(role: 'editor');
      await put(
        'bill',
        bill,
        book,
        publicBill(
          {...expense('1000'), 'account_id': null},
          hidden: ['account_id'],
        ),
      );
      final entity = (await ledger.read(space)).bills.single;
      expect(entity.canEdit, isFalse);
      expect(entity.editMode, 'metadata');
      expect(entity.editablePayload, isNull);
      await expectLater(
        ledger.save(
          space,
          entityType: 'bill',
          scopeId: book,
          entityId: bill,
          payload: {
            ...entity.payload,
            'money': money('2000'),
            'preserve_hidden_financial_links': true,
          },
        ),
        throwsA(isA<DomainError>()),
      );
      await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: {
          ...entity.payload,
          'note': '只改公开备注',
          'preserve_hidden_financial_links': true,
        },
      );
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        BigInt.from(10000),
      );
      expect(
        jsonDecode(
          (await local.pending(space)).single.operationJson,
        )['payload']['account_id'],
        isNull,
      );
    },
  );
  test(
    'invalid management hierarchy, group use and archived new reference are rejected',
    () async {
      await seed();
      final group = uid(10), tag = uid(11), category = uid(12);
      await ledger.save(
        space,
        entityType: 'tag',
        scopeId: book,
        entityId: group,
        payload: {'name': '组', 'color': '#2279D7', 'kind': 'group'},
      );
      await ledger.save(
        space,
        entityType: 'tag',
        scopeId: book,
        entityId: tag,
        payload: {'name': '子', 'color': '#2279D7', 'group_id': group},
      );
      await expectLater(
        ledger.delete(space, (await ledger.read(space)).find('tag', group)!),
        throwsA(isA<DomainError>()),
      );
      await expectLater(
        ledger.save(
          space,
          entityType: 'bill',
          scopeId: book,
          payload: {
            ...expense('1'),
            'tag_ids': [group],
          },
        ),
        throwsA(isA<DomainError>()),
      );
      await ledger.save(
        space,
        entityType: 'category',
        scopeId: book,
        entityId: category,
        payload: {
          'name': '归档',
          'kind': 'expense',
          'parent_id': null,
          'icon': 'food',
          'sort_order': 0,
          'archived': true,
        },
      );
      await expectLater(
        ledger.save(
          space,
          entityType: 'bill',
          scopeId: book,
          payload: {...expense('1'), 'category_id': category},
        ),
        throwsA(isA<DomainError>()),
      );
      expect((await ledger.read(space)).categories, isEmpty);
      expect(
        (await ledger.read(
          space,
          query: const LedgerQuery(includeArchived: true),
        )).categories.single.id,
        category,
      );
    },
  );
  test(
    'watch observes coherent transaction updates and data spaces remain isolated',
    () async {
      await seed();
      final events = <LedgerView>[];
      final sub = ledger.watch(space).listen(events.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await ledger.saveBatch(space, [
        LedgerWrite(
          entityType: 'tag',
          scopeId: book,
          payload: {'name': '一', 'color': '#2279D7'},
        ),
        LedgerWrite(
          entityType: 'tag',
          scopeId: book,
          payload: {'name': '二', 'color': '#2279D7'},
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(events.map((view) => view.tags.length), contains(2));
      expect(events.any((view) => view.tags.length == 1), isFalse);
      final other = spaceFor(20);
      await local.registerSpace(other);
      expect((await ledger.read(other)).books, isEmpty);
      expect((await ledger.read(other)).balances, isEmpty);
    },
  );
  test(
    'complete draft retains long raw UI and attachment IDs through recovery and disk reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'flowtrace-ledger-draft-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final disk = AppDatabase(
        NativeDatabase(File('${dir.path}/isolated.sqlite')),
      );
      final diskLocal = LocalRepository(disk);
      final diskLedger = LedgerRepository(diskLocal);
      await diskLocal.registerSpace(space);
      await SyncStore(diskLocal).configure(space, client, epoch);
      await (disk.update(disk.syncStates)
            ..where((t) => t.spaceId.equals(space.id)))
          .write(const SyncStatesCompanion(status: Value('recovery_required')));
      final text = '1+'.padRight(5000, '1');
      final id = await diskLedger.saveDraft(
        space,
        bookId: book,
        payload: {
          'attachment_ids': [uid(22)],
          'money': 'partial',
        },
        ui: {'expression': text, 'entry_entity_id': bill},
      );
      await expectLater(
        diskLedger.save(
          space,
          entityType: 'book',
          scopeId: user,
          payload: bookData(),
        ),
        throwsA(isA<DomainError>()),
      );
      await disk.close();
      final reopened = AppDatabase(
        NativeDatabase(File('${dir.path}/isolated.sqlite')),
      );
      addTearDown(reopened.close);
      final draft = await LedgerRepository(
        LocalRepository(reopened),
      ).readDraft(space, id);
      expect(draft!.ui['expression'], text);
      expect(draft.payload['attachment_ids'], [uid(22)]);
      expect(draft.ui['entry_entity_id'], bill);
      await expectLater(
        ledger.saveDraft(
          space,
          bookId: book,
          draftId: id,
          payload: {'note': 'x' * LedgerRepository.maxDraftBytes},
        ),
        throwsA(isA<DomainError>()),
      );
      expect(await ledger.readDraft(space, id), isNull);
    },
  );
  test(
    'stale local revision and integer overflow reject without changing prior balance',
    () async {
      await seed(opening: '9223372036854775807');
      await expectLater(
        ledger.save(
          space,
          entityType: 'bill',
          scopeId: book,
          payload: {...expense('1'), 'bill_type': 'income'},
        ),
        throwsA(isA<DomainError>()),
      );
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        int64Max,
      );
      await expectLater(
        ledger.save(
          space,
          entityType: 'account',
          scopeId: user,
          entityId: account,
          baseRevision: '0',
          payload: accountData('1'),
        ),
        throwsA(isA<DomainError>()),
      );
      expect(
        (await ledger.read(space)).accounts.single.payload['opening'],
        money('9223372036854775807'),
      );
    },
  );

  test(
    'pending display keeps own account and cross-book sources out of public payload',
    () async {
      await seed();
      await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: expense('1000'),
      );
      final row = (await ledger.read(space)).bills.single;
      expect(row.payload['account_id'], isNull);
      expect(row.editablePayload!['account_id'], account);
      expect(row.projection['hidden_account_fields'], ['account_id']);
    },
  );

  test(
    'refund source edit cannot shrink below already allocated amount',
    () async {
      await seed();
      await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: expense('1000'),
      );
      await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        payload: {
          ...expense('800'),
          'bill_type': 'refund',
          'allocations': [
            {
              'source_bill_id': bill,
              'source_amount_minor': '800',
              'receipt_amount_minor': '800',
            },
          ],
        },
      );
      await expectLater(
        ledger.save(
          space,
          entityType: 'bill',
          scopeId: book,
          entityId: bill,
          payload: expense('799'),
        ),
        throwsA(isA<DomainError>()),
      );
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        BigInt.from(9800),
      );
    },
  );

  test(
    'shared historical adjustment without signed evidence is explicit unknown when edited',
    () async {
      await seed(sharedAccount: true, balance: '9500');
      final payload = {
        ...expense('500'),
        'bill_type': 'balance_adjustment',
        'target_balance_minor': '9500',
      };
      await put('bill', bill, book, publicBill(payload));
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        BigInt.from(9500),
      );
      await expectLater(
        ledger.save(
          space,
          entityType: 'bill',
          scopeId: book,
          entityId: bill,
          payload: {...payload, 'note': '没有原方向'},
        ),
        throwsA(isA<DomainError>()),
      );
      expect(await local.pending(space), isEmpty);
    },
  );

  test(
    'valid 64-bit final balances do not reject an out-of-range temporary delta',
    () async {
      await seed(opening: '-9223372036854775808');
      await ledger.save(
        space,
        entityType: 'account',
        scopeId: user,
        entityId: account,
        payload: accountData('9223372036854775807'),
      );
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        int64Max,
      );
      await seed(opening: '10000', balance: '9223372036854775807');
      await put('bill', bill, book, publicBill(expense('1')));
      await db
          .into(db.serverShadows)
          .insertOnConflictUpdate(
            ServerShadowsCompanion.insert(
              spaceId: space.id,
              scopeId: user,
              entityType: 'bill',
              entityId: bill,
              revision: '1',
              dataJson: jsonEncode(finance(expense('1'), '-1')),
              deleted: false,
            ),
          );
      await ledger.save(
        space,
        entityType: 'bill',
        scopeId: book,
        entityId: bill,
        payload: expense('2'),
      );
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor,
        int64Max - BigInt.one,
      );
    },
  );

  final scenarios =
      ledgerObject(
            jsonDecode(
              File(
                '../../contracts/fixtures/ledger/scenarios.json',
              ).readAsStringSync(),
            ),
          )['scenarios']
          as List;
  for (final scenarioRaw in scenarios.take(4)) {
    final scenario = ledgerObject(scenarioRaw);
    test('shared golden account results ${scenario['scenario_id']}', () async {
      final setup = ledgerObject(scenario['setup']);
      await roles('owner');
      await put('book', book, book, {
        'projection_kind': 'book',
        'payload': bookData(),
      });
      final ids = <String, String>{};
      var next = 100;
      String mapped(String type, String name) =>
          ids.putIfAbsent('$type/$name', () => uid(next++));
      for (final raw in setup['accounts'] as List) {
        final value = ledgerObject(raw),
            id = mapped('account', ledgerObject(raw)['id'] as String);
        final opening = {
          'currency': value['currency'],
          'currency_scale': value['currency_scale'],
          'amount_minor': value['opening_minor'],
        };
        await put('account', id, user, {
          'projection_kind': 'account',
          'payload': {
            'name': value['id'],
            'kind': value['kind'],
            'opening': opening,
            'include_in_net_assets': value['include_in_net_assets'],
            'hidden': false,
          },
          'balance': opening,
        });
      }
      final current = <String, Map<String, Object?>>{};
      final categories = <String>{};
      Future<String?> category(Object? name, String kind) async {
        if (name == null) return null;
        final key = '$kind/$name', id = mapped('category', key);
        if (categories.add(key)) {
          await ledger.save(
            space,
            entityType: 'category',
            scopeId: book,
            entityId: id,
            payload: {
              'name': name,
              'kind': kind,
              'parent_id': null,
              'icon': 'food',
              'sort_order': 0,
            },
          );
        }
        return id;
      }

      Map<String, Object?>? reporting(Object? raw) => raw == null
          ? null
          : {
              ...ledgerObject(raw),
              'report_currency': setup['report_currency'],
              'report_scale': setup['report_scale'],
            };
      for (final stepRaw in scenario['steps'] as List) {
        final step = ledgerObject(stepRaw),
            command = ledgerObject(ledgerObject(stepRaw)['command']),
            expected = ledgerObject(ledgerObject(stepRaw)['expected']);
        final action = command['action'];
        Future<void> execute() async {
          if (action == 'create_bill') {
            final data = ledgerCopy(ledgerObject(command['bill']));
            final sourceId = data.remove('id') as String;
            data['book_id'] = book;
            for (final key in [
              'account_id',
              'from_account_id',
              'to_account_id',
            ]) {
              if (data[key] != null) {
                data[key] = mapped('account', data[key] as String);
              }
            }
            data['category_id'] = await category(
              data['category_id'],
              data['bill_type'] == 'income' ? 'income' : 'expense',
            );
            data['reporting'] = reporting(data['reporting']);
            if (data['fee'] != null) {
              final fee = ledgerCopy(ledgerObject(data['fee']));
              fee['account_id'] = mapped(
                'account',
                fee['account_id'] as String,
              );
              fee['category_id'] = await category(
                fee['category_id'],
                'expense',
              );
              fee['flags'] = fee['flags'] ?? data['flags'];
              fee['reporting'] = reporting(fee['reporting']);
              data['fee'] = fee;
            }
            if (data['allocations'] != null) {
              data['allocations'] = [
                for (final item in data['allocations'] as List)
                  {
                    ...ledgerObject(item),
                    'source_bill_id': mapped(
                      'bill',
                      ledgerObject(item)['source_bill_id'] as String,
                    ),
                  },
              ];
            }
            await ledger.save(
              space,
              entityType: 'bill',
              scopeId: book,
              entityId: mapped('bill', sourceId),
              payload: data,
            );
            current[sourceId] = normalizeLedgerPayload('bill', data);
          } else if (action == 'update_bill') {
            final sourceId = command['bill_id'] as String;
            final data = {
              ...current[sourceId]!,
              ...ledgerObject(command['changes']),
            };
            await ledger.save(
              space,
              entityType: 'bill',
              scopeId: book,
              entityId: mapped('bill', sourceId),
              payload: data,
            );
            current[sourceId] = data;
          } else if (action == 'delete_bill') {
            await ledger.delete(
              space,
              (await ledger.read(
                space,
              )).find('bill', mapped('bill', command['bill_id'] as String))!,
            );
          } else if (action != 'set_valuation_rate') {
            fail('Unsupported fixture action $action');
          }
        }

        if (expected['result'] == 'rejected') {
          await expectLater(
            execute(),
            throwsA(isA<DomainError>()),
            reason: '${scenario['scenario_id']}/${step['step_id']}',
          );
        } else {
          await execute();
        }
        final balances = (await ledger.read(space)).balances;
        final expectedBalances = ledgerObject(
          ledgerObject(expected['state'])['account_balances_minor'],
        );
        for (final entry in expectedBalances.entries) {
          expect(
            balances[mapped('account', entry.key)]!.value?.minor.toString(),
            entry.value,
            reason:
                '${scenario['scenario_id']}/${step['step_id']}/${entry.key}',
          );
        }
      }
    });
  }
}
