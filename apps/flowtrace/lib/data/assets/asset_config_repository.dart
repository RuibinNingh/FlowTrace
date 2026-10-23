import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../core/network/api_failure.dart';
import '../../domain/assets/asset_config.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_store.dart';
import 'asset_config_store.dart';

/// A private REST mutation is frozen before any network I/O. Its original
/// bytes remain available after timeouts, conflicts, logout and epoch changes.
final class AssetConfigOperation {
  AssetConfigOperation._({
    required this.id,
    required this.method,
    required this.path,
    required this.bodyJson,
    required this.state,
    this.errorCode,
  });
  factory AssetConfigOperation.fromJson(Object? value) {
    final row = assetObject(value, {
      'version',
      'operation_id',
      'method',
      'path',
      'body_json',
      'state',
      'error_code',
    });
    if (row['version'] != 1 ||
        row['body_json'] is! String ||
        !{
          'queued',
          'retry',
          'conflict',
          'applied',
          'abandoned',
        }.contains(row['state'])) {
      throw const DomainError('assets.invalid_data');
    }
    final operation = AssetConfigOperation._(
      id: assetId(row['operation_id']),
      method: assetText(row['method']),
      path: assetText(row['path'], max: 100),
      bodyJson: row['body_json'] as String,
      state: row['state'] as String,
      errorCode: row['error_code'] == null
          ? null
          : assetText(row['error_code'], max: 100),
    );
    operation._validate();
    return operation;
  }
  final String id, method, path, bodyJson, state;
  final String? errorCode;
  bool get pending => !{'applied', 'abandoned'}.contains(state);
  AssetConfigSection get section {
    if (path == '/assets/groups' || path.startsWith('/assets/groups/')) {
      return AssetConfigSection.groups;
    }
    if (path == '/currencies/preferences') {
      return AssetConfigSection.preferences;
    }
    if (path == '/currencies/rates' || path.startsWith('/currencies/rates/')) {
      return AssetConfigSection.rates;
    }
    throw const DomainError('assets.invalid_data');
  }

  Map<String, Object?> get body =>
      (jsonDecode(bodyJson) as Map).cast<String, Object?>();
  void _validate() {
    final request = body;
    final deleting = method == 'DELETE';
    final payloadKey = switch (section) {
      AssetConfigSection.groups => 'group',
      AssetConfigSection.preferences => 'preferences',
      AssetConfigSection.rates => 'rate',
    };
    assetObject(request, {
      'operation_id',
      'client_id',
      'instance_id',
      'sync_epoch',
      'base_revision',
      if (!deleting) payloadKey,
    });
    if (assetId(request['operation_id']) != id) {
      throw const DomainError('assets.invalid_data');
    }
    assetId(request['client_id']);
    assetId(request['instance_id']);
    assetId(request['sync_epoch']);
    assetRevision(request['base_revision']);
    switch (section) {
      case AssetConfigSection.groups:
        if (method == 'POST' && path == section.path) {
          final group = assetObject(request['group'], {
            'id',
            'name',
            'sort_order',
          });
          AssetGroup.fromJson({...group, 'revision': '0'});
        } else if (method == 'PATCH' && path.startsWith('${section.path}/')) {
          final group = assetObject(request['group'], {'name', 'sort_order'});
          AssetGroup.fromJson({
            ...group,
            'id': assetId(path.split('/').last),
            'revision': '0',
          });
        } else if (deleting && path.startsWith('${section.path}/')) {
          assetId(path.split('/').last);
        } else {
          throw const DomainError('assets.invalid_data');
        }
      case AssetConfigSection.preferences:
        if (method != 'PUT' || path != section.path) {
          throw const DomainError('assets.invalid_data');
        }
        CurrencyPreferences.fromJson(request['preferences']);
      case AssetConfigSection.rates:
        if (method == 'POST' && path == section.path) {
          final rate = request['rate'];
          if (rate is! Map<String, Object?>) {
            throw const DomainError('assets.invalid_data');
          }
          AssetRate.fromJson({...rate, 'revision': '0'});
        } else if (deleting && path.startsWith('${section.path}/')) {
          assetId(path.split('/').last);
        } else {
          throw const DomainError('assets.invalid_data');
        }
    }
  }

  AssetConfigOperation withState(String state, [String? error]) =>
      AssetConfigOperation._(
        id: id,
        method: method,
        path: path,
        bodyJson: bodyJson,
        state: state,
        errorCode: error,
      );
  Map<String, Object?> toJson() => {
    'version': 1,
    'operation_id': id,
    'method': method,
    'path': path,
    'body_json': bodyJson,
    'state': state,
    'error_code': errorCode,
  };
}

final class AssetConfigRepository {
  AssetConfigRepository(this.store, {required this.refreshPermissions});
  final AssetConfigStore store;
  final Future<void> Function(SyncLease lease) refreshPermissions;
  static const _uuid = Uuid();
  final Set<String> _sending = {};

  Future<void> _authorize(SyncLease lease) async {
    lease.check();
    await store.requireState(lease.space, lease);
    await refreshPermissions(lease);
    lease.check();
    await store.requireState(lease.space, lease);
  }

  Future<AssetConfigSectionSnapshot> refresh(
    SyncLease lease,
    AssetConfigSection section,
  ) async {
    await _authorize(lease);
    try {
      final response = await lease.send('GET', section.path);
      final snapshot = AssetConfigSectionSnapshot.fromJson(section, response);
      if (snapshot.operationId != null) {
        throw const DomainError('assets.invalid_data');
      }
      await store.acceptSection(lease, snapshot);
      lease.check();
      // Return the accepted cache, not an older response that lost the race.
      final accepted = await store.readSection(lease.space, section);
      lease.check();
      if (accepted == null) throw const DomainError('assets.stale_response');
      return accepted;
    } on ApiFailure catch (error) {
      await _recovery(lease, error);
      rethrow;
    }
  }

  Future<List<AssetConfigOperation>> operations(
    DataSpace space,
  ) => store.database.readSnapshot(() async {
    final state = await store.requireState(space);
    final rows =
        await (store.database.select(store.database.appSettings)..where(
              (row) => row.key.like(
                '${AssetConfigStore.outboxPrefix(space)}${AssetConfigStore.binding(state)}.%',
              ),
            ))
            .get();
    final operations = rows
        .map((row) => AssetConfigOperation.fromJson(jsonDecode(row.value)))
        .toList();
    for (final operation in operations) {
      _bound(operation, space, state.clientId, state.epoch);
    }
    return List.unmodifiable(operations);
  });

  Future<AssetConfigOperation> createGroup(
    SyncLease lease, {
    required String name,
    int sortOrder = 0,
    String? groupId,
  }) => _mutate(lease, 'POST', '/assets/groups', {
    'group': {
      'id': groupId ?? _uuid.v4(),
      'name': name,
      'sort_order': sortOrder,
    },
  });
  Future<AssetConfigOperation> updateGroup(
    SyncLease lease,
    AssetGroup group, {
    required String name,
    required int sortOrder,
  }) => _mutate(lease, 'PATCH', '/assets/groups/${assetId(group.id)}', {
    'group': {'name': name, 'sort_order': sortOrder},
  });
  Future<AssetConfigOperation> deleteGroup(SyncLease lease, String id) =>
      _mutate(lease, 'DELETE', '/assets/groups/${assetId(id)}', {});
  Future<AssetConfigOperation> savePreferences(
    SyncLease lease,
    CurrencyPreferences preferences,
  ) => _mutate(lease, 'PUT', '/currencies/preferences', {
    'preferences': preferences.toJson(),
  });
  Future<AssetConfigOperation> createRate(SyncLease lease, AssetRate rate) =>
      _mutate(lease, 'POST', '/currencies/rates', {
        'rate': {...rate.toJson()}..remove('revision'),
      });
  Future<AssetConfigOperation> deleteRate(SyncLease lease, String id) =>
      _mutate(lease, 'DELETE', '/currencies/rates/${assetId(id)}', {});

  Future<AssetConfigOperation> _mutate(
    SyncLease lease,
    String method,
    String path,
    Map<String, Object?> payload,
  ) async {
    await _authorize(lease);
    final operation = await store.database.atomicWrite(() async {
      final state = await store.requireState(lease.space, lease);
      final existing = await operations(lease.space);
      if (existing.any((operation) => operation.pending)) {
        throw const DomainError('assets.configuration_pending');
      }
      if (method == 'DELETE' && path.startsWith('/assets/groups/')) {
        await store.requireUnusedGroup(lease.space, path.split('/').last);
      }
      final id = _uuid.v4();
      final operation = AssetConfigOperation.fromJson({
        'version': 1,
        'operation_id': id,
        'method': method,
        'path': path,
        'body_json': _frozenJson({
          'operation_id': id,
          'client_id': lease.clientId,
          'instance_id': lease.space.serverInstanceId,
          'sync_epoch': lease.epoch,
          'base_revision': await store.highestRevision(lease.space, state),
          ...payload,
        }),
        'state': 'queued',
        'error_code': null,
      });
      lease.check();
      await _write(lease, operation);
      lease.check();
      return operation;
    });
    return retry(lease, operation.id, refreshAuthorization: false);
  }

  Future<AssetConfigOperation> retry(
    SyncLease lease,
    String operationId, {
    bool refreshAuthorization = true,
  }) async {
    assetId(operationId);
    final sendKey = '${lease.space.id}.$operationId';
    if (!_sending.add(sendKey)) {
      throw const DomainError('assets.configuration_busy');
    }
    try {
      if (refreshAuthorization) await _authorize(lease);
      final operation = await store.database.readSnapshot(() async {
        await store.requireState(lease.space, lease);
        final operation = (await operations(
          lease.space,
        )).where((item) => item.id == operationId).firstOrNull;
        if (operation == null || operation.state == 'abandoned') {
          throw const DomainError('assets.operation_unavailable');
        }
        return operation;
      });
      if (operation.state == 'applied') return operation;
      if (operation.method == 'DELETE' &&
          operation.section == AssetConfigSection.groups) {
        await store.database.atomicWrite(() async {
          await store.requireState(lease.space, lease);
          await store.requireUnusedGroup(
            lease.space,
            operation.path.split('/').last,
          );
          lease.check();
        });
      }
      try {
        final response = await lease.send(
          operation.method,
          operation.path,
          bodyJson: operation.bodyJson,
        );
        final snapshot = AssetConfigSectionSnapshot.fromJson(
          operation.section,
          response,
        );
        if (snapshot.operationId != operation.id ||
            BigInt.parse(snapshot.revision) <=
                BigInt.parse(operation.body['base_revision'] as String)) {
          throw const DomainError('assets.invalid_data');
        }
        final applied = operation.withState('applied');
        await store.database.atomicWrite(() async {
          await store.requireState(lease.space, lease);
          await store.acceptSection(lease, snapshot);
          await _write(lease, applied);
          lease.check();
        });
        return applied;
      } on ApiFailure catch (error) {
        await _recovery(lease, error);
        if (_rebuildErrors.contains(error.code)) rethrow;
        lease.check();
        await store.database.atomicWrite(() async {
          await store.requireState(lease.space, lease);
          await _write(
            lease,
            operation.withState(
              error.status == 409 || error.status == 422 ? 'conflict' : 'retry',
              error.code,
            ),
          );
          lease.check();
        });
        rethrow;
      }
    } finally {
      _sending.remove(sendKey);
    }
  }

  /// Explicitly abandon an intent after review; its frozen request is retained.
  Future<void> abandon(SyncLease lease, String operationId) async {
    lease.check();
    if (_sending.contains('${lease.space.id}.$operationId')) {
      throw const DomainError('assets.configuration_busy');
    }
    await store.database.atomicWrite(() async {
      await store.requireState(lease.space, lease);
      final operation = (await operations(
        lease.space,
      )).where((item) => item.id == operationId).firstOrNull;
      if (operation == null || operation.state == 'applied') {
        throw const DomainError('assets.operation_unavailable');
      }
      await _write(
        lease,
        operation.withState('abandoned', operation.errorCode),
      );
      lease.check();
    });
  }

  Future<void> _write(
    SyncLease lease,
    AssetConfigOperation operation,
  ) => store.repository.writeSetting(
    '${AssetConfigStore.outboxPrefix(lease.space)}${lease.epoch}.${lease.clientId}.${operation.id}',
    jsonEncode(operation.toJson()),
  );

  void _bound(
    AssetConfigOperation operation,
    DataSpace space,
    String client,
    String epoch,
  ) {
    final body = operation.body;
    if (body['client_id'] != client ||
        body['instance_id'] != space.serverInstanceId ||
        body['sync_epoch'] != epoch) {
      throw const DomainError('assets.identity_mismatch');
    }
  }

  Future<void> _recovery(SyncLease lease, ApiFailure error) async {
    if (!_rebuildErrors.contains(error.code)) return;
    lease.check();
    await SyncStore(store.repository).requireRebuild(lease.space, error.code);
    lease.check();
  }

  static const _rebuildErrors = {
    'epoch_changed',
    'resync_required',
    'client_mismatch',
    'cursor_expired',
  };
}

String _frozenJson(Map<String, Object?> value) {
  Object? sorted(Object? item) {
    if (item == null || item is String || item is bool) return item;
    if (item is int && item >= 0 && item <= 2147483647) return item;
    if (item is List) return item.map(sorted).toList();
    if (item is Map<String, Object?>) {
      final keys = item.keys.toList()..sort();
      return {for (final key in keys) key: sorted(item[key])};
    }
    throw const DomainError('assets.invalid_data');
  }

  return jsonEncode(sorted(value));
}
