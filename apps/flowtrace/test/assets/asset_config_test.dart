import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/assets/asset_config_repository.dart';
import 'package:flowtrace/data/assets/asset_config_store.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/domain/assets/asset_catalog.dart';
import 'package:flowtrace/domain/assets/asset_config.dart';

import '../ledger/query_fixtures.dart';

void main() {
  late QueryFixture f;
  late AssetConfigStore store;
  late AssetConfigRepository repository;
  late SyncLease lease;
  late bool current;
  late int authorizations;
  late SyncRequest request;
  final groupId = qid(501);
  Map<String, Object?> groups({
    String revision = '1',
    String? operation,
    String name = '日常',
    bool empty = false,
  }) => {
    'instance_id': f.space.serverInstanceId,
    'sync_epoch': qEpoch,
    'revision': revision,
    'operation_id': ?operation,
    'groups': [
      if (!empty)
        {'id': groupId, 'name': name, 'sort_order': 0, 'revision': revision},
    ],
  };
  AssetConfigRepository reopened() => AssetConfigRepository(
    AssetConfigStore(LocalRepository(f.db)),
    refreshPermissions: (_) async {
      authorizations++;
    },
  );
  Future<bool> accept(Map<String, Object?> body) => store.acceptSection(
    lease,
    AssetConfigSectionSnapshot.fromJson(AssetConfigSection.groups, body),
  );
  setUp(() async {
    f = QueryFixture();
    await f.seed();
    store = AssetConfigStore(f.local);
    current = true;
    authorizations = 0;
    request = (method, path, {body, bodyJson}) async => groups();
    lease = SyncLease(
      space: f.space,
      clientId: qid(5),
      epoch: qEpoch,
      isCurrent: () => current,
      request: (method, path, {body, bodyJson}) =>
          request(method, path, body: body, bodyJson: bodyJson),
    );
    repository = reopened();
  });
  tearDown(() => f.db.close());

  test(
    'private group requires confirmed complete same-identity list',
    () async {
      await expectLater(
        store.requireConfirmedGroup(f.space, groupId),
        throwsA(isA<DomainError>()),
      );
      await repository.refresh(lease, AssetConfigSection.groups);
      await store.requireConfirmedGroup(f.space, groupId);
      expect(authorizations, 1);
      final changedClient = SyncLease(
        space: f.space,
        clientId: qid(6),
        epoch: qEpoch,
        request: lease.request,
        isCurrent: () => true,
      );
      await expectLater(
        store.acceptSection(
          changedClient,
          AssetConfigSectionSnapshot.fromJson(
            AssetConfigSection.groups,
            groups(),
          ),
        ),
        throwsA(isA<DomainError>()),
      );
    },
  );

  test(
    'lost reply reopens and retries identical bytes and operation ID',
    () async {
      final sent = <String>[];
      var fail = true;
      request = (method, path, {body, bodyJson}) async {
        expect(method, 'POST');
        expect(path, '/assets/groups');
        expect(body, isNull);
        sent.add(bodyJson!);
        if (fail) {
          throw const ApiFailure(
            'network_unavailable',
            'offline',
            offline: true,
          );
        }
        final request = jsonDecode(bodyJson) as Map;
        expect(request['base_revision'], '0');
        return groups(operation: request['operation_id'] as String);
      };
      await expectLater(
        repository.createGroup(lease, name: '日常', groupId: groupId),
        throwsA(isA<ApiFailure>()),
      );
      final pending = (await repository.operations(f.space)).single;
      expect(pending.state, 'retry');
      fail = false;
      final reopenedRepository = reopened();
      final applied = await reopenedRepository.retry(lease, pending.id);
      expect(applied.state, 'applied');
      expect(sent, [pending.bodyJson, pending.bodyJson]);
      await store.requireConfirmedGroup(f.space, groupId);
      await reopenedRepository.retry(lease, pending.id);
      expect(sent, hasLength(2));
      expect((await f.db.select(f.db.pendingOperations).get()), isEmpty);
    },
  );

  test(
    'old replay marks applied without replacing a higher cache revision',
    () async {
      request = (method, path, {body, bodyJson}) async {
        final command = jsonDecode(bodyJson!) as Map;
        await accept(groups(revision: '9', name: '新名称'));
        return groups(
          operation: command['operation_id'] as String,
          name: '旧名称',
        );
      };
      await repository.createGroup(lease, name: '旧名称', groupId: groupId);
      final cached = await store.readSection(
        f.space,
        AssetConfigSection.groups,
      );
      expect(cached!.revision, '9');
      expect(cached.groups.single.name, '新名称');
    },
  );

  test(
    'conflict retains exact bytes and requires explicit abandonment before new intent',
    () async {
      request = (method, path, {body, bodyJson}) async =>
          throw const ApiFailure(
            'asset_config_conflict',
            'conflict',
            status: 409,
          );
      await expectLater(
        repository.createGroup(lease, name: '旧输入'),
        throwsA(isA<ApiFailure>()),
      );
      final conflict = (await repository.operations(f.space)).single;
      expect(conflict.state, 'conflict');
      await expectLater(
        repository.createGroup(lease, name: '新输入'),
        throwsA(isA<DomainError>()),
      );
      await repository.abandon(lease, conflict.id);
      final retained = (await repository.operations(f.space)).single;
      expect(retained.bodyJson, conflict.bodyJson);
      expect(retained.state, 'abandoned');
    },
  );

  test(
    'delete is blocked by current or older queued account reference',
    () async {
      await accept(groups());
      final account = await (f.db.select(
        f.db.localEntities,
      )..where((row) => row.entityId.equals(qCash))).getSingle();
      final data = jsonDecode(account.dataJson) as Map<String, dynamic>;
      final payload = (data['payload'] as Map).cast<String, Object?>();
      payload['group_id'] = groupId;
      await (f.db.update(
        f.db.localEntities,
      )..where((row) => row.entityId.equals(qCash))).write(
        LocalEntitiesCompanion(
          dataJson: Value(jsonEncode({...data, 'payload': payload})),
        ),
      );
      await expectLater(
        repository.deleteGroup(lease, groupId),
        throwsA(isA<DomainError>()),
      );
      expect(await repository.operations(f.space), isEmpty);
      payload['group_id'] = null;
      await (f.db.update(
        f.db.localEntities,
      )..where((row) => row.entityId.equals(qCash))).write(
        LocalEntitiesCompanion(
          dataJson: Value(jsonEncode({...data, 'payload': payload})),
        ),
      );
      await f.local.saveEntityAndQueue(
        f.space,
        QueuedCommand(
          operationId: qid(502),
          scopeId: qUser,
          entityType: 'account',
          entityId: qCash,
          action: 'update',
          baseRevision: '1',
          payload: {...payload, 'group_id': groupId},
        ),
      );
      // A later projected intent removed the group, but the older unsent one still references it.
      await (f.db.update(
        f.db.localEntities,
      )..where((row) => row.entityId.equals(qCash))).write(
        LocalEntitiesCompanion(
          dataJson: Value(jsonEncode({...data, 'payload': payload})),
        ),
      );
      await expectLater(
        repository.deleteGroup(lease, groupId),
        throwsA(isA<DomainError>()),
      );
    },
  );

  test(
    'queued deletion blocks new account references and explicit abandon restores choice',
    () async {
      await accept(groups());
      request = (method, path, {body, bodyJson}) async =>
          throw const ApiFailure(
            'network_unavailable',
            'offline',
            offline: true,
          );
      await expectLater(
        repository.deleteGroup(lease, groupId),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        store.requireConfirmedGroup(f.space, groupId),
        throwsA(isA<DomainError>()),
      );
      final pending = (await repository.operations(f.space)).single;
      await repository.abandon(lease, pending.id);
      await store.requireConfirmedGroup(f.space, groupId);
    },
  );

  test(
    'identity switch during request never applies response or changes frozen queue',
    () async {
      request = (method, path, {body, bodyJson}) async {
        current = false;
        return groups(
          operation: (jsonDecode(bodyJson!) as Map)['operation_id'] as String,
        );
      };
      await expectLater(
        repository.createGroup(lease, name: '保留输入'),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        await store.readSection(f.space, AssetConfigSection.groups),
        isNull,
      );
      expect((await repository.operations(f.space)).single.state, 'queued');
    },
  );

  test(
    'epoch error backs up configuration and frozen request then stops replay',
    () async {
      await accept(groups());
      request = (method, path, {body, bodyJson}) async =>
          throw const ApiFailure('epoch_changed', 'restore', status: 409);
      await expectLater(
        repository.createGroup(lease, name: '不能自动重放'),
        throwsA(isA<ApiFailure>()),
      );
      expect((await f.sync.state(f.space))!.status, 'recovery_required');
      final backups = await f.db.select(f.db.syncRecoveryBackups).get();
      expect(backups, hasLength(1));
      final saved = jsonDecode(backups.single.dataJson) as Map;
      final configuration = (saved['asset_configuration'] as List).cast<Map>();
      expect(
        configuration.any(
          (row) => (row['key'] as String).startsWith(
            AssetConfigStore.configPrefix(f.space),
          ),
        ),
        isTrue,
      );
      expect(
        configuration.any(
          (row) => (row['key'] as String).startsWith(
            AssetConfigStore.outboxPrefix(f.space),
          ),
        ),
        isTrue,
      );
      await expectLater(
        repository.refresh(lease, AssetConfigSection.groups),
        throwsA(isA<DomainError>()),
      );
    },
  );

  test(
    'malformed or mismatched reply does not mark applied or replace cache',
    () async {
      await accept(groups());
      request = (method, path, {body, bodyJson}) async => {
        ...groups(revision: '2', operation: qid(999)),
        'unexpected': true,
      };
      await expectLater(
        repository.createGroup(lease, name: '输入'),
        throwsA(isA<DomainError>()),
      );
      expect((await repository.operations(f.space)).single.state, 'queued');
      expect(
        (await store.readSection(f.space, AssetConfigSection.groups))!.revision,
        '1',
      );
    },
  );

  test(
    'concurrent submissions serialize one frozen configuration intent',
    () async {
      final entered = Completer<void>(),
          finish = Completer<Map<String, Object?>>();
      request = (method, path, {body, bodyJson}) async {
        entered.complete();
        return finish.future;
      };
      final first = repository.createGroup(lease, name: '唯一请求');
      await entered.future;
      await expectLater(
        repository.createGroup(lease, name: '重复点击'),
        throwsA(isA<DomainError>()),
      );
      final operation = (await repository.operations(f.space)).single;
      finish.complete(groups(operation: operation.id));
      expect((await first).state, 'applied');
    },
  );

  test(
    'all configuration sections share base revision but retain separate snapshots',
    () async {
      await accept(groups(revision: '5'));
      request = (method, path, {body, bodyJson}) async {
        final body = jsonDecode(bodyJson!) as Map;
        expect(path, '/currencies/preferences');
        expect(body['base_revision'], '5');
        return {
          'instance_id': f.space.serverInstanceId,
          'sync_epoch': qEpoch,
          'revision': '6',
          'operation_id': body['operation_id'],
          'preferences': body['preferences'],
        };
      };
      await repository.savePreferences(
        lease,
        CurrencyPreferences(baseCurrency: 'USD', enabledCodes: ['CNY', 'USD']),
      );
      expect(
        (await store.readSection(f.space, AssetConfigSection.groups))!.revision,
        '5',
      );
      expect(
        (await store.readSection(
          f.space,
          AssetConfigSection.preferences,
        ))!.revision,
        '6',
      );
      expect(await accept(groups(revision: '4')), isFalse);
      expect(
        (await store.readSection(f.space, AssetConfigSection.groups))!.revision,
        '5',
      );
    },
  );

  test('typed configuration rejects duplicate rates and unknown fields', () {
    final response = {
      'instance_id': f.space.serverInstanceId,
      'sync_epoch': qEpoch,
      'revision': '2',
      'rates': [
        for (var i = 0; i < 2; i++)
          {
            'id': qid(600 + i),
            'from_currency': 'USD',
            'to_currency': 'CNY',
            'effective_date': '2026-10-21',
            'rate': '7.000000000000000001',
            'rate_source': '手动',
            'revision': '2',
          },
      ],
    };
    expect(
      () => AssetConfigSectionSnapshot.fromJson(
        AssetConfigSection.rates,
        response,
      ),
      throwsA(isA<DomainError>()),
    );
    expect(
      () => CurrencyPreferences.fromJson({
        'base_currency': 'CNY',
        'enabled_codes': ['CNY'],
        'valuation_policy': 'auto',
      }),
      throwsA(isA<DomainError>()),
    );
  });

  test('bank and provider catalogs exactly match fixed shared fixture', () {
    final fixture =
        jsonDecode(
              File(
                '../../contracts/fixtures/assets/catalogs.json',
              ).readAsStringSync(),
            )
            as Map;
    final banks = fixture['banks'] as List,
        providers = fixture['providers'] as List;
    expect(assetBanks, {
      for (final row in banks) (row as Map)['id']: row['name'],
    });
    expect(assetProviders.length, providers.length);
    for (final row in providers.cast<Map>()) {
      expect(assetProviders[row['id']]!.name, row['name']);
      expect(assetProviders[row['id']]!.kind, row['kind']);
    }
    expect(assetBanks.length, 11);
    expect(assetProviders.length, 39);
  });
}
