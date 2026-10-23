import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/features/protection/password_deriver_api.dart';
import 'package:flowtrace/features/protection/protection_controller.dart';
import 'package:flowtrace/features/protection/protection_notifications_api.dart';
import 'package:flowtrace/features/protection/protection_store.dart';

class MemoryStore implements ProtectionStore {
  String? raw;
  bool failRead = false, failWrite = false;
  Completer<void>? holdWrite;
  @override
  Future<String?> read() async {
    if (failRead) throw StateError('injected read failure');
    return raw;
  }

  @override
  Future<bool> compareAndSet(String? expected, String next) async {
    if (holdWrite != null) await holdWrite!.future;
    if (failWrite) throw StateError('injected write failure');
    if (raw != expected) return false;
    raw = next;
    return true;
  }
}

class FastDeriver implements PasswordDeriver {
  Completer<void>? hold;
  int calls = 0;
  @override
  Future<List<int>> derive(
    String password,
    List<int> salt, {
    required int iterations,
  }) async {
    calls++;
    if (hold != null) await hold!.future;
    return sha256.convert([...salt, ...utf8.encode(password)]).bytes;
  }
}

class Notifications implements ProtectionNotifications {
  final events = StreamController<void>.broadcast(sync: true);
  @override
  bool available = true;
  @override
  Stream<void> get changes => events.stream;
  @override
  void publish() {}
  @override
  void close() => unawaited(events.close());
}

void main() {
  late MemoryStore store;
  late FastDeriver deriver;
  late Notifications notifications;
  late ProtectionController controller;
  late DateTime now;
  var saltCounter = 0;
  setUp(() {
    store = MemoryStore();
    deriver = FastDeriver();
    notifications = Notifications();
    now = DateTime.utc(2026, 10, 22);
    controller = ProtectionController(
      store: store,
      supported: true,
      deriver: deriver,
      notifications: notifications,
      clock: () => now,
      randomBytes: (count) => List<int>.filled(count, ++saltCounter),
    );
  });
  tearDown(() => controller.dispose());

  Future<void> enable() async {
    await controller.initialize();
    expect(await controller.setPassword('synthetic-password'), isTrue);
  }

  test(
    'fresh disabled, enabled verifier has salt/work factor and no plaintext, reopen starts locked',
    () async {
      await enable();
      expect(controller.enabled, isTrue);
      expect(controller.locked, isFalse);
      expect(store.raw, isNot(contains('synthetic-password')));
      expect(jsonDecode(store.raw!)['iterations'], 600000);
      await controller.initialize();
      expect(controller.locked, isTrue);
      expect(await controller.unlock('synthetic-password'), isTrue);
      expect(controller.locked, isFalse);
    },
  );

  test(
    'wrong unlock retains original protected value and all input; current password required to disable',
    () async {
      await enable();
      final original = jsonDecode(store.raw!);
      await controller.lock();
      expect(await controller.unlock('wrong-password'), isFalse);
      expect(controller.locked, isTrue);
      final failed = jsonDecode(store.raw!);
      expect(failed['verifier'], original['verifier']);
      expect(failed['salt'], original['salt']);
      expect(failed['failures'], 1);
      expect(await controller.disable('synthetic-password'), isTrue);
      expect(controller.enabled, isFalse);
      expect(controller.locked, isFalse);
      expect(jsonDecode(store.raw!), {'version': 1, 'enabled': false});
    },
  );

  test('re-key changes salt and only new password opens', () async {
    await enable();
    final original = jsonDecode(store.raw!);
    expect(
      await controller.setPassword(
        'replacement-password',
        currentPassword: 'synthetic-password',
      ),
      isTrue,
    );
    expect(jsonDecode(store.raw!)['salt'], isNot(original['salt']));
    await controller.lock();
    expect(await controller.unlock('synthetic-password'), isFalse);
    expect(await controller.unlock('replacement-password'), isTrue);
  });

  test(
    'persistent failed attempt cooldown survives reopen and expires',
    () async {
      await enable();
      await controller.lock();
      for (var attempt = 0; attempt < 5; attempt++) {
        expect(await controller.unlock('wrong-password'), isFalse);
      }
      expect(controller.retryAfter, const Duration(seconds: 1));
      final calls = deriver.calls;
      await controller.initialize();
      expect(await controller.unlock('synthetic-password'), isFalse);
      expect(deriver.calls, calls);
      now = now.add(const Duration(seconds: 2));
      expect(await controller.unlock('synthetic-password'), isTrue);
      expect(jsonDecode(store.raw!)['failures'], 0);
    },
  );

  test(
    'background invalidates delayed unlock and failed draft save remains locked without clearing input',
    () async {
      await enable();
      final input = '12+ complete draft';
      controller.beforeLock = () async {
        expect(input, '12+ complete draft');
        return false;
      };
      await controller.lock();
      expect(controller.draftWarning, contains('尚未保存'));
      deriver.hold = Completer<void>();
      final result = controller.unlock('synthetic-password');
      await Future<void>.delayed(Duration.zero);
      await controller.lock();
      deriver.hold!.complete();
      expect(await result, isFalse);
      expect(controller.locked, isTrue);
      expect(input, '12+ complete draft');
    },
  );

  test(
    'an external re-key cannot be overwritten by delayed correct unlock',
    () async {
      await enable();
      await controller.lock();
      deriver.hold = Completer<void>();
      final result = controller.unlock('synthetic-password');
      await Future<void>.delayed(Duration.zero);
      final replacement = jsonDecode(store.raw!) as Map<String, dynamic>;
      replacement['verifier'] = base64Encode(List<int>.filled(32, 94));
      store.raw = jsonEncode(replacement);
      final external = store.raw;
      deriver.hold!.complete();
      expect(await result, isFalse);
      expect(controller.locked, isTrue);
      expect(controller.ready, isFalse);
      expect(store.raw, external);
    },
  );

  test(
    'store read/corrupt/write errors fail closed and never reset the original record',
    () async {
      await enable();
      final original = store.raw;
      await controller.lock();
      store.failWrite = true;
      expect(await controller.unlock('synthetic-password'), isFalse);
      expect(controller.locked, isTrue);
      expect(store.raw, original);
      store.failRead = true;
      await controller.initialize();
      expect(controller.locked, isTrue);
      expect(controller.ready, isFalse);
      store.failRead = false;
      store.raw = '{"version":99,"future":"retained"}';
      await controller.initialize();
      expect(controller.locked, isTrue);
      expect(controller.ready, isFalse);
      expect(store.raw, '{"version":99,"future":"retained"}');
    },
  );

  test(
    'background while an enable commit is pending cannot reveal afterwards',
    () async {
      await controller.initialize();
      store.holdWrite = Completer<void>();
      final operation = controller.setPassword('synthetic-password');
      await Future<void>.delayed(Duration.zero);
      await controller.lock();
      store.holdWrite!.complete();
      expect(await operation, isFalse);
      expect(controller.locked, isTrue);
      expect(controller.enabled, isTrue);
      expect(await controller.unlock('synthetic-password'), isTrue);
    },
  );

  test(
    'platform-disabled protection never reads or rewrites its configuration',
    () async {
      final other = ProtectionController(
        store: store,
        supported: false,
        deriver: deriver,
        notifications: Notifications(),
      );
      store.failRead = true;
      await other.initialize();
      expect(other.ready, isTrue);
      expect(other.locked, isFalse);
      expect(await other.setPassword('synthetic-password'), isFalse);
      expect(store.raw, isNull);
      other.dispose();
    },
  );

  test(
    'another tab invalidates an unlocked view before its record read completes',
    () async {
      await enable();
      notifications.events.add(null);
      expect(controller.locked, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.enabled, isTrue);
      expect(controller.locked, isTrue);
    },
  );

  test(
    'another tab enabling protection conceals a previously unprotected view immediately',
    () async {
      await enable();
      final enabledRecord = store.raw;
      expect(await controller.disable('synthetic-password'), isTrue);
      expect(controller.enabled, isFalse);
      expect(controller.locked, isFalse);
      store.raw = enabledRecord;
      notifications.events.add(null);
      expect(controller.locked, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.enabled, isTrue);
      expect(controller.locked, isTrue);
    },
  );
}
