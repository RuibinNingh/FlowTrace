import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/data/attachments/attachment_repository.dart';
import 'package:flowtrace/data/attachments/byte_store_platform.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/features/attachments/attachment_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native attachment originals reopen and revocation deletes only controlled cache',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final unique = const Uuid().v4();
      final fixture = Directory(
        p.join(support.path, 'flowtrace-qa', 'attachment-$unique'),
      );
      await fixture.create(recursive: true);
      final epoch = const Uuid().v4(),
          scope = const Uuid().v4(),
          id = const Uuid().v4();
      final space = DataSpace(
        server: ServerAddress.parse('http://127.0.0.1:18080'),
        serverInstanceId: const Uuid().v4(),
        userId: const Uuid().v4(),
      );
      final original = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFElEQVR4nGPUaXnNAAZMEIqBgQEAHGMBn0OjIGsAAAAASUVORK5CYII=',
      );
      final checksum = sha256.convert(original).toString();
      final originalKey = attachmentBlobKey(
        space.id,
        epoch,
        scope,
        id,
        'local-original-$checksum',
      );
      final controlledKey = attachmentBlobKey(
        space.id,
        epoch,
        scope,
        id,
        'remote-original-$checksum',
      );
      final path = p.join(fixture.path, 'attachments.sqlite');
      var database = AppDatabase(NativeDatabase(File(path)));
      var bytes = await openAttachmentBytes();
      try {
        var local = LocalRepository(database);
        await local.registerSpace(space);
        var repository = AttachmentRepository(local, bytes);
        final staged = await repository.stage(
          space,
          epoch,
          scope,
          original,
          mediaType: 'image/png',
          attachmentId: id,
        );
        expect(await File(path).exists(), isTrue);
        await bytes.close();
        await database.close();
        bytes = await openAttachmentBytes();
        database = AppDatabase(NativeDatabase(File(path)));
        local = LocalRepository(database);
        repository = AttachmentRepository(local, bytes);
        final reopened = (await repository.get(space, id))!;
        expect(reopened.toJson(), staged.toJson());
        expect(await repository.original(space, reopened), original);
        await repository.cache(
          space,
          epoch,
          scope,
          id,
          'original',
          original,
          checksum,
        );
        expect(await bytes.read(controlledKey), original);
        await database
            .into(database.syncStates)
            .insertOnConflictUpdate(
              SyncStatesCompanion.insert(
                spaceId: space.id,
                clientId: const Uuid().v4(),
                epoch: epoch,
                revokedScopesJson: Value(jsonEncode([scope])),
              ),
            );
        await repository.revokeScope(space, scope);
        expect(await bytes.read(controlledKey), isNull);
        expect(await repository.cached(space, epoch, id, 'original'), isNull);
        expect(
          (await repository.get(space, id))!.phase,
          AttachmentPhase.revoked,
        );
        expect(await bytes.read(originalKey), original);
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Center(child: Text('附件原件与撤权清理验收通过'))),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('附件原件与撤权清理验收通过'), findsOneWidget);
      } finally {
        // Only UUID-derived keys created by this test are disposable.
        await bytes.delete(originalKey);
        await bytes.delete(controlledKey);
        await bytes.close();
        await database.close();
        final resolved = p.normalize(p.absolute(fixture.path));
        final allowed = p.normalize(
          p.absolute(p.join(support.path, 'flowtrace-qa')),
        );
        if (!p.isWithin(allowed, resolved) ||
            p.basename(resolved) != 'attachment-$unique') {
          throw StateError(
            'Refusing deletion outside isolated attachment fixture',
          );
        }
        await Directory(resolved).delete(recursive: true);
      }
    },
  );
}
