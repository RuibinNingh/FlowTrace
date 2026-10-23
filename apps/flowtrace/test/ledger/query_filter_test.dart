import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/data/ledger/ledger_query.dart';

import 'query_fixtures.dart';

void main() {
  late QueryFixture f;
  setUp(() async {
    f = QueryFixture();
    await f.seed();
  });
  tearDown(() => f.close());
  Future<BillQueryResult> run([BillFilter? filter]) async =>
      queryBills(await f.ledger.read(f.space), filter: filter);
  test(
    'fixed SQLite set has stable date/instant/UUID order and separate nominal totals',
    () async {
      final result = await run();
      expect(result.ids, [qe, qc, qa, qd, qb, qf]);
      expect(result.totalsByCurrency.keys, ['CNY', 'JPY', 'USD']);
      expect(
        result.totalsByCurrency['CNY']!.nominalAmount!.minor.toString(),
        '8233',
      );
      expect(
        result.totalsByCurrency['USD']!.nominalAmount!.minor.toString(),
        '200',
      );
      expect(
        result.totalsByCurrency['JPY']!.nominalAmount!.minor.toString(),
        '300',
      );
      expect(
        result.totalsByCurrency['CNY']!.byType['transfer']!.minor.toString(),
        '1000',
      );
      expect(result.unavailableIds, isEmpty);
    },
  );
  test(
    'combined dimensions return exact IDs without summing other currencies',
    () async {
      final result = await run(
        BillFilter(
          fromDate: '2026-10-20',
          endDateExclusive: '2026-10-22',
          bookIds: {qBook},
          categoryIds: {qParent},
          tagIds: {qWork},
          types: {'expense'},
          sources: {'manual'},
          currency: 'CNY',
          minAmount: Money('CNY', 2, BigInt.from(1000)),
          maxAmount: Money('CNY', 2, BigInt.from(2000)),
          hasAttachments: true,
          excludeFromStatistics: false,
          excludeFromBudget: false,
        ),
      );
      expect(result.ids, [qa]);
      expect(result.totalsByCurrency.keys, ['CNY']);
      expect(
        result.totalsByCurrency['CNY']!.nominalAmount!.minor.toString(),
        '1234',
      );
    },
  );
  test(
    'category descendants, tag any/all and keyword label/note/amount matching',
    () async {
      expect((await run(BillFilter(categoryIds: {qParent}))).idSet, {qa, qb});
      expect(
        (await run(
          BillFilter(categoryIds: {qParent}, includeDescendants: false),
        )).ids,
        [qb],
      );
      expect(
        (await run(BillFilter(tagIds: {qWork, qTrip}, allTags: true))).ids,
        [qb],
      );
      expect((await run(BillFilter(tagIds: {qTrip}))).idSet, {qb, qc, qf});
      expect((await run(BillFilter(keyword: '餐饮'))).idSet, {qa, qb});
      expect((await run(BillFilter(keyword: '差旅'))).idSet, {qb, qc, qf});
      expect((await run(BillFilter(keyword: 'lUnCh'))).ids, [qa]);
      expect((await run(BillFilter(keyword: '12.34'))).ids, [qa]);
      expect((await run(BillFilter(bookIds: {}))).ids, isEmpty);
      expect((await run(BillFilter(tagIds: {}, allTags: true))).ids, isEmpty);
    },
  );
  test(
    'public hidden account markers are not mistaken for no assets; flags independent',
    () async {
      expect((await run(BillFilter(hasAccount: false))).idSet, {qe, qf});
      expect((await run(BillFilter(hasTags: false))).idSet, {qd, qe});
      expect((await run(BillFilter(hasAttachments: true))).idSet, {qa, qf});
      expect(
        (await run(
          BillFilter(excludeFromStatistics: true, excludeFromBudget: false),
        )).ids,
        [qb],
      );
      expect(
        (await run(
          BillFilter(excludeFromStatistics: false, excludeFromBudget: true),
        )).ids,
        [qe],
      );
      expect(
        (await run(
          BillFilter(fromDate: '2026-10-01', endDateExclusive: '2026-10-20'),
        )).ids,
        [qf],
      );
    },
  );
  test(
    'invalid filter bounds reject, exact amounts beyond 2^53 round-trip',
    () async {
      expect(
        () => BillFilter(
          minAmount: Money('CNY', 2, BigInt.one),
          maxAmount: Money('USD', 2, BigInt.two),
        ),
        throwsA(isA<DomainError>()),
      );
      expect(
        () =>
            BillFilter(fromDate: '2026-10-22', endDateExclusive: '2026-10-21'),
        throwsA(isA<DomainError>()),
      );
      await f.putBill(qid(110), {
        'bill_type': 'income',
        'money': qmoney('9007199254740993'),
      });
      expect(
        (await run(
          BillFilter(
            minAmount: Money('CNY', 2, BigInt.parse('9007199254740993')),
            maxAmount: Money('CNY', 2, BigInt.parse('9007199254740993')),
          ),
        )).ids,
        [qid(110)],
      );
    },
  );
  test(
    'overflow or invalid rows expose missing evidence without dropping valid IDs',
    () async {
      await f.putBill(qid(110), {
        'bill_type': 'income',
        'money': qmoney('9223372036854775807'),
      });
      var result = await run();
      expect(result.ids, contains(qid(110)));
      expect(result.totalsByCurrency['CNY']!.nominalAmount, isNull);
      expect(result.totalsByCurrency['CNY']!.issue, 'query.total_overflow');
      await f.putBill(qid(111), {
        'bill_type': 'expense',
        'money': qmoney('1'),
        'category_id': qid(999),
      });
      result = await run(BillFilter(keyword: '不存在分类'));
      expect(result.unavailableIds, contains(qid(111)));
      expect(result.issues[qid(111)], 'query.search_metadata_unavailable');
    },
  );
}
