import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../sync/snapshot_protocol.dart';
import 'receipt_read_repository.dart';

enum ReceiptPreviewKind { refund, reimbursement }

/// The caller pairs an actual read with the lease/query used to obtain it.
/// This pure DTO cannot prove that provenance or authorize a later write.
final class ReceiptPreviewSelection {
  const ReceiptPreviewSelection({
    required this.lease,
    required this.query,
    required this.read,
    required this.sourceMoney,
    required this.receiptMoney,
    this.rate,
  });

  final ReceiptReadLease lease;
  final ReceiptSourceQuery query;
  final ReceiptSourceRead read;
  final Money sourceMoney, receiptMoney;
  final String? rate;
}

/// An immutable observation to compare with fresh reads at confirmation time.
/// Reusing a matching value alone does not establish current authorization.
final class ReceiptPreviewSourceBinding {
  const ReceiptPreviewSourceBinding._({
    required this.spaceId,
    required this.instanceId,
    required this.userId,
    required this.clientId,
    required this.epoch,
    required this.sourceId,
    required this.scopeId,
    required this.entityRevision,
    required this.permissionVersion,
    required this.role,
    required this.checkpoint,
    required this.remainingBefore,
    required this.remainingAfter,
  });

  final String spaceId, instanceId, userId, clientId, epoch;
  final String sourceId, scopeId, entityRevision, permissionVersion, role;
  final ReceiptScopeCheckpoint checkpoint;
  final Money remainingBefore, remainingAfter;

  /// A future confirmation adapter must reread under its current lease first.
  bool matchesCurrentRead(
    ReceiptReadLease lease,
    ReceiptSourceQuery query,
    ReceiptSourceRead read,
  ) {
    final cut = read.canonical;
    return lease.isCurrent() &&
        read.disposition == ReceiptReadDisposition.ready &&
        cut != null &&
        lease.space.id == spaceId &&
        lease.space.serverInstanceId == instanceId &&
        lease.space.userId == userId &&
        lease.clientId == clientId &&
        lease.epoch == epoch &&
        query.sourceId == sourceId &&
        query.scopeId == scopeId &&
        cut.sourceId == sourceId &&
        cut.scopeId == scopeId &&
        cut.entityRevision == entityRevision &&
        cut.permissionVersion == permissionVersion &&
        cut.role == role &&
        cut.checkpoint.scopeId == checkpoint.scopeId &&
        cut.checkpoint.value == checkpoint.value &&
        cut.state.paid.currency == remainingBefore.currency &&
        cut.state.paid.currencyScale == remainingBefore.currencyScale &&
        cut.state.remainingAllocatableMinor == remainingBefore.minor;
  }
}

final class ReceiptPreviewAllocation {
  const ReceiptPreviewAllocation._({
    required this.source,
    required this.sourceMoney,
    required this.receiptMoney,
    required this.rate,
  });

  final ReceiptPreviewSourceBinding source;
  final Money sourceMoney, receiptMoney;
  final String? rate;

  /// The existing v1 allocation shape, with no new protocol fields/defaults.
  Map<String, Object?> toJson() => {
    'source_bill_id': source.sourceId,
    'source_amount_minor': sourceMoney.minor.toString(),
    'receipt_amount_minor': receiptMoney.minor.toString(),
    'rate': rate,
  };
}

/// Pure source-allocation preview: no network, SQL, outbox or balance mutation.
/// It accepts current ready reads only and preserves each source's own money.
/// A transaction adapter must obtain fresh reads and repeat these checks when
/// confirming; this model is neither an authorization token nor a write command.
final class ReceiptPreview {
  ReceiptPreview._({
    required this.kind,
    required this.receiptMoney,
    required this.incomeComponent,
    required List<ReceiptPreviewAllocation> allocations,
  }) : allocations = List.unmodifiable(allocations);

  factory ReceiptPreview.create({
    required ReceiptPreviewKind kind,
    required Money receiptMoney,
    required Money incomeComponent,
    required List<ReceiptPreviewSelection> selections,
  }) {
    _supported(receiptMoney);
    _supported(incomeComponent);
    _sameCurrency(receiptMoney, incomeComponent);
    if (receiptMoney.minor <= BigInt.zero) {
      throw const DomainError('money.must_be_positive');
    }
    if (incomeComponent.minor.isNegative ||
        kind == ReceiptPreviewKind.reimbursement &&
            incomeComponent.minor != BigInt.zero) {
      throw const DomainError('receipt.invalid_income');
    }
    // This source preview covers one or more links. Converting an entire
    // unlinked receipt into ordinary income belongs to the lifecycle command.
    if (selections.isEmpty || selections.length > 100) {
      throw const DomainError('receipt.invalid_allocations');
    }
    final reference = selections.first.lease;
    final ids = <String>{};
    final allocations = <ReceiptPreviewAllocation>[];
    var allocatedReceipt = incomeComponent;
    for (final selection in selections) {
      final lease = selection.lease, query = selection.query;
      if (!lease.isCurrent() ||
          !lease.space.verified ||
          lease.space.id != reference.space.id ||
          lease.clientId != reference.clientId ||
          lease.epoch != reference.epoch) {
        throw const DomainError('receipt.preview_identity_changed');
      }
      final cut = selection.read.canonical;
      if (selection.read.disposition != ReceiptReadDisposition.ready ||
          cut == null) {
        throw const DomainError('receipt.source_unavailable');
      }
      syncIdentifier(cut.sourceId);
      syncIdentifier(cut.scopeId);
      syncRevision(cut.entityRevision);
      syncRevision(cut.permissionVersion);
      syncRevision(cut.checkpoint.value);
      if (cut.sourceId != query.sourceId ||
          cut.scopeId != query.scopeId ||
          cut.checkpoint.scopeId != cut.scopeId ||
          BigInt.parse(cut.entityRevision) <= BigInt.zero ||
          !{'owner', 'editor'}.contains(cut.role)) {
        throw const DomainError('allocation.invalid_source');
      }
      if (!ids.add(cut.sourceId)) {
        throw const DomainError('allocation.invalid_source');
      }
      final sourceMoney = selection.sourceMoney;
      final receivedMoney = selection.receiptMoney;
      _supported(cut.state.paid);
      _supported(sourceMoney);
      _supported(receivedMoney);
      _sameCurrency(sourceMoney, cut.state.paid);
      _sameCurrency(receivedMoney, receiptMoney);
      if (sourceMoney.minor <= BigInt.zero ||
          receivedMoney.minor <= BigInt.zero) {
        throw const DomainError('money.must_be_positive');
      }
      final remaining = cut.state.remainingAllocatableMinor;
      if (remaining == null) {
        throw const DomainError('receipt.remaining_unknown');
      }
      if (sourceMoney.minor > remaining) {
        throw const DomainError('allocation.exceeds_remaining');
      }
      final rate = selection.rate;
      if (sourceMoney.currency == receiptMoney.currency) {
        if (sourceMoney.minor != receivedMoney.minor) {
          throw const DomainError('allocation.amount_mismatch');
        }
        // Preserve an explicitly supplied valid rate exactly; same-currency
        // allocation equality remains the authoritative existing v1 rule.
        if (rate != null) parseRate(rate);
      } else {
        if (rate == null) throw const DomainError('fx.rate_required');
        if (convertMoney(
              sourceMoney,
              rate,
              receiptMoney.currency,
              receiptMoney.currencyScale,
            ).minor !=
            receivedMoney.minor) {
          throw const DomainError('allocation.amount_mismatch');
        }
      }
      allocatedReceipt = allocatedReceipt.plus(receivedMoney);
      allocations.add(
        ReceiptPreviewAllocation._(
          source: ReceiptPreviewSourceBinding._(
            spaceId: lease.space.id,
            instanceId: lease.space.serverInstanceId,
            userId: lease.space.userId,
            clientId: lease.clientId,
            epoch: lease.epoch,
            sourceId: cut.sourceId,
            scopeId: cut.scopeId,
            entityRevision: cut.entityRevision,
            permissionVersion: cut.permissionVersion,
            role: cut.role,
            checkpoint: cut.checkpoint,
            remainingBefore: Money(
              sourceMoney.currency,
              sourceMoney.currencyScale,
              remaining,
            ),
            remainingAfter: Money(
              sourceMoney.currency,
              sourceMoney.currencyScale,
              checkedMinor(remaining - sourceMoney.minor),
            ),
          ),
          sourceMoney: sourceMoney,
          receiptMoney: receivedMoney,
          rate: rate,
        ),
      );
    }
    if (allocatedReceipt.minor != receiptMoney.minor) {
      throw const DomainError('allocation.amount_mismatch');
    }
    // Recheck a generation-changing closure before publishing any amounts.
    if (selections.any((selection) => !selection.lease.isCurrent())) {
      throw const DomainError('receipt.preview_identity_changed');
    }
    return ReceiptPreview._(
      kind: kind,
      receiptMoney: receiptMoney,
      incomeComponent: incomeComponent,
      allocations: allocations,
    );
  }

  final ReceiptPreviewKind kind;
  final Money receiptMoney, incomeComponent;
  final List<ReceiptPreviewAllocation> allocations;

  List<Map<String, Object?>> get allocationPayloads => [
    for (final allocation in allocations) allocation.toJson(),
  ];
}

void _sameCurrency(Money first, Money second) {
  if (first.currency != second.currency ||
      first.currencyScale != second.currencyScale) {
    throw const DomainError('money.currency_mismatch');
  }
}

void _supported(Money value) {
  if (currencyScales[value.currency] != value.currencyScale) {
    throw const DomainError('currency.unsupported');
  }
}
