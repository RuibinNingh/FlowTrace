import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/money/currency_catalog.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/data/ledger/ledger_projection.dart';
import 'package:flowtrace/data/ledger/ledger_repository.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_store.dart';

import '../ledger/ledger_repository_test.dart'
    show
        uid,
        spaceFor,
        money,
        bookData,
        accountData,
        expense,
        book,
        account,
        bill,
        epoch,
        client;

void main() {
  final space = spaceFor();
  late AppDatabase database;
  late LocalRepository local;
  late LedgerRepository ledger;
  late SyncStore sync;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    local = LocalRepository(database);
    ledger = LedgerRepository(local);
    sync = SyncStore(local);
    await local.registerSpace(space);
    await sync.configure(space, client, epoch);
    await ledger.save(
      space,
      entityType: 'book',
      scopeId: space.userId,
      entityId: book,
      payload: bookData(),
    );
  });
  tearDown(() => database.close());

  Future<void> saveAccount(Map<String, Object?> data, [String? id]) async {
    await ledger.save(
      space,
      entityType: 'account',
      scopeId: space.userId,
      entityId: id ?? account,
      payload: data,
    );
  }

  Future<void> saveBill(Map<String, Object?> data, [String? id]) async {
    await ledger.save(
      space,
      entityType: 'bill',
      scopeId: book,
      entityId: id ?? bill,
      payload: data,
    );
  }

  Matcher code(String value) =>
      throwsA(isA<DomainError>().having((e) => e.code, 'code', value));
  Future<int> operationCount() async =>
      (await database.select(database.pendingOperations).get()).length;
  Map<String, Object?> transfer({String target = '1250', Object? fx}) => {
    ...expense('10000'),
    'bill_type': 'transfer',
    'account_id': null,
    'from_account_id': account,
    'to_account_id': uid(31),
    'target_money': money(target, currency: 'EUR'),
    'transfer_fx': ?fx,
  };
  const fx = {
    'rate': '0.125',
    'rate_date': '2026-10-21',
    'rate_source': 'manual',
  };
  Future<void> transferAccounts() async {
    await saveAccount(accountData());
    await saveAccount({
      ...accountData('0'),
      'opening': money('0', currency: 'EUR'),
    }, uid(31));
  }

  test(
    'frozen ISO catalog equals all 165 shared entries and keeps old precision',
    () {
      final fixture =
          jsonDecode(
                File(
                  '../../contracts/fixtures/assets/catalogs.json',
                ).readAsStringSync(),
              )
              as Map;
      final catalog = fixture['currency_catalog'] as Map;
      final rows = catalog['currencies'] as List;
      expect(rows, hasLength(165));
      expect(currencyScales, {
        for (final row in rows) row['code'] as String: row['scale'] as int,
      });
      expect(currencyNames, {
        for (final row in rows) row['code'] as String: row['name'] as String,
      });
      expect(currencyCatalogDate, catalog['catalog_date']);
      expect(currencyCatalogSource, catalog['source']);
      expect(currencyCatalogSourceSha256, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(currencyScales['CNY'], 2);
      expect(currencyScales['JPY'], 0);
      expect(currencyScales['KWD'], 3);
      expect(currencyScales['CLF'], 4);
      expect(currencyScales.containsKey('XAU'), isFalse);
    },
  );

  test(
    'old account form preserves credit, date and optional metadata',
    () async {
      final advanced = {
        ...accountData('-1000', 'credit_card'),
        'opening_date': '2026-10-01',
        'note': '卡片资料',
        'sort_order': 20,
        'card_last_four': '0123',
        'credit': {
          'limit': money('200000'),
          'statement_day': 31,
          'statement_day_inclusive': false,
          'due_mode': 'days_after',
          'due_days': 25,
          'due_day': null,
        },
      };
      await saveAccount(advanced);
      await saveAccount({
        ...accountData('-1000', 'credit_card'),
        'name': '新名称',
      });
      final row = (await ledger.read(space)).find('account', account)!;
      for (final key in [
        'opening_date',
        'note',
        'sort_order',
        'card_last_four',
        'credit',
      ]) {
        expect(row.payload[key], advanced[key]);
      }
    },
  );

  test(
    'explicit null cannot masquerade as an omitted nonnullable account field',
    () async {
      final before = await operationCount();
      for (final key in ['sort_order', 'archived', 'icon', 'note']) {
        await expectLater(
          saveAccount({...accountData(), key: null}),
          throwsA(isA<DomainError>()),
        );
      }
      await expectLater(
        saveAccount({
          ...accountData('0', 'credit_card'),
          'credit': {'statement_day_inclusive': null},
        }),
        throwsA(isA<DomainError>()),
      );
      await expectLater(
        saveAccount({...accountData(), 'name': '   '}),
        throwsA(isA<DomainError>()),
      );
      expect(await operationCount(), before);
      expect((await ledger.read(space)).accounts, isEmpty);
    },
  );

  test(
    'used opening amount and unknown historical opening date cannot change',
    () async {
      await saveAccount(accountData());
      await saveBill(expense('125'));
      final before = await operationCount();
      await expectLater(
        saveAccount(accountData('10001')),
        code('account.definition_in_use'),
      );
      await expectLater(
        saveAccount({...accountData(), 'opening_date': '2026-10-01'}),
        code('account.definition_in_use'),
      );
      expect(await operationCount(), before);
      expect(
        (await ledger.read(space)).balances[account]!.value!.minor.toString(),
        '9875',
      );
      await saveAccount({...accountData(), 'name': '仅改名称'});
    },
  );

  test(
    'archived account rejects new references and retains existing bill edits',
    () async {
      await saveAccount(accountData());
      await saveBill(expense('125'));
      await saveAccount({...accountData(), 'archived': true});
      final before = await operationCount();
      await expectLater(
        saveBill(expense('50'), uid(35)),
        code('account.archived'),
      );
      expect(await operationCount(), before);
      await saveBill({...expense('125'), 'note': '已有账户引用保留'});
      expect(
        (await ledger.read(space)).bills.single.payload['note'],
        '已有账户引用保留',
      );
    },
  );

  test('funds cannot be recorded before a known opening day', () async {
    await saveAccount({...accountData(), 'opening_date': '2026-10-22'});
    final before = await operationCount();
    await expectLater(saveBill(expense('125')), code('account.before_opening'));
    expect(await operationCount(), before);
    expect((await ledger.read(space)).bills, isEmpty);
  });

  test(
    'cross currency frozen rate survives old metadata forms and cannot be cleared',
    () async {
      await transferAccounts();
      await saveBill(transfer(fx: fx));
      await saveBill({...transfer(), 'note': '只改备注'});
      var view = await ledger.read(space);
      expect(view.bills.single.payload['transfer_fx'], fx);
      expect(view.balances[account]!.value!.minor.toString(), '0');
      expect(view.balances[uid(31)]!.value!.minor.toString(), '1250');
      final before = await operationCount();
      await expectLater(
        saveBill({...transfer(), 'transfer_fx': null}),
        code('fx.frozen_rate_required'),
      );
      await expectLater(
        saveBill(transfer(target: '1251')),
        code('fx.amount_mismatch'),
      );
      expect(await operationCount(), before);
      view = await ledger.read(space);
      expect(
        view.bills.single.payload['target_money'],
        money('1250', currency: 'EUR'),
      );
    },
  );

  test(
    'invalid frozen rate, extra keys and rate on a single-account bill roll back',
    () async {
      await transferAccounts();
      final before = await operationCount();
      await expectLater(
        saveBill(transfer(fx: {...fx, 'rate': '0'})),
        code('fx.rate_invalid'),
      );
      await expectLater(
        saveBill(transfer(fx: {...fx, 'hidden': true})),
        code('ledger.unknown_field'),
      );
      await expectLater(
        saveBill({...expense('125'), 'transfer_fx': fx}),
        code('bill.transfer_fields_not_allowed'),
      );
      expect(await operationCount(), before);
    },
  );

  test(
    'a changed frozen rate changes financial fingerprints including move comparison',
    () {
      final original = transfer(fx: fx);
      expect(
        financialFingerprint(original),
        isNot(
          financialFingerprint(transfer(fx: {...fx, 'rate_source': 'other'})),
        ),
      );
      expect(
        financialFingerprint(original),
        financialFingerprint({...original, 'note': '元数据'}),
      );
    },
  );

  test(
    'unconfirmed REST group never creates an account or sync dependency',
    () async {
      final before = await operationCount();
      await expectLater(
        saveAccount({...accountData(), 'group_id': uid(40)}),
        code('assets.group_unconfirmed'),
      );
      expect(await operationCount(), before);
      expect((await ledger.read(space)).accounts, isEmpty);
    },
  );

  test(
    'prepaid and investment remain ordinary fund sides for debt actions',
    () async {
      await saveAccount(accountData('10000', 'prepaid'));
      await saveAccount(accountData('0', 'loan_receivable'), uid(31));
      await saveBill({
        ...expense('100'),
        'bill_type': 'loan_lend',
        'account_id': null,
        'from_account_id': account,
        'to_account_id': uid(31),
      });
      var view = await ledger.read(space);
      expect(view.balances[account]!.value!.minor.toString(), '9900');
      expect(view.balances[uid(31)]!.value!.minor.toString(), '100');
      await saveAccount(accountData('0', 'investment'), uid(32));
      await saveBill({
        ...expense('100'),
        'bill_type': 'loan_collect',
        'account_id': null,
        'from_account_id': uid(31),
        'to_account_id': uid(32),
      }, uid(33));
      view = await ledger.read(space);
      expect(view.balances[uid(31)]!.value!.minor.toString(), '0');
      expect(view.balances[uid(32)]!.value!.minor.toString(), '100');
    },
  );

  test(
    'recovery preserves asset cache and frozen queue across old epochs only in this space',
    () async {
      final own = {
        'assets.config.v1.${space.id}.$epoch.$client.groups':
            '{"revision":"9"}',
        'assets.outbox.v1.${space.id}.${uid(88)}.$client.${uid(89)}':
            '{"bodyJson":"frozen"}',
      };
      for (final entry in own.entries) {
        await local.writeSetting(entry.key, entry.value);
      }
      await local.writeSetting(
        'assets.config.v1.${spaceFor(2).id}.foreign',
        'other-user',
      );
      final readKey = 'assets.read.v1.${space.id}.$epoch.$client.synthetic';
      await local.writeSetting(readKey, 'last-authorized-read');
      await sync.requireRebuild(space, 'asset-test');
      final backups = await database.select(database.syncRecoveryBackups).get();
      final saved = jsonDecode(backups.single.dataJson) as Map;
      final settings = saved['asset_configuration'] as List;
      expect({for (final row in settings) row['key']: row['value']}, own);
      expect(
        (saved['asset_read_cache'] as List).single['value'],
        'last-authorized-read',
      );
      for (final entry in own.entries) {
        expect(await local.readSetting(entry.key), entry.value);
      }
    },
  );

  test(
    'scope revocation drops controlled asset reads and increments nonce without changing user commands',
    () async {
      final readKey = 'assets.read.v1.${space.id}.$epoch.$client.synthetic';
      final otherRead = 'assets.read.v1.${spaceFor(2).id}.synthetic';
      final command = 'assets.outbox.v1.${space.id}.$epoch.$client.${uid(50)}';
      await local.writeSetting(readKey, 'old-authorized-body');
      await local.writeSetting(otherRead, 'other-user-body');
      await local.writeSetting(command, 'frozen-private-intent');
      await sync.revokeScope(space, book);
      expect(await local.readSetting(readKey), isNull);
      expect(await local.readSetting(otherRead), 'other-user-body');
      expect(await local.readSetting(command), 'frozen-private-intent');
      expect(
        await local.readSetting('assets.read.invalidate.v1.${space.id}'),
        '1',
      );
      await sync.restoreScopeAccess(space, {book});
      await sync.revokeScope(space, book);
      expect(
        await local.readSetting('assets.read.invalidate.v1.${space.id}'),
        '2',
      );
    },
  );
}
