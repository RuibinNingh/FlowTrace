import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_client.dart';

import '../identity/identity_controller_test.dart' show Rig;

const stageId = '00000000-0000-4000-8000-000000000001';
const chunkPath = '/data-tools/import-stages/$stageId/chunks/0?stage_version=1';
final server = ServerAddress.parse('https://stage-transport.isolated.example');

void main() {
  test(
    'only the dedicated chunk header is added to exact frozen binary bytes',
    () async {
      final bytes = Uint8List.fromList([0, 1, 127, 128, 255]);
      final original = Uint8List.fromList(bytes);
      final hash = sha256.convert(bytes).toString();
      final client = ApiClient(
        MockClient((request) async {
          expect(request.method, 'PUT');
          expect(
            request.url.path,
            '/api/v1/data-tools/import-stages/$stageId/chunks/0',
          );
          expect(request.headers['X-Chunk-SHA256'], hash);
          expect(request.headers['Content-Type'], 'application/octet-stream');
          expect(request.bodyBytes, original);
          return http.Response('{"ok":true}', 200);
        }),
      );
      addTearDown(client.close);
      final result = client.request(
        server,
        'PUT',
        chunkPath,
        bodyBytes: bytes,
        chunkSha256: hash,
      );
      bytes.fillRange(0, bytes.length, 42);
      expect((await result)['ok'], isTrue);
    },
  );

  test(
    'invalid method path hash size content type and version never reach HTTP',
    () async {
      var calls = 0;
      final client = ApiClient(
        MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(client.close);
      final bytes = Uint8List.fromList([1, 2, 3]);
      final hash = sha256.convert(bytes).toString();
      for (final method in ['GET', 'POST', 'DELETE']) {
        await expectLater(
          client.request(
            server,
            method,
            chunkPath,
            bodyBytes: bytes,
            chunkSha256: hash,
          ),
          throwsArgumentError,
        );
      }
      for (final path in [
        '/attachments/$stageId/content',
        '/data-tools/import-stages/$stageId/chunks/100?stage_version=1',
        '/data-tools/import-stages/$stageId/chunks/0?stage_version=0',
        '/data-tools/import-stages/$stageId/chunks/0?stage_version=2147483648',
        '$chunkPath&other=forbidden',
      ]) {
        await expectLater(
          client.request(
            server,
            'PUT',
            path,
            bodyBytes: bytes,
            chunkSha256: hash,
          ),
          throwsArgumentError,
        );
      }
      for (final invalidHash in [
        List.filled(64, 'a').join(),
        hash.toUpperCase(),
        '$hash\r\nOther: forbidden',
      ]) {
        await expectLater(
          client.request(
            server,
            'PUT',
            chunkPath,
            bodyBytes: bytes,
            chunkSha256: invalidHash,
          ),
          throwsArgumentError,
        );
      }
      for (final invalidBytes in [Uint8List(0), Uint8List(512 * 1024 + 1)]) {
        await expectLater(
          client.request(
            server,
            'PUT',
            chunkPath,
            bodyBytes: invalidBytes,
            chunkSha256: sha256.convert(invalidBytes).toString(),
          ),
          throwsArgumentError,
        );
      }
      await expectLater(
        client.request(
          server,
          'PUT',
          chunkPath,
          bodyBytes: bytes,
          contentType: 'text/plain',
          chunkSha256: hash,
        ),
        throwsArgumentError,
      );
      expect(calls, 0);
    },
  );

  test(
    'ordinary binary attachment requests retain their existing interface',
    () async {
      final client = ApiClient(
        MockClient((request) async {
          expect(request.headers.containsKey('X-Chunk-SHA256'), isFalse);
          expect(request.bodyBytes, [1, 2, 3]);
          return http.Response('{}', 200);
        }),
      );
      addTearDown(client.close);
      await client.request(
        server,
        'PUT',
        '/attachments/$stageId/content',
        bodyBytes: Uint8List.fromList([1, 2, 3]),
      );
    },
  );

  test(
    'identity 401 refresh retries the original chunk bytes and SHA after caller mutation',
    () async {
      final rig = Rig(web: true);
      addTearDown(rig.close);
      await rig.signIn();
      final bytes = Uint8List.fromList([7, 0, 255, 66]);
      final original = Uint8List.fromList(bytes);
      final hash = sha256.convert(bytes).toString();
      var uploads = 0;
      rig.intercept = (request) async {
        if (request.url.path.endsWith('/chunks/0')) {
          uploads++;
          expect(request.bodyBytes, original);
          expect(request.headers['X-Chunk-SHA256'], hash);
          expect(request.headers['X-CSRF-Token'], 'synthetic-csrf');
          return uploads == 1
              ? rig.error('session_invalid')
              : rig.jsonResponse({'ok': true});
        }
        if (request.url.path.endsWith('/auth/refresh')) {
          bytes.fillRange(0, bytes.length, 3);
        }
        return null;
      };
      final identity = rig.identity;
      final result = await identity.authorizedRequest(
        'PUT',
        chunkPath,
        bodyBytes: bytes,
        contentType: 'application/octet-stream',
        chunkSha256: hash,
        expectedSpaceId: identity.accountSpace!.id,
        expectedClientId: identity.clientId,
        expectedEpoch: identity.serverIdentity!.syncEpoch,
      );
      expect(result['ok'], isTrue);
      expect(uploads, 2);
      expect(rig.count('/auth/refresh'), 1);
      expect(bytes, [3, 3, 3, 3]);
    },
  );
}
