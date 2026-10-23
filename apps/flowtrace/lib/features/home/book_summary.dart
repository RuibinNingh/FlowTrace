import '../../core/money/money.dart';
import '../../data/ledger/ledger_models.dart';

final class BookSummary {
  const BookSummary(this.income, this.expense, this.issue);
  final Money? income, expense;
  final String? issue;

  static BookSummary calculate(
    Iterable<LedgerEntity> bills,
    String currency,
    int scale,
  ) {
    var income = BigInt.zero;
    var expense = BigInt.zero;
    BigInt report(Map<String, Object?> payload) {
      final source = Money.fromJson(payload['money']);
      if (source.currency == currency && source.currencyScale == scale) {
        return source.minor;
      }
      final converted = payload['reporting'];
      if (converted is! Map ||
          converted['report_currency'] != currency ||
          converted['report_scale'] != scale) {
        throw const DomainError('fx.report_unavailable');
      }
      return parseMinor(converted['report_amount_minor']);
    }

    try {
      for (final bill in bills) {
        final payload = bill.payload;
        final flags = payload['flags'] as Map? ?? {};
        final type = payload['bill_type'];
        // Receipt allocation is introduced with the reporting projection. Until
        // then, a historical receipt must not produce an apparently exact total.
        if (type == 'refund' || type == 'reimbursement') {
          return const BookSummary(null, null, '本期含退款或报销，汇总待关联分配投影核对。');
        }
        if (flags['exclude_from_statistics'] != true) {
          if (type == 'income') income += report(payload);
          if (type == 'expense') expense += report(payload);
        }
        final fee = payload['fee'];
        if (fee is Map<String, Object?> &&
            (fee['flags'] as Map?)?['exclude_from_statistics'] != true) {
          expense += report(fee);
        }
      }
      return BookSummary(
        Money(currency, scale, income),
        Money(currency, scale, expense),
        null,
      );
    } on DomainError {
      return const BookSummary(null, null, '缺少本期折算资料，汇总暂不可用。');
    }
  }
}
