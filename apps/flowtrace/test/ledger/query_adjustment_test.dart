import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/data/ledger/ledger_batch.dart';

import 'query_fixtures.dart';

final adjustment = qid(201);
Map<String, Object?> abill(String kind, String amount) => {
  'book_id': qBook,
  'bill_type': kind,
  'money': qmoney(amount),
  'account_id': qCash,
  'business_date': '2026-10-21',
  'business_timezone': 'Asia/Shanghai',
  if (kind == 'balance_adjustment') 'target_balance_minor': '9500',
};

void main() {
  late QueryFixture f;
  Future<String> balance() async =>
      (await f.ledger.read(f.space)).balances[qCash]!.value!.minor.toString();
  setUp(() async {
    f = QueryFixture();
    await f.local.registerSpace(f.space);
    await f.sync.configure(f.space, qid(5), qEpoch);
    await f.roles();
    await f.put('book', qBook, qBook, {
      'projection_kind': 'book',
      'payload': {
        'name': '合成调整',
        'currency': 'CNY',
        'timezone': 'Asia/Shanghai',
        'month_start_day': 1,
      },
    });
    final opening = qmoney('10000');
    await f.put('account', qCash, qUser, {
      'projection_kind': 'account',
      'payload': {
        'name': '合成现金',
        'kind': 'cash',
        'opening': opening,
        'hidden': false,
        'include_in_net_assets': true,
      },
      'balance': opening,
    });
    await f.ledger.save(
      f.space,
      entityType: 'bill',
      scopeId: qBook,
      entityId: qid(200),
      payload: abill('expense', '1000'),
    );
    await f.ledger.save(
      f.space,
      entityType: 'bill',
      scopeId: qBook,
      entityId: adjustment,
      payload: abill('balance_adjustment', '500'),
    );
    await f.ledger.save(
      f.space,
      entityType: 'bill',
      scopeId: qBook,
      entityId: qid(202),
      payload: abill('income', '1000'),
    );
    expect(await balance(), '10500');
  });
  tearDown(() => f.close());
  final changes = <String, Map<String, Object?>>{
    'note': {'note': '只改合成备注'},
    'time': {
      'business_date': '2026-10-22',
      'occurred_at': '2026-10-22T03:04:05.123456Z',
    },
    'flags': {
      'flags': {'exclude_from_statistics': true, 'exclude_from_budget': false},
    },
  };
  for (final change in changes.entries) {
    test(
      'direct ${change.key} retains signed adjustment; delete reverses original',
      () async {
        await f.ledger.save(
          f.space,
          entityType: 'bill',
          scopeId: qBook,
          entityId: adjustment,
          payload: {
            ...(await f.entity(adjustment)).editablePayload!,
            ...change.value,
          },
        );
        expect(await balance(), '10500');
        await f.ledger.delete(f.space, await f.entity(adjustment));
        expect(await balance(), '10000');
      },
    );
  }
  final patches = <String, BillBatchPatch>{
    'note': const BillBatchPatch(note: BillChange.set('只改批量备注')),
    'time': const BillBatchPatch(
      time: BillChange.set(
        BillTimeEdit(date: '2026-10-22', time: '11:04:05.123456'),
      ),
    ),
    'flags': const BillBatchPatch(excludeFromStatistics: BillChange.set(true)),
  };
  for (final patch in patches.entries) {
    test(
      'batch ${patch.key} preview and save retain original signed movement',
      () async {
        final preview = await f.batch.preview(
          f.space,
          ids: [adjustment],
          patch: patch.value,
        );
        expect(preview.canConfirm, isTrue);
        await f.batch.confirm(f.space, preview);
        expect(await balance(), '10500');
        final deletion = await f.batch.preview(
          f.space,
          ids: [adjustment],
          action: BillBatchAction.delete,
        );
        expect(deletion.canConfirm, isTrue);
        await f.batch.confirm(f.space, deletion);
        expect(await balance(), '10000');
      },
    );
  }
  test(
    'explicit financial changes still compute from current balance without old adjustment',
    () async {
      await f.ledger.save(
        f.space,
        entityType: 'bill',
        scopeId: qBook,
        entityId: adjustment,
        payload: {
          ...(await f.entity(adjustment)).editablePayload!,
          'money': qmoney('400'),
          'target_balance_minor': '9600',
        },
      );
      expect(await balance(), '9600');
    },
  );
  test(
    'invalid financial adjustment edit leaves prior sign and state unchanged',
    () async {
      await expectLater(
        f.ledger.save(
          f.space,
          entityType: 'bill',
          scopeId: qBook,
          entityId: adjustment,
          payload: {
            ...(await f.entity(adjustment)).editablePayload!,
            'money': qmoney('999'),
            'target_balance_minor': '9600',
          },
        ),
        throwsA(isA<DomainError>()),
      );
      expect(await balance(), '10500');
      await f.ledger.delete(f.space, await f.entity(adjustment));
      expect(await balance(), '10000');
    },
  );
}
