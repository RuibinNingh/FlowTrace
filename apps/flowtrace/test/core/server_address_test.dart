import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';

void main() {
  test('normalizes server origin and retains a deployment prefix', () {
    final address = ServerAddress.parse(' HTTPS://Example.COM/flowtrace/ ');
    expect(address.toString(), 'https://example.com/flowtrace');
    expect(
      address.resolve('/health/live').toString(),
      'https://example.com/flowtrace/health/live',
    );
  });

  test('rejects credentials, public HTTP, query and incomplete addresses', () {
    for (final input in [
      'example.com',
      'file:///tmp/a',
      'https://user:password@example.com',
      'https://example.com?token=secret',
      'https://example.com#fragment',
      'http://example.com',
    ]) {
      expect(
        () => ServerAddress.parse(input),
        throwsFormatException,
        reason: input,
      );
    }
    expect(
      ServerAddress.parse('http://127.0.0.1:18080').toString(),
      'http://127.0.0.1:18080',
    );
    expect(ServerAddress.parse('http://10.0.2.2:18080').uri.host, '10.0.2.2');
  });

  test('origin, instance and user all partition the local data space', () {
    DataSpace space(String address, String instance, String user) => DataSpace(
      server: ServerAddress.parse(address),
      serverInstanceId: instance,
      userId: user,
    );
    final original = space('https://one.example', 'instance-a', 'alice');
    expect(
      original.id,
      space('https://ONE.example/', 'instance-a', 'alice').id,
    );
    expect(
      original.id,
      isNot(space('https://one.example', 'instance-a', 'bob').id),
    );
    expect(
      original.id,
      isNot(space('https://one.example', 'instance-b', 'alice').id),
    );
    expect(
      original.id,
      isNot(space('https://two.example', 'instance-a', 'alice').id),
    );
  });
}
