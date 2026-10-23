import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/data/assets/asset_config_store.dart';
import 'package:flowtrace/data/assets/asset_repository.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/domain/assets/asset_config.dart';

import '../ledger/query_fixtures.dart';

void main() {
  late QueryFixture f;
  late AssetConfigStore config;
  late AssetRepository repository;
  late SyncLease lease;
  setUp(() async {
    f = QueryFixture();
    await f.seed();
    config = AssetConfigStore(f.local);
    repository = AssetRepository(f.ledger, config);
    lease = SyncLease(
      space: f.space,
      clientId: qid(5),
      epoch: qEpoch,
      isCurrent: () => true,
      request: (method, path, {body, bodyJson}) async => {},
    );
  });
  tearDown(() => f.close());
  Future<void> accept(
    AssetConfigSection section,
    String revision,
    Object body,
  ) async {
    await config.acceptSection(
      lease,
      AssetConfigSectionSnapshot.fromJson(section, {
        'instance_id': f.space.serverInstanceId,
        'sync_epoch': qEpoch,
        'revision': revision,
        section.name: body,
      }),
    );
  }

  Future<void> rates(String revision) =>
      accept(AssetConfigSection.rates, revision, [
        {
          'id': qid(700),
          'from_currency': 'USD',
          'to_currency': 'CNY',
          'effective_date': '2026-10-21',
          'rate': '7',
          'rate_source': '手动',
          'revision': revision,
        },
      ]);
  Future<void> preferences(String revision) =>
      accept(AssetConfigSection.preferences, revision, {
        'base_currency': 'CNY',
        'enabled_codes': ['CNY', 'USD'],
        'valuation_policy': 'exact_date',
      });

  test(
    'private overview excludes shared accounts and includes hidden archived balances',
    () async {
      await preferences('1');
      await rates('1');
      final account = (await f.ledger.read(
        f.space,
      )).accounts.firstWhere((row) => row.id == qCash);
      await f.put('account', qCash, qUser, {
        'projection_kind': 'account',
        'payload': {...account.payload, 'hidden': true, 'archived': true},
        'balance': qmoney('100000'),
      });
      await f.put('account', qid(701), qBook, {
        'projection_kind': 'account',
        'payload': {
          'name': '共享不入私人总览',
          'kind': 'bank',
          'opening': qmoney('999999'),
          'include_in_net_assets': true,
          'hidden': false,
        },
        'balance': qmoney('999999'),
      });
      final snapshot = await repository.read(
        f.space,
        valuationDate: '2026-10-21',
      );
      expect(snapshot.accounts.map((row) => row.id).toSet(), {
        qCash,
        qBank,
        qUsd,
      });
      expect(snapshot.totals.net!.minor.toString(), '270000');
      expect(
        snapshot.accounts
            .firstWhere((row) => row.id == qCash)
            .effectiveArchived,
        isTrue,
      );
      expect(snapshot.configurationConfirmed, isTrue);
    },
  );

  test(
    'different preference and quote revisions never form a foreign grand total',
    () async {
      await preferences('1');
      await rates('2');
      var snapshot = await repository.read(
        f.space,
        valuationDate: '2026-10-21',
      );
      expect(snapshot.configurationConfirmed, isFalse);
      expect(snapshot.totals.net, isNull);
      expect(snapshot.ledger.balances[qUsd]!.value!.minor.toString(), '10000');
      await preferences('2');
      snapshot = await repository.read(f.space, valuationDate: '2026-10-21');
      expect(snapshot.totals.net!.minor.toString(), '270000');
      expect(snapshot.configurationConfirmed, isTrue);
    },
  );

  test(
    'no manual FX silently derives a rate from an old bill reporting field',
    () async {
      final snapshot = await repository.read(
        f.space,
        valuationDate: '2026-10-21',
      );
      expect(snapshot.accounts, hasLength(3));
      expect(snapshot.totals.available, isFalse);
      expect(snapshot.totals.issues, contains('assets.rate_required'));
      expect(snapshot.totals.usedRates, isEmpty);
    },
  );
}
