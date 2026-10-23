import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/features/protection/password_deriver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('PBKDF2-HMAC-SHA256 matches independent standard vector', () async {
    final bytes = await createPasswordDeriver().derive('password', [
      115,
      97,
      108,
      116,
    ], iterations: 1);
    expect(
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
    );
  });
  test('production work factor runs off the native UI isolate', () async {
    var ticks = 0;
    final ticker = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => ticks++,
    );
    try {
      final result = await createPasswordDeriver().derive(
        'synthetic-only-password',
        List<int>.generate(32, (index) => index),
        iterations: 600000,
      );
      expect(result.length, 32);
      expect(ticks, greaterThan(0));
    } finally {
      ticker.cancel();
    }
  });
}
