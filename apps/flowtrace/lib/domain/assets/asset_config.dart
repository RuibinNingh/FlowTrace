import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../ledger/calendar_rules.dart';
import 'asset_totals.dart';

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

String assetId(Object? value) {
  if (value is! String || !_uuid.hasMatch(value)) {
    throw const DomainError('assets.invalid_data');
  }
  return value;
}

Map<String, Object?> assetObject(Object? value, Set<String> keys) {
  if (value is! Map<String, Object?> ||
      value.length != keys.length ||
      !keys.containsAll(value.keys)) {
    throw const DomainError('assets.invalid_data');
  }
  return value;
}

String assetText(Object? value, {int max = 80}) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > max ||
      value.contains('\u0000')) {
    throw const DomainError('assets.invalid_data');
  }
  return value;
}

String assetRevision(Object? value) {
  final revision = parseMinor(value);
  if (revision.isNegative) throw const DomainError('assets.invalid_data');
  return revision.toString();
}

final class AssetGroup {
  AssetGroup({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.revision,
  }) {
    assetId(id);
    assetText(name);
    assetRevision(revision);
    if (sortOrder < 0 || sortOrder > 2147483647) {
      throw const DomainError('assets.invalid_data');
    }
  }
  factory AssetGroup.fromJson(Object? value) {
    final row = assetObject(value, {'id', 'name', 'sort_order', 'revision'});
    if (row['sort_order'] is! int) {
      throw const DomainError('assets.invalid_data');
    }
    return AssetGroup(
      id: assetId(row['id']),
      name: assetText(row['name']),
      sortOrder: row['sort_order'] as int,
      revision: assetRevision(row['revision']),
    );
  }
  final String id, name, revision;
  final int sortOrder;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'sort_order': sortOrder,
    'revision': revision,
  };
}

final class CurrencyPreferences {
  CurrencyPreferences({
    required this.baseCurrency,
    required Iterable<String> enabledCodes,
    this.valuationPolicy = 'exact_date',
  }) : enabledCodes = List.unmodifiable(enabledCodes) {
    if (!currencyScales.containsKey(baseCurrency) ||
        this.enabledCodes.isEmpty ||
        this.enabledCodes.length > 200 ||
        this.enabledCodes.toSet().length != this.enabledCodes.length ||
        !this.enabledCodes.contains(baseCurrency) ||
        this.enabledCodes.any((code) => !currencyScales.containsKey(code)) ||
        !{'exact_date', 'latest_on_or_before'}.contains(valuationPolicy)) {
      throw const DomainError('assets.invalid_data');
    }
  }
  factory CurrencyPreferences.fromJson(Object? value) {
    final row = assetObject(value, {
      'base_currency',
      'enabled_codes',
      'valuation_policy',
    });
    final codes = row['enabled_codes'];
    if (codes is! List || codes.any((code) => code is! String)) {
      throw const DomainError('assets.invalid_data');
    }
    return CurrencyPreferences(
      baseCurrency: assetText(row['base_currency'], max: 3),
      enabledCodes: codes.cast<String>(),
      valuationPolicy: assetText(row['valuation_policy']),
    );
  }
  final String baseCurrency, valuationPolicy;
  final List<String> enabledCodes;
  Map<String, Object?> toJson() => {
    'base_currency': baseCurrency,
    'enabled_codes': enabledCodes,
    'valuation_policy': valuationPolicy,
  };
}

final class AssetRate {
  AssetRate({
    required this.id,
    required this.fromCurrency,
    required this.toCurrency,
    required this.effectiveDate,
    required this.rate,
    required this.source,
    required this.revision,
  }) {
    assetId(id);
    assetRevision(revision);
    businessDate(effectiveDate);
    parseRate(rate);
    assetText(source);
    if (fromCurrency == toCurrency ||
        !currencyScales.containsKey(fromCurrency) ||
        !currencyScales.containsKey(toCurrency)) {
      throw const DomainError('assets.invalid_data');
    }
  }
  factory AssetRate.fromJson(Object? value) {
    final row = assetObject(value, {
      'id',
      'from_currency',
      'to_currency',
      'effective_date',
      'rate',
      'rate_source',
      'revision',
    });
    return AssetRate(
      id: assetId(row['id']),
      fromCurrency: assetText(row['from_currency'], max: 3),
      toCurrency: assetText(row['to_currency'], max: 3),
      effectiveDate: assetText(row['effective_date'], max: 10),
      rate: assetText(row['rate'], max: 40),
      source: assetText(row['rate_source']),
      revision: assetRevision(row['revision']),
    );
  }
  final String id,
      fromCurrency,
      toCurrency,
      effectiveDate,
      rate,
      source,
      revision;
  AssetValuationRate get quote => AssetValuationRate(
    fromCurrency: fromCurrency,
    toCurrency: toCurrency,
    effectiveDate: effectiveDate,
    rate: rate,
    source: source,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'from_currency': fromCurrency,
    'to_currency': toCurrency,
    'effective_date': effectiveDate,
    'rate': rate,
    'rate_source': source,
    'revision': revision,
  };
}

enum AssetConfigSection {
  groups('/assets/groups'),
  preferences('/currencies/preferences'),
  rates('/currencies/rates');

  const AssetConfigSection(this.path);
  final String path;
}

/// Each section has a complete list and the shared user configuration revision.
final class AssetConfigSectionSnapshot {
  AssetConfigSectionSnapshot._({
    required this.section,
    required this.instanceId,
    required this.epoch,
    required this.revision,
    this.operationId,
    this.groups = const [],
    this.preferences,
    this.rates = const [],
  });
  factory AssetConfigSectionSnapshot.fromJson(
    AssetConfigSection section,
    Object? value,
  ) {
    final optional = value is Map && value.containsKey('operation_id');
    final row = assetObject(value, {
      'instance_id',
      'sync_epoch',
      'revision',
      section.name,
      if (optional) 'operation_id',
    });
    final instance = assetId(row['instance_id']),
        epoch = assetId(row['sync_epoch']);
    final revision = assetRevision(row['revision']);
    final operation = optional ? assetId(row['operation_id']) : null;
    var groups = const <AssetGroup>[];
    var rates = const <AssetRate>[];
    CurrencyPreferences? preferences;
    if (section == AssetConfigSection.preferences) {
      preferences = CurrencyPreferences.fromJson(row['preferences']);
    } else {
      final list = row[section.name];
      final maximum = section == AssetConfigSection.groups ? 1000 : 10000;
      if (list is! List || list.length > maximum) {
        throw const DomainError('assets.invalid_data');
      }
      if (section == AssetConfigSection.groups) {
        groups = List.unmodifiable(list.map(AssetGroup.fromJson));
        if (groups.map((item) => item.id).toSet().length != groups.length ||
            groups.any(
              (item) => BigInt.parse(item.revision) > BigInt.parse(revision),
            )) {
          throw const DomainError('assets.invalid_data');
        }
      } else {
        rates = List.unmodifiable(list.map(AssetRate.fromJson));
        if (rates.map((item) => item.id).toSet().length != rates.length ||
            rates
                    .map(
                      (item) =>
                          '${item.fromCurrency}/${item.toCurrency}/${item.effectiveDate}',
                    )
                    .toSet()
                    .length !=
                rates.length ||
            rates.any(
              (item) => BigInt.parse(item.revision) > BigInt.parse(revision),
            )) {
          throw const DomainError('assets.invalid_data');
        }
      }
    }
    return AssetConfigSectionSnapshot._(
      section: section,
      instanceId: instance,
      epoch: epoch,
      revision: revision,
      operationId: operation,
      groups: groups,
      preferences: preferences,
      rates: rates,
    );
  }
  final AssetConfigSection section;
  final String instanceId, epoch, revision;
  final String? operationId;
  final List<AssetGroup> groups;
  final CurrencyPreferences? preferences;
  final List<AssetRate> rates;
  Map<String, Object?> toJson() => {
    'instance_id': instanceId,
    'sync_epoch': epoch,
    'revision': revision,
    if (operationId != null) 'operation_id': operationId,
    section.name: switch (section) {
      AssetConfigSection.groups => groups.map((item) => item.toJson()).toList(),
      AssetConfigSection.preferences => preferences!.toJson(),
      AssetConfigSection.rates => rates.map((item) => item.toJson()).toList(),
    },
  };
}
