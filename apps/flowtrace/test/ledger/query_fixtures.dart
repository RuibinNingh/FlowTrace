import 'dart:convert';

import 'package:drift/drift.dart' show QueryExecutor, Value;
import 'package:drift/native.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/data/ledger/ledger_batch.dart';
import 'package:flowtrace/data/ledger/ledger_projection.dart';
import 'package:flowtrace/data/ledger/ledger_repository.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/domain/ledger/postings.dart';

String qid(int n) => '22222222-2222-4222-8222-${n.toString().padLeft(12, '0')}';
final qUser = qid(1),
    qBook = qid(2),
    qOtherBook = qid(3),
    qEpoch = qid(4),
    qCash = qid(10),
    qBank = qid(11),
    qUsd = qid(12),
    qParent = qid(20),
    qChild = qid(21),
    qWork = qid(22),
    qTrip = qid(23),
    qIncome = qid(24);
final qa = qid(100),
    qb = qid(101),
    qc = qid(102),
    qd = qid(103),
    qe = qid(104),
    qf = qid(105);
Map<String, Object?> qmoney(
  String amount, {
  String currency = 'CNY',
  int scale = 2,
}) => {'currency': currency, 'currency_scale': scale, 'amount_minor': amount};

final class QueryFixture {
  QueryFixture({QueryExecutor? executor})
    : db = AppDatabase(executor ?? NativeDatabase.memory());
  final AppDatabase db;
  late final local = LocalRepository(db);
  late final ledger = LedgerRepository(local);
  late final batch = LedgerBatchService(ledger);
  late final sync = SyncStore(local);
  final space = DataSpace(
    server: ServerAddress.parse('http://127.0.0.1:18199'),
    serverInstanceId: qid(99),
    userId: qUser,
  );
  Future<void> roles({
    String role = 'owner',
    String otherRole = 'owner',
    String version = '1',
  }) => local.writeSetting(
    'sync.scope-details.${space.id}',
    jsonEncode({
      'version': 1,
      'epoch': qEpoch,
      'scopes': [
        {
          'scope_id': qBook,
          'kind': 'book',
          'role': role,
          'permission_version': version,
        },
        {
          'scope_id': qOtherBook,
          'kind': 'book',
          'role': otherRole,
          'permission_version': version,
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
    await shadow(type, id, scope, data, revision: revision);
  }

  Future<void> shadow(
    String type,
    String id,
    String scope,
    Map<String, Object?> data, {
    String revision = '1',
  }) async {
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

  Future<void> putBill(
    String id,
    Map<String, Object?> input, {
    String? scope,
    String revision = '1',
    bool ownFinance = true,
  }) async {
    final book = scope ?? qBook;
    final full = normalizeLedgerPayload('bill', {
      'book_id': book,
      'business_date': '2026-10-21',
      'business_timezone': 'Asia/Shanghai',
      ...input,
    });
    final payload = ledgerCopy(full),
        hidden = <String>[],
        links = <String, Object?>{
          'account_id': null,
          'from_account_id': null,
          'to_account_id': null,
          'fee_account_id': null,
        };
    for (final field in ['account_id', 'from_account_id', 'to_account_id']) {
      if ({qCash, qBank, qUsd}.contains(payload[field])) {
        hidden.add(field);
        links[field] = payload[field];
        payload[field] = null;
      }
    }
    await put('bill', id, book, {
      'projection_kind': 'bill_public',
      'payload': payload,
      'hidden_account_fields': hidden,
      'hidden_allocation_count': 0,
      'paid_by_user_ids': hidden.isEmpty ? [] : [qUser],
      'nonfinancial_editable_fields': [
        'note',
        'category_id',
        'tag_ids',
        'attachment_ids',
        'flags',
      ],
      'remaining_allocatable_minor': full['bill_type'] == 'expense'
          ? ledgerObject(full['money'])['amount_minor']
          : null,
    }, revision: revision);
    if (hidden.isNotEmpty && ownFinance) {
      await shadow('bill', id, qUser, {
        'projection_kind': 'bill_private_finance',
        'book_id': book,
        'bill_type': full['bill_type'],
        'business_date': full['business_date'],
        'business_timezone': full['business_timezone'],
        'occurred_at': full['occurred_at'],
        'account_links': links,
        'entries': financialPostings(full).map(postingJson).toList(),
      }, revision: revision);
    }
  }

  Future<void> seed() async {
    await local.registerSpace(space);
    await sync.configure(space, qid(5), qEpoch);
    await roles();
    for (final book in [qBook, qOtherBook]) {
      await put('book', book, book, {
        'projection_kind': 'book',
        'payload': {
          'name': book == qBook ? '合成日常' : '合成旅行',
          'currency': 'CNY',
          'timezone': 'Asia/Shanghai',
          'month_start_day': 1,
        },
      });
    }
    for (final id in [qCash, qBank, qUsd]) {
      final opening = qmoney(
        id == qUsd ? '10000' : '100000',
        currency: id == qUsd ? 'USD' : 'CNY',
      );
      await put('account', id, qUser, {
        'projection_kind': 'account',
        'payload': {
          'name': id == qCash ? '合成现金' : '合成账户',
          'kind': id == qCash ? 'cash' : 'bank',
          'opening': opening,
          'hidden': false,
          'include_in_net_assets': true,
        },
        'balance': opening,
      });
    }
    for (final id in [qParent, qChild, qIncome]) {
      await put('category', id, qBook, {
        'projection_kind': 'category',
        'payload': {
          'name': id == qParent
              ? '餐饮'
              : id == qChild
              ? '午餐'
              : '工资',
          'kind': id == qIncome ? 'income' : 'expense',
          'parent_id': id == qChild ? qParent : null,
          'icon': 'food',
          'sort_order': 0,
          'archived': false,
        },
      });
    }
    for (final id in [qWork, qTrip]) {
      await put('tag', id, qBook, {
        'projection_kind': 'tag',
        'payload': {
          'name': id == qWork ? '工作' : '差旅',
          'color': '#2279D7',
          'kind': 'tag',
          'group_id': null,
          'archived': false,
          'sort_order': 0,
        },
      });
    }
    await putBill(qa, {
      'bill_type': 'expense',
      'money': qmoney('1234'),
      'account_id': qCash,
      'category_id': qChild,
      'tag_ids': [qWork],
      'attachment_ids': [qid(42)],
      'note': 'Lunch 样本',
      'occurred_at': '2026-10-21T16:30:00.123456+08:00',
    });
    await putBill(qb, {
      'bill_type': 'expense',
      'money': qmoney('200', currency: 'USD'),
      'account_id': qUsd,
      'category_id': qParent,
      'tag_ids': [qWork, qTrip],
      'source': 'import',
      'business_date': '2026-10-20',
      'flags': {'exclude_from_statistics': true, 'exclude_from_budget': false},
      'reporting': {
        'rate': '7',
        'rate_date': '2026-10-20',
        'rate_source': 'manual',
        'report_currency': 'CNY',
        'report_scale': 2,
        'report_amount_minor': '1400',
      },
    });
    await putBill(qc, {
      'bill_type': 'income',
      'money': qmoney('5000'),
      'account_id': qCash,
      'category_id': qIncome,
      'tag_ids': [qTrip],
      'source': 'auto',
      'occurred_at': '2026-10-21T09:00:00Z',
    });
    await putBill(qd, {
      'bill_type': 'transfer',
      'money': qmoney('1000'),
      'from_account_id': qCash,
      'to_account_id': qBank,
    });
    await putBill(qe, {
      'bill_type': 'expense',
      'money': qmoney('999'),
      'business_date': '2026-10-22',
      'flags': {'exclude_from_statistics': false, 'exclude_from_budget': true},
    }, scope: qOtherBook);
    await putBill(qf, {
      'bill_type': 'expense',
      'money': qmoney('300', currency: 'JPY', scale: 0),
      'tag_ids': [qTrip],
      'attachment_ids': [qid(43)],
      'business_date': '2026-10-01',
      'reporting': {
        'rate': '0.048',
        'rate_date': '2026-10-01',
        'rate_source': 'manual',
        'report_currency': 'CNY',
        'report_scale': 2,
        'report_amount_minor': '1440',
      },
    });
  }

  Future<LedgerEntity> entity(String id) async => (await ledger.read(
    space,
    query: const LedgerQuery(includeArchived: true, includeDeleted: true),
  )).find('bill', id)!;
  Future<void> close() => db.close();
}
