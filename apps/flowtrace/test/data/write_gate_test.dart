import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';

void main() {
  late AppDatabase db;
  late LocalRepository local;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    local = LocalRepository(db);
    await local.writeSetting('baseline', 'saved');
  });
  tearDown(() => db.close());

  test(
    'drain waits for whole transaction, permits its nested work, fences raw writes',
    () async {
      final entered = Completer<void>(), finish = Completer<void>();
      final write = db.atomicWrite(() async {
        await local.writeSetting('outer', 'before');
        entered.complete();
        await finish.future;
        await db.atomicWrite(() => local.writeSetting('inner', 'after'));
      });
      await entered.future;
      var drained = false;
      final pause = db.writeGate.pauseAndDrain().then(
        (value) => drained = value,
      );
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      await expectLater(local.writeSetting('blocked', 'no'), throwsStateError);
      await expectLater(db.transaction(() async {}), throwsStateError);
      finish.complete();
      await write;
      await pause;
      expect(drained, isTrue);
      expect(await local.readSetting('inner'), 'after');
      expect(await local.readSetting('blocked'), isNull);
      db.writeGate.resume();
      db.writeGate.resume();
      await local.writeSetting('resumed', 'yes');
    },
  );

  test('rollback finishes before drain and has no partial value', () async {
    final entered = Completer<void>(), finish = Completer<void>();
    final write = db.atomicWrite(() async {
      await local.writeSetting('partial', 'no');
      entered.complete();
      await finish.future;
      throw StateError('synthetic rollback');
    });
    final rejected = expectLater(write, throwsStateError);
    await entered.future;
    final pause = db.writeGate.pauseAndDrain();
    finish.complete();
    await rejected;
    expect(await pause, isTrue);
    expect(await local.readSetting('partial'), isNull);
  });

  test(
    'timeout never reports prepared and resume admits future writes',
    () async {
      final entered = Completer<void>(), finish = Completer<void>();
      final write = db.atomicWrite(() async {
        entered.complete();
        await finish.future;
      });
      await entered.future;
      expect(
        await db.writeGate.pauseAndDrain(
          timeout: const Duration(milliseconds: 5),
        ),
        isFalse,
      );
      db.writeGate.resume();
      finish.complete();
      await write;
      await local.writeSetting('usable', 'yes');
    },
  );

  test('batch and custom statements cannot bypass a paused gate', () async {
    expect(await db.writeGate.pauseAndDrain(), isTrue);
    await expectLater(
      db.customStatement("DELETE FROM app_settings"),
      throwsStateError,
    );
    await expectLater(
      db.batch(
        (batch) => batch.insert(
          db.appSettings,
          AppSettingsCompanion.insert(key: 'batch', value: 'no'),
        ),
      ),
      throwsStateError,
    );
    expect(await local.readSetting('baseline'), 'saved');
    expect(await db.readSnapshot(() => local.readSetting('baseline')), 'saved');
    await expectLater(
      db.readSnapshot(() => local.writeSetting('read-write', 'no')),
      throwsStateError,
    );
  });

  test(
    'direct statement remains in drain until underlying writer returns',
    () async {
      final slow = _SlowInsert();
      final other = AppDatabase(NativeDatabase.memory().interceptWith(slow));
      final repository = LocalRepository(other);
      await repository.writeSetting('open', 'first');
      slow.enabled = true;
      final write = repository.writeSetting('held', 'durable');
      await slow.entered.future;
      var drained = false;
      final pause = other.writeGate.pauseAndDrain().then(
        (value) => drained = value,
      );
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      slow.finish.complete();
      await write;
      await pause;
      expect(drained, isTrue);
      expect(await repository.readSetting('held'), 'durable');
      await other.close();
    },
  );
}

final class _SlowInsert extends QueryInterceptor {
  bool enabled = false;
  final entered = Completer<void>(), finish = Completer<void>();
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (enabled) {
      entered.complete();
      await finish.future;
    }
    return executor.runInsert(statement, args);
  }
}
