import 'package:drift/drift.dart' show Value;
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/data/assets/asset_read_repository.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/domain/ledger/calendar_rules.dart';

import '../ledger/query_fixtures.dart';

final class AssetReadFixture {
  final data = QueryFixture();
  late final AppController app = AppController(data.db)
    ..space = data.space
    ..loading = false;
  // Business-date vectors stay fixed; cache proof time uses the production
  // clock so a real page cannot reject a synthetic future confirmation.
  final now = DateTime.now().toUtc();
  bool current = true;
  int authorizations = 0, requests = 0;
  late SyncRequest request = (method, path, {body, bodyJson}) async =>
      entriesBody();
  late final lease = SyncLease(
    space: data.space,
    clientId: qid(5),
    epoch: qEpoch,
    isCurrent: () => current,
    request: (method, path, {body, bodyJson}) {
      requests++;
      return request(method, path, body: body, bodyJson: bodyJson);
    },
  );
  late final reads = AssetReadRepository(
    data.local,
    now: () => now,
    refreshPermissions: (_) async {
      authorizations++;
    },
  );
  AssetReadQuery get entriesQuery => AssetReadQuery.entries(
    scopeId: qUser,
    accountId: qCash,
    startDate: '2026-10-01',
    endDateExclusive: '2026-11-01',
  );
  AssetReadQuery get creditQuery => AssetReadQuery.creditCalendar(
    scopeId: qUser,
    accountId: qBank,
    startDate: '2026-10-01',
    endDateExclusive: '2026-11-01',
  );
  AssetReadQuery get historyQuery => AssetReadQuery.history(
    scopeId: qUser,
    startDate: '2026-10-01',
    endDateExclusive: '2026-11-01',
  );
  Future<void> open() async {
    await data.local.registerSpace(data.space);
    await data.sync.configure(data.space, qid(5), qEpoch);
    await data.roles();
    await data.local.writeSetting(
      'sync.scopes.${data.space.id}',
      canonicalSyncJson({qUser: '1', qBook: '1', qOtherBook: '1'}),
    );
    await cursors('5');
    await data.put('book', qBook, qBook, {
      'projection_kind': 'book',
      'payload': {
        'name': '合成授权账本',
        'currency': 'CNY',
        'timezone': 'Asia/Shanghai',
        'month_start_day': 1,
      },
    });
    await data.put('account', qCash, qUser, {
      'projection_kind': 'account',
      'payload': {
        'name': '已同步现金',
        'kind': 'cash',
        'opening': qmoney('10000'),
        'opening_date': '2026-10-01',
        'hidden': false,
        'include_in_net_assets': true,
      },
      'balance': qmoney('9875'),
    });
    await data.put('account', qBank, qUser, {
      'projection_kind': 'account',
      'payload': {
        'name': '已同步信用卡',
        'kind': 'credit_card',
        'opening': qmoney('-5000'),
        'opening_date': '2026-10-01',
        'hidden': false,
        'include_in_net_assets': true,
        'credit': {
          'limit': qmoney('10000'),
          'statement_day': 31,
          'statement_day_inclusive': true,
          'due_mode': 'fixed_day',
          'due_day': 10,
          'due_days': null,
        },
      },
      'balance': qmoney('-5000'),
    });
  }

  Future<void> cursors(String value) =>
      (data.db.update(data.db.syncStates)
            ..where((row) => row.spaceId.equals(data.space.id)))
          .write(
            SyncStatesCompanion(
              cursorsJson: Value(
                canonicalSyncJson({qUser: value, qBook: '1', qOtherBook: '0'}),
              ),
            ),
          )
          .then((_) {});
  Map<String, Object?> envelope({String revision = '5', String config = '0'}) =>
      {
        'instance_id': data.space.serverInstanceId,
        'sync_epoch': qEpoch,
        'scope_id': qUser,
        'scope_revision': revision,
        'config_revision': config,
      };
  Map<String, Object?> entry({
    int number = 0,
    bool visible = true,
    String amount = '-1',
  }) => {
    'entry_id': qid(900 + number),
    'business_date': '2026-10-21',
    'component': number == 0 ? 'fee' : 'principal',
    'money': qmoney(amount),
    'detail_available': visible,
    'bill_id': visible ? qa : null,
    'book_id': visible ? qBook : null,
    'bill_type': visible ? 'transfer' : null,
    'note': visible ? '合成授权备注' : null,
    'category_id': null,
    'tag_ids': <Object?>[],
    'attachment_ids': <Object?>[],
  };
  Map<String, Object?> entriesBody({
    String revision = '5',
    String config = '0',
    int offset = 0,
    int limit = 100,
  }) {
    final all = [entry(), entry(number: 1, visible: false, amount: '-124')];
    return {
      ...envelope(revision: revision, config: config),
      'account_id': qCash,
      'currency': 'CNY',
      'currency_scale': 2,
      'start_date': '2026-10-01',
      'end_date_exclusive': '2026-11-01',
      'total_count': all.length,
      'offset': offset,
      'limit': limit,
      'entries': all.skip(offset).take(limit).toList(),
      'opening_balance': qmoney('10000'),
      'closing_balance': qmoney('9875'),
      'issues': <Object?>[],
    };
  }

  Map<String, Object?> totals(String net) => {
    'assets_minor': net,
    'liabilities_minor': '0',
    'net_minor': net,
    'borrowed_minor': '0',
    'lent_minor': '0',
  };
  Map<String, Object?> historyBody({
    String revision = '5',
    String config = '0',
  }) => {
    ...envelope(revision: revision, config: config),
    'base_currency': 'CNY',
    'base_scale': 2,
    'valuation_policy': 'exact_date',
    'start_date': '2026-10-01',
    'end_date_exclusive': '2026-11-01',
    'points': [
      for (var day = 1; day <= 31; day++)
        {
          'date': isoBusinessDate(DateTime.utc(2026, 10, day)),
          'available': day != 16,
          'issues': day == 16 ? ['asset.opening_date_required'] : <Object?>[],
          'totals': day == 16
              ? null
              : totals(day <= 15 ? '9007199254740993' : '9007199254740992'),
        },
    ],
  };
  Map<String, Object?> creditBody() => {
    ...envelope(),
    'account_id': qBank,
    'currency': 'CNY',
    'currency_scale': 2,
    'total_debt_minor': '5000',
    'overpayment_minor': '0',
    'available_credit_minor': '5000',
    'over_limit_minor': '0',
    'opening_carry_minor': '0',
    'repayment_available': true,
    'issues': <Object?>[],
    'cycles': [
      {
        'start_date': '2026-10-01',
        'end_date_exclusive': '2026-11-01',
        'statement_date': '2026-10-31',
        'due_date': '2026-11-10',
        'charges_minor': '5000',
        'statement_due_minor': '5000',
        'remaining_due_minor': '5000',
        'max_interest_free_days': 40,
        'min_interest_free_days': 10,
      },
    ],
  };
  bool _storageClosed = false;
  Future<void> closeStorage() async {
    if (_storageClosed) return;
    await data.db.close();
    _storageClosed = true;
  }

  Future<void> close() async {
    app.dispose();
    await closeStorage();
  }
}
