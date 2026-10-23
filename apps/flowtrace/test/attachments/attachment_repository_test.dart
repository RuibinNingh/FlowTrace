import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/attachments/attachment_repository.dart';
import 'package:flowtrace/data/attachments/attachment_transfer.dart';
import 'package:flowtrace/data/attachments/byte_store.dart';
import 'package:flowtrace/data/attachments/byte_store_native.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/features/attachments/attachment_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const epoch = '10000000-0000-4000-8000-000000000001';
const scope = '20000000-0000-4000-8000-000000000002';
const otherScope = '20000000-0000-4000-8000-000000000003';
const attachmentId = '30000000-0000-4000-8000-000000000003';
const clientId = '40000000-0000-4000-8000-000000000004';
const uploadId = '50000000-0000-4000-8000-000000000005';
Uint8List picture() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFElEQVR4nGPUaXnNAAZMEIqBgQEAHGMBn0OjIGsAAAAASUVORK5CYII=',
);

final class AttachmentHarness {
  AttachmentHarness(this.directory);
  final Directory directory;
  late AppDatabase db;
  late LocalRepository local;
  late AttachmentRepository repository;
  late NativeAttachmentBytes bytes;
  final space = DataSpace(
    server: ServerAddress.parse('http://127.0.0.1:18080'),
    serverInstanceId: '60000000-0000-4000-8000-000000000006',
    userId: '70000000-0000-4000-8000-000000000007',
  );

  Future<void> open() async {
    db = AppDatabase(
      NativeDatabase(File(p.join(directory.path, 'local.sqlite'))),
    );
    local = LocalRepository(db);
    bytes = NativeAttachmentBytes(Directory(p.join(directory.path, 'bytes')));
    repository = AttachmentRepository(local, bytes);
    await local.registerSpace(space);
  }

  Future<void> state({
    String status = 'active',
    List<String> revoked = const [],
  }) async {
    await db
        .into(db.syncStates)
        .insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            spaceId: space.id,
            clientId: clientId,
            epoch: epoch,
            status: Value(status),
            revokedScopesJson: Value(jsonEncode(revoked)),
          ),
        );
  }

  Future<LocalAttachment> stage({
    String id = attachmentId,
    String scopeId = scope,
  }) => repository.stage(
    space,
    epoch,
    scopeId,
    picture(),
    mediaType: 'image/png',
    attachmentId: id,
  );

  Future<void> close() async {
    await bytes.close();
    await db.close();
  }
}

final class SyntheticUpload {
  int failures = 0;
  int declarations = 0;
  int puts = 0;
  int completions = 0;
  bool current = true;
  String status = 'pending';
  Uint8List? received;
  final bodies = <String>[];
  Completer<void>? reachedDeclaration;
  Completer<void>? releaseDeclaration;

  Map<String, Object?> info({String scopeId = scope, String? checksum}) => {
    'attachment_id': attachmentId,
    'scope_id': scopeId,
    'sha256': checksum ?? sha256.convert(picture()).toString(),
    'size_bytes': picture().length,
    'media_type': 'image/png',
    'width': 3,
    'height': 2,
    'status': 'ready',
  };

  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Uint8List? bodyBytes,
    String? contentType,
  }) async {
    if (method == 'POST' && path == '/attachments/uploads') {
      declarations++;
      bodies.add(jsonEncode(body));
      reachedDeclaration?.complete();
      if (releaseDeclaration != null) await releaseDeclaration!.future;
      return {
        'attachment_id': attachmentId,
        'upload_id': uploadId,
        'status': status,
        'expires_at': '2026-10-22T00:00:00Z',
        'replayed': declarations > 1,
      };
    }
    if (method == 'PUT') {
      puts++;
      expect(contentType, 'image/png');
      received = Uint8List.fromList(bodyBytes!);
      if (failures-- > 0) {
        throw const ApiFailure('network_unavailable', '离线', offline: true);
      }
      status = 'uploaded';
      return {
        'attachment_id': attachmentId,
        'upload_id': uploadId,
        'status': status,
      };
    }
    if (method == 'POST' && path.endsWith('/complete')) {
      completions++;
      status = 'ready';
      return info();
    }
    if (method == 'GET') return info();
    throw StateError('Unexpected synthetic request');
  }

  AttachmentLease lease(
    DataSpace space, {
    AttachmentRequest? send,
    AttachmentDownload? download,
  }) => AttachmentLease(
    space: space,
    epoch: epoch,
    clientId: clientId,
    generation: 1,
    isCurrent: () => current,
    request: send ?? request,
    download:
        download ?? (path, {maxBytes = attachmentMaxBytes}) async => picture(),
  );
}

void main() {
  late AttachmentHarness harness;
  setUp(() async {
    harness = AttachmentHarness(
      await Directory.systemTemp.createTemp('flowtrace-attachment-test-'),
    );
    await harness.open();
  });
  tearDown(() async {
    await harness.close();
    final absolute = p.normalize(p.absolute(harness.directory.path));
    if (!p.isWithin(p.absolute(Directory.systemTemp.path), absolute) ||
        !p.basename(absolute).startsWith('flowtrace-attachment-test-')) {
      throw StateError(
        'Refusing deletion outside isolated attachment test directory',
      );
    }
    await Directory(absolute).delete(recursive: true);
  });

  test(
    'file bytes and SQLite metadata survive closing and reopening; input is frozen',
    () async {
      final input = picture();
      final staged = harness.repository.stage(
        harness.space,
        epoch,
        scope,
        input,
        mediaType: 'image/png',
        attachmentId: attachmentId,
      );
      input.fillRange(0, input.length, 0);
      final before = await staged;
      await harness.close();
      await harness.open();
      final after = (await harness.repository.get(
        harness.space,
        attachmentId,
      ))!;
      expect(after.toJson(), before.toJson());
      expect(
        await harness.repository.original(harness.space, after),
        picture(),
      );
      expect(
        await harness.directory.list().any(
          (item) => item.path.endsWith('local.sqlite'),
        ),
        isTrue,
      );
    },
  );

  test(
    'same ID stays immutable across concurrent staging and other account has no queue',
    () async {
      final changed = Uint8List.fromList(picture())..[20] ^= 1;
      final outcomes = await Future.wait([
        harness
            .stage()
            .then<Object>((value) => value)
            .catchError((Object error) => error),
        harness.repository
            .stage(
              harness.space,
              epoch,
              scope,
              changed,
              mediaType: 'image/png',
              attachmentId: attachmentId,
            )
            .then<Object>((value) => value)
            .catchError((Object error) => error),
      ]);
      expect(outcomes.whereType<LocalAttachment>(), hasLength(1));
      expect(
        outcomes.whereType<ApiFailure>().single.code,
        'attachment_mismatch',
      );
      final record = (await harness.repository.get(
        harness.space,
        attachmentId,
      ))!;
      expect(
        sha256
            .convert(await harness.repository.original(harness.space, record))
            .toString(),
        record.sha256,
      );
      final other = DataSpace(
        server: harness.space.server,
        serverInstanceId: harness.space.serverInstanceId,
        userId: 'different-fixture-user',
      );
      expect(await harness.repository.list(other), isEmpty);
      expect(await harness.repository.get(other, attachmentId), isNull);
    },
  );

  test(
    'failed PUT preserves original; reopening and retry keep declaration and attachment ID',
    () async {
      final before = await harness.stage();
      final remote = SyntheticUpload()..failures = 1;
      await expectLater(
        AttachmentTransfer(
          harness.repository,
        ).upload(remote.lease(harness.space), attachmentId),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.code,
            'code',
            'network_unavailable',
          ),
        ),
      );
      expect(
        (await harness.repository.get(harness.space, attachmentId))!.phase,
        AttachmentPhase.failed,
      );
      await harness.close();
      await harness.open();
      final complete = await AttachmentTransfer(
        harness.repository,
      ).upload(remote.lease(harness.space), attachmentId);
      expect(complete.phase, AttachmentPhase.ready);
      expect(complete.id, before.id);
      expect(remote.bodies, hasLength(2));
      expect(remote.bodies.first, remote.bodies.last);
      expect(remote.received, picture());
      expect(
        await harness.repository.original(harness.space, complete),
        picture(),
      );
    },
  );

  test(
    'simultaneous retries share one declaration, PUT and completion',
    () async {
      await harness.stage();
      final remote = SyntheticUpload();
      final transfer = AttachmentTransfer(harness.repository);
      final lease = remote.lease(harness.space);
      final first = transfer.upload(lease, attachmentId);
      final second = transfer.upload(lease, attachmentId);
      expect(identical(first, second), isTrue);
      await Future.wait([first, second]);
      expect([remote.declarations, remote.puts, remote.completions], [1, 1, 1]);
    },
  );

  test(
    'late declaration after identity switch cannot PUT or mark ready',
    () async {
      await harness.stage();
      final remote = SyntheticUpload()
        ..reachedDeclaration = Completer<void>()
        ..releaseDeclaration = Completer<void>();
      final pending = AttachmentTransfer(
        harness.repository,
      ).upload(remote.lease(harness.space), attachmentId);
      final assertion = expectLater(
        pending,
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      await remote.reachedDeclaration!.future;
      remote.current = false;
      remote.releaseDeclaration!.complete();
      await assertion;
      expect(remote.puts, 0);
      expect(
        (await harness.repository.get(harness.space, attachmentId))!.phase,
        isNot(AttachmentPhase.ready),
      );
    },
  );

  test(
    'recovery blocks all network upload but allows durable local staging',
    () async {
      await harness.state(status: 'recovery_required');
      final staged = await harness.stage();
      final remote = SyntheticUpload();
      await expectLater(
        AttachmentTransfer(
          harness.repository,
        ).upload(remote.lease(harness.space), attachmentId),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'recovery_required'),
        ),
      );
      expect(remote.declarations, 0);
      expect(
        await harness.repository.original(harness.space, staged),
        picture(),
      );
    },
  );

  test(
    'sync revocation purges actual downloaded bytes while keeping local original and other scope',
    () async {
      final staged = await harness.stage();
      final checksum = sha256.convert(picture()).toString();
      await harness.repository.cache(
        harness.space,
        epoch,
        scope,
        attachmentId,
        'original',
        picture(),
        checksum,
      );
      const otherId = '30000000-0000-4000-8000-000000000009';
      await harness.repository.cache(
        harness.space,
        epoch,
        otherScope,
        otherId,
        'original',
        picture(),
        checksum,
      );
      final cacheKey = attachmentBlobKey(
        harness.space.id,
        epoch,
        scope,
        attachmentId,
        'remote-original-$checksum',
      );
      expect(await harness.bytes.read(cacheKey), isNotNull);
      await harness.state(revoked: [scope]);
      await harness.repository.revokeScope(harness.space, scope);
      expect(await harness.bytes.read(cacheKey), isNull);
      expect(
        await harness.repository.cached(
          harness.space,
          epoch,
          attachmentId,
          'original',
        ),
        isNull,
      );
      expect(
        await harness.repository.cached(
          harness.space,
          epoch,
          otherId,
          'original',
        ),
        picture(),
      );
      final local = (await harness.repository.get(
        harness.space,
        attachmentId,
      ))!;
      expect(local.phase, AttachmentPhase.revoked);
      expect(
        await harness.repository.original(harness.space, staged),
        picture(),
      );
      await harness.repository.revokeScope(
        harness.space,
        scope,
      ); // startup replay is safe
    },
  );

  test(
    'download checksum mismatch and foreign scope do not create controlled cache',
    () async {
      final remote = SyntheticUpload();
      final transfer = AttachmentTransfer(harness.repository);
      await expectLater(
        transfer.downloadOriginal(
          remote.lease(
            harness.space,
            download: (path, {maxBytes = attachmentMaxBytes}) async =>
                Uint8List.fromList([1, 2, 3]),
          ),
          scope,
          attachmentId,
        ),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'hash_mismatch'),
        ),
      );
      expect(
        await harness.repository.cached(
          harness.space,
          epoch,
          attachmentId,
          'original',
        ),
        isNull,
      );
      await expectLater(
        transfer.downloadOriginal(
          remote.lease(
            harness.space,
            send: (method, path, {body, bodyBytes, contentType}) async =>
                remote.info(scopeId: otherScope),
          ),
          scope,
          attachmentId,
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'download persists verified bytes; late download cannot commit after account switch',
    () async {
      final remote = SyntheticUpload();
      final transfer = AttachmentTransfer(harness.repository);
      expect(
        await transfer.downloadOriginal(
          remote.lease(harness.space),
          scope,
          attachmentId,
        ),
        picture(),
      );
      await harness.close();
      await harness.open();
      expect(
        await harness.repository.cached(
          harness.space,
          epoch,
          attachmentId,
          'original',
        ),
        picture(),
      );
      final delayed = Completer<Uint8List>();
      final reached = Completer<void>();
      final pending = AttachmentTransfer(harness.repository).downloadOriginal(
        remote.lease(
          harness.space,
          download: (path, {maxBytes = attachmentMaxBytes}) {
            reached.complete();
            return delayed.future;
          },
        ),
        scope,
        attachmentId,
      );
      final assertion = expectLater(
        pending,
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      await reached.future;
      remote.current = false;
      delayed.complete(picture());
      await assertion;
    },
  );

  test(
    'corrupt queue/cache keys cannot redirect cleanup to a user original',
    () async {
      final record = await harness.stage();
      final meta = <String, Object?>{
        'version': 1,
        'attachment_id': attachmentId,
        'variant': 'original',
        'scope_id': scope,
        'epoch': epoch,
        'blob_key': record.blobKey,
        'sha256': record.sha256,
      };
      await harness.local.writeSetting(
        'attachments.v1.${harness.space.id}.cache.$attachmentId.original',
        jsonEncode(meta),
      );
      await expectLater(
        harness.repository.revokeScope(harness.space, scope),
        throwsA(isA<FormatException>()),
      );
      expect(
        await harness.repository.original(harness.space, record),
        picture(),
      );
      final corrupted = record.toJson()..['blob_key'] = 'a' * 64;
      await harness.local.writeSetting(
        'attachments.v1.${harness.space.id}.queue.$attachmentId',
        jsonEncode(corrupted),
      );
      await expectLater(
        harness.repository.get(harness.space, attachmentId),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'server uploaded status resumes completion without unnecessary PUT',
    () async {
      await harness.stage();
      final remote = SyntheticUpload()..status = 'uploaded';
      await AttachmentTransfer(
        harness.repository,
      ).ensureReady(remote.lease(harness.space), scope, [attachmentId]);
      expect(remote.puts, 0);
      expect(remote.completions, 1);
    },
  );

  test(
    'native byte store refuses replacement, path escape and unavailable root',
    () async {
      final key = 'a' * 64;
      await harness.bytes.write(key, picture());
      await expectLater(
        harness.bytes.write(key, Uint8List.fromList([1, 2, 3])),
        throwsA(isA<AttachmentStorageFailure>()),
      );
      expect(await harness.bytes.read(key), picture());
      await expectLater(
        harness.bytes.read('../outside'),
        throwsA(isA<FormatException>()),
      );
      final badRoot = File(p.join(harness.directory.path, 'not-a-directory'));
      await badRoot.writeAsString('fixture');
      await expectLater(
        NativeAttachmentBytes(
          Directory(badRoot.path),
        ).write('b' * 64, picture()),
        throwsA(isA<AttachmentStorageFailure>()),
      );
    },
  );
}
