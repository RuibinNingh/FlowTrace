import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/attachments/byte_store.dart';
import 'package:flowtrace/features/attachments/image_attachment_selector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'attachment_repository_test.dart' show picture;

final class SyntheticFile extends XFile {
  SyntheticFile(this.reported, this.content) : super('synthetic-file');
  final int reported;
  final Uint8List content;
  bool opened = false;
  int? boundedEnd;
  @override
  Future<int> length() async => reported;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    opened = true;
    boundedEnd = end;
    yield content;
  }
}

void main() {
  const selector = ImageAttachmentSelector();
  test(
    'actual PNG signature and pixel dimensions override an unreliable filename/MIME',
    () async {
      final result = await selector.read(
        XFile.fromData(
          picture(),
          name: 'not-a-jpeg.jpg',
          mimeType: 'image/jpeg',
        ),
      );
      expect(result.mediaType, 'image/png');
      expect((result.width, result.height), (3, 2));
      final changed = result.bytes..[0] = 0;
      expect(changed, isNot(result.bytes));
      expect(result.bytes, picture());
    },
  );
  test(
    'real filesystem XFile read is bounded and preserves original bytes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'flowtrace-selector-test-',
      );
      final file = File('${directory.path}/synthetic.png');
      try {
        await file.writeAsBytes(picture(), flush: true);
        expect((await selector.read(XFile(file.path))).bytes, picture());
      } finally {
        // Delete only the exact file and its empty directory created above.
        if (await file.exists()) await file.delete();
        await directory.delete();
      }
    },
  );
  test(
    'oversize metadata is rejected before opening the provider stream',
    () async {
      final file = SyntheticFile(attachmentMaxBytes + 1, Uint8List(0));
      await expectLater(
        selector.read(file),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.code,
            'code',
            'attachment_too_large',
          ),
        ),
      );
      expect(file.opened, isFalse);
    },
  );
  test(
    'lying provider cannot exceed the actual byte limit and slice end stays bounded',
    () async {
      final file = SyntheticFile(1, Uint8List(attachmentMaxBytes + 1));
      await expectLater(
        selector.read(file),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.code,
            'code',
            'attachment_too_large',
          ),
        ),
      );
      expect(file.boundedEnd, lessThanOrEqualTo(attachmentMaxBytes + 1));
    },
  );
  test(
    'provider truncation, fake image and corrupt image reject safely',
    () async {
      await expectLater(
        selector.read(SyntheticFile(picture().length + 1, picture())),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'attachment_changed'),
        ),
      );
      await expectLater(
        selector.read(
          XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'fake.png'),
        ),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'attachment_invalid'),
        ),
      );
      await expectLater(
        selector.read(
          XFile.fromData(picture().sublist(0, 24), name: 'partial.png'),
        ),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'attachment_invalid'),
        ),
      );
    },
  );
  test(
    '40MP guard rejects an oversized PNG header before raster decode',
    () async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAJxAAABOICAIAAACYNeAfAAAACUlEQVR4nGMAAAABAAFe/335AAAAAElFTkSuQmCC',
      );
      await expectLater(
        selector.read(XFile.fromData(bytes, name: 'large.png')),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'image_dimensions'),
        ),
      );
    },
  );
  test(
    'animated PNG is rejected even if a platform decoder exposes only its first frame',
    () async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAADAAAAAgAAAAAAAAAAAAEACgAAP7ZcWAAAABRJREFUeJxj1Gl5zQAGTBCKgYEBABxjAZ9DoyBrAAAAGmZjVEwAAAABAAAAAwAAAAIAAAAAAAAAAAABAAoAAKTFtowAAAAYZmRBVAAAAAJ4nGN8raHBAAZMEIqBgQEAFyUBPxo2rcAAAAAASUVORK5CYII=',
      );
      await expectLater(
        selector.read(XFile.fromData(bytes, name: 'animated.png')),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'image_animated'),
        ),
      );
    },
  );
}
