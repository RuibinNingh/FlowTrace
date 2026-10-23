import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/app/app_controller.dart';
import 'package:flowtrace/data/local/app_database.dart';

void main() {
  late AppController app;
  late Route<dynamic> home, editor;
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    app = AppController(AppDatabase(NativeDatabase.memory()));
    await app.initialize();
    home = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    editor = MaterialPageRoute<void>(builder: (_) => const SizedBox());
  });
  tearDown(() async {
    app.dispose();
    await app.database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'active durable import blocks update and application lock flush',
    () async {
      final release = Completer<void>();
      final upload = app.stageImports.track(() => release.future);
      expect(await app.prepareForUpdate([home]), isFalse);
      expect(await app.flushActiveDrafts(), isFalse);
      expect(app.database.writeGate.paused, isFalse);
      release.complete();
      await upload;
      expect(await app.flushActiveDrafts(), isTrue);
      expect(await app.prepareForUpdate([home]), isTrue);
      app.resumeAfterUpdate();
    },
  );

  test(
    'import starting during participant flush vetoes the update fence',
    () async {
      final release = Completer<void>();
      Future<void>? upload;
      app.registerUpdateParticipant(
        Object(),
        route: editor,
        prepare: () async {
          upload = app.stageImports.track(() => release.future);
          return true;
        },
      );
      expect(await app.prepareForUpdate([home, editor]), isFalse);
      expect(app.database.writeGate.paused, isFalse);
      release.complete();
      await upload;
      await app.repository.writeSetting('after-import-veto', 'kept');
    },
  );

  test('flushes complete draft before fencing every local writer', () async {
    final owner = Object();
    app.registerUpdateParticipant(
      owner,
      route: editor,
      prepare: () async {
        await app.repository.saveDraft(app.space!, 'pending full input');
        return true;
      },
    );
    expect(await app.prepareForUpdate([home, editor]), isTrue);
    expect(await app.prepareForUpdate([home, editor]), isFalse);
    expect(app.database.writeGate.paused, isTrue);
    expect(
      (await app.repository.drafts(app.space!)).single.body,
      'pending full input',
    );
    await expectLater(
      app.repository.writeSetting('blocked', 'no'),
      throwsStateError,
    );
    app.resumeAfterUpdate();
    app.resumeAfterUpdate();
    await app.repository.writeSetting('resumed', 'yes');
    expect(app.preparingUpdate, isFalse);
  });

  test(
    'an unregistered editor or dialog vetoes without losing its input',
    () async {
      var flushed = false;
      app.registerUpdateParticipant(
        Object(),
        route: home,
        prepare: () async {
          flushed = true;
          return true;
        },
      );
      expect(await app.prepareForUpdate([home, editor]), isFalse);
      expect(flushed, isFalse);
      expect(app.database.writeGate.paused, isFalse);
    },
  );

  test('abort while prepare awaits cannot pause surviving app later', () async {
    final entered = Completer<void>(), finish = Completer<void>();
    app.registerUpdateParticipant(
      Object(),
      route: editor,
      prepare: () async {
        entered.complete();
        await finish.future;
        return true;
      },
    );
    final preparing = app.prepareForUpdate([home, editor]);
    await entered.future;
    app.resumeAfterUpdate();
    expect(await app.prepareForUpdate([home, editor]), isFalse);
    finish.complete();
    expect(await preparing, isFalse);
    expect(app.preparingUpdate, isFalse);
    expect(app.database.writeGate.paused, isFalse);
    await app.repository.writeSetting('after-abort', 'yes');
  });

  test('navigation changing during flush aborts and resumes', () async {
    var sameNavigation = true;
    app.registerUpdateParticipant(
      Object(),
      route: editor,
      prepare: () async {
        sameNavigation = false;
        return true;
      },
    );
    expect(
      await app.prepareForUpdate([
        home,
        editor,
      ], navigationCurrent: () => sameNavigation),
      isFalse,
    );
    expect(app.database.writeGate.paused, isFalse);
  });

  test('save failure rejects update and keeps previous durable data', () async {
    await app.repository.saveDraft(app.space!, 'previous draft');
    app.registerUpdateParticipant(
      Object(),
      route: editor,
      prepare: () async {
        throw StateError('synthetic write failure');
      },
    );
    expect(await app.prepareForUpdate([home, editor]), isFalse);
    expect(
      (await app.repository.drafts(app.space!)).single.body,
      'previous draft',
    );
    expect(app.preparingUpdate, isFalse);
  });

  test('late lifecycle lock while draft flush awaits rejects update', () async {
    expect(
      await app.protection.setPassword('synthetic-update-lock-password'),
      isTrue,
    );
    final entered = Completer<void>(), finish = Completer<void>();
    app.registerUpdateParticipant(
      Object(),
      route: editor,
      prepare: () async {
        entered.complete();
        await finish.future;
        return true;
      },
    );
    final preparing = app.prepareForUpdate([home, editor]);
    await entered.future;
    app.protection.beforeLock = null;
    await app.protection.lock();
    finish.complete();
    expect(await preparing, isFalse);
    expect(app.protection.locked, isTrue);
    expect(app.database.writeGate.paused, isFalse);
  });

  test('a settings save starting during draft flush vetoes update', () async {
    app.registerUpdateParticipant(
      Object(),
      route: editor,
      prepare: () async {
        app.preferences.saving = true;
        return true;
      },
    );
    try {
      expect(await app.prepareForUpdate([home, editor]), isFalse);
      expect(app.database.writeGate.paused, isFalse);
    } finally {
      app.preferences.saving = false;
    }
  });
}
