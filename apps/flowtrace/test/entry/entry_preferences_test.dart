import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/data/ledger/ledger_models.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/attachments/attachment_panel.dart';
import 'package:flowtrace/features/entry/entry_page.dart';
import 'package:flowtrace/platform/windows/windows_runtime.dart';

import 'entry_page_test.dart' show setupApp, bookId;

Future<void> _flush(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 60)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<AppController> _fixture(WidgetTester tester) async {
  final app = (await tester.runAsync(setupApp))!;
  await app.preferences.initialize();
  await app.preferences.update(
    app.preferences.value.copyWith(
      assetsEnabled: false,
      multiCurrencyEnabled: false,
      discountEnabled: false,
      billTimeEnabled: false,
      billImagesEnabled: false,
      billFlagsEnabled: false,
      tagsEnabled: false,
    ),
  );
  await SyncStore(app.repository).configure(
    app.space!,
    'fa000000-0000-4000-8000-000000000098',
    'fa000000-0000-4000-8000-000000000099',
  );
  final folder = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('flowtrace-entry-prefs-'),
  ))!;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const provider = MethodChannel('plugins.flutter.io/path_provider');
  messenger.setMockMethodCallHandler(provider, (_) async => folder.path);
  if (Platform.isWindows) {
    messenger.setMockMethodCallHandler(
      WindowsRuntime.channel,
      (_) async => {'path': folder.path, 'leaseHeld': true},
    );
  }
  addTearDown(() async {
    messenger.setMockMethodCallHandler(provider, null);
    messenger.setMockMethodCallHandler(WindowsRuntime.channel, null);
    final resolved = await folder.resolveSymbolicLinks();
    if (await folder.parent.resolveSymbolicLinks() !=
            await Directory.systemTemp.resolveSymbolicLinks() ||
        !folder.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('flowtrace-entry-prefs-') ||
        resolved != folder.path) {
      throw StateError('Unexpected isolated entry attachment path');
    }
    await folder.delete(recursive: true);
  });
  await tester.runAsync(app.attachments);
  return app;
}

Future<void> _mount(
  WidgetTester tester,
  AppController app, {
  LedgerDraft? draft,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: EntryPage(
        key: ValueKey(draft?.id ?? 'new'),
        app: app,
        space: app.space!,
        bookId: bookId,
        draft: draft,
      ),
    ),
  );
  await _flush(tester);
  await _flush(tester);
}

Future<void> _close(WidgetTester tester, AppController app) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _flush(tester);
  app.dispose();
  await tester.runAsync(app.database.close);
}

void main() {
  testWidgets(
    'entry reveal is revoked by a later privacy enable and the exact expression still saves',
    (tester) async {
      final app = await _fixture(tester);
      try {
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: true),
        );
        await _mount(tester, app);
        await tester.tap(find.text('餐饮'));
        for (final key in ['1', '+', '2']) {
          await tester.tap(find.byKey(Key('entry-key-$key')));
        }
        await tester.tap(find.byKey(const Key('entry-reveal-amounts')));
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const Key('entry-expression'))).data,
          '1+2',
        );
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: false),
        );
        await tester.pump();
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: true),
        );
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const Key('entry-expression'))).data,
          '••••',
        );
        expect(find.text('= 3.00'), findsNothing);
        await tester.tap(find.byKey(const Key('entry-key-再记')));
        await _flush(tester);
        expect(
          ((await app.ledger.read(app.space!)).bills.single.payload['money']
              as Map)['amount_minor'],
          '300',
        );
      } finally {
        await _close(tester, app);
      }
    },
  );
  testWidgets(
    'disabled features hide only empty new-entry fields and keep exact keypad saves',
    (tester) async {
      final app = await _fixture(tester);
      try {
        await _mount(tester, app);
        for (final key in [
          'entry-currency',
          'entry-time',
          'entry-discount',
          'entry-tags',
          'entry-statistics-flag',
          'entry-budget-flag',
        ]) {
          expect(find.byKey(Key(key)), findsNothing, reason: key);
        }
        expect(find.byType(AttachmentPanel), findsNothing);
        expect(find.text('资金账户'), findsNothing);
        await tester.tap(find.text('餐饮'));
        for (final key in ['0', '.', '1', '+', '0', '.', '2']) {
          await tester.tap(find.byKey(Key('entry-key-$key')));
        }
        await tester.tap(find.byKey(const Key('entry-key-再记')));
        await _flush(tester);
        final bill = (await app.ledger.read(app.space!)).bills.single;
        expect((bill.payload['money'] as Map)['amount_minor'], '30');
        expect(bill.payload['attachment_ids'], isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await _close(tester, app);
      }
    },
  );

  testWidgets(
    'disabled features retain complete nonempty draft fields through private editing and reopen',
    (tester) async {
      final app = await _fixture(tester);
      final semantics = tester.ensureSemantics();
      try {
        await app.preferences.update(
          app.preferences.value.copyWith(hideAmounts: true),
        );
        const image = 'aa000000-0000-4000-8000-000000000098';
        const account = 'ac000000-0000-4000-8000-000000000098';
        const tag = 'da000000-0000-4000-8000-000000000098';
        final id = await app.ledger.saveDraft(
          app.space!,
          bookId: bookId,
          payload: {
            'bill_type': 'expense',
            'book_id': bookId,
            'money': {
              'currency': 'USD',
              'currency_scale': 2,
              'amount_minor': '9007199254740993',
            },
            'business_date': '2026-10-20',
            'business_timezone': 'UTC',
            'occurred_at': '2026-10-20T12:34:56.123456Z',
            'account_id': account,
            'tag_ids': [tag],
            'attachment_ids': [image],
            'flags': {
              'exclude_from_statistics': true,
              'exclude_from_budget': true,
            },
            'discount_minor': '10',
            'note': '原完整草稿',
          },
          ui: {
            'expression': '90071992547409.93+',
            'discount': '0.10',
            'rate': '7.001',
            'time': '12:34',
          },
        );
        final original = (await app.ledger.readDraft(app.space!, id))!;
        await _mount(tester, app, draft: original);
        for (final key in [
          'entry-currency',
          'entry-time',
          'entry-discount',
          'entry-tags',
          'entry-statistics-flag',
          'entry-budget-flag',
        ]) {
          expect(find.byKey(Key(key)), findsOneWidget, reason: key);
        }
        expect(find.byType(AttachmentPanel), findsOneWidget);
        expect(
          tester
              .widget<AttachmentPanel>(find.byType(AttachmentPanel))
              .attachmentIds,
          [image],
        );
        expect(
          tester.widget<Text>(find.byKey(const Key('entry-expression'))).data,
          '••••',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('entry-discount')))
              .obscureText,
          isTrue,
        );
        expect(
          tester.getSemantics(find.byType(Scaffold)).toStringDeep(),
          isNot(contains('90071992547409.93')),
        );
        await tester.enterText(
          find.byKey(const Key('entry-note')),
          '修改备注后保留全部',
        );
        await tester.pump(const Duration(milliseconds: 500));
        await _flush(tester);
        final saved = (await app.ledger.readDraft(app.space!, id))!;
        expect(saved.payload['occurred_at'], original.payload['occurred_at']);
        expect(saved.payload['account_id'], account);
        expect(saved.payload['tag_ids'], [tag]);
        expect(saved.payload['attachment_ids'], [image]);
        expect(saved.payload['flags'], original.payload['flags']);
        // An unfinished expression has no valid committed amount. Its exact
        // input stays in UI; the draft placeholder must retain its currency.
        expect((saved.payload['money'] as Map)['currency'], 'USD');
        expect((saved.payload['money'] as Map)['currency_scale'], 2);
        for (final field in ['expression', 'discount', 'rate', 'time']) {
          expect(saved.ui[field], original.ui[field], reason: field);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await _flush(tester);
        await _mount(tester, app, draft: saved);
        expect(find.text('修改备注后保留全部'), findsOneWidget);
        await tester.tap(find.byKey(const Key('entry-reveal-amounts')));
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const Key('entry-expression'))).data,
          '90071992547409.93+',
        );
        expect((await app.ledger.read(app.space!)).bills, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await _close(tester, app);
      }
    },
  );
}
