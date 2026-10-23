import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/app/flowtrace_app.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/security/session_vault.dart';
import 'package:flowtrace/data/ledger/ledger_repository.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';
import 'package:flowtrace/features/management/management_editor.dart';

class _DisposableVault implements SessionVault {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// Deliberately rejects HTTP in this test. It does not change device networking.
class _NetworkSwitch extends http.BaseClient {
  final _inner = http.Client();
  bool blocked = false;
  int blockedRequests = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (blocked) {
      blockedRequests++;
      throw const SocketException('Synthetic isolated-client offline mode');
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

Future<void> _wait(
  WidgetTester tester,
  Future<bool> Function() ready,
  String reason,
) async {
  for (var i = 0; i < 300; i++) {
    if (await ready()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(await ready(), isTrue, reason: reason);
}

Future<void> _tapFinder(WidgetTester tester, Finder finder) async {
  await _wait(
    tester,
    () async => finder.evaluate().isNotEmpty,
    'Requested UI control was not found',
  );
  final visible = finder.hitTestable();
  final target = visible.evaluate().isEmpty ? finder.last : visible.last;
  if (visible.evaluate().isEmpty) {
    await tester.ensureVisible(target);
  }
  await _wait(
    tester,
    () async => target.hitTestable().evaluate().isNotEmpty,
    'UI control reachable after route transition',
  );
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String label) =>
    _tapFinder(tester, find.text(label));

Future<void> _input(WidgetTester tester, Finder finder, String value) async {
  await _wait(tester, () async => finder.evaluate().isNotEmpty, 'Input field');
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);

Future<void> _select(WidgetTester tester, String field, String value) async {
  await _tapFinder(
    tester,
    find.widgetWithText(DropdownButtonFormField<String>, field),
  );
  await _tap(tester, value);
}

Future<void> _drawer(WidgetTester tester, String label) async {
  await _tapFinder(tester, find.byIcon(Icons.menu));
  await _tap(tester, label);
}

Future<void> _back(WidgetTester tester) =>
    _tapFinder(tester, find.byTooltip('返回'));

Future<void> _saveDefinition(WidgetTester tester) async {
  await _tap(tester, '保存');
  await _wait(
    tester,
    () async => find.byType(ManagementEditor).evaluate().isEmpty,
    'Management save completed and editor dismissed',
  );
  await tester.pumpAndSettle();
}

Future<void> _amount(WidgetTester tester, List<String> keys) async {
  for (final key in keys) {
    await _tapFinder(tester, find.byKey(Key('entry-key-$key')));
  }
}

AppController _app(
  AppDatabase database,
  SessionVault vault,
  http.Client transport,
) => AppController(
  database,
  identity: IdentityController(
    repository: LocalRepository(database),
    api: ApiClient(transport),
    vault: vault,
    deviceName: 'FlowTrace isolated Android ledger UI',
    allowLocalHttp: true,
  ),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android real ledger UI survives offline reopen and syncs exact balances to peer',
    (tester) async {
      const username = String.fromEnvironment('FLOWTRACE_QA_USERNAME');
      const password = String.fromEnvironment('FLOWTRACE_QA_PASSWORD');
      expect(
        username.isNotEmpty && password.isNotEmpty,
        isTrue,
        reason: 'Requires ignored synthetic loopback QA credentials.',
      );
      final runId = const Uuid().v4();
      final marker = runId.substring(0, 8);
      final bookName = 'FT真机账本-$marker';
      final expenseName = 'FT支出-$marker', incomeName = 'FT收入-$marker';
      final childName = 'FT早餐-$marker';
      final tagName = 'FT标签-$marker';
      final cashName = 'FT现金-$marker', bankName = 'FT银行卡-$marker';
      final expenseNote = 'FT午餐-$marker', incomeNote = 'FT工资-$marker';
      final transferNote = 'FT转账-$marker';
      final support = await getApplicationSupportDirectory();
      final directory = await Directory(
        p.join(support.path, 'flowtrace-integration', 'ledger-$runId'),
      ).create(recursive: true);
      final file = File(p.join(directory.path, 'client.sqlite'));
      final vault = _DisposableVault();
      var transport = _NetworkSwitch();
      var db = AppDatabase(NativeDatabase(file));
      var app = _app(db, vault, transport);
      final peerDb = AppDatabase(NativeDatabase.memory());
      final peerRepository = LocalRepository(peerDb);
      final peerLedger = LedgerRepository(peerRepository);
      final peerIdentity = IdentityController(
        repository: peerRepository,
        api: ApiClient(http.Client()),
        vault: _DisposableVault(),
        deviceName: 'FlowTrace isolated Android ledger peer',
        allowLocalHttp: true,
      );
      final peerEngine = SyncEngine(SyncStore(peerRepository));
      String? bookId;
      String? cashId, bankId;
      var serverWritesStarted = false;
      Future<void> peerSync() =>
          peerEngine.synchronize(SyncLease.capture(peerIdentity));

      Future<void> cleanupServer() async {
        if (!serverWritesStarted || bookId == null || !peerIdentity.online) {
          return;
        }
        await peerSync();
        final space = peerIdentity.accountSpace!;
        var view = await peerLedger.read(space);
        for (final bill in view.bills.where(
          (entity) => entity.payload['book_id'] == bookId,
        )) {
          await peerLedger.delete(space, bill);
        }
        await peerSync();
        view = await peerLedger.read(space);
        final definitions =
            [
              ...view.categories,
              ...view.tags,
            ].where((entity) => entity.scopeId == bookId).toList()..sort(
              (a, b) => (a.payload['parent_id'] == null ? 1 : 0).compareTo(
                b.payload['parent_id'] == null ? 1 : 0,
              ),
            );
        for (final item in definitions) {
          await peerLedger.delete(space, item);
        }
        for (final id in [cashId, bankId].whereType<String>()) {
          final account = view.find('account', id);
          if (account != null && !account.deleted) {
            await peerLedger.delete(space, account);
          }
        }
        await peerSync();
        view = await peerLedger.read(space);
        final book = view.find('book', bookId);
        if (book != null && !book.deleted) {
          await peerLedger.delete(space, book);
          await peerSync();
        }
        expect(await peerRepository.pending(space), isEmpty);
      }

      try {
        await app.initialize();
        await _wait(tester, () async => !app.identity!.busy, 'Identity setup');
        await app.setServerAddress('http://127.0.0.1:18080');
        await app.identity!.signIn(username: username, password: password);
        await _wait(tester, () async => app.canSync, 'Primary verified space');
        await app.syncEngine.synchronize(SyncLease.capture(app.identity!));
        await peerIdentity.configure(
          ServerAddress.parse('http://127.0.0.1:18080'),
        );
        await peerIdentity.signIn(username: username, password: password);
        await peerRepository.registerSpace(peerIdentity.accountSpace!);
        await tester.pumpWidget(FlowTraceApp(controller: app));
        await tester.pumpAndSettle();

        await _drawer(tester, '管理账本、分类与标签');
        await _tap(tester, '新建账本');
        await _input(tester, _field('账本名称'), bookName);
        await _select(tester, '显示方式', '全部');
        await _tapFinder(
          tester,
          find.widgetWithText(SwitchListTile, '显示资产记账入口'),
        );
        await _saveDefinition(tester);
        await _wait(
          tester,
          () async => (await app.ledger.read(
            app.space!,
          )).books.any((book) => book.name == bookName),
          'Book transaction committed',
        );
        bookId = (await app.ledger.read(
          app.space!,
        )).books.singleWhere((book) => book.name == bookName).id;
        expect(
          (await app.ledger.read(
            app.space!,
          )).find('book', bookId)!.payload['show_assets'],
          isTrue,
        );
        await _tap(tester, '分类');
        await _tap(tester, '添加分类');
        await _input(tester, _field('分类名称'), expenseName);
        await _saveDefinition(tester);
        await _tapFinder(tester, find.byTooltip('分类操作 $expenseName'));
        await _tap(tester, '添加二级分类');
        await _input(tester, _field('分类名称'), childName);
        await _saveDefinition(tester);
        await _tap(tester, '收入');
        await _tap(tester, '添加分类');
        await _input(tester, _field('分类名称'), incomeName);
        await _saveDefinition(tester);
        await _tap(tester, '标签');
        await _tap(tester, '添加标签');
        await _input(tester, _field('标签名称'), tagName);
        await _saveDefinition(tester);
        await _back(tester);
        debugPrint('FLOWTRACE_P3_STAGE book/category/tag UI complete');

        await _drawer(tester, '资金账户');
        for (final item in [(cashName, '1000.00'), (bankName, '200.00')]) {
          await _tapFinder(tester, find.byKey(const Key('new-account')));
          await _input(tester, find.byKey(const Key('account-name')), item.$1);
          await _input(
            tester,
            find.byKey(const Key('account-opening')),
            item.$2,
          );
          if (item.$1 == bankName) await _select(tester, '类型', '银行卡');
          await _tapFinder(tester, find.byKey(const Key('save-account')));
          await _wait(
            tester,
            () async => (await app.ledger.read(
              app.space!,
            )).accounts.any((entity) => entity.name == item.$1),
            'Account local transaction',
          );
          await _wait(
            tester,
            () async =>
                find.byKey(const Key('save-account')).evaluate().isEmpty,
            'Account editor dismissed',
          );
        }
        var view = await app.ledger.read(app.space!);
        cashId = view.accounts.singleWhere((a) => a.name == cashName).id;
        bankId = view.accounts.singleWhere((a) => a.name == bankName).id;
        await _back(tester);
        debugPrint('FLOWTRACE_P3_STAGE account UI complete');

        // All three business saves below happen without successful HTTP.
        transport.blocked = true;
        await _tapFinder(tester, find.byKey(const Key('new-entry')));
        await _tap(tester, expenseName);
        await _tap(tester, childName);
        await _input(tester, find.byKey(const Key('entry-note')), expenseNote);
        await _select(tester, '资金账户', cashName);
        await _input(tester, find.widgetWithText(TextField, '优惠金额'), '0.10');
        await _tap(tester, tagName);
        await _tapFinder(
          tester,
          find.widgetWithText(CheckboxListTile, '不计入预算'),
        );
        await _amount(tester, ['0', '.', '1', '+', '0', '.', '2']);
        await _tapFinder(tester, find.byKey(const Key('entry-key-保存')));
        await _wait(
          tester,
          () async => (await app.ledger.read(
            app.space!,
          )).bills.any((bill) => bill.payload['note'] == expenseNote),
          'Expense saved offline',
        );
        await _tapFinder(tester, find.byKey(const Key('new-entry')));
        await _tap(tester, '收入');
        await _tap(tester, incomeName);
        await _input(tester, find.byKey(const Key('entry-note')), incomeNote);
        await _select(tester, '资金账户', bankName);
        await _amount(tester, ['1', '0', '0']);
        await _tapFinder(tester, find.byKey(const Key('entry-key-保存')));
        await _wait(
          tester,
          () async => (await app.ledger.read(
            app.space!,
          )).bills.any((bill) => bill.payload['note'] == incomeNote),
          'Income saved offline',
        );
        await _tapFinder(tester, find.byKey(const Key('new-entry')));
        await _tap(tester, '转账');
        await _input(tester, find.byKey(const Key('entry-note')), transferNote);
        await _select(tester, '转出账户', cashName);
        await _select(tester, '转入账户', bankName);
        await _input(
          tester,
          find.widgetWithText(TextField, '手续费 (CNY)'),
          '1.00',
        );
        await _amount(tester, ['5', '0']);
        await _tapFinder(tester, find.byKey(const Key('entry-key-保存')));
        await _wait(
          tester,
          () async =>
              (await app.ledger.read(app.space!)).bills
                  .where((bill) => bill.payload['book_id'] == bookId)
                  .length ==
              3,
          'Transfer saved offline',
        );
        view = await app.ledger.read(app.space!);
        final savedIds = view.bills
            .where((bill) => bill.payload['book_id'] == bookId)
            .map((bill) => bill.id)
            .toSet();
        final operationIds = (await app.repository.pending(
          app.space!,
        )).map((op) => op.operationId).toSet();
        expect(operationIds, isNotEmpty);
        // Golden: cash 100000 - paid30 - transfer5000 - fee100 = 94870;
        // bank 20000 + income10000 + transfer5000 = 35000. Discount is
        // informational: gross40 = paid30 + discount10, never a second debit.
        expect(view.balances[cashId]!.value!.minor.toString(), '94870');
        expect(view.balances[bankId]!.value!.minor.toString(), '35000');
        final expense = view.bills.singleWhere(
          (bill) => bill.payload['note'] == expenseNote,
        );
        expect((expense.payload['money'] as Map)['amount_minor'], '30');
        expect(expense.payload['discount_minor'], '10');
        expect(expense.payload['gross_amount_minor'], '40');
        expect(expense.payload['tag_ids'], hasLength(1));
        expect(
          expense.payload['category_id'],
          view.categories
              .singleWhere((category) => category.name == childName)
              .id,
        );
        expect(expense.payload['flags'], {
          'exclude_from_statistics': false,
          'exclude_from_budget': true,
        });
        final transfer = view.bills.singleWhere(
          (bill) => bill.payload['note'] == transferNote,
        );
        final fee = transfer.editablePayload!['fee'] as Map;
        expect((fee['money'] as Map)['amount_minor'], '100');
        expect(fee['account_id'], cashId);
        debugPrint(
          'FLOWTRACE_P3_STAGE three offline bills and golden balances',
        );
        final originalSpaceId = app.space!.id;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        app.dispose();
        await db.close();

        // Reopen the actual isolated disk file with a new controller/transport.
        // This is a database/controller restart, not an Android process kill.
        transport = _NetworkSwitch()..blocked = true;
        db = AppDatabase(NativeDatabase(file));
        app = _app(db, vault, transport);
        await app.initialize();
        await _wait(
          tester,
          () async => !app.identity!.busy && !app.switchingSpace,
          'Offline cached identity restored',
        );
        expect(app.space!.id, originalSpaceId);
        expect(app.identity!.online, isFalse);
        expect(transport.blockedRequests, greaterThan(0));
        view = await app.ledger.read(app.space!);
        expect(
          view.bills
              .where((bill) => bill.payload['book_id'] == bookId)
              .map((bill) => bill.id)
              .toSet(),
          savedIds,
        );
        expect(
          (await app.repository.pending(
            app.space!,
          )).map((op) => op.operationId).toSet(),
          operationIds,
        );
        expect(view.balances[cashId]!.value!.minor.toString(), '94870');
        expect(view.balances[bankId]!.value!.minor.toString(), '35000');
        await tester.pumpWidget(FlowTraceApp(controller: app));
        await tester.pumpAndSettle();
        await _wait(
          tester,
          () async => find.text(bookName).evaluate().isNotEmpty,
          'Selected book survives disk reopen',
        );
        expect(
          tester.widget<Text>(find.byKey(const Key('home-expense'))).data,
          'CNY 1.30',
        );
        await binding.convertFlutterSurfaceToImage();
        await tester.pump();
        final evidence = await Directory(
          p.join(support.path, 'flowtrace-validation'),
        ).create(recursive: true);
        final screenshot = File(p.join(evidence.path, 'p3-ledger-offline.png'));
        await screenshot.writeAsBytes(
          await binding.takeScreenshot('p3-ledger-offline'),
          flush: true,
        );
        debugPrint('FLOWTRACE_P3_SCREENSHOT ${screenshot.path}');
        debugPrint(
          'FLOWTRACE_P3_STAGE offline disk/controller reopen complete',
        );

        transport.blocked = false;
        await app.identity!.configure(
          ServerAddress.parse('http://127.0.0.1:18080'),
        );
        await _wait(tester, () async => app.canSync, 'Refresh after reconnect');
        serverWritesStarted = true;
        final report = await app.syncEngine.synchronize(
          SyncLease.capture(app.identity!),
        );
        expect(report.conflicts, 0);
        expect(report.pending, 0);
        expect(await app.repository.pending(app.space!), isEmpty);
        await peerSync();
        final remote = await peerLedger.read(peerIdentity.accountSpace!);
        final remoteBills = remote.bills
            .where((bill) => bill.payload['book_id'] == bookId)
            .toList();
        expect(remoteBills.map((bill) => bill.id).toSet(), savedIds);
        expect(remoteBills, hasLength(3));
        expect(remote.find('book', bookId)!.payload['display_mode'], 'all');
        expect(remote.find('book', bookId)!.payload['show_assets'], isTrue);
        expect(
          remote.categories.where((c) => c.scopeId == bookId),
          hasLength(3),
        );
        expect(remote.tags.where((t) => t.scopeId == bookId), hasLength(1));
        final confirmedExpense = remoteBills
            .singleWhere((bill) => bill.payload['note'] == expenseNote)
            .editablePayload!;
        expect(confirmedExpense['discount_minor'], '10');
        expect(confirmedExpense['gross_amount_minor'], '40');
        expect(
          confirmedExpense['category_id'],
          remote.categories
              .singleWhere((category) => category.name == childName)
              .id,
        );
        expect(confirmedExpense['flags'], {
          'exclude_from_statistics': false,
          'exclude_from_budget': true,
        });
        expect(confirmedExpense['tag_ids'], hasLength(1));
        final confirmedTransfer = remoteBills
            .singleWhere((bill) => bill.payload['note'] == transferNote)
            .editablePayload!;
        expect(
          ((confirmedTransfer['fee'] as Map)['money'] as Map)['amount_minor'],
          '100',
        );
        expect((confirmedTransfer['fee'] as Map)['account_id'], cashId);
        expect(remote.balances[cashId]!.value!.minor.toString(), '94870');
        expect(remote.balances[bankId]!.value!.minor.toString(), '35000');
        debugPrint(
          'FLOWTRACE_P3_LEDGER UI/disk/offline/peer assertions complete',
        );
      } finally {
        transport.blocked = false;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        try {
          await cleanupServer();
        } finally {
          if (app.identity!.online) await app.identity!.signOut();
          if (peerIdentity.online) await peerIdentity.signOut();
          await _wait(tester, () async => !app.switchingSpace, 'Space cleanup');
          app.dispose();
          peerIdentity.dispose();
          await db.close();
          await peerDb.close();
          // This path is created above under this app's support directory, with
          // an unguessable run UUID. No normal app file or other app is touched.
          await directory.delete(recursive: true);
        }
      }
    },
  );
}
