@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flowtrace/data/attachments/byte_store.dart';
import 'package:flowtrace/data/attachments/byte_store_web.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'real IndexedDB commit survives connection reopen and immutable collision is rejected',
    () async {
      final name =
          'flowtrace-attachments-test-${DateTime.now().microsecondsSinceEpoch}';
      final key = 'a' * 64;
      final first = WebAttachmentBytes(databaseName: name);
      final input = Uint8List.fromList([1, 2, 3, 4]);
      final pending = first.write(key, input);
      input[0] = 99;
      await pending;
      await first.close();
      final second = WebAttachmentBytes(databaseName: name);
      try {
        expect(await second.read(key), [1, 2, 3, 4]);
        await expectLater(
          second.write(key, Uint8List.fromList([9])),
          throwsA(isA<AttachmentStorageFailure>()),
        );
        expect(await second.read(key), [1, 2, 3, 4]);
        await second.delete(key);
        expect(await second.read(key), isNull);
      } finally {
        await second.close();
      }
    },
  );
}
