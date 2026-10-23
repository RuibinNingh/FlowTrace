import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flowtrace/data/ledger/image_export/saver_native.dart';
import 'package:flowtrace/data/ledger/image_export/target.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flowtrace/image_export/test');
  const token = '33333333-3333-4333-8333-333333333333';
  final zipBytes = Uint8List.fromList([80, 75, 3, 4, 1, 2]);
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'choose') return token;
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'SAF channel keeps URI native and separates choose, stage, guard and commit',
    () async {
      final saver = AndroidLedgerImageExportSaver(channel: channel);
      final destination = (await saver.choose())!;
      var checks = 0;
      final status = await destination.write(
        zipBytes,
        guard: () async {
          checks++;
        },
      );
      await destination.discard();
      expect(status, LedgerImageExportStatus.saved);
      expect(checks, 2);
      expect(calls.map((call) => call.method), ['choose', 'stage', 'commit']);
      expect((calls[1].arguments as Map).keys.toSet(), {'token', 'bytes'});
      expect((calls[1].arguments as Map)['token'], token);
    },
  );

  test(
    'SAF guard after staging rejects publication and discards its opaque selection',
    () async {
      final destination = (await AndroidLedgerImageExportSaver(
        channel: channel,
      ).choose())!;
      var checks = 0;
      await expectLater(
        destination.write(
          zipBytes,
          guard: () async {
            if (++checks == 2) throw StateError('synthetic identity switch');
          },
        ),
        throwsStateError,
      );
      await destination.discard();
      expect(calls.map((call) => call.method), ['choose', 'stage', 'discard']);
    },
  );

  for (final failBeforePublish in [false, true]) {
    test(
      'native selected path ${failBeforePublish ? 'keeps previous file on guard failure' : 'publishes full bytes'}',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'flowtrace-export-target-',
        );
        try {
          final file = File('${directory.path}/chosen.zip');
          await file.writeAsString('previous');
          final saver = WindowsLedgerImageExportSaver(
            chooseLocation: () async => FileSaveLocation(file.path),
          );
          final destination = (await saver.choose())!;
          var checks = 0;
          Future<void> guard() async {
            if (++checks == 2 && failBeforePublish) {
              throw StateError('synthetic revocation');
            }
          }

          if (failBeforePublish) {
            await expectLater(
              destination.write(zipBytes, guard: guard),
              throwsStateError,
            );
            await destination.discard();
            expect(await file.readAsString(), 'previous');
          } else {
            expect(
              await destination.write(zipBytes, guard: guard),
              LedgerImageExportStatus.saved,
            );
            await destination.discard();
            expect(await file.readAsBytes(), zipBytes);
          }
          expect(await directory.list().length, 1);
        } finally {
          expect(
            directory.absolute.parent.path,
            Directory.systemTemp.absolute.path,
          );
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
