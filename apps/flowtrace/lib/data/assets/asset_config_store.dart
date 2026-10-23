import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../domain/assets/asset_config.dart';
import '../local/app_database.dart';
import '../local/local_repository.dart';
import '../sync/sync_engine.dart';

/// Private configuration and frozen REST requests use identity-scoped settings.
/// They are not ledger entities and cannot be inserted into the sync journal.
final class AssetConfigStore {
  AssetConfigStore(this.repository);
  final LocalRepository repository;
  AppDatabase get database => repository.database;

  static String configPrefix(DataSpace space) =>
      'assets.config.v1.${space.id}.';
  static String outboxPrefix(DataSpace space) =>
      'assets.outbox.v1.${space.id}.';
  static String binding(SpaceSyncState state) =>
      '${state.epoch}.${state.clientId}';

  Future<SpaceSyncState> requireState(
    DataSpace space, [
    SyncLease? lease,
  ]) async {
    lease?.check();
    final state = await (database.select(
      database.syncStates,
    )..where((row) => row.spaceId.equals(space.id))).getSingleOrNull();
    lease?.check();
    if (!space.verified ||
        state == null ||
        state.status != 'active' ||
        (lease != null &&
            (lease.space.id != space.id ||
                state.epoch != lease.epoch ||
                state.clientId != lease.clientId))) {
      throw const DomainError('assets.read_only');
    }
    return state;
  }

  Future<AssetConfigSectionSnapshot?> readSection(
    DataSpace space,
    AssetConfigSection section,
  ) => database.readSnapshot(() async {
    final state = await requireState(space);
    return _readSection(space, state, section);
  });

  Future<AssetConfigSectionSnapshot?> _readSection(
    DataSpace space,
    SpaceSyncState state,
    AssetConfigSection section,
  ) async {
    final raw = await repository.readSetting(
      '${configPrefix(space)}${binding(state)}.${section.name}',
    );
    if (raw == null) return null;
    final cache = assetObject(jsonDecode(raw), {
      'version',
      'space_id',
      'user_id',
      'client_id',
      'response',
    });
    if (cache['version'] != 1 ||
        cache['space_id'] != space.id ||
        cache['user_id'] != space.userId ||
        cache['client_id'] != state.clientId) {
      throw const DomainError('assets.invalid_data');
    }
    final snapshot = AssetConfigSectionSnapshot.fromJson(
      section,
      cache['response'],
    );
    if (snapshot.instanceId != space.serverInstanceId ||
        snapshot.epoch != state.epoch) {
      throw const DomainError('assets.invalid_data');
    }
    return snapshot;
  }

  Future<String> highestRevision(DataSpace space, SpaceSyncState state) async {
    var highest = BigInt.zero;
    for (final section in AssetConfigSection.values) {
      final snapshot = await _readSection(space, state, section);
      if (snapshot != null && BigInt.parse(snapshot.revision) > highest) {
        highest = BigInt.parse(snapshot.revision);
      }
    }
    return highest.toString();
  }

  /// Late idempotency replies cannot roll back any newer known configuration.
  Future<bool> acceptSection(
    SyncLease lease,
    AssetConfigSectionSnapshot snapshot,
  ) => database.atomicWrite(() async {
    final state = await requireState(lease.space, lease);
    if (snapshot.instanceId != lease.space.serverInstanceId ||
        snapshot.epoch != lease.epoch) {
      throw const DomainError('assets.identity_mismatch');
    }
    final highest = await highestRevision(lease.space, state);
    if (BigInt.parse(snapshot.revision) < BigInt.parse(highest)) return false;
    lease.check();
    await repository.writeSetting(
      '${configPrefix(lease.space)}${binding(state)}.${snapshot.section.name}',
      jsonEncode({
        'version': 1,
        'space_id': lease.space.id,
        'user_id': lease.space.userId,
        'client_id': lease.clientId,
        'response': snapshot.toJson(),
      }),
    );
    lease.check();
    return true;
  });

  /// Shared with LedgerRepository: only REST-confirmed private groups qualify.
  Future<void> requireConfirmedGroup(
    DataSpace space,
    String groupId,
  ) => database.readSnapshot(() async {
    assetId(groupId);
    final state = await requireState(space);
    final groups = await _readSection(space, state, AssetConfigSection.groups);
    if (groups == null || !groups.groups.any((group) => group.id == groupId)) {
      throw const DomainError('assets.group_unconfirmed');
    }
    final rows =
        await (database.select(database.appSettings)..where(
              (row) =>
                  row.key.like('${outboxPrefix(space)}${binding(state)}.%'),
            ))
            .get();
    for (final row in rows) {
      final operation = jsonDecode(row.value) as Map<String, dynamic>;
      if ({'queued', 'retry', 'conflict'}.contains(operation['state']) &&
          operation['method'] == 'DELETE' &&
          operation['path'] == '/assets/groups/$groupId') {
        throw const DomainError('assets.group_unconfirmed');
      }
    }
  });

  /// Check both projected accounts and older unsent intents before group delete.
  Future<void> requireUnusedGroup(DataSpace space, String groupId) async {
    final accounts =
        await (database.select(database.localEntities)..where(
              (row) =>
                  row.spaceId.equals(space.id) &
                  row.entityType.equals('account') &
                  row.deleted.equals(false),
            ))
            .get();
    for (final account in accounts) {
      final data = jsonDecode(account.dataJson) as Map<String, dynamic>;
      final payload = data['payload'] is Map ? data['payload'] as Map : data;
      if (payload['group_id'] == groupId) {
        throw const DomainError('assets.group_in_use');
      }
    }
    final pending =
        await (database.select(database.pendingOperations)..where(
              (row) =>
                  row.spaceId.equals(space.id) &
                  row.entityType.equals('account') &
                  row.state.isIn(['queued', 'sending', 'retry']),
            ))
            .get();
    for (final operation in pending) {
      final data = jsonDecode(operation.operationJson) as Map<String, dynamic>;
      if ((data['payload'] as Map?)?['group_id'] == groupId) {
        throw const DomainError('assets.group_in_use');
      }
    }
  }
}
