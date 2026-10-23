import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';
import 'package:flowtrace/features/identity/identity_models.dart';

import '../identity/identity_controller_test.dart' show Rig, address;

Future<AppController> signedIn(Rig rig) async {
  final app = AppController(rig.db, identity: rig.identity)
    ..space = DataSpace.provisional(ServerAddress.parse(address))
    ..loading = false;
  await app.repository.registerSpace(app.space!);
  await rig.signIn();
  for (var attempt = 0; attempt < 400; attempt++) {
    if (!app.switchingSpace && app.space?.verified == true) return app;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('Synthetic account space did not open');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'provisional and signed-out identity cannot capture receipt authority',
    () async {
      final rig = Rig();
      final app = AppController(rig.db, identity: rig.identity)
        ..space = DataSpace.provisional(ServerAddress.parse(address));
      addTearDown(() async {
        app.dispose();
        await rig.db.close();
      });
      await expectLater(app.captureReceiptReadLease(), throwsStateError);
    },
  );

  test(
    'offline last confirmed identity reads without issuing requests',
    () async {
      final rig = Rig();
      final app = await signedIn(rig);
      addTearDown(() async {
        app.dispose();
        await rig.db.close();
      });
      // Cached identity without an online ServerIdentity remains read-only evidence.
      rig.identity.serverIdentity = null;
      rig.identity.status = IdentityStatus.offline;
      final count = rig.requests.length;
      final lease = await app.captureReceiptReadLease();
      expect(lease.isCurrent(), isTrue);
      expect(lease.space.id, app.space!.id);
      expect(rig.requests.length, count);
      app.switchingSpace = true;
      expect(lease.isCurrent(), isFalse);
    },
  );

  test(
    'logout immediately invalidates the captured account generation',
    () async {
      final rig = Rig();
      final app = await signedIn(rig);
      addTearDown(() async {
        app.dispose();
        await rig.db.close();
      });
      final lease = await app.captureReceiptReadLease();
      final invalidated = Completer<void>();
      final subscription = lease.invalidations.listen((_) {
        if (!lease.isCurrent() && !invalidated.isCompleted) {
          invalidated.complete();
        }
      });
      addTearDown(subscription.cancel);
      await rig.identity.signOut();
      await invalidated.future.timeout(const Duration(seconds: 3));
      expect(lease.isCurrent(), isFalse);
    },
  );

  test('epoch changes and controller disposal reject retained cuts', () async {
    final rig = Rig();
    final app = await signedIn(rig);
    addTearDown(rig.db.close);
    final lease = await app.captureReceiptReadLease();
    rig.identity.serverIdentity = ServerIdentity.fromJson({
      'instance_id': lease.space.serverInstanceId,
      'sync_epoch': '99999999-9999-4999-8999-999999999999',
      'minimum_protocol': 1,
      'capabilities': ['identity'],
    });
    expect(lease.isCurrent(), isFalse);
    await expectLater(app.captureReceiptReadLease(), throwsStateError);
    app.dispose();
    expect(lease.isCurrent(), isFalse);
  });
}
