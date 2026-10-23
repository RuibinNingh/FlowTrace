import 'dart:async';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, TransactionExecutor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';

void main() {
  late AppDatabase db;
  late LocalRepository local;
  late _TransactionCounter counter;
  setUp(() {
    counter = _TransactionCounter();
    db = AppDatabase(NativeDatabase.memory().interceptWith(counter));
    local = LocalRepository(db);
  });
  tearDown(() => db.close());

  test('nested writes and snapshot reads share the outer executor', () async {
    await db.atomicWrite(() async {
      await local.writeSetting('outer', 'before');
      await db.atomicWrite(() async {
        await local.writeSetting('inner', 'saved');
      });
      await db.readSnapshot(() async {
        expect(await local.readSetting('inner'), 'saved');
      });
    });
    expect(await local.readSetting('outer'), 'before');
    expect(await local.readSetting('inner'), 'saved');
    expect(counter.begins, 1);
  });

  test('caught nested failure rolls back before and after writes', () async {
    final failure = StateError('synthetic nested failure');
    await expectLater(
      db.atomicWrite(() async {
        await local.writeSetting('outer', 'before');
        try {
          await db.atomicWrite(() async {
            await local.writeSetting('inner', 'partial');
            throw failure;
          });
        } on StateError {
          await local.writeSetting('outer', 'after');
        }
      }),
      throwsA(same(failure)),
    );
    expect(await db.select(db.appSettings).get(), isEmpty);
    await db.atomicWrite(() => local.writeSetting('after-rollback', 'usable'));
    expect(await local.readSetting('after-rollback'), 'usable');
  });

  test('uncaught outer error retains its identity and rolls back', () async {
    final failure = ArgumentError('synthetic outer failure');
    await expectLater(
      db.atomicWrite(() async {
        await local.writeSetting('outer', 'before');
        await db.atomicWrite(() => local.writeSetting('inner', 'saved'));
        throw failure;
      }),
      throwsA(same(failure)),
    );
    expect(await db.select(db.appSettings).get(), isEmpty);
  });

  test('a read snapshot can reuse an external raw transaction', () async {
    await db.transaction(() async {
      await local.writeSetting('raw', 'visible');
      await db.readSnapshot(() async {
        expect(await local.readSetting('raw'), 'visible');
      });
    });
    expect(await local.readSetting('raw'), 'visible');
    expect(counter.begins, 1);
  });

  test(
    'raw nested transaction rollback still preserves the outer write',
    () async {
      await db.transaction(() async {
        await local.writeSetting('outer', 'kept');
        await expectLater(
          db.transaction(() async {
            await local.writeSetting('inner', 'rolled back');
            throw StateError('raw savepoint failure');
          }, requireNew: true),
          throwsStateError,
        );
      });
      expect(await local.readSetting('outer'), 'kept');
      expect(await local.readSetting('inner'), isNull);
      expect(counter.begins, 2);
    },
  );

  test(
    'an unmanaged transaction cannot implicitly own an atomic write',
    () async {
      var entered = false;
      await db.transaction(() async {
        await local.writeSetting('raw', 'kept');
        await expectLater(
          db.atomicWrite(() async {
            entered = true;
            await local.writeSetting('managed', 'must not run');
          }),
          throwsStateError,
        );
      });
      expect(entered, isFalse);
      expect(await local.readSetting('raw'), 'kept');
      expect(await local.readSetting('managed'), isNull);
    },
  );

  test(
    'independent concurrent writes each finish with their own transaction',
    () async {
      await Future.wait([
        db.atomicWrite(() async {
          await local.writeSetting('first', '1');
          await Future<void>.delayed(Duration.zero);
          await db.atomicWrite(() => local.writeSetting('first-inner', '2'));
        }),
        db.atomicWrite(() => local.writeSetting('second', '3')),
      ]);
      expect(await local.readSetting('first'), '1');
      expect(await local.readSetting('first-inner'), '2');
      expect(await local.readSetting('second'), '3');
    },
  );

  test(
    'completed transaction zones reject late asynchronous helpers',
    () async {
      late Zone completed;
      await db.atomicWrite(() async {
        completed = Zone.current;
        await local.writeSetting('committed', 'safe');
      });
      await expectLater(
        completed.run(
          () => db.atomicWrite(() => local.writeSetting('late', 'no')),
        ),
        throwsStateError,
      );
      expect(await local.readSetting('committed'), 'safe');
      expect(await local.readSetting('late'), isNull);
    },
  );

  test('different databases do not share rollback-only state', () async {
    final other = AppDatabase(NativeDatabase.memory());
    final otherLocal = LocalRepository(other);
    try {
      await expectLater(
        db.atomicWrite(() async {
          await local.writeSetting('first-db', 'rollback');
          await other.atomicWrite(
            () => otherLocal.writeSetting('second-db', 'committed'),
          );
          throw StateError('only the first database fails');
        }),
        throwsStateError,
      );
      expect(await local.readSetting('first-db'), isNull);
      expect(await otherLocal.readSetting('second-db'), 'committed');
    } finally {
      await other.close();
    }
  });
}

final class _TransactionCounter extends QueryInterceptor {
  int begins = 0;

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    ++begins;
    return super.beginTransaction(parent);
  }
}
