import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/features/entry/entry_page.dart';

import 'entry_page_test.dart' show setupApp, bookId;

void main() {
  testWidgets('update flushes expression and note before 350ms debounce', (
    tester,
  ) async {
    final app = (await tester.runAsync(setupApp))!;
    await tester.pumpWidget(
      MaterialApp(
        home: EntryPage(app: app, space: app.space!, bookId: bookId),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('entry-note')), '更新前最后一次输入');
    await tester.tap(find.byKey(const Key('entry-key-1')));
    await tester.tap(find.byKey(const Key('entry-key-+')));
    final route = ModalRoute.of(tester.element(find.byType(EntryPage)))!;
    expect(await tester.runAsync(() => app.prepareForUpdate([route])), isTrue);
    final drafts = (await tester.runAsync(
      () => app.ledger.watchDrafts(app.space!).first,
    ))!;
    expect(drafts.single.ui['expression'], '1+');
    expect(drafts.single.payload['note'], '更新前最后一次输入');
    expect(
      (await tester.runAsync(() => app.ledger.read(app.space!)))!.bills,
      isEmpty,
    );
    app.resumeAfterUpdate();
    await tester.enterText(find.byKey(const Key('entry-note')), '取消更新后继续输入');
    expect(await tester.runAsync(() => app.prepareForUpdate([route])), isTrue);
    expect(
      (await tester.runAsync(
        () => app.ledger.watchDrafts(app.space!).first,
      ))!.single.payload['note'],
      '取消更新后继续输入',
    );
    app.resumeAfterUpdate();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    app.dispose();
    await tester.runAsync(app.database.close);
  });
}
