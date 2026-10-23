import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/config/data_space.dart';
import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../../core/network/api_failure.dart';
import '../../domain/assets/asset_config.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../local/app_database.dart';
import '../local/local_repository.dart';
import '../sync/snapshot_protocol.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_store.dart';
import 'asset_config_store.dart';

enum AssetReadKind { entries, history, creditCalendar }

/// Queries identify an authorized scope explicitly. Account ownership is never
/// inferred from a bill's public account links or a previously cached result.
final class AssetReadQuery {
  AssetReadQuery.entries({
    required this.scopeId,
    required String accountId,
    required this.startDate,
    required this.endDateExclusive,
    this.offset = 0,
    this.limit = 100,
  }) : kind = AssetReadKind.entries,
       accountId = assetId(accountId),
       baseCurrency = null,
       valuationPolicy = null {
    _validate();
  }
  AssetReadQuery.history({
    required this.scopeId,
    required this.startDate,
    required this.endDateExclusive,
    this.baseCurrency,
    this.valuationPolicy,
  }) : kind = AssetReadKind.history,
       accountId = null,
       offset = 0,
       limit = 100 {
    _validate();
  }
  AssetReadQuery.creditCalendar({
    required this.scopeId,
    required String accountId,
    required this.startDate,
    required this.endDateExclusive,
  }) : kind = AssetReadKind.creditCalendar,
       accountId = assetId(accountId),
       offset = 0,
       limit = 100,
       baseCurrency = null,
       valuationPolicy = null {
    _validate();
  }
  final AssetReadKind kind;
  final String scopeId, startDate, endDateExclusive;
  final String? accountId, baseCurrency, valuationPolicy;
  final int offset, limit;
  void _validate() {
    assetId(scopeId);
    final days = businessDate(
      endDateExclusive,
    ).difference(businessDate(startDate)).inDays;
    if (days < 1 ||
        days > 366 ||
        offset < 0 ||
        offset > 50000 ||
        limit < 1 ||
        limit > 200 ||
        baseCurrency != null && !currencyScales.containsKey(baseCurrency) ||
        valuationPolicy != null &&
            !{'exact_date', 'latest_on_or_before'}.contains(valuationPolicy)) {
      throw const DomainError('assets.invalid_query');
    }
  }

  Map<String, Object?> get identity => {
    'kind': kind.name,
    'scope_id': scopeId,
    'account_id': accountId,
    'start_date': startDate,
    'end_date_exclusive': endDateExclusive,
    'offset': offset,
    'limit': limit,
    'base_currency': baseCurrency,
    'valuation_policy': valuationPolicy,
  };
  String get id => syncContentHash(identity);
  String get path => Uri(
    path: switch (kind) {
      AssetReadKind.entries => '/assets/accounts/$accountId/entries',
      AssetReadKind.history => '/assets/history',
      AssetReadKind.creditCalendar =>
        '/assets/accounts/$accountId/credit-calendar',
    },
    queryParameters: {
      'start_date': startDate,
      'end_date_exclusive': endDateExclusive,
      if (kind == AssetReadKind.entries) ...{
        'offset': '$offset',
        'limit': '$limit',
      },
      if (kind == AssetReadKind.history) ...{
        'scope_id': scopeId,
        'base_currency': ?baseCurrency,
        'valuation_policy': ?valuationPolicy,
      },
    },
  ).toString();
}

final class AssetReadEnvelope {
  AssetReadEnvelope._(Map<String, Object?> row)
    : instanceId = assetId(row['instance_id']),
      epoch = assetId(row['sync_epoch']),
      scopeId = assetId(row['scope_id']),
      scopeRevision = assetRevision(row['scope_revision']),
      configRevision = assetRevision(row['config_revision']);
  final String instanceId, epoch, scopeId, scopeRevision, configRevision;
}

sealed class AssetReadData {
  AssetReadData(Map<String, Object?> row) : envelope = AssetReadEnvelope._(row);
  final AssetReadEnvelope envelope;
}

const _envelopeKeys = {
  'instance_id',
  'sync_epoch',
  'scope_id',
  'scope_revision',
  'config_revision',
};
const _billKinds = {
  'expense',
  'income',
  'transfer',
  'credit_repayment',
  'loan_borrow',
  'loan_lend',
  'loan_collect',
  'loan_repay',
  'balance_adjustment',
  'refund',
  'reimbursement',
};

String _date(Object? raw) => isoBusinessDate(businessDate(raw));
bool _boolean(Object? raw) {
  if (raw is! bool) throw const DomainError('assets.invalid_data');
  return raw;
}

int _integer(Object? raw, {int min = 0, int max = 50000}) {
  if (raw is! int || raw < min || raw > max) {
    throw const DomainError('assets.invalid_data');
  }
  return raw;
}

List<Object?> _list(Object? raw, {int max = 200}) {
  if (raw is! List || raw.length > max) {
    throw const DomainError('assets.invalid_data');
  }
  return raw;
}

List<String> _ids(Object? raw, int max) {
  final result = _list(raw, max: max).map(assetId).toList();
  if (result.toSet().length != result.length) {
    throw const DomainError('assets.invalid_data');
  }
  return List.unmodifiable(result);
}

List<String> _issues(Object? raw) {
  final result = _list(
    raw,
    max: 100,
  ).map((value) => assetText(value, max: 100)).toList();
  if (result.any(
    (value) => !RegExp(r'^[a-z][a-z0-9_.]{0,99}$').hasMatch(value),
  )) {
    throw const DomainError('assets.invalid_data');
  }
  return List.unmodifiable(result);
}

(String, int) _currency(
  Map<String, Object?> row,
  String codeKey,
  String scaleKey,
) {
  final code = assetText(row[codeKey], max: 3),
      scale = validateScale(row[scaleKey]);
  if (currencyScales[code] != scale) {
    throw const DomainError('currency.unsupported');
  }
  return (code, scale);
}

Money _money(Object? raw, String currency, int scale) {
  final result = Money.fromJson(raw);
  if (result.currency != currency || result.currencyScale != scale) {
    throw const DomainError('money.currency_mismatch');
  }
  return result;
}

String? _note(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || raw.length > 2000 || raw.contains('\u0000')) {
    throw const DomainError('assets.invalid_data');
  }
  return raw;
}

BigInt _nonnegative(Object? raw) {
  final result = parseMinor(raw);
  if (result.isNegative) throw const DomainError('assets.invalid_data');
  return result;
}

final class AssetEntry {
  AssetEntry._(Map<String, Object?> row, String currency, int scale)
    : id = assetId(row['entry_id']),
      businessDate = _date(row['business_date']),
      component = assetText(row['component']),
      money = _money(row['money'], currency, scale),
      detailAvailable = _boolean(row['detail_available']),
      billId = row['bill_id'] == null ? null : assetId(row['bill_id']),
      bookId = row['book_id'] == null ? null : assetId(row['book_id']),
      billType = row['bill_type'] == null ? null : assetText(row['bill_type']),
      note = _note(row['note']),
      categoryId = row['category_id'] == null
          ? null
          : assetId(row['category_id']),
      tagIds = _ids(row['tag_ids'], 100),
      attachmentIds = _ids(row['attachment_ids'], 20) {
    if (!{'principal', 'fee'}.contains(component) ||
        detailAvailable &&
            (billId == null ||
                bookId == null ||
                !_billKinds.contains(billType) ||
                note == null) ||
        !detailAvailable &&
            (billId != null ||
                bookId != null ||
                billType != null ||
                note != null ||
                categoryId != null ||
                tagIds.isNotEmpty ||
                attachmentIds.isNotEmpty)) {
      throw const DomainError('assets.invalid_data');
    }
  }
  factory AssetEntry.fromJson(Object? raw, String currency, int scale) =>
      AssetEntry._(
        assetObject(raw, {
          'entry_id',
          'business_date',
          'component',
          'money',
          'detail_available',
          'bill_id',
          'book_id',
          'bill_type',
          'note',
          'category_id',
          'tag_ids',
          'attachment_ids',
        }),
        currency,
        scale,
      );
  final String id, businessDate, component;
  final Money money;
  final bool detailAvailable;
  final String? billId, bookId, billType, note, categoryId;
  final List<String> tagIds, attachmentIds;
}

final class AssetAccountEntries extends AssetReadData {
  AssetAccountEntries._(Map<String, Object?> row, AssetReadQuery query)
    : super(row) {
    accountId = assetId(row['account_id']);
    final (code, precision) = _currency(row, 'currency', 'currency_scale');
    currency = code;
    scale = precision;
    startDate = _date(row['start_date']);
    endDateExclusive = _date(row['end_date_exclusive']);
    totalCount = _integer(row['total_count']);
    offset = _integer(row['offset']);
    limit = _integer(row['limit'], min: 1, max: 200);
    entries = List.unmodifiable(
      _list(
        row['entries'],
      ).map((raw) => AssetEntry.fromJson(raw, currency, scale)),
    );
    openingBalance = row['opening_balance'] == null
        ? null
        : _money(row['opening_balance'], currency, scale);
    closingBalance = row['closing_balance'] == null
        ? null
        : _money(row['closing_balance'], currency, scale);
    issues = _issues(row['issues']);
    if (accountId != query.accountId ||
        startDate != query.startDate ||
        endDateExclusive != query.endDateExclusive ||
        offset != query.offset ||
        limit != query.limit ||
        entries.length != (totalCount - offset).clamp(0, limit) ||
        entries.map((entry) => entry.id).toSet().length != entries.length ||
        entries.any(
          (entry) =>
              entry.businessDate.compareTo(startDate) < 0 ||
              entry.businessDate.compareTo(endDateExclusive) >= 0,
        )) {
      throw const DomainError('assets.invalid_data');
    }
    if (offset == 0 &&
        totalCount == entries.length &&
        openingBalance != null &&
        closingBalance != null &&
        checkedMinor(
              openingBalance!.minor +
                  entries.fold(
                    BigInt.zero,
                    (sum, entry) => sum + entry.money.minor,
                  ),
            ) !=
            closingBalance!.minor) {
      throw const DomainError('asset.balance_unavailable');
    }
  }
  factory AssetAccountEntries.fromJson(Object? raw, AssetReadQuery query) =>
      AssetAccountEntries._(
        assetObject(raw, {
          ..._envelopeKeys,
          'account_id',
          'currency',
          'currency_scale',
          'start_date',
          'end_date_exclusive',
          'total_count',
          'offset',
          'limit',
          'entries',
          'opening_balance',
          'closing_balance',
          'issues',
        }),
        query,
      );
  late final String accountId, currency, startDate, endDateExclusive;
  late final int scale, totalCount, offset, limit;
  late final List<AssetEntry> entries;
  late final Money? openingBalance, closingBalance;
  late final List<String> issues;
  bool get hasNext => offset + entries.length < totalCount;
}

final class AssetReadTotals {
  AssetReadTotals._(Map<String, Object?> row, String currency, int scale)
    : assets = Money(currency, scale, _nonnegative(row['assets_minor'])),
      liabilities = Money(
        currency,
        scale,
        _nonnegative(row['liabilities_minor']),
      ),
      net = Money(currency, scale, parseMinor(row['net_minor'])),
      borrowed = Money(currency, scale, _nonnegative(row['borrowed_minor'])),
      lent = Money(currency, scale, _nonnegative(row['lent_minor'])) {
    if (assets.minor - liabilities.minor != net.minor ||
        borrowed.minor > liabilities.minor ||
        lent.minor > assets.minor) {
      throw const DomainError('assets.invalid_data');
    }
  }
  factory AssetReadTotals.fromJson(Object? raw, String currency, int scale) =>
      AssetReadTotals._(
        assetObject(raw, {
          'assets_minor',
          'liabilities_minor',
          'net_minor',
          'borrowed_minor',
          'lent_minor',
        }),
        currency,
        scale,
      );
  final Money assets, liabilities, net, borrowed, lent;
}

final class AssetHistoryPoint {
  AssetHistoryPoint._(Map<String, Object?> row, String currency, int scale)
    : date = _date(row['date']),
      available = _boolean(row['available']),
      issues = _issues(row['issues']),
      totals = row['totals'] == null
          ? null
          : AssetReadTotals.fromJson(row['totals'], currency, scale) {
    if (available != (totals != null) ||
        available && issues.isNotEmpty ||
        !available && issues.isEmpty) {
      throw const DomainError('assets.invalid_data');
    }
  }
  factory AssetHistoryPoint.fromJson(Object? raw, String currency, int scale) =>
      AssetHistoryPoint._(
        assetObject(raw, {'date', 'available', 'issues', 'totals'}),
        currency,
        scale,
      );
  final String date;
  final bool available;
  final List<String> issues;
  final AssetReadTotals? totals;
}

final class AssetHistory extends AssetReadData {
  AssetHistory._(Map<String, Object?> row, AssetReadQuery query) : super(row) {
    final (code, precision) = _currency(row, 'base_currency', 'base_scale');
    currency = code;
    scale = precision;
    valuationPolicy = assetText(row['valuation_policy']);
    startDate = _date(row['start_date']);
    endDateExclusive = _date(row['end_date_exclusive']);
    points = List.unmodifiable(
      _list(
        row['points'],
        max: 366,
      ).map((raw) => AssetHistoryPoint.fromJson(raw, currency, scale)),
    );
    final first = businessDate(startDate),
        stop = businessDate(endDateExclusive);
    if (startDate != query.startDate ||
        endDateExclusive != query.endDateExclusive ||
        query.baseCurrency != null && currency != query.baseCurrency ||
        query.valuationPolicy != null &&
            valuationPolicy != query.valuationPolicy ||
        !{'exact_date', 'latest_on_or_before'}.contains(valuationPolicy) ||
        points.length != stop.difference(first).inDays) {
      throw const DomainError('assets.invalid_data');
    }
    for (var i = 0; i < points.length; i++) {
      if (points[i].date != isoBusinessDate(first.add(Duration(days: i)))) {
        throw const DomainError('assets.invalid_data');
      }
    }
  }
  factory AssetHistory.fromJson(Object? raw, AssetReadQuery query) =>
      AssetHistory._(
        assetObject(raw, {
          ..._envelopeKeys,
          'base_currency',
          'base_scale',
          'valuation_policy',
          'start_date',
          'end_date_exclusive',
          'points',
        }),
        query,
      );
  late final String currency, valuationPolicy, startDate, endDateExclusive;
  late final int scale;
  late final List<AssetHistoryPoint> points;
}

final class AssetCreditCycle {
  AssetCreditCycle._(Map<String, Object?> row, String currency, int scale)
    : startDate = _date(row['start_date']),
      endDateExclusive = _date(row['end_date_exclusive']),
      statementDate = _date(row['statement_date']),
      dueDate = _date(row['due_date']),
      charges = Money(currency, scale, _nonnegative(row['charges_minor'])),
      statementDue = row['statement_due_minor'] == null
          ? null
          : Money(currency, scale, _nonnegative(row['statement_due_minor'])),
      remainingDue = row['remaining_due_minor'] == null
          ? null
          : Money(currency, scale, _nonnegative(row['remaining_due_minor'])),
      maxInterestFreeDays = _integer(row['max_interest_free_days'], max: 200),
      minInterestFreeDays = _integer(row['min_interest_free_days'], max: 200) {
    if (startDate.compareTo(endDateExclusive) >= 0 ||
        dueDate.compareTo(statementDate) <= 0 ||
        maxInterestFreeDays < minInterestFreeDays ||
        businessDate(dueDate).difference(businessDate(startDate)).inDays !=
            maxInterestFreeDays ||
        businessDate(dueDate)
                .difference(
                  businessDate(
                    endDateExclusive,
                  ).subtract(const Duration(days: 1)),
                )
                .inDays !=
            minInterestFreeDays ||
        (statementDue == null) != (remainingDue == null)) {
      throw const DomainError('assets.invalid_data');
    }
  }
  factory AssetCreditCycle.fromJson(Object? raw, String currency, int scale) =>
      AssetCreditCycle._(
        assetObject(raw, {
          'start_date',
          'end_date_exclusive',
          'statement_date',
          'due_date',
          'charges_minor',
          'statement_due_minor',
          'remaining_due_minor',
          'max_interest_free_days',
          'min_interest_free_days',
        }),
        currency,
        scale,
      );
  final String startDate, endDateExclusive, statementDate, dueDate;
  final Money charges;
  final Money? statementDue, remainingDue;
  final int maxInterestFreeDays, minInterestFreeDays;
}

final class AssetCreditCalendar extends AssetReadData {
  AssetCreditCalendar._(Map<String, Object?> row, AssetReadQuery query)
    : super(row) {
    accountId = assetId(row['account_id']);
    final (code, precision) = _currency(row, 'currency', 'currency_scale');
    currency = code;
    scale = precision;
    Money amount(String field) =>
        Money(currency, scale, _nonnegative(row[field]));
    totalDebt = amount('total_debt_minor');
    overpayment = amount('overpayment_minor');
    availableCredit = row['available_credit_minor'] == null
        ? null
        : amount('available_credit_minor');
    overLimit = row['over_limit_minor'] == null
        ? null
        : amount('over_limit_minor');
    openingCarry = row['opening_carry_minor'] == null
        ? null
        : amount('opening_carry_minor');
    repaymentAvailable = _boolean(row['repayment_available']);
    issues = _issues(row['issues']);
    cycles = List.unmodifiable(
      _list(
        row['cycles'],
        max: 13,
      ).map((raw) => AssetCreditCycle.fromJson(raw, currency, scale)),
    );
    if (accountId != query.accountId ||
        totalDebt.minor > BigInt.zero && overpayment.minor > BigInt.zero ||
        (availableCredit == null) != (overLimit == null) ||
        repaymentAvailable &&
            (openingCarry == null ||
                cycles.any((cycle) => cycle.statementDue == null)) ||
        cycles.map((cycle) => cycle.statementDate).toSet().length !=
            cycles.length ||
        cycles.any(
          (cycle) =>
              cycle.statementDate.compareTo(query.startDate) < 0 ||
              cycle.statementDate.compareTo(query.endDateExclusive) >= 0,
        )) {
      throw const DomainError('assets.invalid_data');
    }
  }
  factory AssetCreditCalendar.fromJson(Object? raw, AssetReadQuery query) =>
      AssetCreditCalendar._(
        assetObject(raw, {
          ..._envelopeKeys,
          'account_id',
          'currency',
          'currency_scale',
          'total_debt_minor',
          'overpayment_minor',
          'available_credit_minor',
          'over_limit_minor',
          'opening_carry_minor',
          'repayment_available',
          'issues',
          'cycles',
        }),
        query,
      );
  late final String accountId, currency;
  late final int scale;
  late final Money totalDebt, overpayment;
  late final Money? availableCredit, overLimit, openingCarry;
  late final bool repaymentAvailable;
  late final List<String> issues;
  late final List<AssetCreditCycle> cycles;
}

final class AssetReadSnapshot {
  const AssetReadSnapshot({
    required this.data,
    required this.confirmedAt,
    required this.fromCache,
    required this.evidence,
  });
  final AssetReadData data;
  final DateTime confirmedAt;
  final bool fromCache;
  final String evidence;
}

final class _ReadContext {
  const _ReadContext(
    this.state,
    this.permissions,
    this.nonce,
    this.configRevision,
  );
  final SpaceSyncState state;
  final Map<String, String> permissions;
  final String nonce, configRevision;
}

/// Authorized server projections only. No private financial links are expanded
/// into book details; cache reads require an exact, currently confirmed cut.
final class AssetReadRepository {
  AssetReadRepository(
    this.repository, {
    required this.refreshPermissions,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final LocalRepository repository;
  final Future<void> Function(SyncLease lease) refreshPermissions;
  final DateTime Function() now;
  AppDatabase get database => repository.database;
  static String cachePrefix(DataSpace space) => 'assets.read.v1.${space.id}.';
  static String invalidationKey(DataSpace space) =>
      'assets.read.invalidate.v1.${space.id}';
  static const maxCachedQueries = 128;
  static const maxCachedBytes = 4 * 1024 * 1024;

  Future<_ReadContext> _context(
    DataSpace space,
    AssetReadQuery query, {
    SyncLease? lease,
  }) async {
    final store = AssetConfigStore(repository);
    final state = await store.requireState(space, lease);
    final permissionsRaw = await repository.readSetting(
      'sync.scopes.${space.id}',
    );
    final permissions = permissionsRaw == null
        ? <String, String>{}
        : syncVector(jsonDecode(permissionsRaw));
    final revoked = (jsonDecode(state.revokedScopesJson) as List)
        .cast<String>();
    if (!permissions.containsKey(space.userId) ||
        !permissions.containsKey(query.scopeId) ||
        revoked.contains(query.scopeId)) {
      throw const DomainError('assets.scope_unavailable');
    }
    if (query.accountId != null) {
      final account =
          await (database.select(database.localEntities)..where(
                (row) =>
                    row.spaceId.equals(space.id) &
                    row.entityType.equals('account') &
                    row.entityId.equals(query.accountId!) &
                    row.deleted.equals(false),
              ))
              .getSingleOrNull();
      if (account == null ||
          account.scopeId != query.scopeId ||
          account.serverRevision == '0') {
        throw const DomainError('assets.account_unconfirmed');
      }
    }
    final nonce = await repository.readSetting(invalidationKey(space)) ?? '0';
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(nonce) || nonce.length > 100) {
      throw const DomainError('assets.invalid_data');
    }
    lease?.check();
    return _ReadContext(
      state,
      permissions,
      nonce,
      await store.highestRevision(space, state),
    );
  }

  String _key(DataSpace space, _ReadContext context, AssetReadQuery query) =>
      '${cachePrefix(space)}${context.state.epoch}.${context.state.clientId}.${query.scopeId}.${query.id}';
  AssetReadData _parse(Object? body, AssetReadQuery query) =>
      switch (query.kind) {
        AssetReadKind.entries => AssetAccountEntries.fromJson(body, query),
        AssetReadKind.history => AssetHistory.fromJson(body, query),
        AssetReadKind.creditCalendar => AssetCreditCalendar.fromJson(
          body,
          query,
        ),
      };
  void _identity(
    AssetReadData data,
    DataSpace space,
    _ReadContext context,
    AssetReadQuery query,
  ) {
    final envelope = data.envelope;
    if (envelope.instanceId != space.serverInstanceId ||
        envelope.epoch != context.state.epoch ||
        envelope.scopeId != query.scopeId) {
      throw const DomainError('assets.identity_mismatch');
    }
    if (data is AssetAccountEntries &&
        data.entries.any(
          (entry) =>
              entry.detailAvailable &&
              (entry.bookId == space.userId ||
                  !context.permissions.containsKey(entry.bookId)),
        )) {
      throw const DomainError('assets.scope_unavailable');
    }
  }

  Future<AssetReadSnapshot> fetch(SyncLease lease, AssetReadQuery query) async {
    lease.check();
    await AssetConfigStore(repository).requireState(lease.space, lease);
    await refreshPermissions(lease);
    final captured = await database.readSnapshot(
      () => _context(lease.space, query, lease: lease),
    );
    try {
      final body = await lease.send('GET', query.path);
      final data = _parse(body, query);
      final confirmedAt = now().toUtc();
      late String evidence;
      await database.atomicWrite(() async {
        final current = await _context(lease.space, query, lease: lease);
        _identity(data, lease.space, current, query);
        if (current.nonce != captured.nonce ||
            canonicalSyncJson(current.permissions) !=
                canonicalSyncJson(captured.permissions)) {
          throw const DomainError('assets.evidence_changed');
        }
        final cursor =
            syncVector(jsonDecode(current.state.cursorsJson))[query.scopeId] ??
            '0';
        if (BigInt.parse(data.envelope.scopeRevision) < BigInt.parse(cursor) ||
            BigInt.parse(data.envelope.configRevision) <
                BigInt.parse(current.configRevision)) {
          throw const DomainError('assets.stale_response');
        }
        final key = _key(lease.space, current, query),
            previous = await repository.readSetting(
              _key(lease.space, current, query),
            );
        if (previous != null) {
          final cached = jsonDecode(previous) as Map;
          final envelope = _parse(cached['response'], query).envelope;
          if (BigInt.parse(envelope.scopeRevision) >
                  BigInt.parse(data.envelope.scopeRevision) ||
              BigInt.parse(envelope.configRevision) >
                  BigInt.parse(data.envelope.configRevision)) {
            throw const DomainError('assets.stale_response');
          }
        }
        await repository.writeSetting(
          key,
          jsonEncode({
            'version': 1,
            'space_id': lease.space.id,
            'user_id': lease.space.userId,
            'client_id': lease.clientId,
            'epoch': lease.epoch,
            'nonce': current.nonce,
            'permission_versions': current.permissions,
            'query': query.identity,
            'confirmed_at': confirmedAt.toIso8601String(),
            'response': body,
          }),
        );
        await _boundCache(lease.space);
        evidence = await evidenceStamp(lease.space, query);
        lease.check();
      });
      return AssetReadSnapshot(
        data: data,
        confirmedAt: confirmedAt,
        fromCache: false,
        evidence: evidence,
      );
    } on ApiFailure catch (error) {
      if ({
        'epoch_changed',
        'resync_required',
        'client_mismatch',
        'cursor_expired',
      }.contains(error.code)) {
        lease.check();
        await SyncStore(repository).requireRebuild(lease.space, error.code);
      }
      rethrow;
    }
  }

  Future<AssetReadSnapshot?> cached(
    DataSpace space,
    AssetReadQuery query,
  ) => database.readSnapshot(() async {
    final context = await _context(space, query);
    final raw = await repository.readSetting(_key(space, context, query));
    if (raw == null) return null;
    final row = assetObject(jsonDecode(raw), {
      'version',
      'space_id',
      'user_id',
      'client_id',
      'epoch',
      'nonce',
      'permission_versions',
      'query',
      'confirmed_at',
      'response',
    });
    if (row['version'] != 1 ||
        row['space_id'] != space.id ||
        row['user_id'] != space.userId ||
        row['client_id'] != context.state.clientId ||
        row['epoch'] != context.state.epoch ||
        row['nonce'] != context.nonce ||
        canonicalSyncJson(row['query']) != canonicalSyncJson(query.identity) ||
        canonicalSyncJson(row['permission_versions']) !=
            canonicalSyncJson(context.permissions)) {
      return null;
    }
    final data = _parse(row['response'], query);
    _identity(data, space, context, query);
    final cursor = syncVector(
      jsonDecode(context.state.cursorsJson),
    )[query.scopeId];
    if (cursor != data.envelope.scopeRevision ||
        context.configRevision != data.envelope.configRevision) {
      return null;
    }
    final pending =
        await (database.select(database.pendingOperations)..where(
              (row) =>
                  row.spaceId.equals(space.id) &
                  row.state.isNotIn(['applied', 'discarded']),
            ))
            .get();
    if (pending.isNotEmpty) return null;
    final configPending =
        await (database.select(database.appSettings)..where(
              (row) => row.key.like(
                '${AssetConfigStore.outboxPrefix(space)}${AssetConfigStore.binding(context.state)}.%',
              ),
            ))
            .get();
    if (configPending.any(
      (row) => !{
        'applied',
        'abandoned',
      }.contains((jsonDecode(row.value) as Map)['state']),
    )) {
      return null;
    }
    final confirmedAt = DateTime.tryParse(row['confirmed_at'] as String? ?? '');
    if (confirmedAt == null ||
        !confirmedAt.isUtc ||
        confirmedAt.isAfter(now().toUtc().add(const Duration(minutes: 5)))) {
      throw const DomainError('assets.invalid_data');
    }
    return AssetReadSnapshot(
      data: data,
      confirmedAt: confirmedAt,
      fromCache: true,
      evidence: await evidenceStamp(space, query),
    );
  });

  /// An invalidation nonce is also advanced by SyncStore inside scope revoke.
  Future<void> clearControlledCache(DataSpace space) =>
      database.atomicWrite(() async {
        final nonce = BigInt.parse(
          await repository.readSetting(invalidationKey(space)) ?? '0',
        );
        await repository.writeSetting(
          invalidationKey(space),
          (nonce + BigInt.one).toString(),
        );
        await (database.delete(
          database.appSettings,
        )..where((row) => row.key.like('${cachePrefix(space)}%'))).go();
      });

  Future<void> _boundCache(DataSpace space) async {
    final rows = await (database.select(
      database.appSettings,
    )..where((row) => row.key.like('${cachePrefix(space)}%'))).get();
    final ordered = rows.toList()
      ..sort((a, b) {
        final first = (jsonDecode(a.value) as Map)['confirmed_at'] as String,
            second = (jsonDecode(b.value) as Map)['confirmed_at'] as String;
        return second.compareTo(first);
      });
    var bytes = 0;
    for (var i = 0; i < ordered.length; i++) {
      bytes += utf8.encode(ordered[i].value).length;
      if (i >= maxCachedQueries || bytes > maxCachedBytes) {
        await (database.delete(
          database.appSettings,
        )..where((row) => row.key.equals(ordered[i].key))).go();
      }
    }
  }

  /// UI retains a server result only while this local evidence cut is stable.
  /// Cache writes themselves do not change the stamp, avoiding reload loops.
  Future<String> evidenceStamp(
    DataSpace space,
    AssetReadQuery query,
  ) => database.readSnapshot(() async {
    final context = await _context(space, query);
    final pending =
        await (database.select(database.pendingOperations)..where(
              (row) =>
                  row.spaceId.equals(space.id) &
                  row.state.isNotIn(['applied', 'discarded']),
            ))
            .get();
    final configuration =
        await (database.select(database.appSettings)..where(
              (row) => row.key.like(
                '${AssetConfigStore.outboxPrefix(space)}${AssetConfigStore.binding(context.state)}.%',
              ),
            ))
            .get();
    return syncContentHash({
      'query': query.identity,
      'client_id': context.state.clientId,
      'epoch': context.state.epoch,
      'nonce': context.nonce,
      'permissions': context.permissions,
      'cursors': syncVector(jsonDecode(context.state.cursorsJson)),
      'config_revision': context.configRevision,
      'pending': [
        for (final row in pending)
          {
            'id': row.operationId,
            'state': row.state,
            'intent': row.operationJson,
          },
      ],
      'configuration': [
        for (final row in configuration) {'key': row.key, 'value': row.value},
      ],
    });
  });

  Stream<int> get changes => database
      .customSelect(
        'SELECT 1',
        readsFrom: {
          database.localEntities,
          database.serverShadows,
          database.pendingOperations,
          database.syncStates,
          database.appSettings,
        },
      )
      .watch()
      .map((_) => 1);
}
