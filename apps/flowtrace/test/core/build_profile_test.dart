import 'package:flowtrace/core/config/build_profile.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ordinary native release requires HTTPS even for a loopback server', () {
    expect(
      allowsLocalHttp(
        debug: false,
        web: false,
        webHost: '127.0.0.1',
        localTest: false,
      ),
      isFalse,
    );
  });
  test('local test release can use the configured private HTTP service', () {
    expect(
      allowsLocalHttp(debug: false, web: false, webHost: '', localTest: true),
      isTrue,
    );
    expect(ServerAddress.parse('http://127.0.0.1:18090').uri.host, '127.0.0.1');
    expect(
      ServerAddress.parse('http://192.168.1.2:18090').uri.host,
      '192.168.1.2',
    );
    expect(
      () => ServerAddress.parse('http://public.example'),
      throwsFormatException,
    );
    expect(() => ServerAddress.parse('http://8.8.8.8'), throwsFormatException);
  });
  test(
    'loopback Web remains usable while normal remote Web requires HTTPS',
    () {
      for (final host in ['localhost', '127.0.0.1', '::1']) {
        expect(
          allowsLocalHttp(
            debug: false,
            web: true,
            webHost: host,
            localTest: false,
          ),
          isTrue,
        );
      }
      expect(
        allowsLocalHttp(
          debug: false,
          web: true,
          webHost: '192.168.1.2',
          localTest: false,
        ),
        isFalse,
      );
      expect(
        allowsLocalHttp(
          debug: false,
          web: true,
          webHost: 'public.example',
          localTest: false,
        ),
        isFalse,
      );
    },
  );
}
