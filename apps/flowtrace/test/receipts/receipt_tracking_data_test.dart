import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/data/ledger/ledger_projection.dart';
import 'package:flowtrace/data/ledger/ledger_reporting.dart';
import 'package:flowtrace/data/ledger/ledger_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart';

const trackingField = 'reimbursement_tracking';

Map<String, Object?> loadContract() {
  final file = File(
    '../../contracts/fixtures/ledger/refund-reimbursement.json',
  );
  return (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
}

void main() {
  final contract = loadContract();
  final baseRaw = ledgerObject(contract['base_expense_payload']);
  final fixtureBook = baseRaw['book_id'],
      fixtureAccount = baseRaw['account_id'];
  Object? remap(Object? value) {
    if (value is Map) {
      return value.map((key, item) => MapEntry(key as String, remap(item)));
    }
    if (value is List) return value.map(remap).toList();
    if (value == fixtureBook) return qBook;
    if (value == fixtureAccount) return qCash;
    return value;
  }

  final base = ledgerObject(remap(baseRaw));
  late QueryFixture f;
  setUp(() async {
    f = QueryFixture();
    await f.seed();
  });
  tearDown(() => f.close());

  Future<String> save(Map<String, Object?> payload, {String? id}) =>
      f.ledger.save(
        f.space,
        entityType: 'bill',
        scopeId: qBook,
        entityId: id ?? qid(9000),
        payload: payload,
      );

  Future<String> databaseState() async => jsonEncode({
    'entities': (await f.db.select(f.db.localEntities).get())
        .map((row) => row.toJson())
        .toList(),
    'shadows': (await f.db.select(f.db.serverShadows).get())
        .map((row) => row.toJson())
        .toList(),
    'operations': (await f.db.select(f.db.pendingOperations).get())
        .map((row) => row.toJson())
        .toList(),
    'settings': (await f.db.select(f.db.appSettings).get())
        .map((row) => row.toJson())
        .toList(),
  });

  Map<String, Object?> queuedPayload(String operationJson) =>
      ledgerObject(ledgerObject(jsonDecode(operationJson))['payload']);

  for (final raw in contract['tracking_vectors'] as List) {
    final vector = ledgerObject(raw);
    test('shared strict tracking vector ${vector['id']}', () async {
      final payload = ledgerObject(remap(vector['payload']));
      if (vector['accepted'] == true) {
        await save(payload);
        final queued = queuedPayload(
          (await f.local.pending(f.space)).single.operationJson,
        );
        expect(
          queued.containsKey(trackingField),
          payload.containsKey(trackingField),
        );
        if (payload.containsKey(trackingField)) {
          expect(queued[trackingField], payload[trackingField]);
        }
      } else {
        final before = await databaseState();
        await expectLater(save(payload), throwsA(isA<DomainError>()));
        expect(await databaseState(), before);
      }
    });
  }

  for (final raw in contract['preservation_vectors'] as List) {
    final vector = ledgerObject(raw);
    test('shared exact presence vector ${vector['id']}', () async {
      final id = qid(9000);
      await f.putBill(id, {...base, ...ledgerObject(vector['before'])});
      final shadowBefore = (await f.db.select(f.db.serverShadows).get())
          .map((row) => row.dataJson)
          .toList();
      await save({
        ...base,
        'bill_type': vector['after_bill_type'] ?? 'expense',
        'note': 'Older complete form only changed this metadata.',
        ...ledgerObject(vector['incoming']),
      });
      final expected = ledgerObject(vector['expected']);
      final queued = queuedPayload(
        (await f.local.pending(f.space)).single.operationJson,
      );
      final entity = await f.entity(id);
      for (final payload in [queued, entity.editablePayload!]) {
        expect(
          payload.containsKey(trackingField),
          expected.containsKey(trackingField),
        );
        if (expected.containsKey(trackingField)) {
          expect(payload[trackingField], expected[trackingField]);
        }
      }
      expect(
        (await f.db.select(f.db.serverShadows).get())
            .map((row) => row.dataJson)
            .toList(),
        shadowBefore,
      );
      if (vector['after_bill_type'] == 'income') {
        expect(queued['bill_type'], 'income');
        expect(queued.containsKey(trackingField), isFalse);
      }
    });
  }

  test(
    'tracking is metadata while real financial differences stay fingerprinted',
    () {
      expect(
        financialFingerprint({...base, trackingField: true}),
        financialFingerprint(base),
      );
      expect(
        financialFingerprint({...base, trackingField: false}),
        financialFingerprint(base),
      );
      expect(
        financialFingerprint({...base, 'money': qmoney('9999')}),
        isNot(financialFingerprint(base)),
      );
      expect(
        normalizeLedgerPayload('bill', base).containsKey(trackingField),
        isFalse,
      );
    },
  );

  test(
    'legacy shadows and a frozen predecessor keep their exact bytes and hash',
    () async {
      final entity = await f.entity(qa);
      expect(entity.payload.containsKey(trackingField), isFalse);
      final shadowsBefore = (await f.db.select(f.db.serverShadows).get())
          .map((row) => row.toJson())
          .toList();
      await save({...entity.editablePayload!, 'note': 'legacy edit'}, id: qa);
      final frozen = (await f.sync.nextPush(f.space))!;
      final oldOperation = (await f.local.pending(f.space)).single;
      final oldHash = sha256.convert(utf8.encode(frozen.body));
      expect(
        queuedPayload(oldOperation.operationJson).containsKey(trackingField),
        isFalse,
      );
      await save({
        ...entity.editablePayload!,
        'note': 'legacy edit',
        trackingField: true,
      }, id: qa);
      await save({
        ...entity.editablePayload!,
        'note': 'legacy edit',
        trackingField: false,
      }, id: qa);
      final operations = await f.local.pending(f.space);
      expect(operations, hasLength(3));
      expect(operations.first.operationJson, oldOperation.operationJson);
      expect(operations.first.frozenRequestJson, frozen.body);
      expect((await f.sync.nextPush(f.space))!.body, frozen.body);
      expect(
        sha256.convert(utf8.encode(operations.first.frozenRequestJson!)),
        oldHash,
      );
      expect(
        (await f.db.select(f.db.serverShadows).get())
            .map((row) => row.toJson())
            .toList(),
        shadowsBefore,
      );
    },
  );

  test(
    'cancelling tracking leaves balances, report, calendar and budget unchanged',
    () async {
      final original = (await f.entity(qa)).editablePayload!;
      await f.putBill(qa, {...original, trackingField: true});
      await f.put('budget', qid(9100), qBook, {
        'projection_kind': 'budget',
        'payload': {
          'period_start': '2026-10-01',
          'period_end_exclusive': '2026-11-01',
          'total': qmoney('5000'),
          'categories': [],
          'carry_forward': false,
        },
      });
      final reports = LedgerReportingService(f.local);
      final query = ReportQuery(
        bookId: qBook,
        reportCurrency: 'CNY',
        reportScale: 2,
        startDate: '2026-10-01',
        endDateExclusive: '2026-11-01',
      );
      final beforeReport = await reports.read(f.space, query);
      expect(beforeReport.available, isTrue, reason: '${beforeReport.issues}');
      expect(beforeReport.budget, isNotNull);
      final beforeBalances = (await f.ledger.read(f.space)).balances;
      await save({...original, trackingField: false}, id: qa);
      final afterReport = await reports.read(f.space, query);
      expect(afterReport.toJson(), beforeReport.toJson());
      final afterBalances = (await f.ledger.read(f.space)).balances;
      for (final id in beforeBalances.keys) {
        expect(
          afterBalances[id]!.value?.toJson(),
          beforeBalances[id]!.value?.toJson(),
        );
        expect(
          afterBalances[id]!.status,
          id == qCash ? 'pending' : beforeBalances[id]!.status,
        );
      }
      expect((await f.entity(qa)).payload[trackingField], isFalse);
    },
  );

  test(
    'redacted tracking metadata preserves hidden finance and read-only summary',
    () async {
      final original = (await f.entity(qa)).projection;
      final oldPayload = ledgerObject(original['payload']);
      final summary = {
        'refund_source_minor': '300',
        'reimbursement_source_minor': '200',
        'remaining_source_minor': '734',
        'settlement_reason': 'open',
      };
      await f.put('bill', qa, qBook, {
        ...original,
        'payload': {...oldPayload, trackingField: true},
        'source_summary': summary,
        'remaining_allocatable_minor': '734',
      });
      // Simulate an authorized shared-book editor without the payer's private
      // projection. Public metadata must not require or invent that evidence.
      await (f.db.delete(
        f.db.serverShadows,
      )..where((t) => t.scopeId.equals(qUser) & t.entityId.equals(qa))).go();
      await f.roles(role: 'editor');
      final entity = await f.entity(qa);
      expect(entity.editMode, 'metadata');
      expect(entity.editablePayload, isNull);
      expect(entity.projection['source_summary'], summary);
      expect(entity.payload.containsKey('source_summary'), isFalse);
      final originalShadow = (await f.db.select(f.db.serverShadows).get())
          .map((row) => row.toJson())
          .toList();
      final balances = (await f.ledger.read(f.space)).balances;
      await save({
        ...entity.payload,
        trackingField: false,
        'preserve_hidden_financial_links': true,
      }, id: qa);
      final pending = queuedPayload(
        (await f.local.pending(f.space)).single.operationJson,
      );
      expect(pending[trackingField], isFalse);
      expect(pending['account_id'], isNull);
      expect(pending['money'], oldPayload['money']);
      expect(pending['allocations'], oldPayload['allocations']);
      expect(pending.containsKey('source_summary'), isFalse);
      expect(financialFingerprint(pending), financialFingerprint(oldPayload));
      expect(
        (await f.db.select(f.db.serverShadows).get())
            .map((row) => row.toJson())
            .toList(),
        originalShadow,
      );
      expect((await f.entity(qa)).editMode, 'metadata');
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.value!.toJson(),
        balances[qCash]!.value!.toJson(),
      );
    },
  );

  test(
    'summary stays outside writable payload and private finance is not split evidence',
    () async {
      final entity = await f.entity(qa);
      final raw = entity.projection;
      await f.put('bill', qa, qBook, {
        ...raw,
        'remaining_allocatable_minor': '734',
      });
      final report = await LedgerReportingService(f.local).read(
        f.space,
        ReportQuery(
          bookId: qBook,
          reportCurrency: 'CNY',
          reportScale: 2,
          startDate: '2026-10-01',
          endDateExclusive: '2026-11-01',
        ),
      );
      expect(report.available, isTrue, reason: '${report.issues}');
      expect(report.allocationBreakdownAvailable, isFalse);
      expect(report.totals!.refund, isNull);
      expect(report.totals!.reimbursement, isNull);
      final before = await databaseState();
      await expectLater(
        save({
          ...entity.editablePayload!,
          'source_summary': {
            'refund_source_minor': '0',
            'reimbursement_source_minor': '500',
            'remaining_source_minor': '734',
            'settlement_reason': 'open',
          },
        }, id: qa),
        throwsA(isA<DomainError>()),
      );
      expect(await databaseState(), before);
    },
  );

  test(
    'last invalid tracking write rolls back the complete local batch and hints',
    () async {
      final before = await databaseState();
      await expectLater(
        f.ledger.saveBatch(f.space, [
          LedgerWrite(
            entityType: 'bill',
            scopeId: qBook,
            entityId: qid(9200),
            payload: {...base, trackingField: true},
          ),
          LedgerWrite(
            entityType: 'bill',
            scopeId: qBook,
            entityId: qid(9201),
            payload: {...base, trackingField: null},
          ),
        ]),
        throwsA(isA<DomainError>()),
      );
      expect(await databaseState(), before);
    },
  );

  test('viewer cannot change tracking or create any queued intent', () async {
    final original = (await f.entity(qa)).editablePayload!;
    await f.roles(role: 'viewer');
    final before = await databaseState();
    await expectLater(
      save({...original, trackingField: true}, id: qa),
      throwsA(isA<DomainError>()),
    );
    expect(await databaseState(), before);
  });
}
