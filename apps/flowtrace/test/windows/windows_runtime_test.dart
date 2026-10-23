import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/platform/windows/windows_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(WindowsRuntime.channel, null),
  );

  test('uses the native leased canonical directory', () async {
    messenger.setMockMethodCallHandler(WindowsRuntime.channel, (call) async {
      expect(call.method, 'dataDirectory');
      return {'path': r'C:\isolated\FlowTrace', 'leaseHeld': true};
    });
    expect(
      (await WindowsRuntime.dataDirectory()).path,
      r'C:\isolated\FlowTrace',
    );
  }, skip: !Platform.isWindows);

  for (final value in <Map<String, Object?>>[
    {'path': r'C:\isolated\FlowTrace', 'leaseHeld': false},
    {'path': r'\\server\share', 'leaseHeld': true},
    {'path': 'relative', 'leaseHeld': true},
    {'leaseHeld': true},
  ]) {
    test(
      'refuses an unleased or invalid native directory $value',
      () async {
        messenger.setMockMethodCallHandler(
          WindowsRuntime.channel,
          (_) async => value,
        );
        await expectLater(
          WindowsRuntime.dataDirectory(),
          throwsA(isA<FileSystemException>()),
        );
      },
      skip: !Platform.isWindows,
    );
  }
  test(
    'missing native lease channel never falls back to another DB',
    () async {
      await expectLater(
        WindowsRuntime.dataDirectory(),
        throwsA(isA<MissingPluginException>()),
      );
    },
    skip: !Platform.isWindows,
  );
}
