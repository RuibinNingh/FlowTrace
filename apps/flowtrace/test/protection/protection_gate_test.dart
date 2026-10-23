import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/features/protection/password_deriver_api.dart';
import 'package:flowtrace/features/protection/protection_controller.dart';
import 'package:flowtrace/features/protection/protection_gate.dart';
import 'package:flowtrace/features/protection/protection_store.dart';

class _Store implements ProtectionStore {
  String? raw;
  @override
  Future<String?> read() async => raw;
  @override
  Future<bool> compareAndSet(String? expected, String next) async {
    if (raw != expected) return false;
    raw = next;
    return true;
  }
}

class _Deriver implements PasswordDeriver {
  @override
  Future<List<int>> derive(
    String password,
    List<int> salt, {
    required int iterations,
  }) async => sha256.convert([...salt, ...utf8.encode(password)]).bytes;
}

class _DraftEditor extends StatefulWidget {
  const _DraftEditor();
  @override
  State<_DraftEditor> createState() => _DraftEditorState();
}

class _DraftEditorState extends State<_DraftEditor> {
  final input = TextEditingController();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const Text('synthetic private bill details'),
        TextField(key: const Key('complete-draft'), controller: input),
      ],
    ),
  );
}

void main() {
  testWidgets(
    'background concealment removes private content from semantics but keeps failed-save draft state',
    (tester) async {
      final controller = ProtectionController(
        store: _Store(),
        supported: true,
        deriver: _Deriver(),
        beforeLock: () async => false,
      );
      await controller.initialize();
      await controller.setPassword('synthetic-password');
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              AppProtectionGate(controller: controller, child: child!),
          home: const _DraftEditor(),
        ),
      );
      await tester.enterText(find.byKey(const Key('complete-draft')), '12+');
      final original = tester.state<_DraftEditorState>(
        find.byType(_DraftEditor),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(controller.locked, isTrue);
      expect(find.text('synthetic private bill details'), findsNothing);
      expect(find.byKey(const Key('complete-draft')), findsNothing);
      expect(original.input.text, '12+');
      expect(find.textContaining('尚未保存'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('protection-unlock-password')),
        'wrong-password',
      );
      await tester.tap(find.byKey(const Key('protection-unlock')));
      await tester.pump();
      expect(controller.locked, isTrue);
      expect(original.input.text, '12+');
      await tester.enterText(
        find.byKey(const Key('protection-unlock-password')),
        'synthetic-password',
      );
      await tester.tap(find.byKey(const Key('protection-unlock')));
      await tester.pump();
      expect(controller.locked, isFalse);
      expect(find.text('synthetic private bill details'), findsOneWidget);
      expect(
        tester.state<_DraftEditorState>(find.byType(_DraftEditor)),
        same(original),
      );
      expect(original.input.text, '12+');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'corrupt protection record never reveals the navigator and is preserved on retry',
    (tester) async {
      final store = _Store()..raw = '{"version":9,"future":"retain-original"}';
      final controller = ProtectionController(
        store: store,
        supported: true,
        deriver: _Deriver(),
      );
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              AppProtectionGate(controller: controller, child: child!),
          home: const _DraftEditor(),
        ),
      );
      expect(find.text('synthetic private bill details'), findsNothing);
      expect(find.byKey(const Key('protection-retry-load')), findsOneWidget);
      await tester.tap(find.byKey(const Key('protection-retry-load')));
      await tester.pump();
      expect(find.text('synthetic private bill details'), findsNothing);
      expect(store.raw, '{"version":9,"future":"retain-original"}');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'cooldown end updates the button without another controller event',
    (tester) async {
      var now = DateTime.utc(2026, 10, 22);
      final controller = ProtectionController(
        store: _Store(),
        supported: true,
        deriver: _Deriver(),
        clock: () => now,
      );
      await controller.initialize();
      await controller.setPassword('synthetic-password');
      await controller.lock();
      for (var index = 0; index < 5; index++) {
        await controller.unlock('wrong-password');
      }
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              AppProtectionGate(controller: controller, child: child!),
          home: const _DraftEditor(),
        ),
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('protection-unlock')))
            .onPressed,
        isNull,
      );
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('protection-unlock')))
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
