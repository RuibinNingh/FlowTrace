import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/data/assets/asset_config_store.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/domain/assets/asset_config.dart';
import 'package:flowtrace/features/entry/entry_page.dart';

import 'entry_page_test.dart' show setupApp, bookId, categoryId;

const cash = 'ab000000-0000-4000-8000-000000000001';
const credit = 'ab000000-0000-4000-8000-000000000002';
Map<String, Object?> money(String minor, [String currency = 'CNY']) => {
  'currency': currency,
  'currency_scale': 2,
  'amount_minor': minor,
};
Future<void> accounts(AppController app, {bool foreign = false}) async {
  for (final item in [
    (cash, '零钱', 'cash', '10000', 'CNY'),
    (
      credit,
      foreign ? '欧元账户' : '信用卡',
      foreign ? 'bank' : 'credit_card',
      foreign ? '0' : '-3000',
      foreign ? 'EUR' : 'CNY',
    ),
  ]) {
    await app.ledger.save(
      app.space!,
      entityType: 'account',
      scopeId: app.space!.userId,
      entityId: item.$1,
      payload: {
        'name': item.$2,
        'kind': item.$3,
        'opening': money(item.$4, item.$5),
        'include_in_net_assets': true,
        'hidden': false,
      },
    );
  }
}

Future<void> open(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => page),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  // Both ledger and preference snapshots are sequential native SQLite reads.
  // Drain each completion outside the widget fake clock before settling UI.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    if (find.byKey(const Key('entry-key-保存')).evaluate().isNotEmpty) break;
  }
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String label, String name) async {
  final field = find.byWidgetPredicate(
    (widget) =>
        widget is DropdownButtonFormField<String> &&
        widget.decoration.labelText == label,
  );
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

Future<void> close(WidgetTester tester, AppController app) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  app.dispose();
  await tester.runAsync(app.database.close);
}

void main() {
  testWidgets(
    'common currencies are ordered first while original and other supported currencies remain selectable',
    (tester) async {
      final app = (await tester.runAsync(
        () => setupApp(instance: 'fa000000-0000-4000-8000-000000000099'),
      ))!;
      const clientId = 'fa000000-0000-4000-8000-000000000088';
      const epochId = 'fa000000-0000-4000-8000-000000000077';
      await tester.runAsync(() async {
        await SyncStore(
          app.repository,
        ).configure(app.space!, clientId, epochId);
        final lease = SyncLease(
          space: app.space!,
          clientId: clientId,
          epoch: epochId,
          isCurrent: () => true,
          request: (method, path, {body, bodyJson}) async {
            throw StateError('Preference selection must stay local.');
          },
        );
        await AssetConfigStore(app.repository).acceptSection(
          lease,
          AssetConfigSectionSnapshot.fromJson(AssetConfigSection.preferences, {
            'instance_id': app.space!.serverInstanceId,
            'sync_epoch': epochId,
            'revision': '1',
            'preferences': {
              'base_currency': 'CNY',
              'enabled_codes': ['JPY', 'USD', 'CNY'],
              'valuation_policy': 'exact_date',
            },
          }),
        );
      });
      await open(
        tester,
        EntryPage(app: app, space: app.space!, bookId: bookId),
      );
      final selector = tester.widget<DropdownButton<String>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is DropdownButton<String> && widget.items?.length == 165,
        ),
      );
      expect(selector.items!.take(3).map((item) => item.value), [
        'JPY',
        'USD',
        'CNY',
      ]);
      expect(selector.value, 'CNY');
      expect(selector.items!.any((item) => item.value == 'KWD'), isTrue);
      await close(tester, app);
    },
  );
  testWidgets(
    'metadata edit preserves independently denominated fee and both historical reporting sources',
    (tester) async {
      final app = (await tester.runAsync(setupApp))!;
      await tester.runAsync(() => accounts(app, foreign: true));
      const id = 'ab000000-0000-4000-8000-000000000008';
      final fee = {
        'money': money('100', 'EUR'),
        'account_id': credit,
        'category_id': categoryId,
        'flags': {
          'exclude_from_statistics': true,
          'exclude_from_budget': false,
        },
        'reporting': {
          'rate': '7.25',
          'rate_date': '2026-09-29',
          'rate_source': '手续费历史来源',
          'report_currency': 'CNY',
          'report_scale': 2,
          'report_amount_minor': '725',
        },
      };
      const principalReporting = {
        'rate': '1',
        'rate_date': '2026-09-28',
        'rate_source': '同币原始来源',
        'report_currency': 'CNY',
        'report_scale': 2,
        'report_amount_minor': '10000',
      };
      await tester.runAsync(
        () => app.ledger.save(
          app.space!,
          entityType: 'bill',
          scopeId: bookId,
          entityId: id,
          payload: {
            'bill_type': 'transfer',
            'money': money('10000'),
            'from_account_id': cash,
            'to_account_id': credit,
            'target_money': money('1250', 'EUR'),
            'business_date': '2026-10-01',
            'business_timezone': 'Asia/Shanghai',
            'reporting': principalReporting,
            'fee': fee,
            'transfer_fx': {
              'rate': '0.125',
              'rate_date': '2026-09-30',
              'rate_source': '原转账来源',
            },
          },
        ),
      );
      final existing = (await app.ledger.read(app.space!)).find('bill', id)!;
      await open(
        tester,
        EntryPage(
          app: app,
          space: app.space!,
          bookId: bookId,
          existing: existing,
        ),
      );
      await tester.enterText(find.byKey(const Key('entry-note')), '保留独立手续费');
      await tester.tap(find.byKey(const Key('entry-key-保存')));
      await tester.pumpAndSettle();
      final view = await app.ledger.read(app.space!);
      final row = view.find('bill', id)!;
      expect((row.payload['fee'] as Map)['account_id'], isNull);
      final payload = row.editablePayload!;
      expect(payload['note'], '保留独立手续费');
      expect(payload['fee'], fee);
      expect(payload['reporting'], principalReporting);
      expect(view.balances[credit]!.value!.minor.toString(), '1150');
      await close(tester, app);
    },
  );
  testWidgets(
    'credit repayment saves two signed principal movements without an income bill',
    (tester) async {
      final app = (await tester.runAsync(setupApp))!;
      await tester.runAsync(() => accounts(app));
      await open(
        tester,
        EntryPage(
          app: app,
          space: app.space!,
          bookId: bookId,
          initialType: 'credit_repayment',
          initialAccountId: credit,
        ),
      );
      await choose(tester, '转出账户', '零钱');
      for (final key in ['1', '0']) {
        await tester.tap(find.byKey(Key('entry-key-$key')));
      }
      await tester.tap(find.byKey(const Key('entry-key-保存')));
      await tester.pumpAndSettle();
      final view = await app.ledger.read(app.space!);
      expect(view.bills.single.payload['bill_type'], 'credit_repayment');
      expect(view.balances[cash]!.value!.minor.toString(), '9000');
      expect(view.balances[credit]!.value!.minor.toString(), '-2000');
      await close(tester, app);
    },
  );

  testWidgets(
    'balance adjustment derives and records signed difference from target',
    (tester) async {
      final app = (await tester.runAsync(setupApp))!;
      await tester.runAsync(() => accounts(app));
      await open(
        tester,
        EntryPage(
          app: app,
          space: app.space!,
          bookId: bookId,
          initialType: 'balance_adjustment',
          initialAccountId: cash,
        ),
      );
      final target = find.byKey(const Key('entry-adjustment-target'));
      await tester.ensureVisible(target);
      await tester.enterText(target, '95.00');
      await tester.tap(find.byKey(const Key('entry-key-保存')));
      await tester.pumpAndSettle();
      final view = await app.ledger.read(app.space!);
      expect(view.bills.single.payload['bill_type'], 'balance_adjustment');
      expect(
        (view.bills.single.payload['money'] as Map)['amount_minor'],
        '500',
      );
      expect(view.bills.single.payload['target_balance_minor'], '9500');
      expect(view.balances[cash]!.value!.minor.toString(), '9500');
      await close(tester, app);
    },
  );

  testWidgets(
    'cross currency transfer requires its own rate and freezes both amounts',
    (tester) async {
      final app = (await tester.runAsync(setupApp))!;
      await tester.runAsync(() => accounts(app, foreign: true));
      await open(
        tester,
        EntryPage(
          app: app,
          space: app.space!,
          bookId: bookId,
          initialType: 'transfer',
          initialAccountId: cash,
        ),
      );
      await choose(tester, '转入账户', '欧元账户');
      for (final key in ['1', '0', '0']) {
        await tester.tap(find.byKey(Key('entry-key-$key')));
      }
      final target = find.byKey(const Key('entry-target-money'));
      await tester.ensureVisible(target);
      await tester.enterText(target, '12.50');
      await tester.tap(find.byKey(const Key('entry-key-保存')));
      await tester.pumpAndSettle();
      expect((await app.ledger.read(app.space!)).bills, isEmpty);
      expect(find.text('请填写本次转出到转入币种的冻结汇率。'), findsOneWidget);
      final rate = find.byKey(const Key('entry-transfer-rate'));
      await tester.ensureVisible(rate);
      await tester.enterText(rate, '0.125');
      await tester.tap(find.byKey(const Key('entry-key-保存')));
      await tester.pumpAndSettle();
      final view = await app.ledger.read(app.space!);
      final payload = view.bills.single.payload;
      expect(payload['target_money'], money('1250', 'EUR'));
      expect((payload['transfer_fx'] as Map)['rate'], '0.125');
      expect(
        (payload['transfer_fx'] as Map)['rate_date'],
        payload['business_date'],
      );
      expect(view.balances[cash]!.value!.minor.toString(), '0');
      expect(view.balances[credit]!.value!.minor.toString(), '1250');
      await close(tester, app);
    },
  );

  testWidgets(
    'resumed editing draft retains historical transfer rate date and source',
    (tester) async {
      final app = (await tester.runAsync(setupApp))!;
      await tester.runAsync(() => accounts(app, foreign: true));
      const id = 'ab000000-0000-4000-8000-000000000004';
      await tester.runAsync(
        () => app.ledger.save(
          app.space!,
          entityType: 'bill',
          scopeId: bookId,
          entityId: id,
          payload: {
            'bill_type': 'transfer',
            'money': money('10000'),
            'from_account_id': cash,
            'to_account_id': credit,
            'target_money': money('1250', 'EUR'),
            'business_date': '2026-10-01',
            'business_timezone': 'Asia/Shanghai',
            'transfer_fx': {
              'rate': '0.125',
              'rate_date': '2026-09-30',
              'rate_source': '历史银行记录',
            },
          },
        ),
      );
      final existing = (await app.ledger.read(app.space!)).find('bill', id)!;
      await open(
        tester,
        EntryPage(
          app: app,
          space: app.space!,
          bookId: bookId,
          existing: existing,
        ),
      );
      await tester.enterText(find.byKey(const Key('entry-note')), '仅修改备注');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final draft = (await tester.runAsync(
        () => app.ledger.watchDrafts(app.space!).first,
      ))!.single;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await open(
        tester,
        EntryPage(app: app, space: app.space!, bookId: bookId, draft: draft),
      );
      await tester.tap(find.byKey(const Key('entry-key-保存')));
      await tester.pumpAndSettle();
      final payload = (await app.ledger.read(
        app.space!,
      )).find('bill', id)!.payload;
      expect(payload['note'], '仅修改备注');
      expect(payload['transfer_fx'], {
        'rate': '0.125',
        'rate_date': '2026-09-30',
        'rate_source': '历史银行记录',
      });
      await close(tester, app);
    },
  );
}
