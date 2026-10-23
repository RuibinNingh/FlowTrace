import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/app/flowtrace_app.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/security/session_vault.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';

class _DisposableVault implements SessionVault {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

IdentityController _identity(LocalRepository repo, String name) =>
    IdentityController(
      repository: repo,
      api: ApiClient(http.Client()),
      vault: _DisposableVault(),
      allowLocalHttp: true,
      deviceName: name,
    );

Future<void> _wait(
  WidgetTester tester,
  Future<bool> Function() ready,
  String reason,
) async {
  for (var i = 0; i < 250; i++) {
    if (await ready()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(await ready(), isTrue, reason: reason);
}

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  await _wait(
    tester,
    () async => target.evaluate().isNotEmpty,
    'Missing UI control: $label',
  );
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android sync UI resolves both conflicts and reviews a preserved backup',
    (tester) async {
      const username = String.fromEnvironment('FLOWTRACE_QA_USERNAME');
      const password = String.fromEnvironment('FLOWTRACE_QA_PASSWORD');
      expect(
        username.isNotEmpty && password.isNotEmpty,
        isTrue,
        reason: 'Use the ignored synthetic QA file; no real financial data.',
      );
      // These are two isolated native SQLite caches, not the user's on-disk app
      // database. The UI and both HTTP sessions run on the real Android device.
      final db = AppDatabase(NativeDatabase.memory());
      final peerDb = AppDatabase(NativeDatabase.memory());
      final repo = LocalRepository(db), peerRepo = LocalRepository(peerDb);
      final identity = _identity(repo, 'Android sync UI primary');
      final peer = _identity(peerRepo, 'Android sync UI peer');
      final app = AppController(db, identity: identity);
      final peerEngine = SyncEngine(SyncStore(peerRepo));
      final bookId = const Uuid().v4(), tagId = const Uuid().v4();
      var bookCreated = false, tagCreated = false;
      Future<void> peerSync() =>
          peerEngine.synchronize(SyncLease.capture(peer));
      QueuedCommand tag(
        String name,
        String revision, {
        String action = 'update',
      }) => QueuedCommand(
        operationId: const Uuid().v4(),
        scopeId: bookId,
        entityType: 'tag',
        entityId: tagId,
        action: action,
        baseRevision: revision,
        payload: action == 'delete' ? {} : {'name': name, 'color': '#2279d7'},
      );
      try {
        await app.initialize();
        await _wait(
          tester,
          () async => !identity.busy,
          'Initial identity setup',
        );
        await app.setServerAddress('http://127.0.0.1:18080');
        await identity.signIn(username: username, password: password);
        await _wait(tester, () async => app.canSync, 'Primary account space');
        await peer.configure(ServerAddress.parse('http://127.0.0.1:18080'));
        await peer.signIn(username: username, password: password);
        final space = app.space!, peerSpace = peer.accountSpace!;
        await peerRepo.registerSpace(peerSpace);
        await repo.saveEntityAndQueue(
          space,
          QueuedCommand(
            operationId: const Uuid().v4(),
            scopeId: space.userId,
            entityType: 'book',
            entityId: bookId,
            action: 'create',
            baseRevision: '0',
            payload: {
              'name': 'Android UI isolated sync',
              'currency': 'CNY',
              'timezone': 'Asia/Shanghai',
              'month_start_day': 1,
            },
          ),
        );
        await app.syncEngine.synchronize(SyncLease.capture(identity));
        expect(await repo.pending(space), isEmpty);
        bookCreated = true;
        await repo.saveEntityAndQueue(
          space,
          tag('initial', '0', action: 'create'),
        );
        await app.syncEngine.synchronize(SyncLease.capture(identity));
        tagCreated = true;
        await peerSync();

        await repo.saveEntityAndQueue(
          space,
          tag('Android mine discarded', '1'),
        );
        await peerRepo.saveEntityAndQueue(
          peerSpace,
          tag('remote wins first', '1'),
        );
        await peerSync();
        await tester.pumpWidget(FlowTraceApp(controller: app));
        await tester.pumpAndSettle();
        await _tap(tester, '管理');
        await tester.pumpAndSettle();
        await _tap(tester, '同步与恢复');
        await tester.pumpAndSettle();
        await _tap(tester, '立即同步');
        await _wait(
          tester,
          () async => (await app.syncEngine.store.conflicts(space)).length == 1,
          'First genuine revision conflict',
        );
        await _wait(
          tester,
          () async => find.text('使用服务器版本').evaluate().isNotEmpty,
          'Server resolution control',
        );
        expect(find.text('本机内容：Android mine discarded'), findsOneWidget);
        await _tap(tester, '使用服务器版本');
        await _tap(tester, '确认');
        await _wait(
          tester,
          () async =>
              (await app.syncEngine.store.conflicts(space)).isEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
          'Server choice completed',
        );
        await tester.pumpAndSettle();
        expect(find.text('这项记录在其他设备上发生了变化'), findsNothing);
        final accepted = await identity.authorizedRequest(
          'GET',
          '/sync/entities/tag/$tagId?scope_id=$bookId',
        );
        expect(
          syncObject(accepted['editable_payload'])['name'],
          'remote wins first',
        );

        await peerSync();
        await repo.saveEntityAndQueue(
          space,
          tag('Android mine preserved', '2'),
        );
        await peerRepo.saveEntityAndQueue(peerSpace, tag('remote second', '2'));
        await peerSync();
        await _tap(tester, '立即同步');
        await _wait(
          tester,
          () async => (await app.syncEngine.store.conflicts(space)).length == 1,
          'Second genuine revision conflict',
        );
        await _tap(tester, '保留我的修改');
        await _tap(tester, '确认');
        await _wait(
          tester,
          () async =>
              (await app.syncEngine.store.conflicts(space)).isEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
          'My choice completed',
        );
        await tester.pumpAndSettle();
        expect(find.text('这项记录在其他设备上发生了变化'), findsNothing);
        final preserved = await identity.authorizedRequest(
          'GET',
          '/sync/entities/tag/$tagId?scope_id=$bookId',
        );
        expect(
          syncObject(preserved['editable_payload'])['name'],
          'Android mine preserved',
        );
        expect(decodeSyncEvent(preserved['event']).revision, '4');

        // Seed the local backup-review state, not a server restore. The unsent
        // tag differs from its confirmed shadow and must remain visible for review.
        await repo.saveEntityAndQueue(
          space,
          tag('Android backup preserved', '4'),
        );
        await app.syncEngine.store.requireRebuild(
          space,
          'synthetic_ui_backup_check',
        );
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        await _tap(tester, '同步与恢复');
        await _wait(
          tester,
          () async => find.text('需要恢复资料').evaluate().isNotEmpty,
          'Recovery-required status',
        );
        await _tap(tester, '核对缺失和变化的记录');
        await _wait(
          tester,
          () async => find.text('核对恢复备份').evaluate().isNotEmpty,
          'Backup review route',
        );
        expect(find.text('Android backup preserved'), findsOneWidget);
        expect(find.text('内容与服务器不同'), findsOneWidget);
        await _tap(tester, 'Android backup preserved');
        await _wait(
          tester,
          () async => find.text('恢复前的记录').evaluate().isNotEmpty,
          'Preserved record details',
        );
        expect(find.byType(SelectableText), findsOneWidget);
        await _tap(tester, '关闭');
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(
          (await app.syncEngine.store.recoveryBackups(space)).isNotEmpty,
          isTrue,
        );
        expect((await repo.pending(space)).isNotEmpty, isTrue);
        expect(
          (await app.syncEngine.store.state(space))!.status,
          'recovery_required',
        );
      } finally {
        // Clean only the fresh synthetic server objects through normal tombstones.
        // The primary cache stays frozen; the independent peer does the cleanup.
        if (peer.online && bookCreated) {
          await peerSync();
          final peerSpace = peer.accountSpace!;
          if (tagCreated) {
            final current = await peer.authorizedRequest(
              'GET',
              '/sync/entities/tag/$tagId?scope_id=$bookId',
            );
            final event = decodeSyncEvent(current['event']);
            if (!event.deleted) {
              await peerRepo.saveEntityAndQueue(
                peerSpace,
                tag('', event.revision, action: 'delete'),
              );
              await peerSync();
            }
          }
          await peerRepo.saveEntityAndQueue(
            peerSpace,
            QueuedCommand(
              operationId: const Uuid().v4(),
              scopeId: bookId,
              entityType: 'book',
              entityId: bookId,
              action: 'delete',
              baseRevision: '1',
              payload: {},
            ),
          );
          await peerSync();
          expect(await peerRepo.pending(peerSpace), isEmpty);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        if (identity.online) await identity.signOut();
        if (peer.online) await peer.signOut();
        await _wait(
          tester,
          () async => !app.switchingSpace,
          'Identity cleanup space',
        );
        app.dispose();
        peer.dispose();
        await db.close();
        await peerDb.close();
      }
    },
  );
}
