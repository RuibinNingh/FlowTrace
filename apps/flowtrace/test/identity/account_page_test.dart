import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/app/flowtrace_app.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/security/session_vault.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';

import 'identity_controller_test.dart' show Rig, address;

final class _PageRig {
  _PageRig(this.protocol, this.app, {this.cleanupVault});
  final Rig protocol;
  final AppController app;
  final _CleanupGateVault? cleanupVault;
}

final class _CleanupGateVault implements SessionVault {
  _CleanupGateVault(this.delegate);
  final SessionVault delegate;
  final release = Completer<void>();
  @override
  Future<String?> read(String key) => delegate.read(key);
  @override
  Future<void> write(String key, String value) => delegate.write(key, value);
  @override
  Future<void> delete(String key) async {
    await release.future.timeout(const Duration(seconds: 10));
    await delegate.delete(key);
  }
}

Future<_PageRig> _signedInPage({bool holdCredentialCleanup = false}) async {
  final protocol = Rig();
  _CleanupGateVault? cleanupVault;
  if (holdCredentialCleanup) {
    cleanupVault = _CleanupGateVault(protocol.vault);
    protocol.identity.dispose();
    protocol.identity = IdentityController(
      repository: LocalRepository(protocol.db),
      api: ApiClient(MockClient(protocol.handle)),
      vault: cleanupVault,
      isWeb: false,
      csrfReader: () => 'synthetic-csrf',
    );
  }
  final app = AppController(protocol.db, identity: protocol.identity)
    ..space = DataSpace.provisional(ServerAddress.parse(address))
    ..loading = false;
  await app.repository.registerSpace(app.space!);
  await protocol.signIn();
  for (var i = 0; i < 400; i++) {
    if (!app.switchingSpace && app.space?.verified == true) {
      return _PageRig(protocol, app, cleanupVault: cleanupVault);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  app.dispose();
  await protocol.db.close();
  throw StateError('Synthetic identity space did not become ready.');
}

Future<_PageRig> _signedOutPage() async {
  final protocol = Rig();
  await protocol.identity.configure(ServerAddress.parse(address));
  final app = AppController(protocol.db, identity: protocol.identity)
    ..space = DataSpace.provisional(ServerAddress.parse(address))
    ..loading = false;
  await app.repository.registerSpace(app.space!);
  return _PageRig(protocol, app);
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  for (var i = 0; i < 150; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  fail(reason);
}

Future<void> _openAccount(
  WidgetTester tester,
  _PageRig rig, {
  bool signedIn = true,
}) async {
  await tester.pumpWidget(FlowTraceApp(controller: rig.app));
  await tester.pumpAndSettle();
  unawaited(
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .pushNamed('/account'),
  );
  await tester.pumpAndSettle();
  expect(
    find.byKey(Key(signedIn ? 'sign-out' : 'auth-username')),
    findsOneWidget,
  );
}

Future<void> _disposePage(WidgetTester tester, _PageRig rig) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  rig.app.dispose();
  await tester.runAsync(rig.protocol.db.close);
}

void _expectEditableSemantics(WidgetTester tester, String key, String label) {
  final node = tester.getSemantics(find.byKey(Key(key)));
  final data = node.getSemanticsData();
  expect(data.flagsCollection.isTextField, isTrue);
  expect(data.flagsCollection.isEnabled, ui.Tristate.isTrue);
  expect(data.label, contains(label));
  expect(node.parent, isNotNull);
  expect(node.rect.isEmpty, isFalse);
  final root = tester
      .binding
      .renderViews
      .single
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  final reachable = <SemanticsNode>{};
  void visit(SemanticsNode current) {
    if (current.getSemanticsData().flagsCollection.isHidden ||
        current.isMergedIntoParent) {
      return;
    }
    reachable.add(current);
    if (!current.mergeAllDescendantsIntoThisNode) {
      current.visitChildren((child) {
        visit(child);
        return true;
      });
    }
  }

  visit(root);
  expect(
    reachable,
    contains(node),
    reason:
        'A local semantics node is insufficient: $key must be exposed '
        'through the actual root traversal without a hidden or merged ancestor.',
  );
  expect(node.attached, isTrue);
}

Future<void> _checkNewLoginForm(
  WidgetTester tester,
  _PageRig rig, {
  int expectedLoginRequests = 1,
}) async {
  expect(rig.protocol.identity.online, isFalse);
  expect(rig.protocol.identity.busy, isFalse);
  expect(find.byKey(const Key('signed-in-username')), findsNothing);
  expect(find.byKey(const Key('sign-out')), findsNothing);
  _expectEditableSemantics(tester, 'auth-username', '用户名');
  _expectEditableSemantics(tester, 'auth-password', '密码');
  expect(
    tester.widget<FilledButton>(find.byKey(const Key('submit-auth'))).onPressed,
    isNotNull,
  );
  await tester.enterText(
    find.byKey(const Key('auth-username')),
    'focus_probe_01',
  );
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pump();
  final password = tester.widget<EditableText>(
    find.descendant(
      of: find.byKey(const Key('auth-password')),
      matching: find.byType(EditableText),
    ),
  );
  expect(password.focusNode.hasFocus, isTrue);
  await tester.enterText(
    find.byKey(const Key('auth-password')),
    'Synthetic-password-again-123',
  );
  expect(password.controller.text, 'Synthetic-password-again-123');
  expect(rig.protocol.count('/auth/login'), expectedLoginRequests);
}

void main() {
  testWidgets(
    'saved server address then immediate account route exposes editable form while snackbar is visible',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final rig = (await tester.runAsync(_signedOutPage))!;
      try {
        await tester.pumpWidget(FlowTraceApp(controller: rig.app));
        await tester.pumpAndSettle();
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        unawaited(navigator.pushNamed('/settings'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const Key('server-address')),
          500,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 30,
        );
        await tester.enterText(
          find.byKey(const Key('server-address')),
          'http://127.0.0.1:18091',
        );
        await tester.ensureVisible(find.byKey(const Key('save-server')));
        await tester.tap(find.byKey(const Key('save-server')));
        await _until(
          tester,
          () => find.text('地址已保存；已切换到对应资料空间。').evaluate().isNotEmpty,
          reason: 'The normal settings save did not reach its actual snackbar.',
        );
        unawaited(navigator.pushNamed('/account'));
        await tester.pumpAndSettle();
        expect(find.text('地址已保存；已切换到对应资料空间。'), findsOneWidget);
        await _checkNewLoginForm(tester, rig, expectedLoginRequests: 0);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await _disposePage(tester, rig);
      }
    },
  );

  testWidgets(
    'fresh form stays in the accessible root after on-page login and logout',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final rig = (await tester.runAsync(_signedOutPage))!;
      try {
        await _openAccount(tester, rig, signedIn: false);
        _expectEditableSemantics(tester, 'auth-username', '用户名');
        _expectEditableSemantics(tester, 'auth-password', '密码');
        await tester.enterText(find.byKey(const Key('auth-username')), 'Alice');
        await tester.enterText(
          find.byKey(const Key('auth-password')),
          'Synthetic-password-123',
        );
        await tester.tap(find.byKey(const Key('submit-auth')));
        await _until(
          tester,
          () =>
              rig.protocol.identity.online &&
              !rig.protocol.identity.busy &&
              !rig.app.switchingSpace,
          reason: 'The on-page synthetic login did not finish.',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('auth-username')), findsNothing);
        expect(find.byKey(const Key('sign-out')), findsOneWidget);
        await tester.tap(find.byKey(const Key('sign-out')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认'));
        await _until(
          tester,
          () =>
              rig.protocol.identity.account == null &&
              !rig.protocol.identity.busy &&
              !rig.app.switchingSpace,
          reason: 'The on-page synthetic logout did not finish.',
        );
        await tester.pumpAndSettle();
        await _checkNewLoginForm(tester, rig);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await _disposePage(tester, rig);
      }
    },
  );

  testWidgets(
    'logout waits for the confirmation overlay before changing identity and keeps new fields accessible',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final rig = (await tester.runAsync(_signedInPage))!;
      var dialogCompleted = false;
      var logoutBeforeDialogCompleted = false;
      rig.protocol.intercept = (request) async {
        if (request.url.path.endsWith('/auth/logout')) {
          logoutBeforeDialogCompleted = !dialogCompleted;
          return http.Response('', 204);
        }
        return null;
      };
      try {
        await _openAccount(tester, rig);
        await tester.tap(find.byKey(const Key('sign-out')));
        await tester.pumpAndSettle();
        final route = ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
        unawaited(route.completed.then((_) => dialogCompleted = true));
        await tester.tap(find.text('确认'));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
        expect(dialogCompleted, isFalse);
        expect(
          rig.protocol.count('/auth/logout'),
          0,
          reason:
              'Do not replace the form while the modal semantics barrier still exists.',
        );
        await _until(
          tester,
          () =>
              dialogCompleted &&
              !rig.protocol.identity.busy &&
              rig.protocol.identity.account == null &&
              !rig.app.switchingSpace,
          reason: 'Confirmed logout did not complete.',
        );
        await tester.pumpAndSettle();
        expect(logoutBeforeDialogCompleted, isFalse);
        expect(rig.protocol.count('/auth/logout'), 1);
        await _checkNewLoginForm(tester, rig);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await _disposePage(tester, rig);
      }
    },
  );

  testWidgets(
    'slow logout disables account actions then exposes editable sign-in after local cleanup',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final rig = (await tester.runAsync(
        () => _signedInPage(holdCredentialCleanup: true),
      ))!;
      final gate = Completer<void>();
      final transitions = <({bool hasAccount, bool busy})>[];
      void record() => transitions.add((
        hasAccount: rig.protocol.identity.account != null,
        busy: rig.protocol.identity.busy,
      ));
      rig.protocol.identity.addListener(record);
      rig.protocol.intercept = (request) async {
        if (request.url.path.endsWith('/auth/logout')) {
          await gate.future;
          return http.Response('', 204);
        }
        return null;
      };
      try {
        await _openAccount(tester, rig);
        await tester.tap(find.byKey(const Key('sign-out')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认'));
        await _until(
          tester,
          () => rig.protocol.count('/auth/logout') == 1,
          reason: 'Logout HTTP boundary was not reached.',
        );
        expect(rig.protocol.identity.busy, isTrue);
        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('sign-out')))
              .onPressed,
          isNull,
        );
        expect(find.byKey(const Key('auth-username')), findsNothing);
        gate.complete();
        await _until(
          tester,
          () =>
              rig.protocol.identity.account == null &&
              rig.protocol.identity.busy &&
              find.byType(Form).evaluate().isNotEmpty,
          reason: 'The real signed-out/busy cleanup frame was not reached.',
        );
        final busyForm = tester.element(find.byType(Form));
        final busyCardFinder = find
            .ancestor(of: find.byType(Form), matching: find.byType(Card))
            .first;
        final busyCard = tester.element(busyCardFinder);
        final busyCardRenderObject = tester.renderObject(busyCardFinder);
        rig.cleanupVault!.release.complete();
        await _until(
          tester,
          () =>
              !rig.protocol.identity.busy &&
              rig.protocol.identity.account == null &&
              !rig.app.switchingSpace,
          reason: 'Local logout cleanup did not finish.',
        );
        await tester.pumpAndSettle();
        expect(transitions, contains((hasAccount: false, busy: true)));
        expect(transitions.last, (hasAccount: false, busy: false));
        final idleCardFinder = find
            .ancestor(of: find.byType(Form), matching: find.byType(Card))
            .first;
        expect(tester.element(find.byType(Form)), same(busyForm));
        expect(
          tester.element(idleCardFinder),
          same(busyCard),
          reason:
              'Removing the progress row must not graft the global Form '
              'into a different unkeyed Card.',
        );
        expect(tester.renderObject(idleCardFinder), same(busyCardRenderObject));
        await _checkNewLoginForm(tester, rig);
        expect(tester.takeException(), isNull);
      } finally {
        if (!gate.isCompleted) gate.complete();
        if (!rig.cleanupVault!.release.isCompleted) {
          rig.cleanupVault!.release.complete();
        }
        rig.protocol.identity.removeListener(record);
        semantics.dispose();
        await _disposePage(tester, rig);
      }
    },
  );

  testWidgets(
    'cancel and a confirmation whose account page was removed never log out',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final rig = (await tester.runAsync(_signedInPage))!;
      try {
        await _openAccount(tester, rig);
        await tester.tap(find.byKey(const Key('sign-out')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(rig.protocol.count('/auth/logout'), 0);
        expect(rig.protocol.identity.online, isTrue);

        final pageRoute = ModalRoute.of(
          tester.element(find.byKey(const Key('sign-out'))),
        )!;
        final navigator = Navigator.of(
          tester.element(find.byKey(const Key('sign-out'))),
        );
        await tester.tap(find.byKey(const Key('sign-out')));
        await tester.pumpAndSettle();
        navigator.removeRoute(pageRoute);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('sign-out')), findsNothing);
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('确认'));
        await tester.pumpAndSettle();
        expect(rig.protocol.count('/auth/logout'), 0);
        expect(rig.protocol.identity.online, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await _disposePage(tester, rig);
      }
    },
  );
}
