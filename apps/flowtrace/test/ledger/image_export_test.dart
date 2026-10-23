import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/attachments/attachment_repository.dart';
import 'package:flowtrace/data/attachments/attachment_transfer.dart';
import 'package:flowtrace/data/attachments/byte_store_native.dart';
import 'package:flowtrace/data/ledger/ledger_image_export.dart';
import 'package:flutter_test/flutter_test.dart';

import 'query_fixtures.dart';

Uint8List exportPicture() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFElEQVR4nGPUaXnNAAZMEIqBgQEAHGMBn0OjIGsAAAAASUVORK5CYII=',
);

final class _Destination implements LedgerImageExportDestination {
  Uint8List? published;
  bool discarded = false;
  Future<void> Function()? afterStaging;
  @override
  Future<LedgerImageExportStatus> write(
    Uint8List bytes, {
    required Future<void> Function() guard,
  }) async {
    await guard();
    final staged = Uint8List.fromList(bytes);
    await afterStaging?.call();
    await guard();
    published = staged;
    return LedgerImageExportStatus.saved;
  }

  @override
  Future<void> discard() async {
    if (published == null) discarded = true;
  }
}

final class _Saver implements LedgerImageExportSaver {
  final destination = _Destination();
  bool cancel = false;
  int chosen = 0;
  Future<void> Function()? onChoose;
  @override
  Future<LedgerImageExportDestination?> choose() async {
    chosen++;
    await onChoose?.call();
    return cancel ? null : destination;
  }
}

final class _Remote {
  _Remote(this.fixture);
  final QueryFixture fixture;
  bool current = true;
  final roles = {qBook: 'owner', qOtherBook: 'owner'};
  final images = <String, Uint8List>{};
  final scopes = <String, String>{};
  int downloads = 0;
  bool badHash = false;
  Future<void> Function()? afterDownload;
  AttachmentLease get lease => AttachmentLease(
    space: fixture.space,
    epoch: qEpoch,
    clientId: qid(5),
    generation: 1,
    isCurrent: () => current,
    request: (method, path, {body, bodyBytes, contentType}) async {
      if (method == 'GET' && path == '/sync/scopes') {
        return {
          'sync_epoch': qEpoch,
          'requires_rebuild': false,
          'control_version': '1',
          'revoked_scope_ids': [if (!roles.containsKey(qBook)) qBook],
          'scopes': [
            for (final entry in roles.entries)
              {
                'scope_id': entry.key,
                'kind': 'book',
                'role': entry.value,
                'revision': '1',
                'permission_version': '1',
              },
          ],
        };
      }
      final id = path.split('/').last, image = images[id];
      if (method != 'GET' || image == null) {
        throw const ApiFailure('not_found', '合成缺件', status: 404);
      }
      return {
        'attachment_id': id,
        'scope_id': scopes[id] ?? qBook,
        'status': 'ready',
        'sha256': badHash ? '0' * 64 : sha256.convert(image).toString(),
        'size_bytes': image.length,
        'media_type': 'image/png',
        'width': 3,
        'height': 2,
      };
    },
    download: (path, {maxBytes = 10 * 1024 * 1024}) async {
      downloads++;
      final id = path.split('/')[2], bytes = images[id]!;
      if (bytes.length > maxBytes) throw const ApiFailure('too_large', '合成超限');
      await afterDownload?.call();
      return Uint8List.fromList(bytes);
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late QueryFixture f;
  late Directory directory;
  late NativeAttachmentBytes bytes;
  late AttachmentRepository attachments;
  late _Remote remote;
  late _Saver saver;
  late LedgerImageExportService service;
  setUp(() async {
    f = QueryFixture();
    await f.seed();
    directory = await Directory.systemTemp.createTemp(
      'flowtrace-image-export-',
    );
    bytes = NativeAttachmentBytes(directory);
    attachments = AttachmentRepository(f.local, bytes);
    remote = _Remote(f);
    saver = _Saver();
    service = LedgerImageExportService(f.ledger, attachments, saver: saver);
  });
  tearDown(() async {
    await bytes.close();
    await f.close();
    expect(directory.absolute.parent.path, Directory.systemTemp.absolute.path);
    expect(
      directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
      startsWith('flowtrace-image-export-'),
    );
    await directory.delete(recursive: true);
  });
  Future<void> stage(int id, {Uint8List? content}) async {
    await attachments.stage(
      f.space,
      qEpoch,
      qBook,
      content ?? exportPicture(),
      mediaType: 'image/png',
      attachmentId: qid(id),
    );
  }

  Future<void> refs(
    String id,
    List<String> images, {
    String revision = '1',
  }) async {
    final entity = await f.entity(id), data = entity.projection;
    data['payload'] = {...entity.payload, 'attachment_ids': images};
    await f.put('bill', id, entity.scopeId, data, revision: revision);
  }

  test(
    'real originals and duplicate references produce one synthetic ZIP entry per image',
    () async {
      await stage(42);
      await stage(43);
      await refs(qb, [qid(42)]);
      final preview = await service.preview(f.space, [qa, qb, qf, qa]);
      expect(preview.canExport, isTrue);
      expect(preview.selectedBillCount, 3);
      expect(preview.imageCount, 2);
      final result = await service.export(remote.lease, preview);
      expect(result.status, LedgerImageExportStatus.saved);
      expect(result.imageCount, 2);
      final zip = saver.destination.published!;
      final decoded = ZipDecoder().decodeBytes(zip, verify: true);
      expect(decoded.files.map((file) => file.name), [
        'images/image_0001.png',
        'images/image_0002.png',
      ]);
      for (final file in decoded.files) {
        expect(file.content, exportPicture());
        expect(file.comment ?? '', isEmpty);
        expect(file.name, isNot(contains(qid(42))));
        expect(file.name, isNot(contains('Lunch')));
      }
      expect(result.archiveBytes, zip.length);
      expect(
        await attachments.original(
          f.space,
          (await attachments.get(f.space, qid(42)))!,
        ),
        exportPicture(),
      );
      expect(remote.downloads, 0);
    },
  );

  test(
    'viewer may export visible images despite hidden financial links',
    () async {
      await stage(42);
      await f.roles(role: 'viewer');
      remote.roles[qBook] = 'viewer';
      final preview = await service.preview(f.space, [qa]);
      expect(preview.canExport, isTrue);
      final result = await service.export(remote.lease, preview);
      expect(result.imageCount, 1);
    },
  );

  test(
    'remote original is freshly authorized, hash checked and downloaded once',
    () async {
      remote.images[qid(42)] = exportPicture();
      final preview = await service.preview(f.space, [qa]);
      expect(preview.unknownSizeCount, 1);
      await service.export(remote.lease, preview);
      expect(remote.downloads, 1);
      expect(saver.destination.published, isNotNull);
      expect(
        await attachments.cached(f.space, qEpoch, qid(42), 'original'),
        exportPicture(),
      );
    },
  );

  for (final changeRevision in [false, true]) {
    test(
      'selected ${changeRevision ? 'revision' : 'same-revision body'} change invalidates preview before choosing',
      () async {
        await stage(42);
        final preview = await service.preview(f.space, [qa]);
        final data = (await f.entity(qa)).projection;
        if (!changeRevision) {
          data['payload'] = {...(await f.entity(qa)).payload, 'note': '后续更改'};
        }
        await f.put(
          'bill',
          qa,
          qBook,
          data,
          revision: changeRevision ? '2' : '1',
        );
        await expectLater(
          service.export(remote.lease, preview),
          throwsA(
            isA<ApiFailure>().having(
              (e) => e.code,
              'code',
              'image_export_stale',
            ),
          ),
        );
        expect(saver.chosen, 0);
      },
    );
  }

  for (final serverRevoked in [false, true]) {
    test(
      '${serverRevoked ? 'server revocation' : 'identity switch'} while system dialog is open never writes bytes',
      () async {
        await stage(42);
        final preview = await service.preview(f.space, [qa]);
        saver.onChoose = () async {
          if (serverRevoked) {
            remote.roles.remove(qBook);
          } else {
            remote.current = false;
          }
        };
        await expectLater(
          service.export(remote.lease, preview),
          throwsA(isA<ApiFailure>()),
        );
        expect(saver.destination.published, isNull);
        expect(saver.destination.discarded, isTrue);
      },
    );
  }

  test(
    'missing local original prevents the whole archive and leaves other originals alone',
    () async {
      await stage(42);
      await stage(43);
      final missing = (await attachments.get(f.space, qid(43)))!;
      await bytes.delete(missing.blobKey);
      final preview = await service.preview(f.space, [qa, qf]);
      await expectLater(
        service.export(remote.lease, preview),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.code,
            'code',
            'local_attachment_missing',
          ),
        ),
      );
      expect(saver.chosen, 0);
      expect(
        await attachments.original(
          f.space,
          (await attachments.get(f.space, qid(42)))!,
        ),
        exportPicture(),
      );
    },
  );

  test('a remote hash mismatch returns no partial file', () async {
    remote.images[qid(42)] = exportPicture();
    remote.badHash = true;
    final preview = await service.preview(f.space, [qa]);
    await expectLater(
      service.export(remote.lease, preview),
      throwsA(isA<ApiFailure>().having((e) => e.code, 'code', 'hash_mismatch')),
    );
    expect(saver.chosen, 0);
    expect(saver.destination.published, isNull);
  });

  test(
    'unknown cumulative original size is bounded and never emits a partial ZIP',
    () async {
      final large = Uint8List(8 * 1024 * 1024)
        ..setRange(0, exportPicture().length, exportPicture());
      for (final id in [42, 43, 44]) {
        remote.images[qid(id)] = large;
      }
      await refs(qa, [qid(42), qid(43), qid(44)]);
      final preview = await service.preview(f.space, [qa]);
      expect(preview.canExport, isTrue);
      await expectLater(
        service.export(remote.lease, preview),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.code,
            'code',
            'image_export_size_limit',
          ),
        ),
      );
      expect(saver.chosen, 0);
      expect(saver.destination.published, isNull);
    },
  );

  test(
    'local revocation during original download prevents destination selection',
    () async {
      remote.images[qid(42)] = exportPicture();
      final preview = await service.preview(f.space, [qa]);
      remote.afterDownload = () => f.sync.revokeScope(f.space, qBook);
      await expectLater(
        service.export(remote.lease, preview),
        throwsA(isA<ApiFailure>()),
      );
      expect(saver.chosen, 0);
    },
  );

  test('cancellation publishes nothing and preserves originals', () async {
    await stage(42);
    saver.cancel = true;
    final preview = await service.preview(f.space, [qa]);
    final result = await service.export(remote.lease, preview);
    expect(result.status, LedgerImageExportStatus.cancelled);
    expect(result.imageCount, 0);
    expect(result.archiveBytes, 0);
    expect(saver.destination.published, isNull);
    expect(
      await attachments.original(
        f.space,
        (await attachments.get(f.space, qid(42)))!,
      ),
      exportPicture(),
    );
  });

  test(
    'revalidation before publish discards an unfinished destination',
    () async {
      await stage(42);
      final preview = await service.preview(f.space, [qa]);
      saver.destination.afterStaging = () async => remote.current = false;
      await expectLater(
        service.export(remote.lease, preview),
        throwsA(isA<ApiFailure>()),
      );
      expect(saver.destination.published, isNull);
      expect(saver.destination.discarded, isTrue);
    },
  );

  test(
    'empty selection, missing bills and recovery produce no exportable preview',
    () async {
      final empty = await service.preview(f.space, [qb]);
      expect(empty.canExport, isFalse);
      expect(
        empty.issues.map((e) => e.code),
        contains('image_export_no_images'),
      );
      final missing = await service.preview(f.space, [qid(999)]);
      expect(
        missing.issues.singleWhere((e) => e.billId != null).billId,
        qid(999),
      );
      await expectLater(
        f.sync.configure(f.space, qid(5), qid(999)),
        throwsStateError,
      );
      expect((await service.preview(f.space, [qa])).canExport, isFalse);
    },
  );

  test('concurrent export taps cannot start a second destination', () async {
    await stage(42);
    final preview = await service.preview(f.space, [qa]);
    final entered = Completer<void>(), release = Completer<void>();
    saver.onChoose = () async {
      entered.complete();
      await release.future;
    };
    final first = service.export(remote.lease, preview);
    await entered.future;
    await expectLater(
      service.export(remote.lease, preview),
      throwsA(
        isA<ApiFailure>().having((e) => e.code, 'code', 'image_export_busy'),
      ),
    );
    release.complete();
    await first;
    expect(saver.chosen, 1);
  });

  test(
    'input limit rejects duplicates beyond the bound instead of silently truncating later bills',
    () async {
      await expectLater(
        service.preview(f.space, [...List.filled(1001, qa), qf]),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.code,
            'code',
            'image_export_selection_limit',
          ),
        ),
      );
      expect(saver.chosen, 0);
    },
  );

  test(
    'too many image references cannot create any export destination',
    () async {
      final ids = <String>[];
      for (var row = 0; row < 6; row++) {
        final bill = qid(1000 + row);
        ids.add(bill);
        await f.putBill(bill, {
          'bill_type': 'income',
          'money': qmoney('1'),
          'attachment_ids': [
            for (var image = 0; image < 20; image++)
              qid(2000 + row * 20 + image),
          ],
        });
      }
      final preview = await service.preview(f.space, ids);
      expect(preview.canExport, isFalse);
      expect(preview.imageCount, 120);
      expect(
        preview.issues.map((e) => e.code),
        contains('image_export_image_limit'),
      );
      await expectLater(
        service.export(remote.lease, preview),
        throwsA(isA<ApiFailure>()),
      );
      expect(saver.chosen, 0);
    },
  );
}
