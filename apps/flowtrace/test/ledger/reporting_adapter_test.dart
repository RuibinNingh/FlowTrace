import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flowtrace/data/ledger/ledger_reporting.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'query_fixtures.dart';

final receiptId = qid(800), newSourceId = qid(801), budgetId = qid(802);
Map<String, Object?> receipt(
  String amount, {
  String? sourceId,
  String? bookId,
  String kind = 'refund',
}) => {
  'book_id': bookId ?? qBook,
  'bill_type': kind,
  'money': qmoney(amount),
  'account_id': qCash,
  'business_date': '2026-11-03',
  'business_timezone': 'Asia/Shanghai',
  'allocations': [
    {
      'source_bill_id': sourceId ?? qa,
      'source_amount_minor': amount,
      'receipt_amount_minor': amount,
      'rate': null,
    },
  ],
};

void main() {
  late QueryFixture f;
  late LedgerReportingService reports;
  final query = ReportQuery(
    bookId: qBook,
    reportCurrency: 'CNY',
    reportScale: 2,
    startDate: '2026-10-01',
    endDateExclusive: '2026-11-01',
  );
  setUp(() async {
    f = QueryFixture();
    await f.seed();
    reports = LedgerReportingService(f.local);
  });
  tearDown(() => f.close());
  Future<ReportResult> read({String? budget}) =>
      reports.read(f.space, query, budgetId: budget);
  Future<void> remaining(String value, {String revision = '2'}) async {
    final data = (await f.entity(qa)).projection;
    data['remaining_allocatable_minor'] = value;
    await f.put('bill', qa, qBook, data, revision: revision);
  }

  Future<String> saveReceipt(
    String amount, {
    String? sourceId,
    String? bookId,
    String kind = 'refund',
  }) => f.ledger.save(
    f.space,
    entityType: 'bill',
    entityId: receiptId,
    scopeId: bookId ?? qBook,
    payload: receipt(amount, sourceId: sourceId, bookId: bookId, kind: kind),
  );

  Future<void> putBudget({
    String? id,
    String? total = '5000',
    Map<String, String> categories = const {},
    String currency = 'CNY',
    String start = '2026-10-01',
    String end = '2026-11-01',
  }) => f.put('budget', id ?? budgetId, qBook, {
    'projection_kind': 'budget',
    'payload': {
      'period_start': start,
      'period_end_exclusive': end,
      'total': total == null ? null : qmoney(total, currency: currency),
      'categories': [
        for (final entry in categories.entries)
          {
            'category_id': entry.key,
            'limit': qmoney(entry.value, currency: currency),
          },
      ],
      'carry_forward': false,
    },
  });

  test(
    'confirmed public history uses exact FX, independent flags and hierarchy',
    () async {
      final result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.totals!.income.minor.toString(), '5000');
      expect(result.totals!.expense.minor.toString(), '2674');
      expect(result.totals!.net.minor.toString(), '2326');
      expect(result.totals!.budgetEligible.minor.toString(), '4074');
      expect(result.categoryExpenseRollupMinor![qParent], '1234');
      expect(result.calendar!['2026-10-21']!.expense.minor.toString(), '1234');
      expect(result.calendar!.containsKey('2026-10-22'), isFalse);
      final text = jsonEncode(result.toJson());
      expect(text, isNot(contains(qCash)));
      expect(text, isNot(contains('Lunch')));
      expect(text, isNot(contains('account_links')));
    },
  );

  test(
    'cross-period pending refund create/edit/delete adjusts only the local delta',
    () async {
      await saveReceipt('234');
      var result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.totals!.expense.minor.toString(), '2440');
      expect(result.totals!.refund!.minor.toString(), '234');
      expect(result.calendar!.containsKey('2026-11-03'), isFalse);
      await saveReceipt('500');
      result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.totals!.expense.minor.toString(), '2174');
      await f.ledger.delete(f.space, await f.entity(receiptId));
      result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.totals!.expense.minor.toString(), '2674');
    },
  );

  for (final deleting in [false, true]) {
    test(
      'confirmed receipt ${deleting ? 'delete' : 'edit'} reverses its canonical allocation first',
      () async {
        await f.putBill(receiptId, receipt('500'));
        await remaining('734');
        expect((await read()).totals!.expense.minor.toString(), '2174');
        if (deleting) {
          await f.ledger.delete(f.space, await f.entity(receiptId));
        } else {
          await saveReceipt('700');
        }
        final result = await read();
        expect(result.available, isTrue, reason: '${result.issues}');
        expect(
          result.totals!.expense.minor.toString(),
          deleting ? '2674' : '1974',
        );
        expect(result.totals!.refund!.minor.toString(), deleting ? '0' : '700');
      },
    );
  }

  test(
    'canonical pull before ACK does not count the queued receipt twice',
    () async {
      final operation = await saveReceipt('234');
      await f.sync.nextPush(f.space);
      await f.putBill(receiptId, receipt('234'));
      await remaining('1000');
      final before = await read();
      expect(before.available, isTrue, reason: '${before.issues}');
      expect(before.totals!.expense.minor.toString(), '2440');
      await f.sync.acknowledge(f.space, operation, '1');
      final after = await read();
      expect(after.available, isTrue, reason: '${after.issues}');
      expect(after.totals!.expense.minor.toString(), '2440');
    },
  );

  test(
    'raw ACK is unavailable until canonical source and receipt arrive',
    () async {
      final operation = await saveReceipt('234');
      await f.sync.nextPush(f.space);
      await f.sync.acknowledge(f.space, operation, '1');
      var result = await read();
      expect(result.available, isFalse);
      expect(result.issues, ['report.allocation_stale']);
      expect(result.totals, isNull);
      await f.putBill(receiptId, receipt('234'));
      await remaining('1000');
      result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.totals!.expense.minor.toString(), '2440');
    },
  );

  test(
    'own revision-zero expense and receipt prove a complete local intent',
    () async {
      await f.ledger.save(
        f.space,
        entityType: 'bill',
        entityId: newSourceId,
        scopeId: qBook,
        payload: {
          'book_id': qBook,
          'bill_type': 'expense',
          'money': qmoney('1000'),
          'account_id': qCash,
          'business_date': '2026-10-31',
          'business_timezone': 'Asia/Shanghai',
        },
      );
      await saveReceipt('200', sourceId: newSourceId);
      final result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.totals!.expense.minor.toString(), '3474');
      expect(result.totals!.refund!.minor.toString(), '200');
    },
  );

  test(
    'pending source amount edits preserve known canonical allocated amount',
    () async {
      await f.putBill(receiptId, receipt('234'));
      await remaining('1000');
      await f.ledger.save(
        f.space,
        entityType: 'bill',
        entityId: qa,
        scopeId: qBook,
        payload: {
          ...(await f.entity(qa)).editablePayload!,
          'money': qmoney('1500'),
        },
      );
      final result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.totals!.expense.minor.toString(), '2706');
    },
  );

  test(
    'hidden confirmed allocation proves net but never invents refund breakdown',
    () async {
      await remaining('734');
      await (f.db.delete(f.db.serverShadows)..where(
            (t) => t.spaceId.equals(f.space.id) & t.scopeId.equals(qUser),
          ))
          .go();
      final result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.totals!.expense.minor.toString(), '2174');
      expect(result.totals!.refund, isNull);
      expect(result.allocationBreakdownAvailable, isFalse);
      expect(jsonEncode(result.toJson()), isNot(contains(qCash)));
    },
  );

  test(
    'authorized new foreign receipt changes source net without exposing its links',
    () async {
      await saveReceipt('234', bookId: qOtherBook);
      final result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.totals!.expense.minor.toString(), '2440');
      expect(result.allocationBreakdownAvailable, isFalse);
      final text = jsonEncode(result.toJson());
      expect(text, isNot(contains(receiptId)));
      expect(text, isNot(contains(qOtherBook)));
    },
  );

  test(
    'missing canonical remaining is explicit and cannot use private finance to fill it',
    () async {
      final data = (await f.entity(qa)).projection;
      data.remove('remaining_allocatable_minor');
      await f.put('bill', qa, qBook, data);
      final result = await read();
      expect(result.available, isFalse);
      expect(result.issues, ['report.allocations_incomplete']);
      expect(result.totals, isNull);
    },
  );

  test(
    'pending reimbursement has its own split and is not ordinary income',
    () async {
      await saveReceipt('500', kind: 'reimbursement');
      final result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.totals!.expense.minor.toString(), '2174');
      expect(result.totals!.income.minor.toString(), '5000');
      expect(result.totals!.refund!.minor.toString(), '0');
      expect(result.totals!.reimbursement!.minor.toString(), '500');
    },
  );

  for (final metadataOnly in [false, true]) {
    test(
      'foreign hidden allocation ${metadataOnly ? 'metadata' : 'financial edit'} keeps its evidence boundary',
      () async {
        await remaining('1000');
        await f.putBill(
          receiptId,
          receipt('234', bookId: qOtherBook),
          scope: qOtherBook,
        );
        final data = (await f.entity(receiptId)).projection;
        final public = (data['payload'] as Map).cast<String, Object?>();
        public['allocations'] = <Object?>[];
        data['hidden_allocation_count'] = 1;
        await f.put('bill', receiptId, qOtherBook, {
          ...data,
          'payload': public,
        });
        if (metadataOnly) {
          await f.ledger.save(
            f.space,
            entityType: 'bill',
            entityId: receiptId,
            scopeId: qOtherBook,
            payload: {
              ...public,
              'note': '公开备注',
              'preserve_hidden_financial_links': true,
            },
          );
        } else {
          // A legacy cached full financial edit has no canonical old source link.
          // It must never be inferred from the visible empty allocation list.
          await f.local.saveEntityAndQueue(
            f.space,
            QueuedCommand(
              operationId: qid(900),
              scopeId: qOtherBook,
              entityType: 'bill',
              entityId: receiptId,
              action: 'update',
              baseRevision: '1',
              payload: receipt('300', bookId: qOtherBook),
            ),
          );
        }
        final result = await read();
        expect(result.available, metadataOnly, reason: '${result.issues}');
        if (metadataOnly) {
          expect(result.totals!.expense.minor.toString(), '2440');
        } else {
          expect(result.issues, ['report.allocations_incomplete']);
          expect(result.totals, isNull);
        }
        expect(jsonEncode(result.toJson()), isNot(contains(qOtherBook)));
      },
    );
  }

  test(
    'archived categories remain in rollups and total-only budget counts independent flags',
    () async {
      final category = (await f.ledger.read(
        f.space,
      )).find('category', qParent)!;
      await f.put('category', qParent, qBook, {
        'projection_kind': 'category',
        'payload': {...category.payload, 'archived': true},
      });
      await putBudget();
      final result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.categoryExpenseRollupMinor![qParent], '1234');
      expect(result.budget!['spent_minor'], '4074');
      expect(result.budget!['remaining_minor'], '926');
      expect((await f.ledger.read(f.space)).budgets.single.id, budgetId);
    },
  );

  test(
    'category-only and equal total budgets include each descendant once',
    () async {
      await putBudget(total: null, categories: {qParent: '3000'});
      var result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.budget!['spent_minor'], '2634');
      await putBudget(total: '3000', categories: {qParent: '3000'});
      result = await read();
      expect(result.available, isTrue, reason: '${result.issues}');
      expect(result.budget!['spent_minor'], '2634');
    },
  );

  test(
    'ambiguous, foreign currency and period-mismatched budgets never yield partial numbers',
    () async {
      await putBudget();
      await putBudget(id: qid(803));
      expect((await read()).issues, ['report.budget_ambiguous']);
      expect((await read(budget: budgetId)).available, isTrue);
      await putBudget(currency: 'USD');
      expect((await read(budget: budgetId)).issues, [
        'budget.currency_mismatch',
      ]);
      await putBudget(start: '2026-09-01');
      expect((await read(budget: budgetId)).issues, ['budget.period_mismatch']);
      expect((await read(budget: qid(899))).issues, [
        'report.budget_unavailable',
      ]);
    },
  );

  test(
    'scope and epoch recovery guards prevent a stale cache from returning zero totals',
    () async {
      await f.local.writeSetting(
        'sync.scope-details.${f.space.id}',
        jsonEncode({
          'version': 1,
          'epoch': qid(998),
          'scopes': [
            {'scope_id': qBook, 'role': 'owner'},
          ],
        }),
      );
      expect((await read()).issues, ['report.scope_unavailable']);
      await f.roles(role: 'viewer');
      expect((await read()).available, isTrue);
      await (f.db.update(f.db.syncStates)
            ..where((t) => t.spaceId.equals(f.space.id)))
          .write(const SyncStatesCompanion(status: Value('recovery_required')));
      final result = await read();
      expect(result.issues, ['report.sync_unavailable']);
      expect(result.totals, isNull);
    },
  );

  test(
    'rejected deletion stays unavailable rather than silently removing the expense',
    () async {
      await f.ledger.delete(f.space, await f.entity(qa));
      final op = (await f.local.pending(f.space)).single;
      await f.sync.reject(f.space, op.operationId, 'revision_conflict');
      final result = await read();
      expect(result.available, isFalse);
      expect(result.issues, ['report.local_conflict']);
    },
  );

  test(
    'a rejected budget deletion cannot silently turn the budget into absent',
    () async {
      await putBudget();
      final budget = (await f.ledger.read(f.space)).budgets.single;
      await f.ledger.delete(f.space, budget);
      final op = (await f.local.pending(f.space)).single;
      await f.sync.reject(f.space, op.operationId, 'revision_conflict');
      final result = await read();
      expect(result.issues, ['report.local_conflict']);
      expect(result.budget, isNull);
    },
  );

  test(
    'watch observes committed source and pending allocation changes',
    () async {
      final seen = <String>[];
      final complete = Completer<void>();
      final subscription = reports.watch(f.space, query).listen((result) {
        if (result.available) seen.add(result.totals!.expense.minor.toString());
        if (seen.contains('2440') && !complete.isCompleted) complete.complete();
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await saveReceipt('234');
      await complete.future.timeout(const Duration(seconds: 5));
      expect(seen, contains('2674'));
      expect(seen.last, '2440');
      await subscription.cancel();
    },
  );
}
