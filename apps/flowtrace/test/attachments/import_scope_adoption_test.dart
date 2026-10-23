import 'dart:convert';
import 'dart:io';

import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/attachments/attachment_transfer.dart';
import 'package:flowtrace/features/attachments/attachment_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'attachment_repository_test.dart' as fixture;

void main() {
  late fixture.AttachmentHarness h;
  late Directory directory;
  late bool current;
  late String remoteScope;
  late Map<String, Object?> receipt;
  late AttachmentTransfer transfer;
  late AttachmentLease lease;

  Future<void> permissions({
    String version = '1',
    String role = 'owner',
  }) async {
    await h.state();
    await h.local.writeSetting(
      'sync.scope-details.${h.space.id}',
      jsonEncode({
        'version': 1,
        'epoch': fixture.epoch,
        'scopes': [
          {
            'scope_id': h.space.userId,
            'kind': 'user',
            'role': 'owner',
            'permission_version': '1',
          },
          {
            'scope_id': fixture.scope,
            'kind': 'book',
            'role': role,
            'permission_version': version,
          },
        ],
      }),
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'flowtrace_import_scope_',
    );
    h = fixture.AttachmentHarness(directory);
    await h.open();
    await permissions();
    final staged = await h.stage(scopeId: h.space.userId);
    await h.repository.save(
      h.space,
      staged.withPhase(AttachmentPhase.ready, uploadId: fixture.uploadId),
    );
    receipt = {
      'attachment_id': staged.id,
      'from_scope_id': h.space.userId,
      'to_scope_id': fixture.scope,
      'permission_version': '1',
      'sha256': staged.sha256,
      'size_bytes': staged.sizeBytes,
      'media_type': staged.mediaType,
    };
    current = true;
    remoteScope = fixture.scope;
    transfer = AttachmentTransfer(h.repository);
    lease = AttachmentLease(
      space: h.space,
      epoch: fixture.epoch,
      clientId: fixture.clientId,
      generation: 1,
      isCurrent: () => current,
      request: (method, path, {body, bodyBytes, contentType}) async {
        if (method == 'POST' && path == '/attachments/uploads') {
          expect(body?['scope_id'], remoteScope);
          return {
            'attachment_id': fixture.attachmentId,
            'upload_id': fixture.uploadId,
            'status': 'ready',
          };
        }
        // Ordinary ensureReady revalidates the existing ready declaration; it
        // performs no image PUT or financial command and uses the adopted scope.
        expect(
          '$method $path',
          anyOf(
            'GET /attachments/${fixture.attachmentId}',
            'POST /attachments/uploads/${fixture.uploadId}/complete',
          ),
        );
        return {
          'attachment_id': fixture.attachmentId,
          'scope_id': remoteScope,
          'status': 'ready',
          'sha256': receipt['sha256'],
          'size_bytes': receipt['size_bytes'],
          'media_type': receipt['media_type'],
          'width': 3,
          'height': 2,
        };
      },
      download: (path, {maxBytes = 1024}) async =>
          throw StateError('Unexpected download'),
    );
  });

  tearDown(() async {
    await h.close();
    final resolved = directory.absolute.path;
    expect(resolved.startsWith(Directory.systemTemp.absolute.path), isTrue);
    expect(
      directory.uri.pathSegments.where(
        (part) => part.startsWith('flowtrace_import_scope_'),
      ),
      isNotEmpty,
    );
    await directory.delete(recursive: true);
  });

  test(
    'formal import copies verified original, clears old ticket and allows later bill edit',
    () async {
      final prior = (await h.repository.get(h.space, fixture.attachmentId))!;
      await transfer.adoptImportReceipt(lease, receipt);
      var adopted = (await h.repository.get(h.space, fixture.attachmentId))!;
      expect(adopted.scopeId, fixture.scope);
      expect(adopted.phase, AttachmentPhase.ready);
      expect(adopted.uploadId, isNull);
      expect(adopted.blobKey, isNot(prior.blobKey));
      expect(await h.repository.original(h.space, adopted), fixture.picture());
      expect(await h.bytes.read(prior.blobKey), fixture.picture());
      await transfer.ensureReady(lease, fixture.scope, [fixture.attachmentId]);
      final frozen = jsonEncode(adopted.toJson());
      await transfer.adoptImportReceipt(lease, receipt);
      adopted = (await h.repository.get(h.space, fixture.attachmentId))!;
      expect(jsonEncode(adopted.toJson()), frozen);
      await h.close();
      await h.open();
      adopted = (await h.repository.get(h.space, fixture.attachmentId))!;
      expect(adopted.scopeId, fixture.scope);
      expect(await h.repository.original(h.space, adopted), fixture.picture());
    },
  );

  test(
    'undo restores own orphan even after old book cache revocation',
    () async {
      await transfer.adoptImportReceipt(lease, receipt);
      await h.repository.revokeScope(h.space, fixture.scope);
      await h.state(revoked: [fixture.scope]);
      remoteScope = h.space.userId;
      await transfer.adoptImportReceipt(lease, receipt, reverse: true);
      final restored = (await h.repository.get(h.space, fixture.attachmentId))!;
      expect(restored.scopeId, h.space.userId);
      expect(restored.phase, AttachmentPhase.ready);
      expect(restored.uploadId, isNull);
      expect(await h.repository.original(h.space, restored), fixture.picture());
      await transfer.ensureReady(lease, h.space.userId, [fixture.attachmentId]);
    },
  );

  test(
    'current GET in a different scope never trusts an old formal receipt',
    () async {
      final prior = (await h.repository.get(h.space, fixture.attachmentId))!;
      remoteScope = fixture.otherScope;
      await expectLater(
        transfer.adoptImportReceipt(lease, receipt),
        throwsFormatException,
      );
      expect(
        (await h.repository.get(h.space, prior.id))!.toJson(),
        prior.toJson(),
      );
      expect(await h.repository.original(h.space, prior), fixture.picture());
    },
  );

  test(
    'viewer and older permission cache retain staging for explicit refresh',
    () async {
      final prior = (await h.repository.get(h.space, fixture.attachmentId))!;
      await permissions(role: 'viewer');
      await expectLater(
        transfer.adoptImportReceipt(lease, receipt),
        throwsA(isA<ApiFailure>()),
      );
      await permissions();
      receipt['permission_version'] = '2';
      await expectLater(
        transfer.adoptImportReceipt(lease, receipt),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        (await h.repository.get(h.space, prior.id))!.toJson(),
        prior.toJson(),
      );
      await permissions(version: '3');
      await transfer.adoptImportReceipt(lease, receipt);
      expect(
        (await h.repository.get(h.space, prior.id))!.scopeId,
        fixture.scope,
      );
    },
  );

  test(
    'late identity, mismatched original and extra receipt fields cannot rewrite metadata',
    () async {
      final prior = (await h.repository.get(h.space, fixture.attachmentId))!;
      current = false;
      await expectLater(
        transfer.adoptImportReceipt(lease, receipt),
        throwsA(isA<ApiFailure>()),
      );
      current = true;
      receipt['sha256'] = '0' * 64;
      await expectLater(
        transfer.adoptImportReceipt(lease, receipt),
        throwsA(isA<ApiFailure>()),
      );
      receipt['sha256'] = prior.sha256;
      receipt['path'] = 'forbidden';
      await expectLater(
        transfer.adoptImportReceipt(lease, receipt),
        throwsFormatException,
      );
      expect(
        (await h.repository.get(h.space, prior.id))!.toJson(),
        prior.toJson(),
      );
    },
  );
}
