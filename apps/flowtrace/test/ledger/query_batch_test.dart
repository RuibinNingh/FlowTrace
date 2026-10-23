import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/data/ledger/ledger_batch.dart';
import 'package:flowtrace/data/ledger/ledger_models.dart';
import 'package:flowtrace/data/local/app_database.dart';

import 'query_fixtures.dart';

Matcher batchIssue(String id, String code) => isA<BillBatchException>().having(
  (error) => error.issues[id],
  'issue $id',
  code,
);

void main() {
  late QueryFixture f;
  setUp(() async {
    f = QueryFixture();
    await f.seed();
  });
  tearDown(() => f.close());
  test('all unchanged is an explicit no-op and preview never writes', () async {
    final preview = await f.batch.preview(f.space, ids: [qa, qc]);
    expect(preview.canConfirm, isFalse);
    expect(preview.unchangedIds, {qa, qc});
    expect(preview.issues, isEmpty);
    expect(await f.local.pending(f.space), isEmpty);
    await expectLater(
      f.batch.confirm(f.space, preview),
      throwsA(batchIssue('selection', 'batch.not_confirmable')),
    );
  });
  test(
    'confirmation edits only chosen fields and preserves full precision and unseen links',
    () async {
      final before = await f.entity(qa);
      final preview = await f.batch.preview(
        f.space,
        ids: [qa, qc],
        patch: const BillBatchPatch(
          note: BillChange.set('明确备注'),
          excludeFromBudget: BillChange.set(true),
        ),
      );
      expect(preview.canConfirm, isTrue);
      expect(preview.items.first.after['account_id'], isNull);
      expect(preview.items.first.changedFields, {
        'note',
        'flags.exclude_from_budget',
      });
      final result = await f.batch.confirm(f.space, preview);
      expect(result.operationIds.keys.toSet(), {qa, qc});
      final after = await f.entity(qa);
      expect(after.payload['note'], '明确备注');
      expect(after.payload['money'], before.payload['money']);
      expect(after.payload['occurred_at'], '2026-10-21T16:30:00.123456+08:00');
      expect(after.payload['business_timezone'], 'Asia/Shanghai');
      expect((after.payload['flags'] as Map)['exclude_from_statistics'], false);
      expect(after.editablePayload!['account_id'], qCash);
      expect((await f.entity(qb)).payload['source'], 'import');
      expect((await f.local.pending(f.space)).length, 2);
    },
  );
  test(
    'clear and set are distinct from unchanged; invalid mixed categories locate each failure',
    () async {
      final preview = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(
          note: BillChange.clear(),
          categoryId: BillChange.clear(),
          tagIds: BillChange.clear(),
        ),
      );
      expect(preview.canConfirm, isTrue);
      await f.batch.confirm(f.space, preview);
      final data = (await f.entity(qa)).payload;
      expect(data['note'], '');
      expect(data['category_id'], isNull);
      expect(data['tag_ids'], isEmpty);
      final invalid = await f.batch.preview(
        f.space,
        ids: [qa, qc],
        patch: BillBatchPatch(categoryId: BillChange.set(qChild)),
      );
      expect(invalid.canConfirm, isFalse);
      expect(invalid.issues[qc], 'category.kind_mismatch');
      expect((await f.entity(qc)).payload['category_id'], qIncome);
    },
  );
  test(
    'revision or same-revision local changes invalidate confirmation without touching peers',
    () async {
      var preview = await f.batch.preview(
        f.space,
        ids: [qa, qc],
        patch: const BillBatchPatch(note: BillChange.set('预览')),
      );
      await f.putBill(qa, {
        'bill_type': 'expense',
        'money': qmoney('1234'),
        'account_id': qCash,
        'note': '其他设备修改',
      }, revision: '2');
      await expectLater(
        f.batch.confirm(f.space, preview),
        throwsA(batchIssue(qa, 'batch.selection_changed')),
      );
      expect(await f.local.pending(f.space), isEmpty);
      expect((await f.entity(qc)).payload['note'], '');
      preview = await f.batch.preview(
        f.space,
        ids: [qa, qc],
        patch: const BillBatchPatch(note: BillChange.set('另一次预览')),
      );
      await f.ledger.save(
        f.space,
        entityType: 'bill',
        scopeId: qBook,
        entityId: qa,
        payload: {...(await f.entity(qa)).editablePayload!, 'note': '本机继续编辑'},
      );
      await expectLater(
        f.batch.confirm(f.space, preview),
        throwsA(batchIssue(qa, 'batch.selection_changed')),
      );
      expect((await f.local.pending(f.space)).length, 1);
    },
  );
  test(
    'permission version, readonly role and recovery context changes reject confirmation',
    () async {
      var preview = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(note: BillChange.set('预览')),
      );
      await f.roles(version: '2');
      await expectLater(
        f.batch.confirm(f.space, preview),
        throwsA(batchIssue(qa, 'batch.context_changed')),
      );
      preview = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(note: BillChange.set('预览')),
      );
      await f.roles(role: 'viewer', version: '3');
      await expectLater(
        f.batch.confirm(f.space, preview),
        throwsA(batchIssue(qa, 'batch.context_changed')),
      );
      final readonly = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(note: BillChange.set('拒绝')),
      );
      expect(readonly.issues[qa], 'scope.readonly');
      await f.roles();
      preview = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(note: BillChange.set('预览')),
      );
      await (f.db.update(f.db.syncStates)
            ..where((t) => t.spaceId.equals(f.space.id)))
          .write(const SyncStatesCompanion(status: Value('recovery_required')));
      await expectLater(
        f.batch.confirm(f.space, preview),
        throwsA(batchIssue(qa, 'batch.context_changed')),
      );
      expect(await f.local.pending(f.space), isEmpty);
    },
  );
  test(
    'one queue failure rolls back earlier rows and returns the failed selection ID',
    () async {
      final preview = await f.batch.preview(
        f.space,
        ids: [qa, qc],
        patch: const BillBatchPatch(note: BillChange.set('不应半批写入')),
      );
      await f.db.customStatement(
        "CREATE TRIGGER isolated_batch_fail BEFORE INSERT ON pending_operations WHEN NEW.entity_id = '$qc' BEGIN SELECT RAISE(ABORT, 'isolated batch failure'); END",
      );
      await expectLater(
        f.batch.confirm(f.space, preview),
        throwsA(batchIssue(qc, 'batch.storage_failed')),
      );
      expect((await f.entity(qa)).payload['note'], 'Lunch 样本');
      expect((await f.entity(qc)).payload['note'], '');
      expect(await f.local.pending(f.space), isEmpty);
      expect(
        (await f.db.select(f.db.appSettings).get()).where(
          (row) => row.key.startsWith('ledger.postings.'),
        ),
        isEmpty,
      );
    },
  );
  test(
    'hidden financial rows allow strict metadata only; viewer remains denied',
    () async {
      await (f.db.delete(f.db.serverShadows)..where(
            (t) =>
                t.spaceId.equals(f.space.id) &
                t.scopeId.equals(qUser) &
                t.entityId.equals(qa),
          ))
          .go();
      final preview = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(
          note: BillChange.set('公开备注'),
          excludeFromStatistics: BillChange.set(true),
        ),
      );
      expect(preview.canConfirm, isTrue);
      await f.batch.confirm(f.space, preview);
      final command = jsonDecode(
        (await f.local.pending(f.space)).single.operationJson,
      );
      expect(command['payload']['preserve_hidden_financial_links'], true);
      expect(command['payload']['account_id'], isNull);
      final time = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(
          time: BillChange.set(BillTimeEdit(date: '2026-10-22')),
        ),
      );
      expect(time.issues[qa], 'financial_links_hidden');
      final copy = await f.batch.preview(
        f.space,
        ids: [qa],
        action: BillBatchAction.copy,
      );
      expect(copy.issues[qa], 'financial_links_hidden');
    },
  );
  test(
    'book movement is explicitly unsupported while same-book selection stays unchanged',
    () async {
      final move = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: BillBatchPatch(bookId: BillChange.set(qOtherBook)),
      );
      expect(move.issues[qa], 'book_move_requires_server');
      expect(await f.local.pending(f.space), isEmpty);
      final same = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: BillBatchPatch(bookId: BillChange.set(qBook)),
      );
      expect(same.unchangedIds, {qa});
      expect(same.canConfirm, isFalse);
    },
  );
  test(
    'copy freezes a new UUID, retains authorized funding and does not duplicate relations',
    () async {
      final original = await f.entity(qa);
      final preview = await f.batch.preview(
        f.space,
        ids: [qa],
        action: BillBatchAction.copy,
      );
      final target = preview.items.single.targetId;
      expect(target, isNot(qa));
      expect(preview.items.single.after['account_id'], isNull);
      final result = await f.batch.confirm(f.space, preview);
      expect(result.operationIds.keys, [target]);
      final copy = await f.entity(target);
      expect(copy.editablePayload!['account_id'], qCash);
      expect(copy.payload['money'], original.payload['money']);
      expect(
        copy.payload['attachment_ids'],
        original.payload['attachment_ids'],
      );
      expect((await f.entity(qa)).pending, isFalse);
      await expectLater(
        f.batch.confirm(f.space, preview),
        throwsA(isA<BillBatchException>()),
      );
      expect((await f.local.pending(f.space)).length, 1);
    },
  );
  test(
    'related delete refuses an unselected receipt and accepts an explicit source/receipt set',
    () async {
      final receipt = qid(108);
      await f.putBill(receipt, {
        'bill_type': 'refund',
        'money': qmoney('500'),
        'account_id': qCash,
        'allocations': [
          {
            'source_bill_id': qa,
            'source_amount_minor': '500',
            'receipt_amount_minor': '500',
          },
        ],
      });
      final refused = await f.batch.preview(
        f.space,
        ids: [qa],
        action: BillBatchAction.delete,
      );
      expect(refused.issues[qa], 'bill.definition_in_use');
      final preview = await f.batch.preview(
        f.space,
        ids: [qa, receipt],
        action: BillBatchAction.delete,
      );
      expect(preview.canConfirm, isTrue);
      expect(preview.items.first.billId, receipt);
      final result = await f.batch.confirm(f.space, preview);
      expect(result.operationIds.keys.toSet(), {qa, receipt});
      expect((await f.entity(qa)).deleted, isTrue);
      expect((await f.entity(receipt)).deleted, isTrue);
      expect((await f.entity(qc)).deleted, isFalse);
    },
  );
  test(
    'date edits preserve local clock precision and original zone; clear time is explicit',
    () async {
      final preview = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(
          time: BillChange.set(BillTimeEdit(date: '2026-10-22')),
        ),
      );
      expect(preview.items.single.after['business_timezone'], 'Asia/Shanghai');
      expect(
        preview.items.single.after['occurred_at'],
        '2026-10-22T08:30:00.123456Z',
      );
      await f.batch.confirm(f.space, preview);
      final clear = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(time: BillChange.clear()),
      );
      await f.batch.confirm(f.space, clear);
      expect((await f.entity(qa)).payload['occurred_at'], isNull);
      expect((await f.entity(qa)).payload['business_date'], '2026-10-22');
    },
  );
  test(
    'explicit DST gap/fold uses the fixed forward/first-occurrence contract',
    () async {
      await f.putBill(qa, {
        'bill_type': 'expense',
        'money': qmoney('1234'),
        'account_id': qCash,
        'business_date': '2026-03-07',
        'business_timezone': 'America/New_York',
        'occurred_at': '2026-03-07T07:30:00.123456Z',
      });
      var preview = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(
          time: BillChange.set(BillTimeEdit(date: '2026-03-08')),
        ),
      );
      expect(
        preview.items.single.after['occurred_at'],
        '2026-03-08T07:00:00.000Z',
      );
      await f.putBill(qa, {
        'bill_type': 'expense',
        'money': qmoney('1234'),
        'account_id': qCash,
        'business_date': '2026-10-31',
        'business_timezone': 'America/New_York',
        'occurred_at': '2026-10-31T05:30:00.123456Z',
      });
      preview = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(
          time: BillChange.set(BillTimeEdit(date: '2026-11-01')),
        ),
      );
      expect(
        preview.items.single.after['occurred_at'],
        '2026-11-01T05:30:00.123456Z',
      );
    },
  );
  test(
    'unknown IDs are visible failures and cannot accidentally broaden the batch',
    () async {
      final missing = qid(999);
      final preview = await f.batch.preview(
        f.space,
        ids: [qa, missing],
        patch: const BillBatchPatch(note: BillChange.set('不应写入')),
      );
      expect(preview.issues[missing], 'bill.unavailable');
      expect(preview.canConfirm, isFalse);
      await expectLater(
        f.batch.confirm(f.space, preview),
        throwsA(batchIssue(missing, 'bill.unavailable')),
      );
      expect(await f.local.pending(f.space), isEmpty);
    },
  );
  test(
    'delete overflow is rejected in preview and a direct delete rolls back',
    () async {
      final account =
          await (f.db.select(f.db.localEntities)..where(
                (t) => t.spaceId.equals(f.space.id) & t.entityId.equals(qCash),
              ))
              .getSingle();
      final projection = ledgerObject(jsonDecode(account.dataJson));
      projection['balance'] = qmoney('9223372036854775807');
      await f.put('account', qCash, qUser, projection);
      final preview = await f.batch.preview(
        f.space,
        ids: [qa],
        action: BillBatchAction.delete,
      );
      expect(preview.issues[qa], 'money.out_of_range');
      expect(preview.canConfirm, isFalse);
      await expectLater(
        f.ledger.delete(f.space, await f.entity(qa)),
        throwsA(anything),
      );
      expect((await f.entity(qa)).deleted, isFalse);
      expect(await f.local.pending(f.space), isEmpty);
    },
  );
  test(
    'remove attachments changes selected references only, keeps other bills and staging metadata',
    () async {
      await f.putBill(qf, {
        ...(await f.entity(qf)).payload,
        'attachment_ids': [qid(42)],
      });
      await f.local.writeSetting(
        'attachments.local.synthetic.${f.space.id}',
        jsonEncode({
          'attachment_id': qid(42),
          'original_reference': 'synthetic-retained',
        }),
      );
      final preview = await f.batch.preview(
        f.space,
        ids: [qa, qc],
        patch: const BillBatchPatch(removeAttachments: true),
      );
      expect(preview.canConfirm, isTrue);
      expect(preview.unchangedIds, {qc});
      expect(preview.items.first.changedFields, {'attachment_ids'});
      final result = await f.batch.confirm(f.space, preview);
      expect(result.operationIds.keys, [qa]);
      expect((await f.entity(qa)).payload['attachment_ids'], isEmpty);
      expect((await f.entity(qf)).payload['attachment_ids'], [qid(42)]);
      expect(
        await f.local.readSetting('attachments.local.synthetic.${f.space.id}'),
        contains('synthetic-retained'),
      );
      expect((await f.entity(qa)).payload['money'], qmoney('1234'));
      final invalid = await f.batch.preview(
        f.space,
        ids: [qf],
        action: BillBatchAction.copy,
        patch: const BillBatchPatch(removeAttachments: true),
      );
      expect(invalid.issues[qf], 'batch.attachment_removal_update_only');
    },
  );
  test(
    'redacted attachment removal preserves financial restrictions even after raw ACK',
    () async {
      await (f.db.delete(f.db.serverShadows)..where(
            (t) =>
                t.spaceId.equals(f.space.id) &
                t.scopeId.equals(qUser) &
                t.entityId.equals(qa),
          ))
          .go();
      final preview = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(removeAttachments: true),
      );
      expect(preview.canConfirm, isTrue);
      final result = await f.batch.confirm(f.space, preview);
      expect((await f.entity(qa)).editMode, 'metadata');
      expect((await f.entity(qa)).payload['attachment_ids'], isEmpty);
      await f.sync.nextPush(f.space);
      await f.sync.acknowledge(f.space, result.operationIds[qa]!, '2');
      final after = await f.entity(qa);
      expect(after.editMode, 'metadata');
      expect(after.canEdit, isFalse);
      expect(after.projection['hidden_account_fields'], ['account_id']);
      expect(after.editablePayload, isNull);
      final later = await f.batch.preview(
        f.space,
        ids: [qa],
        patch: const BillBatchPatch(
          time: BillChange.set(BillTimeEdit(date: '2026-10-22')),
        ),
      );
      expect(later.issues[qa], 'financial_links_hidden');
    },
  );
}
