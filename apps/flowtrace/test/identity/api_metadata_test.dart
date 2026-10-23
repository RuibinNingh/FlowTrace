import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/network/api_failure.dart';

const requestId = '12345678-abcd-4000-8000-1234567890ab';
final server = ServerAddress.parse('https://flowtrace.example.test');

void main() {
  test(
    'HTTP metadata exposes an allowlisted category and validated request ID',
    () async {
      final observed = <ApiRequestMetadata>[];
      final client = ApiClient(
        MockClient(
          (request) async => http.Response(
            '{"ok":true,"private":"response-private"}',
            200,
            headers: {
              'X-Request-ID': requestId.toUpperCase(),
              'Set-Cookie': 'must-never-be-observed',
            },
          ),
        ),
      );
      addTearDown(client.close);
      final result = await client.request(
        server,
        'POST',
        '/sync/private-entity?token=query-private',
        body: {'private': 'body-private'},
        accessToken: 'access-private',
        onMetadata: observed.add,
      );
      expect(result['ok'], isTrue);
      final metadata = observed.single;
      expect(metadata.category, ApiCategory.sync);
      expect(metadata.requestId, requestId);
      expect(metadata.method, 'POST');
      expect(metadata.status, 200);
      expect(metadata.durationMs, inInclusiveRange(0, 86400000));
      expect(metadata.toString(), isNot(contains('private')));
    },
  );

  test(
    'error responses retain correlation without exposing error text',
    () async {
      final observed = <ApiRequestMetadata>[];
      final client = ApiClient(
        MockClient(
          (request) async => http.Response(
            jsonEncode({
              'error': {'code': 'scope_forbidden', 'message': 'private detail'},
            }),
            403,
            headers: {'x-request-id': requestId},
          ),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.request(
          server,
          'GET',
          '/books/private-book',
          onMetadata: observed.add,
        ),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
      );
      expect(observed.single.status, 403);
      expect(observed.single.requestId, requestId);
      expect(observed.single.category, ApiCategory.books);
    },
  );

  test(
    'slow and failing diagnostics do not delay or fail a response',
    () async {
      final pending = Completer<void>();
      final client = ApiClient(
        MockClient((request) async => http.Response('{"ok":true}', 200)),
      );
      addTearDown(client.close);
      expect(
        await client.request(
          server,
          'GET',
          '/users/me',
          onMetadata: (_) => pending.future,
        ),
        {'ok': true},
      );
      pending.completeError(
        StateError('Synthetic diagnostics storage failure'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        await client.request(
          server,
          'GET',
          '/users/me',
          onMetadata: (_) => throw StateError('Synthetic callback failure'),
        ),
        {'ok': true},
      );
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('binary downloads produce the same bounded metadata', () async {
    final observed = <ApiRequestMetadata>[];
    final client = ApiClient(
      MockClient(
        (request) async => http.Response.bytes(
          [137, 80, 78, 71],
          200,
          headers: {'x-request-id': requestId},
        ),
      ),
    );
    addTearDown(client.close);
    expect(
      await client.download(
        server,
        '/attachments/private-id/content',
        onMetadata: observed.add,
      ),
      [137, 80, 78, 71],
    );
    expect(observed.single.category, ApiCategory.attachments);
    expect(observed.single.requestId, requestId);
    expect(observed.single.method, 'GET');
  });

  test(
    'projection rejects arbitrary header and method data and bounds numbers',
    () {
      final invalid = ApiRequestMetadata.project(
        path: '/private-path?secret=private-query',
        method: 'GET',
        durationMs: -1,
        requestId: 'not-a-uuid-private-value',
        status: 999,
      )!;
      expect(invalid.category, ApiCategory.other);
      expect(invalid.requestId, isNull);
      expect(invalid.status, isNull);
      expect(invalid.durationMs, 0);
      expect(
        ApiRequestMetadata.project(
          path: '/',
          method: 'PRIVATE-METHOD',
          durationMs: 0,
        ),
        isNull,
      );
      expect(
        ApiRequestMetadata.project(
          path: '/server-info',
          method: 'GET',
          durationMs: 86400001,
        )!.durationMs,
        86400000,
      );
    },
  );

  test('network failures cannot invent a response ID or status', () async {
    final observed = <ApiRequestMetadata>[];
    final client = ApiClient(
      MockClient(
        (request) async => throw http.ClientException('private network text'),
      ),
    );
    addTearDown(client.close);
    await expectLater(
      client.request(server, 'GET', '/sync/scopes', onMetadata: observed.add),
      throwsA(
        isA<ApiFailure>().having((e) => e.code, 'code', 'network_unavailable'),
      ),
    );
    expect(observed.single.status, isNull);
    expect(observed.single.requestId, isNull);
    expect(observed.single.category, ApiCategory.sync);
  });

  test('operation correlation accepts only a canonical UUID', () {
    final base = ApiRequestMetadata.project(
      path: '/sync/push',
      method: 'POST',
      durationMs: 7,
      requestId: requestId,
      status: 200,
    )!;
    final linked = base.withOperationId(requestId);
    expect(base.operationId, isNull);
    expect(linked.operationId, requestId);
    expect(linked.requestId, requestId);
    expect(linked.category, ApiCategory.sync);
    expect(linked.status, 200);
    expect(linked.durationMs, 7);
    for (final invalid in [
      null,
      '',
      'private-body-fragment',
      requestId.toUpperCase(),
      '$requestId?private=query',
    ]) {
      expect(base.withOperationId(invalid).operationId, isNull);
    }
  });
}
