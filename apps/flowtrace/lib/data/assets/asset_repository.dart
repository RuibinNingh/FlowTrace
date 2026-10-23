import '../../core/config/data_space.dart';
import '../../domain/assets/asset_config.dart';
import '../../domain/assets/asset_totals.dart';
import '../ledger/ledger_repository.dart';
import 'asset_config_store.dart';

final class LocalAssetSnapshot {
  const LocalAssetSnapshot({
    required this.ledger,
    required this.accounts,
    required this.groups,
    required this.preferences,
    required this.configurationConfirmed,
    required this.totals,
  });
  final LedgerView ledger;
  final List<LedgerEntity> accounts;
  final List<AssetGroup> groups;
  final CurrencyPreferences preferences;
  final bool configurationConfirmed;
  final AssetTotals totals;
}

/// Current authorized private balances only. Historical reconstruction and
/// private entry details belong to the server's explicit asset read endpoints.
final class AssetRepository {
  AssetRepository(this.ledger, this.config);
  final LedgerRepository ledger;
  final AssetConfigStore config;

  Future<LocalAssetSnapshot> read(
    DataSpace space, {
    required String valuationDate,
  }) => config.database.readSnapshot(() async {
    final view = await ledger.read(
      space,
      query: const LedgerQuery(includeArchived: true),
    );
    AssetConfigSectionSnapshot? groups, preferences, rates;
    // A local-only space can still display its exact native balances.
    // Configuration is read only for the active sync identity.
    final state = await (config.database.select(
      config.database.syncStates,
    )..where((row) => row.spaceId.equals(space.id))).getSingleOrNull();
    if (state?.status == 'active') {
      groups = await config.readSection(space, AssetConfigSection.groups);
      preferences = await config.readSection(
        space,
        AssetConfigSection.preferences,
      );
      rates = await config.readSection(space, AssetConfigSection.rates);
    }
    final settings =
        preferences?.preferences ??
        CurrencyPreferences(baseCurrency: 'CNY', enabledCodes: ['CNY']);
    final groupList = groups?.groups ?? const <AssetGroup>[];
    final order = {for (final group in groupList) group.id: group.sortOrder};
    final accounts =
        view.accounts
            .where(
              (account) => account.scopeId == space.userId && !account.deleted,
            )
            .toList()
          ..sort((a, b) {
            final first = order[a.payload['group_id']] ?? 2147483647,
                second = order[b.payload['group_id']] ?? 2147483647;
            final groupOrder = first.compareTo(second);
            if (groupOrder != 0) return groupOrder;
            final accountOrder = ((a.payload['sort_order'] as int?) ?? 0)
                .compareTo((b.payload['sort_order'] as int?) ?? 0);
            return accountOrder != 0 ? accountOrder : a.id.compareTo(b.id);
          });
    // A mismatched set of preference/rate snapshots is not one valuation
    // configuration. Do not combine them into a plausible foreign total.
    final coherent =
        preferences != null &&
        rates != null &&
        preferences.revision == rates.revision;
    final totals = valueAssetPositions(
      [
        for (final account in accounts)
          AssetPosition(
            id: account.id,
            balance: view.balances[account.id]?.value,
            includeInNetAssets:
                account.payload['include_in_net_assets'] != false,
            hidden: account.payload['hidden'] == true,
            kind: account.payload['kind'] as String? ?? 'cash',
          ),
      ],
      currency: settings.baseCurrency,
      asOfDate: valuationDate,
      valuationPolicy: settings.valuationPolicy,
      rates: coherent ? rates.rates.map((rate) => rate.quote) : const [],
    );
    return LocalAssetSnapshot(
      ledger: view,
      accounts: List.unmodifiable(accounts),
      groups: List.unmodifiable(groupList),
      preferences: settings,
      configurationConfirmed: coherent,
      totals: totals,
    );
  });

  Stream<LocalAssetSnapshot> watch(
    DataSpace space, {
    required String valuationDate,
  }) => config.database
      .customSelect(
        'SELECT 1',
        readsFrom: {
          config.database.localEntities,
          config.database.serverShadows,
          config.database.pendingOperations,
          config.database.syncStates,
          config.database.appSettings,
        },
      )
      .watch()
      .asyncMap((_) => read(space, valuationDate: valuationDate));
}
