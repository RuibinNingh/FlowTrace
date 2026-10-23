import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/app/flowtrace_app.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/network/platform_client.dart';
import 'package:flowtrace/core/security/platform_vault.dart';
import 'package:flowtrace/core/security/session_vault.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';

AppController makeController(AppDatabase db, SessionVault vault) =>
    AppController(
      db,
      identity: IdentityController(
        repository: LocalRepository(db),
        api: ApiClient(createPlatformClient()),
        vault: vault,
        deviceName: 'FlowTrace Android QA',
      ),
    );

Future<void> waitForIdentity(
  WidgetTester tester,
  bool Function() ready,
  IdentityController identity,
) async {
  for (var i = 0; i < 200; i++) {
    if (ready()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    ready(),
    isTrue,
    reason: identity.message ?? 'Identity operation did not finish.',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native invitation, vault rotation, profile space and logout', (
    tester,
  ) async {
    const username = String.fromEnvironment('FLOWTRACE_QA_USERNAME');
    const password = String.fromEnvironment('FLOWTRACE_QA_PASSWORD');
    const invite = String.fromEnvironment('FLOWTRACE_QA_INVITE');
    expect(
      username.isNotEmpty && password.isNotEmpty && invite.isNotEmpty,
      isTrue,
      reason:
          'Use an ignored synthetic QA dart-define file, never a real account.',
    );
    var db = AppDatabase();
    final vault = createSessionVault();
    var app = makeController(db, vault);
    try {
      await app.initialize();
      await waitForIdentity(tester, () => !app.identity!.busy, app.identity!);
      await app.setServerAddress('http://127.0.0.1:18080');
      await waitForIdentity(tester, () => !app.identity!.busy, app.identity!);
      if (app.identity!.account != null) await app.identity!.signOut();
      await tester.pumpWidget(FlowTraceApp(controller: app));
      await tester.pumpAndSettle();
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('邀请码注册'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('auth-username')), username);
      await tester.enterText(find.byKey(const Key('auth-password')), password);
      await tester.enterText(find.byKey(const Key('auth-invite')), invite);
      await tester.tap(find.byKey(const Key('submit-auth')));
      await waitForIdentity(
        tester,
        () => app.identity!.online && !app.identity!.busy && app.canSync,
        app.identity!,
      );
      await tester.pumpAndSettle();
      expect(find.text(username), findsOneWidget);
      final originalSpace = app.space!;
      final originalClient = app.identity!.clientId;
      final originalSession = app.identity!.account!.sessionId;
      final marker =
          'FlowTrace native auth fixture ${DateTime.now().microsecondsSinceEpoch}';
      await app.saveDraft(marker);
      final draftId = app.drafts.singleWhere((d) => d.body == marker).id;
      final key = 'flowtrace.refresh.v1.${originalSpace.id}';
      final refreshBefore = await vault.read(key);
      expect(refreshBefore != null && refreshBefore.isNotEmpty, isTrue);
      final settingsBefore = (await db.select(db.appSettings).get())
          .map((v) => v.value)
          .join();
      expect(settingsBefore.contains(refreshBefore!), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
      db = AppDatabase();
      app = makeController(db, createSessionVault());
      await app.initialize();
      await waitForIdentity(
        tester,
        () => !app.identity!.busy && app.canSync,
        app.identity!,
      );
      expect(app.space!.id, originalSpace.id);
      expect(app.identity!.clientId, originalClient);
      expect(app.identity!.account!.sessionId, originalSession);
      expect(
        app.drafts.any((d) => d.id == draftId && d.body == marker),
        isTrue,
      );
      final refreshAfter = await vault.read(key);
      expect(refreshAfter != null && refreshAfter != refreshBefore, isTrue);
      final settingsAfter = (await db.select(db.appSettings).get())
          .map((v) => v.value)
          .join();
      expect(settingsAfter.contains(refreshAfter!), isFalse);
      await app.identity!.signOut();
      await waitForIdentity(tester, () => !app.switchingSpace, app.identity!);
      expect(app.identity!.account, isNull);
      expect(app.canSync, isFalse);
      expect(await vault.read(key), isNull);
      await app.repository.deleteDraft(originalSpace, draftId);
      expect(
        (await app.repository.drafts(
          originalSpace,
        )).any((d) => d.id == draftId),
        isFalse,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    }
  });
}
