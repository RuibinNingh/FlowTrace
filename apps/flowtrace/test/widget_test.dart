import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/app/flowtrace_app.dart';
import 'package:flowtrace/data/local/app_database.dart';

void main() {
  testWidgets('shell offers real local drafts and a separate settings route', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    final controller = AppController(database);
    await tester.runAsync(controller.initialize);
    await tester.pumpWidget(FlowTraceApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('还没有草稿'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('server-address')),
      500,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
    expect(find.byKey(const Key('server-address')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('server-address')),
      'https://user:password@example.com',
    );
    await tester.ensureVisible(find.byKey(const Key('save-server')));
    await tester.tap(find.byKey(const Key('save-server')));
    await tester.pumpAndSettle();
    expect(find.textContaining('不包含账号'), findsOneWidget);
    expect(
      controller.space!.server.toString(),
      'https://home.ruibin-ningh.top:18473',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });
}
