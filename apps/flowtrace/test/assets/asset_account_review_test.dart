import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/assets/asset_config_repository.dart';
import 'package:flowtrace/data/assets/asset_config_store.dart';
import 'package:flowtrace/data/ledger/ledger_projection.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/domain/assets/asset_config.dart';

import '../ledger/query_fixtures.dart';

void main() {
  late QueryFixture f;

  setUp(() async {
    f = QueryFixture();
    await f.local.registerSpace(f.space);
    await f.sync.configure(f.space, qid(5), qEpoch);
    await f.roles();
    for (final id in [qBook, qOtherBook]) {
      await f.put('book', id, id, {
        'projection_kind': 'book',
        'payload': {
          'name': '独立资产审查',
          'currency': 'CNY',
          'timezone': 'Asia/Shanghai',
          'month_start_day': 1,
        },
      });
    }
  });
  tearDown(() => f.db.close());

  Matcher code(String value) =>
      throwsA(isA<DomainError>().having((e) => e.code, 'code', value));
  Future<int> queueSize() async =>
      (await f.db.select(f.db.pendingOperations).get()).length;
  Map<String, Object?> account(
    String amount, {
    String currency = 'CNY',
    int scale = 2,
    String? openingDate,
    bool archived = false,
  }) => {
    'name': '合成私人账户',
    'kind': 'cash',
    'opening': qmoney(amount, currency: currency, scale: scale),
    'hidden': false,
    'include_in_net_assets': true,
    'opening_date': openingDate,
    'archived': archived,
  };
  Future<void> confirmedAccount(
    String id,
    Map<String, Object?> payload, {
    Map<String, Object?>? balance,
  }) => f.put('account', id, qUser, {
    'projection_kind': 'account',
    'payload': payload,
    'balance': balance ?? payload['opening'],
  });
  Future<String> saveAccount(String id, Map<String, Object?> payload) =>
      f.ledger.save(
        f.space,
        entityType: 'account',
        scopeId: qUser,
        entityId: id,
        payload: payload,
      );
  Future<String> saveBill(String id, Map<String, Object?> payload) =>
      f.ledger.save(
        f.space,
        entityType: 'bill',
        scopeId: qBook,
        entityId: id,
        payload: {
          'book_id': qBook,
          'business_date': '2026-10-21',
          'business_timezone': 'Asia/Shanghai',
          ...payload,
        },
      );
  Map<String, Object?> transfer({
    Map<String, Object?>? money,
    Map<String, Object?>? target,
    Object? fx,
  }) => {
    'bill_type': 'transfer',
    'money': money ?? qmoney('125'),
    'from_account_id': qCash,
    'to_account_id': qBank,
    'target_money': ?target,
    'transfer_fx': ?fx,
  };

  test(
    'revoked shared bill keeps the private opening definition and balance protected',
    () async {
      final original = account('10000');
      await confirmedAccount(qCash, original, balance: qmoney('9875'));
      await f.putBill(qa, {
        'bill_type': 'expense',
        'money': qmoney('125'),
        'account_id': qCash,
        'note': '撤权后不能从私人分录找回的正文',
      });
      await f.sync.revokeScope(f.space, qBook);
      final before = await queueSize();
      final view = await f.ledger.read(f.space);
      expect(view.bills, isEmpty);
      expect(view.balances[qCash]!.value!.minor.toString(), '9875');
      final retained = await f.db.select(f.db.serverShadows).get();
      expect(retained.any((row) => row.scopeId == qBook), isFalse);
      expect(
        retained.any(
          (row) => row.scopeId == qUser && row.entityId == qa && !row.deleted,
        ),
        isTrue,
      );
      for (final changed in [
        {...original, 'opening': qmoney('10001')},
        {...original, 'opening_date': '2026-10-01'},
        {...original, 'kind': 'bank'},
      ]) {
        await expectLater(
          saveAccount(qCash, changed),
          code('account.definition_in_use'),
        );
      }
      expect(await queueSize(), before);
      await saveAccount(qCash, {...original, 'name': '允许维护账户名称'});
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.value!.minor.toString(),
        '9875',
      );
    },
  );

  test(
    'zero and three decimal accounts round HALF_UP once and retain frozen provenance',
    () async {
      await f.put('book', qBook, qBook, {
        'projection_kind': 'book',
        'payload': {
          'name': 'JPY账本',
          'currency': 'JPY',
          'timezone': 'Asia/Shanghai',
          'month_start_day': 1,
        },
      });
      await confirmedAccount(qCash, account('10', currency: 'JPY', scale: 0));
      await confirmedAccount(qBank, account('0', currency: 'KWD', scale: 3));
      const fx = {
        'rate': '0.0005',
        'rate_date': '2026-10-21',
        'rate_source': '独立固定夹具',
      };
      final original = transfer(
        money: qmoney('1', currency: 'JPY', scale: 0),
        target: qmoney('1', currency: 'KWD', scale: 3),
        fx: fx,
      );
      await saveBill(qa, original);
      final oldForm = {...original}..remove('transfer_fx');
      await saveBill(qa, {...oldForm, 'note': '旧表单仅改备注'});
      final before = await queueSize();
      await expectLater(
        saveBill(qa, {...oldForm, 'transfer_fx': null}),
        code('fx.frozen_rate_required'),
      );
      await expectLater(
        saveBill(qa, {
          ...oldForm,
          'target_money': qmoney('2', currency: 'KWD', scale: 3),
        }),
        code('fx.amount_mismatch'),
      );
      expect(await queueSize(), before);
      final view = await f.ledger.read(f.space);
      expect(
        view.balances[qCash]!.value!.toJson(),
        qmoney('9', currency: 'JPY', scale: 0),
      );
      expect(
        view.balances[qBank]!.value!.toJson(),
        qmoney('1', currency: 'KWD', scale: 3),
      );
      expect(view.bills.single.payload['transfer_fx'], fx);
    },
  );

  test(
    'target and third fee accounts enforce their own opening and archive guards atomically',
    () async {
      await confirmedAccount(qCash, account('10000'));
      await confirmedAccount(qBank, account('0', openingDate: '2026-10-22'));
      await confirmedAccount(qUsd, account('500', archived: true));
      final original = transfer();
      await expectLater(saveBill(qa, original), code('account.before_opening'));
      await confirmedAccount(qBank, account('0', archived: true));
      await expectLater(saveBill(qa, original), code('account.archived'));
      await confirmedAccount(qBank, account('0', openingDate: '2026-10-21'));
      final withFee = {
        ...original,
        'fee': {
          'money': qmoney('1'),
          'account_id': qUsd,
          'category_id': null,
          'flags': {
            'exclude_from_statistics': false,
            'exclude_from_budget': false,
          },
          'reporting': null,
        },
      };
      await expectLater(saveBill(qa, withFee), code('account.archived'));
      await confirmedAccount(qUsd, account('500', openingDate: '2026-10-22'));
      await expectLater(saveBill(qa, withFee), code('account.before_opening'));
      expect(await queueSize(), 0);
      expect((await f.ledger.read(f.space)).bills, isEmpty);
      await confirmedAccount(qUsd, account('500', openingDate: '2026-10-21'));
      await saveBill(qa, withFee);
      final balances = (await f.ledger.read(f.space)).balances;
      expect(balances[qCash]!.value!.minor.toString(), '9875');
      expect(balances[qBank]!.value!.minor.toString(), '125');
      expect(balances[qUsd]!.value!.minor.toString(), '499');
      expect(await queueSize(), 1);
    },
  );

  test(
    'hidden finance metadata editing cannot clear or rewrite transfer rate provenance',
    () async {
      const fx = {
        'rate': '0.125',
        'rate_date': '2026-10-21',
        'rate_source': '冻结原来源',
      };
      await f.putBill(qa, {
        ...transfer(
          target: qmoney('1250', currency: 'USD'),
          fx: fx,
        ),
        'money': qmoney('10000'),
        'to_account_id': qUsd,
      }, ownFinance: false);
      final initial = (await f.ledger.read(f.space)).bills.single;
      expect(initial.editablePayload, isNull);
      final oldForm = {...initial.payload}..remove('transfer_fx');
      await saveBill(qa, {
        ...oldForm,
        'note': '允许的共享备注',
        'preserve_hidden_financial_links': true,
      });
      final valid = (await f.ledger.read(f.space)).bills.single;
      expect(valid.payload['transfer_fx'], fx);
      expect(valid.payload['from_account_id'], isNull);
      expect(valid.payload['to_account_id'], isNull);
      final before = await queueSize();
      for (final changed in [
        null,
        {...fx, 'rate_source': '伪装成备注修改'},
        {...fx, 'rate_date': '2026-10-20'},
      ]) {
        await expectLater(
          saveBill(qa, {
            ...valid.payload,
            'transfer_fx': changed,
            'preserve_hidden_financial_links': true,
          }),
          code('hidden_financial_fields_changed'),
        );
      }
      expect(await queueSize(), before);
      final after = (await f.ledger.read(f.space)).bills.single;
      expect(after.payload['note'], '允许的共享备注');
      expect(
        financialFingerprint(after.payload),
        financialFingerprint(initial.payload),
      );
      expect(
        (await f.db.select(f.db.serverShadows).get()).any(
          (row) => row.scopeId == qUser && row.entityId == qa,
        ),
        isFalse,
      );
    },
  );

  for (final replaceEpoch in [false, true]) {
    test(
      'explicit recovery quarantines original configuration bytes with a new client${replaceEpoch ? ' and epoch' : ''}',
      () async {
        final store = AssetConfigStore(f.local);
        final repository = AssetConfigRepository(
          store,
          refreshPermissions: (_) async {},
        );
        final nextEpoch = replaceEpoch ? qid(800) : qEpoch;
        final nextClient = qid(801), groupId = qid(802);
        var sends = 0;
        final lease = SyncLease(
          space: f.space,
          clientId: qid(5),
          epoch: qEpoch,
          isCurrent: () => true,
          request: (method, path, {body, bodyJson}) async {
            sends++;
            throw const ApiFailure(
              'network_unavailable',
              'offline',
              offline: true,
            );
          },
        );
        Map<String, Object?> groups(
          String epoch,
          String revision, {
          String? operation,
        }) => {
          'instance_id': f.space.serverInstanceId,
          'sync_epoch': epoch,
          'revision': revision,
          'operation_id': ?operation,
          'groups': [
            {
              'id': groupId,
              'name': '待核对配置',
              'sort_order': 0,
              'revision': revision,
            },
          ],
        };
        await store.acceptSection(
          lease,
          AssetConfigSectionSnapshot.fromJson(
            AssetConfigSection.groups,
            groups(qEpoch, '7'),
          ),
        );
        await expectLater(
          repository.createGroup(lease, name: '响应丢失前输入'),
          throwsA(isA<ApiFailure>()),
        );
        final original = (await repository.operations(f.space)).single;
        final oldKey =
            '${AssetConfigStore.outboxPrefix(f.space)}$qEpoch.${qid(5)}.${original.id}';
        final oldValue = await f.local.readSetting(oldKey);
        expect(original.body['base_revision'], '7');
        expect(sends, 1);

        await f.sync.requireRebuild(f.space, 'independent-review');
        final backup =
            (await f.db.select(f.db.syncRecoveryBackups).get()).single;
        final preserved =
            (jsonDecode(backup.dataJson) as Map)['asset_configuration'] as List;
        expect(
          preserved.any(
            (row) => row['key'] == oldKey && row['value'] == oldValue,
          ),
          isTrue,
        );
        final permissions = {qUser: '1'};
        final manifestBody = <String, Object?>{
          'snapshot_id': qid(803),
          'instance_id': f.space.serverInstanceId,
          'sync_epoch': nextEpoch,
          'checkpoint': {qUser: '0'},
          'permission_versions': permissions,
          'pages': [
            {
              'page_index': 0,
              'item_count': 0,
              'sha256': syncContentHash(<Object?>[]),
            },
          ],
        };
        final manifest = SnapshotManifest.fromStatus({
          'snapshot_id': qid(803),
          'status': 'ready',
          'expires_at': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 15))
              .toIso8601String(),
          'sync_epoch': nextEpoch,
          'checkpoint': {qUser: '0'},
          'permission_versions': permissions,
          'first_page_token': 'synthetic-review-page',
          'manifest': manifestBody,
          'manifest_sha256': syncContentHash(manifestBody),
        });
        await f.sync.stageSnapshotPage(
          f.space,
          manifest,
          0,
          [],
          syncContentHash(<Object?>[]),
        );
        await f.sync.installSnapshot(
          f.space,
          manifest,
          clientId: nextClient,
          permissionVersions: permissions,
          allowRecovery: true,
        );
        expect((await f.sync.state(f.space))!.status, 'active');
        expect(
          await store.readSection(f.space, AssetConfigSection.groups),
          isNull,
        );
        expect(await repository.operations(f.space), isEmpty);
        await expectLater(
          repository.retry(lease, original.id),
          code('assets.read_only'),
        );
        final restoredLease = SyncLease(
          space: f.space,
          clientId: nextClient,
          epoch: nextEpoch,
          isCurrent: () => true,
          request: (method, path, {body, bodyJson}) async {
            sends++;
            expect(method, 'POST');
            expect(path, '/assets/groups');
            final command = jsonDecode(bodyJson!) as Map;
            expect(command['operation_id'], isNot(original.id));
            expect(command['client_id'], nextClient);
            expect(command['sync_epoch'], nextEpoch);
            expect(command['base_revision'], '0');
            return groups(
              nextEpoch,
              '1',
              operation: command['operation_id'] as String,
            );
          },
        );
        await expectLater(
          repository.retry(restoredLease, original.id),
          code('assets.operation_unavailable'),
        );
        expect(sends, 1);
        expect(await f.local.readSetting(oldKey), oldValue);
        final explicitlyNew = await repository.createGroup(
          restoredLease,
          name: '恢复后明确的新意图',
          groupId: groupId,
        );
        expect(explicitlyNew.state, 'applied');
        expect(sends, 2);
        expect(await f.local.readSetting(oldKey), oldValue);
        expect((await f.db.select(f.db.pendingOperations).get()), isEmpty);
      },
    );
  }
}
