import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/app/flowtrace_app.dart';
import 'package:flowtrace/data/local/app_database.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native storage saves a draft and reopens without a server', (
    tester,
  ) async {
    final db = AppDatabase();
    final controller = AppController(db);
    await controller.initialize();
    expect(controller.startupError, isNull);
    // Only fixtures created by this integration test are disposable. Retain
    // unrelated drafts, including data in every other server/user partition.
    final previousFixtureIds = controller.drafts
        .where((d) => d.body.startsWith('FlowTrace isolated device check '))
        .map((d) => d.id)
        .toList();
    await tester.pumpWidget(FlowTraceApp(controller: controller));
    await tester.pumpAndSettle();
    final marker =
        'FlowTrace isolated device check ${DateTime.now().millisecondsSinceEpoch}';
    await tester.tap(find.byKey(const Key('new-draft')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('draft-body')), marker);
    await tester.tap(find.byKey(const Key('save-draft')));
    await tester.pumpAndSettle();
    expect(find.text(marker), findsOneWidget);
    final createdId = controller.drafts.singleWhere((d) => d.body == marker).id;
    final space = controller.space!;
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await db.close();
    final reopenedDb = AppDatabase();
    final reopened = AppController(reopenedDb);
    try {
      await reopened.initialize();
      expect(reopened.startupError, isNull);
      expect(
        reopened.drafts.any((d) => d.id == createdId && d.body == marker),
        isTrue,
      );
      expect(await reopened.repository.pending(space), isEmpty);
      await tester.pumpWidget(FlowTraceApp(controller: reopened));
      await tester.pumpAndSettle();
      expect(find.text(marker), findsOneWidget);
      await reopened.deleteDraft(createdId);
      for (final id in previousFixtureIds) {
        await reopened.deleteDraft(id);
      }
      await tester.pumpAndSettle();
      expect(find.text(marker), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      reopened.dispose();
      await reopenedDb.close();
    }
  });
}
