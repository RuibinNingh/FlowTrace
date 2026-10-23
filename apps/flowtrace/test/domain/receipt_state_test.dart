import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/domain/receipts/receipt_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture_support.dart';

Map<String, Object?> publicSource({
  String paid = '10000',
  String remaining = '5000',
  Object? summary,
  bool includeSummary = true,
  Map<String, Object?> tracking = const {},
}) => {
  'projection_kind': 'bill_public',
  'payload': {
    'bill_type': 'expense',
    'money': {'currency': 'CNY', 'currency_scale': 2, 'amount_minor': paid},
    ...tracking,
  },
  'remaining_allocatable_minor': remaining,
  if (includeSummary) 'source_summary': summary,
};

Matcher receiptError([String? code]) => throwsA(
  isA<DomainError>().having(
    (error) => error.code,
    'finite receipt error',
    code ?? startsWith('receipt.'),
  ),
);

void main() {
  final fixture = loadLedgerFixture('refund-reimbursement.json');
  final sourceVectors = fixture['source_summary_vectors'] as List;
  Map<String, Object?> sourceVector(String id) {
    final vector = sourceVectors.cast<Map>().singleWhere((v) => v['id'] == id);
    final source = publicSource(
      paid: vector['paid_minor'] as String,
      remaining: vector['remaining_allocatable_minor'] as String,
      summary: vector['source_summary'],
      includeSummary: vector.containsKey('source_summary'),
    );
    (source['payload'] as Map)['bill_type'] = vector['bill_type'];
    return source;
  }

  group('shared strict tracking vectors', () {
    for (final raw in fixture['tracking_vectors'] as List) {
      final vector = raw as Map;
      test(vector['id'] as String, () {
        final payload = copyMap(vector['payload'] as Map);
        final unchanged = copyMap(payload);
        if (vector['accepted'] == false) {
          expect(
            () => ReimbursementTracking.fromPayload(payload),
            receiptError('receipt.invalid_tracking'),
          );
        } else {
          final tracking = ReimbursementTracking.fromPayload(payload);
          expect(
            tracking.isPresent,
            payload.containsKey('reimbursement_tracking'),
          );
          expect(tracking.enabled, payload['reimbursement_tracking'] ?? false);
          expect(tracking.toPayloadFields(), {
            if (payload.containsKey('reimbursement_tracking'))
              'reimbursement_tracking': payload['reimbursement_tracking'],
          });
        }
        expect(payload, unchanged);
      });
    }
  });

  group('shared optional field preservation vectors', () {
    for (final raw in fixture['preservation_vectors'] as List) {
      final vector = raw as Map;
      test(vector['id'] as String, () {
        final before = {
          'bill_type': 'expense',
          ...copyMap(vector['before'] as Map),
        };
        final incoming = copyMap(vector['incoming'] as Map);
        final beforeCopy = copyMap(before);
        final incomingCopy = copyMap(incoming);
        final tracking = ReimbursementTracking.afterMetadataPatch(
          beforePayload: before,
          patch: incoming,
          afterBillType: vector['after_bill_type'] as String? ?? 'expense',
        );
        expect(tracking.toPayloadFields(), vector['expected']);
        expect(before, beforeCopy);
        expect(incoming, incomingCopy);
      });
    }
  });

  group('shared closed source summary vectors', () {
    for (final raw in sourceVectors) {
      final vector = raw as Map;
      test(vector['id'] as String, () {
        final source = sourceVector(vector['id'] as String);
        final unchanged = copyMap(source);
        if (vector['accepted'] == false) {
          expect(
            () => ReceiptSourceState.fromCanonicalPublicBill(source),
            receiptError(),
          );
        } else {
          final actual = ReceiptSourceState.fromCanonicalPublicBill(source);
          expect(actual.paid.minor.toString(), vector['paid_minor']);
          expect(
            actual.remainingAllocatableMinor.toString(),
            vector['remaining_allocatable_minor'],
          );
          if (vector.containsKey('source_summary')) {
            expect(actual.summary!.toJson(), vector['source_summary']);
            expect(actual.breakdownKnown, isTrue);
          } else {
            expect(actual.summary, isNull);
            expect(actual.refundSourceMinor, isNull);
            expect(actual.reimbursementSourceMinor, isNull);
            expect(actual.refundProgress, ReceiptComponentProgress.unknown);
            expect(
              actual.reimbursementProgress,
              ReceiptComponentProgress.unknown,
            );
          }
        }
        expect(source, unchanged);
      });
    }
  });

  group('shared lifecycle snapshots are read without executing commands', () {
    final lifecycle = fixture['lifecycle'] as Map;
    final setup = lifecycle['setup'] as Map;
    for (final raw in lifecycle['steps'] as List) {
      final step = raw as Map;
      final expected = (step['expected'] as Map)['state'] as Map;
      if (expected['source_deleted'] == true) continue;
      test(step['step_id'] as String, () {
        final tracking = expected['source_tracking'] as Map;
        final actual = ReceiptSourceState.fromCanonicalPublicBill(
          publicSource(
            paid: setup['source_paid_minor'] as String,
            remaining: expected['remaining_allocatable_minor'] as String,
            summary: expected['source_summary'],
            tracking: {
              if (tracking['present'] == true)
                'reimbursement_tracking': tracking['value'],
            },
          ),
        );
        expect(actual.summary!.toJson(), expected['source_summary']);
        expect(actual.tracking.isPresent, tracking['present']);
        expect(actual.tracking.enabled, tracking['value'] ?? false);
      });
    }
  });

  test('full refunds and mixed settlement never mean fully reimbursed', () {
    final refunded = ReceiptSourceState.fromCanonicalPublicBill(
      sourceVector('all_refunded'),
    );
    final mixed = ReceiptSourceState.fromCanonicalPublicBill(
      sourceVector('mixed_settled'),
    );
    final reimbursed = ReceiptSourceState.fromCanonicalPublicBill(
      sourceVector('all_reimbursed'),
    );
    expect(refunded.settlementProgress, ReceiptSettlementProgress.settled);
    expect(refunded.refundProgress, ReceiptComponentProgress.full);
    expect(refunded.reimbursementProgress, ReceiptComponentProgress.none);
    expect(refunded.fullyReimbursed, isFalse);
    expect(mixed.fullyReimbursed, isFalse);
    expect(mixed.reimbursementProgress, ReceiptComponentProgress.partial);
    expect(reimbursed.tracking.enabled, isFalse);
    expect(reimbursed.fullyReimbursed, isTrue);
    expect(reimbursed.reimbursementProgress, ReceiptComponentProgress.full);
  });

  test('cancel tracking retains actual refund and reimbursement progress', () {
    final tracked = ReceiptSourceState.fromCanonicalPublicBill({
      ...sourceVector('partly_settled'),
      'payload': {
        ...sourceVector('partly_settled')['payload'] as Map,
        'reimbursement_tracking': true,
      },
    });
    final cancelled = tracked.withTracking(
      const ReimbursementTracking.explicit(false),
    );
    expect(tracked.tracking.enabled, isTrue);
    expect(cancelled.tracking.isPresent, isTrue);
    expect(cancelled.tracking.enabled, isFalse);
    expect(cancelled.summary, same(tracked.summary));
    expect(cancelled.refundSourceMinor, BigInt.from(3000));
    expect(cancelled.reimbursementSourceMinor, BigInt.from(2000));
    expect(cancelled.remainingAllocatableMinor, BigInt.from(5000));
    expect(cancelled.refundProgress, ReceiptComponentProgress.partial);
    expect(cancelled.reimbursementProgress, ReceiptComponentProgress.partial);
    expect(cancelled.settlementProgress, ReceiptSettlementProgress.partial);
  });

  for (final remaining in ['0', '10000']) {
    test('legacy remaining $remaining does not establish either component', () {
      final actual = ReceiptSourceState.fromCanonicalPublicBill(
        publicSource(remaining: remaining, includeSummary: false),
      );
      expect(actual.refundSourceMinor, isNull);
      expect(actual.reimbursementSourceMinor, isNull);
      expect(actual.fullyReimbursed, isNull);
      expect(actual.settlementReason, isNull);
      expect(actual.refundProgress, ReceiptComponentProgress.unknown);
      expect(actual.reimbursementProgress, ReceiptComponentProgress.unknown);
      expect(
        actual.settlementProgress,
        remaining == '0'
            ? ReceiptSettlementProgress.settled
            : ReceiptSettlementProgress.unsettled,
      );
    });
  }

  test('missing remaining and summary keeps collective progress unknown', () {
    final source = publicSource(includeSummary: false)
      ..remove('remaining_allocatable_minor');
    final actual = ReceiptSourceState.fromCanonicalPublicBill(source);
    expect(actual.remainingAllocatableMinor, isNull);
    expect(actual.allocatedSourceMinor, isNull);
    expect(actual.settlementProgress, ReceiptSettlementProgress.unknown);
    expect(actual.breakdownKnown, isFalse);
  });

  test('legacy explicit null remaining keeps all receipt progress unknown', () {
    final source = publicSource(includeSummary: false)
      ..['remaining_allocatable_minor'] = null;
    final actual = ReceiptSourceState.fromCanonicalPublicBill(source);
    expect(actual.remainingAllocatableMinor, isNull);
    expect(actual.allocatedSourceMinor, isNull);
    expect(actual.refundSourceMinor, isNull);
    expect(actual.reimbursementSourceMinor, isNull);
    expect(actual.fullyReimbursed, isNull);
    expect(actual.settlementProgress, ReceiptSettlementProgress.unknown);
    expect(actual.refundProgress, ReceiptComponentProgress.unknown);
    expect(actual.reimbursementProgress, ReceiptComponentProgress.unknown);
    expect(actual.breakdownKnown, isFalse);
  });

  test(
    'summary without trusted remaining and explicit null remaining are rejected',
    () {
      final missing = sourceVector('partly_settled')
        ..remove('remaining_allocatable_minor');
      final explicitNull = sourceVector('partly_settled')
        ..['remaining_allocatable_minor'] = null;
      expect(
        () => ReceiptSourceState.fromCanonicalPublicBill(missing),
        receiptError('receipt.invalid_source'),
      );
      expect(
        () => ReceiptSourceState.fromCanonicalPublicBill(explicitNull),
        receiptError('receipt.invalid_source'),
      );
    },
  );

  test(
    'private finance and visible receipt lists cannot fill a missing summary',
    () {
      final source = publicSource(includeSummary: false)
        ..['private_finance'] = {
          'refund_source_minor': '5000',
          'reimbursement_source_minor': '0',
        }
        ..['visible_receipts'] = [
          {'bill_type': 'refund', 'source_amount_minor': '5000'},
        ];
      final actual = ReceiptSourceState.fromCanonicalPublicBill(source);
      expect(actual.breakdownKnown, isFalse);
      expect(actual.refundSourceMinor, isNull);
      expect(actual.reimbursementSourceMinor, isNull);
      expect(actual.allocatedSourceMinor, BigInt.from(5000));
      expect(
        () => ReceiptSourceState.fromCanonicalPublicBill({
          ...source,
          'projection_kind': 'bill_private_finance',
        }),
        receiptError('receipt.invalid_source'),
      );
    },
  );

  test('zero negative and out-of-range source paid are rejected', () {
    for (final paid in ['0', '-1', '9223372036854775808']) {
      expect(
        () => ReceiptSourceState.fromCanonicalPublicBill(
          publicSource(paid: paid, remaining: '0', includeSummary: false),
        ),
        receiptError('receipt.invalid_source'),
      );
    }
  });

  test(
    'summary accepts int64 maximum exactly and rejects aggregate overflow',
    () {
      final actual = ReceiptSourceState.fromCanonicalPublicBill(
        publicSource(
          paid: '9223372036854775807',
          remaining: '0',
          summary: {
            'refund_source_minor': '9223372036854775807',
            'reimbursement_source_minor': '0',
            'remaining_source_minor': '0',
            'settlement_reason': 'refunded',
          },
        ),
      );
      expect(actual.refundSourceMinor, int64Max);
      expect(actual.allocatedSourceMinor, int64Max);
      expect(actual.fullyReimbursed, isFalse);
      expect(
        () => ReceiptSourceState.fromCanonicalPublicBill(
          publicSource(
            paid: '9223372036854775807',
            remaining: '0',
            summary: {
              'refund_source_minor': '9223372036854775807',
              'reimbursement_source_minor': '9223372036854775807',
              'remaining_source_minor': '0',
              'settlement_reason': 'mixed',
            },
          ),
        ),
        receiptError('receipt.invalid_summary'),
      );
    },
  );

  test(
    'amounts above JavaScript safe integer retain exact source difference',
    () {
      final actual = ReceiptSourceState.fromCanonicalPublicBill(
        publicSource(
          paid: '9007199254740993',
          remaining: '9007199254740992',
          summary: {
            'refund_source_minor': '1',
            'reimbursement_source_minor': '0',
            'remaining_source_minor': '9007199254740992',
            'settlement_reason': 'open',
          },
        ),
      );
      expect(actual.paid.minor.toString(), '9007199254740993');
      expect(actual.remainingAllocatableMinor.toString(), '9007199254740992');
      expect(actual.allocatedSourceMinor, BigInt.one);
      expect(actual.refundSourceMinor, BigInt.one);
    },
  );

  test('remaining above paid and incomplete summaries are rejected', () {
    expect(
      () => ReceiptSourceState.fromCanonicalPublicBill(
        publicSource(remaining: '10001', includeSummary: false),
      ),
      receiptError('receipt.invalid_source'),
    );
    final source = sourceVector('partly_settled');
    (source['source_summary'] as Map).remove('settlement_reason');
    expect(
      () => ReceiptSourceState.fromCanonicalPublicBill(source),
      receiptError('receipt.invalid_summary'),
    );
  });

  test(
    'tracking metadata cannot silently accept a malformed or nonexpense patch',
    () {
      expect(
        () => ReimbursementTracking.fromPayload({}),
        receiptError('receipt.invalid_tracking'),
      );
      expect(
        () => ReimbursementTracking.afterMetadataPatch(
          beforePayload: {'bill_type': 'expense'},
          patch: {'reimbursement_tracking': false},
          afterBillType: 'income',
        ),
        receiptError('receipt.invalid_tracking'),
      );
    },
  );
}
