import '../../core/money/money.dart';

/// Display metadata only. Absence must remain distinct from an explicit false.
final class ReimbursementTracking {
  const ReimbursementTracking.absent() : isPresent = false, enabled = false;
  const ReimbursementTracking.explicit(this.enabled) : isPresent = true;

  factory ReimbursementTracking.fromPayload(Map payload) {
    if (payload['bill_type'] is! String) {
      throw const DomainError('receipt.invalid_tracking');
    }
    if (!payload.containsKey('reimbursement_tracking')) {
      return const ReimbursementTracking.absent();
    }
    final value = payload['reimbursement_tracking'];
    if (payload['bill_type'] != 'expense' || value is! bool) {
      throw const DomainError('receipt.invalid_tracking');
    }
    return ReimbursementTracking.explicit(value);
  }

  /// Preserves only this optional field, without applying or authorizing a write.
  /// The caller must separately prove that a requested type change is legal.
  factory ReimbursementTracking.afterMetadataPatch({
    required Map beforePayload,
    required Map patch,
    required String afterBillType,
  }) {
    final before = ReimbursementTracking.fromPayload(beforePayload);
    if (patch.containsKey('reimbursement_tracking')) {
      return ReimbursementTracking.fromPayload({
        'bill_type': afterBillType,
        'reimbursement_tracking': patch['reimbursement_tracking'],
      });
    }
    return afterBillType == 'expense' && beforePayload['bill_type'] == 'expense'
        ? before
        : const ReimbursementTracking.absent();
  }

  final bool isPresent;
  final bool enabled;

  Map<String, bool> toPayloadFields() => {
    if (isPresent) 'reimbursement_tracking': enabled,
  };
}

enum ReceiptSettlementReason { open, refunded, reimbursed, mixed }

enum ReceiptComponentProgress { unknown, none, partial, full }

enum ReceiptSettlementProgress { unknown, unsettled, partial, settled }

BigInt _nonnegative(Object? value, String code) {
  try {
    final amount = parseMinor(value);
    if (amount.isNegative) throw DomainError(code);
    return amount;
  } on DomainError {
    throw DomainError(code);
  }
}

/// Identifier-free, source-currency aggregate from one current public cut.
final class SourceReceiptSummary {
  const SourceReceiptSummary._(
    this.refundSourceMinor,
    this.reimbursementSourceMinor,
    this.remainingSourceMinor,
    this.settlementReason,
  );

  factory SourceReceiptSummary.fromJson(
    Object? value, {
    required BigInt paidMinor,
    required BigInt remainingAllocatableMinor,
  }) {
    const keys = {
      'refund_source_minor',
      'reimbursement_source_minor',
      'remaining_source_minor',
      'settlement_reason',
    };
    const code = 'receipt.invalid_summary';
    if (value is! Map ||
        value.length != keys.length ||
        !keys.containsAll(value.keys) ||
        paidMinor <= BigInt.zero ||
        paidMinor > int64Max ||
        remainingAllocatableMinor.isNegative ||
        remainingAllocatableMinor > int64Max) {
      throw const DomainError(code);
    }
    final refund = _nonnegative(value['refund_source_minor'], code);
    final reimbursement = _nonnegative(
      value['reimbursement_source_minor'],
      code,
    );
    final remaining = _nonnegative(value['remaining_source_minor'], code);
    final reason = switch (value['settlement_reason']) {
      'open' => ReceiptSettlementReason.open,
      'refunded' => ReceiptSettlementReason.refunded,
      'reimbursed' => ReceiptSettlementReason.reimbursed,
      'mixed' => ReceiptSettlementReason.mixed,
      _ => throw const DomainError(code),
    };
    final expectedReason = remaining > BigInt.zero
        ? ReceiptSettlementReason.open
        : reimbursement == BigInt.zero
        ? ReceiptSettlementReason.refunded
        : refund == BigInt.zero
        ? ReceiptSettlementReason.reimbursed
        : ReceiptSettlementReason.mixed;
    if (refund + reimbursement + remaining != paidMinor ||
        remaining != remainingAllocatableMinor ||
        reason != expectedReason) {
      throw const DomainError(code);
    }
    return SourceReceiptSummary._(refund, reimbursement, remaining, reason);
  }

  final BigInt refundSourceMinor;
  final BigInt reimbursementSourceMinor;
  final BigInt remainingSourceMinor;
  final ReceiptSettlementReason settlementReason;

  Map<String, String> toJson() => {
    'refund_source_minor': refundSourceMinor.toString(),
    'reimbursement_source_minor': reimbursementSourceMinor.toString(),
    'remaining_source_minor': remainingSourceMinor.toString(),
    'settlement_reason': settlementReason.name,
  };
}

/// Pure read model, not an authorization or freshness proof.
///
/// The caller must provide an already authorized, current canonical bill_public
/// cut (including its source revision). Parsing a shape does not establish that
/// cut. Private finance and hidden allocation lists are never used as evidence.
final class ReceiptSourceState {
  const ReceiptSourceState._({
    required this.paid,
    required this.tracking,
    required this.remainingAllocatableMinor,
    required this.summary,
  });

  factory ReceiptSourceState.fromCanonicalPublicBill(Object? value) {
    const code = 'receipt.invalid_source';
    if (value is! Map ||
        value['projection_kind'] != 'bill_public' ||
        value['payload'] is! Map) {
      throw const DomainError(code);
    }
    final payload = value['payload'] as Map;
    if (payload['bill_type'] != 'expense') throw const DomainError(code);
    late final Money paid;
    try {
      paid = Money.fromJson(payload['money'], positive: true);
    } on DomainError {
      throw const DomainError(code);
    }
    final tracking = ReimbursementTracking.fromPayload(payload);
    // Legacy public cuts may explicitly carry null. It proves no remaining
    // amount; a present summary still requires a concrete matching value.
    final rawRemaining = value['remaining_allocatable_minor'];
    final remaining = rawRemaining == null
        ? null
        : _nonnegative(rawRemaining, code);
    if (remaining != null && remaining > paid.minor) {
      throw const DomainError(code);
    }
    SourceReceiptSummary? summary;
    if (value.containsKey('source_summary')) {
      if (remaining == null) throw const DomainError(code);
      summary = SourceReceiptSummary.fromJson(
        value['source_summary'],
        paidMinor: paid.minor,
        remainingAllocatableMinor: remaining,
      );
    }
    return ReceiptSourceState._(
      paid: paid,
      tracking: tracking,
      remainingAllocatableMinor: remaining,
      summary: summary,
    );
  }

  final Money paid;
  final ReimbursementTracking tracking;
  final BigInt? remainingAllocatableMinor;
  final SourceReceiptSummary? summary;

  bool get breakdownKnown => summary != null;
  BigInt? get refundSourceMinor => summary?.refundSourceMinor;
  BigInt? get reimbursementSourceMinor => summary?.reimbursementSourceMinor;
  ReceiptSettlementReason? get settlementReason => summary?.settlementReason;
  BigInt? get allocatedSourceMinor => remainingAllocatableMinor == null
      ? null
      : paid.minor - remainingAllocatableMinor!;
  bool? get fullyReimbursed =>
      summary == null ? null : reimbursementSourceMinor == paid.minor;

  ReceiptComponentProgress _component(BigInt? value) => value == null
      ? ReceiptComponentProgress.unknown
      : value == BigInt.zero
      ? ReceiptComponentProgress.none
      : value == paid.minor
      ? ReceiptComponentProgress.full
      : ReceiptComponentProgress.partial;

  ReceiptComponentProgress get refundProgress => _component(refundSourceMinor);
  ReceiptComponentProgress get reimbursementProgress =>
      _component(reimbursementSourceMinor);
  ReceiptSettlementProgress get settlementProgress =>
      remainingAllocatableMinor == null
      ? ReceiptSettlementProgress.unknown
      : remainingAllocatableMinor == BigInt.zero
      ? ReceiptSettlementProgress.settled
      : remainingAllocatableMinor == paid.minor
      ? ReceiptSettlementProgress.unsettled
      : ReceiptSettlementProgress.partial;

  /// Changes presentation metadata only; actual receipt history is retained.
  ReceiptSourceState withTracking(ReimbursementTracking value) =>
      ReceiptSourceState._(
        paid: paid,
        tracking: value,
        remainingAllocatableMinor: remainingAllocatableMinor,
        summary: summary,
      );
}
