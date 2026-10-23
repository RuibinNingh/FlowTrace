import '../../core/money/money.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../sync/snapshot_protocol.dart';
import 'receipt_read_repository.dart';

/// A local pagination position, never a proof of authorization.
final class ReceiptListCursor {
  ReceiptListCursor({required this.cutFingerprint, required this.afterDate, required this.afterId}) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(cutFingerprint)) {
      throw const FormatException('Invalid receipt cursor');
    }
    businessDate(afterDate);
    syncIdentifier(afterId);
  }
  final String cutFingerprint, afterDate, afterId;
}

final class ReceiptHistoryQuery {
  ReceiptHistoryQuery({required this.source, this.limit = 50, this.cursor}) {
    if (limit < 1 || limit > 100) throw ArgumentError('Receipt page requires 1–100 rows.');
  }
  final ReceiptSourceQuery source;
  final int limit;
  final ReceiptListCursor? cursor;
}

enum ReceiptTrackingFilter { allTracked, openOnly }

final class ReceiptTrackingQuery {
  ReceiptTrackingQuery({required this.scopeId, this.filter = ReceiptTrackingFilter.allTracked,
    this.limit = 50, this.cursor}) {
    syncIdentifier(scopeId);
    if (limit < 1 || limit > 100) throw ArgumentError('Receipt page requires 1–100 rows.');
  }
  final String scopeId;
  final ReceiptTrackingFilter filter;
  final int limit;
  final ReceiptListCursor? cursor;
}

enum ReceiptHistoryKind { refund, reimbursement }

/// Only a publicly visible, explicitly linked canonical receipt. No account,
/// private finance, hidden source IDs or inferred foreign counts are returned.
final class ReceiptHistoryItem {
  const ReceiptHistoryItem({required this.receiptId, required this.scopeId,
    required this.entityRevision, required this.authority, required this.kind,
    required this.businessDate, required this.businessTimezone, required this.occurredAt,
    required this.received, required this.allocatedSource, required this.allocatedReceipt,
    required this.rate, required this.incomeComponent, required this.fullReceiptConservationKnown});
  final String receiptId, scopeId, entityRevision, businessDate, businessTimezone;
  final String? occurredAt, rate;
  final ReceiptBookAuthority authority;
  final ReceiptHistoryKind kind;
  final Money received, allocatedSource, allocatedReceipt;
  final Money? incomeComponent;
  final bool fullReceiptConservationKnown;
}

final class ReceiptHistoryRead {
  ReceiptHistoryRead({required this.disposition, this.reason, this.source,
    List<ReceiptHistoryItem> items = const [], this.nextCursor}) : items = List.unmodifiable(items);
  final ReceiptReadDisposition disposition;
  final String? reason;
  final ReceiptSourceRead? source;
  final List<ReceiptHistoryItem> items;
  final ReceiptListCursor? nextCursor;
  bool get hasMore => nextCursor != null;
  /// Cross-book relations are redacted by the production public projection.
  /// Empty items never imply that the source has received no repayments.
  bool get visiblePublicOnly => true;
}

final class ReceiptTrackingItem {
  const ReceiptTrackingItem({required this.sourceId, required this.scopeId,
    required this.businessDate, required this.read});
  final String sourceId, scopeId, businessDate;
  /// Pending/conflicted sources carry no canonical amounts. Local tracking
  /// intent remains separate; it never changes cash, assets or confirmed R/E.
  final ReceiptSourceRead read;
}

final class ReceiptTrackingRead {
  ReceiptTrackingRead({required this.disposition, this.reason, this.authority,
    List<ReceiptTrackingItem> items = const [], this.nextCursor}) : items = List.unmodifiable(items);
  final ReceiptReadDisposition disposition;
  final String? reason;
  final ReceiptBookAuthority? authority;
  final List<ReceiptTrackingItem> items;
  final ReceiptListCursor? nextCursor;
  bool get hasMore => nextCursor != null;
}
