import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/app/flowtrace_app.dart';
import 'package:flowtrace/data/local/app_database.dart';

void main() {
  testWidgets(
    'aborted update reuses provisional draft id when user saves later',
    (tester) async {
      final app = AppController(AppDatabase(NativeDatabase.memory()));
      await tester.runAsync(app.initialize);
      await tester.pumpWidget(FlowTraceApp(controller: app));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-draft')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('draft-body')),
        '更新屏障保存的最后文字',
      );
      expect(await tester.runAsync(() => app.prepareForUpdate([])), isTrue);
      final before = (await tester.runAsync(
        () => app.repository.drafts(app.space!),
      ))!.single;
      expect(before.body, '更新屏障保存的最后文字');
      app.resumeAfterUpdate();
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('draft-body')), '更新取消后继续写');
      await tester.tap(find.byKey(const Key('save-draft')));
      await tester.pumpAndSettle();
      final after = (await tester.runAsync(
        () => app.repository.drafts(app.space!),
      ))!.single;
      expect(after.id, before.id);
      expect(after.body, '更新取消后继续写');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      app.dispose();
      await tester.runAsync(app.database.close);
    },
  );
}
