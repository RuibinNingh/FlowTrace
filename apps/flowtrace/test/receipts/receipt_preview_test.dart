import 'dart:async';
import 'dart:convert';

import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/receipts/receipt_preview.dart';
import 'package:flowtrace/data/receipts/receipt_read_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart';

void main() {
  late QueryFixture fixture;
  late ReceiptReadRepository reader;
  late StreamController<void> authority;
  late ReceiptReadLease lease;
  var current = true;

  Money money(String minor, {String currency = 'CNY', int scale = 2}) =>
      Money(currency, scale, BigInt.parse(minor));

  Future<ReceiptPreviewSelection> selection({
    String? id,
    String? scope,
    String paid = '10000',
    String? remaining = '5000',
    String allocated = '1000',
    String received = '1000',
    String sourceCurrency = 'CNY',
    int sourceScale = 2,
    String receiptCurrency = 'CNY',
    int receiptScale = 2,
    String? rate,
    ReceiptReadLease? sourceLease,
  }) async {
    final sourceId = id ?? qa, sourceScope = scope ?? qBook;
    await fixture.putBill(
      sourceId,
      {
        'bill_type': 'expense',
        'money': qmoney(paid, currency: sourceCurrency, scale: sourceScale),
      },
      scope: sourceScope,
      revision: '7',
    );
    final query = ReceiptSourceQuery(scopeId: sourceScope, sourceId: sourceId);
    final public = {
      'projection_kind': 'bill_public',
      'payload': {
        'book_id': sourceScope,
        'bill_type': 'expense',
        'money': qmoney(paid, currency: sourceCurrency, scale: sourceScale),
      },
      'hidden_allocation_count': 0,
      'remaining_allocatable_minor': remaining,
    };
    await fixture.put('bill', sourceId, sourceScope, public, revision: '7');
    final sourceRead = await reader.read(lease, query);
    return ReceiptPreviewSelection(
      lease: sourceLease ?? lease,
      query: query,
      read: sourceRead,
      sourceMoney: money(
        allocated,
        currency: sourceCurrency,
        scale: sourceScale,
      ),
      receiptMoney: money(
        received,
        currency: receiptCurrency,
        scale: receiptScale,
      ),
      rate: rate,
    );
  }

  ReceiptPreviewSelection change(
    ReceiptPreviewSelection original, {
    ReceiptReadLease? sourceLease,
    ReceiptSourceRead? read,
    ReceiptSourceQuery? query,
    Money? sourceMoney,
    Money? receiptMoney,
  }) => ReceiptPreviewSelection(
    lease: sourceLease ?? original.lease,
    query: query ?? original.query,
    read: read ?? original.read,
    sourceMoney: sourceMoney ?? original.sourceMoney,
    receiptMoney: receiptMoney ?? original.receiptMoney,
    rate: original.rate,
  );

  ReceiptPreview preview(
    List<ReceiptPreviewSelection> selections, {
    ReceiptPreviewKind kind = ReceiptPreviewKind.refund,
    String total = '1000',
    String income = '0',
    String currency = 'CNY',
    int scale = 2,
  }) => ReceiptPreview.create(
    kind: kind,
    receiptMoney: money(total, currency: currency, scale: scale),
    incomeComponent: money(income, currency: currency, scale: scale),
    selections: selections,
  );

  Matcher error(String code) =>
      throwsA(isA<DomainError>().having((value) => value.code, 'code', code));

  setUp(() async {
    current = true;
    authority = StreamController<void>.broadcast();
    fixture = QueryFixture();
    await fixture.seed();
    await fixture.local.writeSetting(
      'sync.scopes.${fixture.space.id}',
      jsonEncode({qBook: '1', qOtherBook: '1', qUser: '1'}),
    );
    await fixture.sync.applyPullPage(
      fixture.space,
      qEpoch,
      [],
      finalPage: true,
      checkpoint: {qBook: '3', qOtherBook: '2', qUser: '1'},
    );
    reader = ReceiptReadRepository(fixture.local);
    lease = ReceiptReadLease(
      space: fixture.space,
      clientId: qid(5),
      epoch: qEpoch,
      isCurrent: () => current,
      invalidations: authority.stream,
    );
  });
  tearDown(() async {
    await authority.close();
    await fixture.close();
  });

  for (final kind in ReceiptPreviewKind.values) {
    test(
      'single-source ${kind.name} retains exact canonical binding and allocation',
      () async {
        final source = await selection();
        final result = preview([source], kind: kind);
        final binding = result.allocations.single.source;
        expect(binding.sourceId, qa);
        expect(binding.scopeId, qBook);
        expect(binding.entityRevision, '7');
        expect(binding.permissionVersion, '1');
        expect(binding.checkpoint.scopeId, qBook);
        expect(binding.checkpoint.value, '3');
        expect(binding.remainingBefore.minor, BigInt.from(5000));
        expect(binding.remainingAfter.minor, BigInt.from(4000));
        expect(binding.spaceId, fixture.space.id);
        expect(binding.clientId, qid(5));
        expect(binding.epoch, qEpoch);
        expect(result.allocationPayloads, [
          {
            'source_bill_id': qa,
            'source_amount_minor': '1000',
            'receipt_amount_minor': '1000',
            'rate': null,
          },
        ]);
        expect(
          binding.matchesCurrentRead(lease, source.query, source.read),
          isTrue,
        );
      },
    );
  }

  test(
    'legacy unknown breakdown with trustworthy remaining still previews',
    () async {
      final source = await selection();
      expect(source.read.canonicalState!.breakdownKnown, isFalse);
      expect(
        preview([source]).allocations.single.source.remainingAfter.display(),
        '40.00',
      );
    },
  );

  test(
    'full remaining allocation closes exactly without negative source balance',
    () async {
      final source = await selection(allocated: '5000', received: '5000');
      expect(
        preview([
          source,
        ], total: '5000').allocations.single.source.remainingAfter.minor,
        BigInt.zero,
      );
    },
  );

  test(
    'multiple sources across authorized scopes add only receipt currency',
    () async {
      final first = await selection(allocated: '1000', received: '1000');
      final second = await selection(
        id: qb,
        scope: qOtherBook,
        allocated: '2000',
        received: '2000',
      );
      final result = preview(
        [first, second],
        total: '3000',
        kind: ReceiptPreviewKind.reimbursement,
      );
      expect(result.allocations.map((row) => row.source.scopeId), [
        qBook,
        qOtherBook,
      ]);
      expect(result.allocations.map((row) => row.source.remainingAfter.minor), [
        BigInt.from(4000),
        BigInt.from(3000),
      ]);
    },
  );

  test(
    'refund requires explicit exact income component conservation',
    () async {
      final source = await selection();
      final result = preview([source], total: '1250', income: '250');
      expect(result.incomeComponent.minor, BigInt.from(250));
      expect(
        result.allocations.single.source.remainingAfter.minor,
        BigInt.from(4000),
      );
      expect(
        () => preview([source], total: '1250'),
        error('allocation.amount_mismatch'),
      );
    },
  );

  for (final invalidIncome in ['-1', '1']) {
    test('reimbursement rejects income $invalidIncome', () async {
      final source = await selection();
      expect(
        () => preview(
          [source],
          income: invalidIncome,
          kind: ReceiptPreviewKind.reimbursement,
        ),
        error('receipt.invalid_income'),
      );
    });
  }

  test('refund rejects negative explicit income', () async {
    final source = await selection();
    expect(
      () => preview([source], income: '-1'),
      error('receipt.invalid_income'),
    );
  });

  test(
    'cross-currency preserves explicit source, receipt and rate without current valuation',
    () async {
      final source = await selection(
        paid: '20000',
        remaining: '10000',
        allocated: '10000',
        received: '1250',
        receiptCurrency: 'EUR',
        rate: '0.125000000000000000',
      );
      final result = preview([source], total: '1250', currency: 'EUR');
      expect(result.allocations.single.sourceMoney.display(), '100.00');
      expect(result.allocations.single.receiptMoney.display(), '12.50');
      expect(result.allocationPayloads.single['rate'], '0.125000000000000000');
    },
  );

  test(
    'different source currencies keep independent remaining Money values',
    () async {
      final cny = await selection(
        allocated: '10000',
        remaining: '10000',
        paid: '10000',
        received: '1250',
        receiptCurrency: 'EUR',
        rate: '0.125',
      );
      final jpy = await selection(
        id: qb,
        sourceCurrency: 'JPY',
        sourceScale: 0,
        paid: '1000',
        remaining: '1000',
        allocated: '1000',
        received: '600',
        receiptCurrency: 'EUR',
        rate: '0.006',
      );
      final result = preview([cny, jpy], total: '1850', currency: 'EUR');
      expect(result.receiptMoney.display(), '18.50');
      expect(result.allocations.map((row) => row.sourceMoney.currency), [
        'CNY',
        'JPY',
      ]);
      expect(
        result.allocations.map((row) => row.source.remainingAfter.minor),
        everyElement(BigInt.zero),
      );
    },
  );

  for (final input in [
    ('JPY', 0, '1', '0.005', 'CNY', 2, '1'),
    ('KWD', 3, '1', '5', 'CNY', 2, '1'),
    ('CNY', 2, '1', '0.05', 'KWD', 3, '1'),
  ]) {
    test(
      'HALF_UP ${input.$1}/${input.$5} scale conversion uses exact money primitive',
      () async {
        final source = await selection(
          sourceCurrency: input.$1,
          sourceScale: input.$2,
          paid: input.$3,
          remaining: input.$3,
          allocated: input.$3,
          rate: input.$4,
          receiptCurrency: input.$5,
          receiptScale: input.$6,
          received: input.$7,
        );
        expect(
          preview(
            [source],
            total: input.$7,
            currency: input.$5,
            scale: input.$6,
          ).allocations.single.receiptMoney.minor,
          BigInt.one,
        );
      },
    );
  }

  test('cross-currency missing rate is rejected', () async {
    final source = await selection(receiptCurrency: 'EUR');
    expect(() => preview([source], currency: 'EUR'), error('fx.rate_required'));
  });

  for (final rate in ['0', '-1', '1e0', '01', '1.0000000000000000001']) {
    test('invalid frozen rate $rate is rejected', () async {
      final source = await selection(receiptCurrency: 'EUR', rate: rate);
      expect(
        () => preview([source], currency: 'EUR'),
        error('fx.rate_invalid'),
      );
    });
  }

  test(
    'explicit FX receipt mismatch never silently recomputes a user amount',
    () async {
      final source = await selection(
        receiptCurrency: 'EUR',
        rate: '0.125',
        received: '126',
      );
      expect(
        () => preview([source], currency: 'EUR', total: '126'),
        error('allocation.amount_mismatch'),
      );
    },
  );

  test(
    'same currency requires equal allocation and keeps an explicit valid rate',
    () async {
      final mismatch = await selection(received: '999');
      expect(
        () => preview([mismatch], total: '999'),
        error('allocation.amount_mismatch'),
      );
      final exact = await selection(rate: '1.000000000000000000');
      expect(preview([exact]).allocations.single.rate, '1.000000000000000000');
    },
  );

  for (final amount in ['0', '-1']) {
    test('nonpositive source allocation $amount is rejected', () async {
      final source = await selection(allocated: amount);
      expect(() => preview([source]), error('money.must_be_positive'));
    });
    test('nonpositive receipt allocation $amount is rejected', () async {
      final source = await selection(received: amount);
      expect(() => preview([source]), error('money.must_be_positive'));
    });
    test('nonpositive receipt total $amount is rejected', () async {
      final source = await selection();
      expect(
        () => preview([source], total: amount),
        error('money.must_be_positive'),
      );
    });
  }

  test('unknown remaining is unavailable, not zero or paid amount', () async {
    final source = await selection(remaining: null);
    expect(source.read.disposition, ReceiptReadDisposition.ready);
    expect(() => preview([source]), error('receipt.remaining_unknown'));
  });

  for (final remaining in ['0', '999']) {
    test('allocation above remaining $remaining is rejected', () async {
      final source = await selection(remaining: remaining);
      expect(() => preview([source]), error('allocation.exceeds_remaining'));
    });
  }

  test(
    'duplicate source ID is rejected rather than aggregating twice',
    () async {
      final source = await selection();
      expect(
        () => preview([source, source], total: '2000'),
        error('allocation.invalid_source'),
      );
    },
  );

  test('empty and 101-source selections fail without allocations', () async {
    expect(() => preview([]), error('receipt.invalid_allocations'));
    final source = await selection();
    expect(
      () => preview(List.filled(101, source), total: '101000'),
      error('receipt.invalid_allocations'),
    );
  });

  test('100 distinct sources are accepted with exact receipt total', () async {
    final sources = <ReceiptPreviewSelection>[];
    for (var index = 0; index < 100; index++) {
      sources.add(
        await selection(
          id: qid(9000 + index),
          paid: '1',
          remaining: '1',
          allocated: '1',
          received: '1',
        ),
      );
    }
    final result = preview(sources, total: '100');
    expect(result.allocations, hasLength(100));
    expect(result.allocationPayloads.last['source_bill_id'], qid(9099));
  });

  test('amounts above 2^53 remain exact through output JSON', () async {
    const amount = '9007199254740993';
    final source = await selection(
      paid: amount,
      remaining: amount,
      allocated: amount,
      received: amount,
    );
    final result = preview([source], total: amount);
    expect(
      jsonDecode(
        jsonEncode(result.allocationPayloads),
      ).single['source_amount_minor'],
      amount,
    );
    expect(result.allocations.single.source.remainingAfter.minor, BigInt.zero);
  });

  test('receipt aggregate overflow is rejected with no result', () async {
    final source = await selection(
      paid: '9223372036854775807',
      remaining: '9223372036854775807',
      allocated: '9223372036854775807',
      received: '9223372036854775807',
    );
    expect(
      () => preview([source], total: '9223372036854775807', income: '1'),
      error('money.out_of_range'),
    );
  });

  test('money currencies and frozen catalog scales must agree', () async {
    final source = await selection();
    expect(
      () => preview([
        change(source, sourceMoney: money('1000', currency: 'EUR')),
      ]),
      error('money.currency_mismatch'),
    );
    expect(
      () => preview([
        change(source, receiptMoney: money('1000', currency: 'EUR')),
      ]),
      error('money.currency_mismatch'),
    );
    expect(
      () => ReceiptPreview.create(
        kind: ReceiptPreviewKind.refund,
        receiptMoney: money('1000'),
        incomeComponent: money('0', currency: 'EUR'),
        selections: [source],
      ),
      error('money.currency_mismatch'),
    );
    expect(
      () => preview([source], currency: 'CNY', scale: 3),
      error('currency.unsupported'),
    );
  });

  test('viewer source cut cannot authorize a new allocation', () async {
    final source = await selection();
    await fixture.roles(role: 'viewer');
    final read = await reader.read(lease, source.query);
    expect(read.disposition, ReceiptReadDisposition.ready);
    expect(
      () => preview([change(source, read: read)]),
      error('allocation.invalid_source'),
    );
  });

  test('lost authority and revoked source read reject preview', () async {
    final source = await selection();
    current = false;
    expect(() => preview([source]), error('receipt.preview_identity_changed'));
    current = true;
    await fixture.sync.revokeScope(fixture.space, qBook);
    final revoked = await reader.read(lease, source.query);
    expect(
      () => preview([change(source, read: revoked)]),
      error('receipt.source_unavailable'),
    );
  });

  test(
    'financial pending source cut is rejected while awaiting canonical progress',
    () async {
      final source = await selection();
      await fixture.local.saveEntityAndQueue(
        fixture.space,
        QueuedCommand(
          operationId: qid(9899),
          scopeId: qBook,
          entityType: 'bill',
          entityId: qa,
          action: 'update',
          baseRevision: '7',
          payload: {
            'book_id': qBook,
            'bill_type': 'expense',
            'money': qmoney('9999'),
          },
        ),
      );
      final pending = await reader.read(lease, source.query);
      expect(pending.disposition, ReceiptReadDisposition.awaitingSourceSync);
      expect(
        () => preview([change(source, read: pending)]),
        error('receipt.source_unavailable'),
      );
    },
  );

  test(
    'mismatched query source and scope cannot relabel a ready cut',
    () async {
      final source = await selection();
      expect(
        () => preview([
          change(
            source,
            query: ReceiptSourceQuery(scopeId: qBook, sourceId: qb),
          ),
        ]),
        error('allocation.invalid_source'),
      );
      expect(
        () => preview([
          change(
            source,
            query: ReceiptSourceQuery(scopeId: qOtherBook, sourceId: qa),
          ),
        ]),
        error('allocation.invalid_source'),
      );
    },
  );

  for (final identity in ['space', 'client', 'epoch']) {
    test('mixed $identity observations cannot form one preview', () async {
      final first = await selection();
      final second = await selection(id: qb);
      final other = ReceiptReadLease(
        space: identity == 'space'
            ? DataSpace(
                server: fixture.space.server,
                serverInstanceId: qid(666),
                userId: qUser,
              )
            : fixture.space,
        clientId: identity == 'client' ? qid(667) : lease.clientId,
        epoch: identity == 'epoch' ? qid(668) : lease.epoch,
        isCurrent: () => true,
        invalidations: authority.stream,
      );
      expect(
        () =>
            preview([first, change(second, sourceLease: other)], total: '2000'),
        error('receipt.preview_identity_changed'),
      );
    });
  }

  test(
    'confirmation comparison rejects changed revision permission checkpoint and authority',
    () async {
      final source = await selection();
      final binding = preview([source]).allocations.single.source;
      expect(
        binding.matchesCurrentRead(lease, source.query, source.read),
        isTrue,
      );
      await fixture.put('bill', qa, qBook, {
        'projection_kind': 'bill_public',
        'payload': {
          'book_id': qBook,
          'bill_type': 'expense',
          'money': qmoney('10000'),
        },
        'remaining_allocatable_minor': '4000',
      }, revision: '8');
      final changed = await reader.read(lease, source.query);
      expect(binding.matchesCurrentRead(lease, source.query, changed), isFalse);
      current = false;
      expect(
        binding.matchesCurrentRead(lease, source.query, source.read),
        isFalse,
      );
    },
  );

  test(
    'preview and serialized allocations cannot mutate retained selection money',
    () async {
      final source = await selection();
      final result = preview([source]);
      final payloads = result.allocationPayloads;
      payloads.single['source_amount_minor'] = '999999';
      payloads.clear();
      expect(result.allocationPayloads.single['source_amount_minor'], '1000');
      expect(() => result.allocations.clear(), throwsUnsupportedError);
      expect(
        source.read.canonicalState!.remainingAllocatableMinor,
        BigInt.from(5000),
      );
    },
  );
}
