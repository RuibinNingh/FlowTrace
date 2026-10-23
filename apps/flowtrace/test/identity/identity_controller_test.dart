import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/core/security/session_vault.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';

const instanceId = '10000000-0000-4000-8000-000000000001';
const userId = '20000000-0000-4000-8000-000000000001';
const sessionId = '30000000-0000-4000-8000-000000000001';
const epoch = '40000000-0000-4000-8000-000000000001';
const address = 'https://flowtrace.example.test';

final class MemoryVault implements SessionVault {
  final values = <String, String>{};
  bool failWrites = false;
  bool failDeletes = false;
  Completer<void>? readGate;
  Completer<void>? writeGate;
  bool readPending = false;
  bool writePending = false;
  int calls = 0;
  @override
  Future<String?> read(String key) async {
    calls++;
    readPending = true;
    await readGate?.future;
    readPending = false;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    calls++;
    writePending = true;
    await writeGate?.future;
    writePending = false;
    if (failWrites) throw StateError('Synthetic vault failure');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    calls++;
    if (failDeletes) throw StateError('Synthetic deletion failure');
    values.remove(key);
  }
}

final class Rig {
  Rig({this.web = false}) {
    identity = _makeController();
  }
  final bool web;
  final db = AppDatabase(NativeDatabase.memory());
  final vault = MemoryVault();
  final requests = <http.Request>[];
  late IdentityController identity;
  Future<http.Response?> Function(http.Request)? intercept;
  String instance = instanceId;

  http.Response jsonResponse(Map<String, Object?> json, [int status = 200]) =>
      http.Response(
        jsonEncode(json),
        status,
        headers: {'Content-Type': 'application/json'},
      );
  http.Response error(String code, [int status = 401]) => jsonResponse({
    'error': {'code': code, 'message': 'must never echo this', 'details': {}},
  }, status);
  http.Response tokens({bool rotated = false}) => jsonResponse({
    'access_token': rotated ? 'synthetic-access-two' : 'synthetic-access-one',
    if (!web)
      'refresh_token': rotated
          ? 'synthetic-refresh-two'
          : 'synthetic-refresh-one',
    if (!rotated) 'csrf_token': 'synthetic-csrf',
    'token_type': 'bearer',
    'expires_in': 900,
    'session_id': sessionId,
    'user_id': userId,
  });
  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final intercepted = await intercept?.call(request);
    if (intercepted != null) return intercepted;
    final path = request.url.path;
    if (path.endsWith('/server-info')) {
      return jsonResponse({
        'instance_id': instance,
        'sync_epoch': epoch,
        'minimum_protocol': 1,
        'capabilities': ['identity'],
      });
    }
    if (path.endsWith('/auth/login') || path.endsWith('/auth/register')) {
      return tokens();
    }
    if (path.endsWith('/auth/refresh')) return tokens(rotated: true);
    if (path.endsWith('/users/me')) {
      return jsonResponse({'id': userId, 'username': 'alice', 'enabled': true});
    }
    if (path.endsWith('/sessions') || path.endsWith('/books')) {
      return jsonResponse({'items': []});
    }
    if (path.endsWith('/auth/logout') || request.method == 'DELETE') {
      return http.Response('', 204);
    }
    return jsonResponse({'ok': true});
  }

  IdentityController _makeController() => IdentityController(
    repository: LocalRepository(db),
    api: ApiClient(MockClient(handle)),
    vault: vault,
    isWeb: web,
    csrfReader: () => 'synthetic-csrf',
  );
  Future<void> signIn({bool register = false}) async {
    await identity.configure(ServerAddress.parse(address));
    await identity.signIn(
      username: 'Alice',
      password: 'Synthetic-password-123',
      inviteToken: register ? 'Synthetic-invite-token-12345' : null,
    );
  }

  Future<void> restart() async {
    identity.dispose();
    identity = _makeController();
    await identity.configure(ServerAddress.parse(address));
  }

  Future<void> close() async {
    identity.dispose();
    await db.close();
  }

  int count(String suffix) =>
      requests.where((r) => r.url.path.endsWith(suffix)).length;
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Expected asynchronous protocol boundary was not reached.');
}

void main() {
  late Rig rig;
  setUp(() {
    rig = Rig();
  });
  tearDown(() => rig.close());

  test(
    'native invitation login persists only refresh in its scoped vault',
    () async {
      await rig.signIn(register: true);
      expect(rig.identity.online, isTrue);
      expect(rig.identity.accountSpace!.verified, isTrue);
      final rawSettings = jsonEncode(
        (await rig.db.select(rig.db.appSettings).get())
            .map((row) => {'key': row.key, 'value': row.value})
            .toList(),
      );
      expect(rawSettings, isNot(contains('synthetic-access')));
      expect(rawSettings, isNot(contains('synthetic-refresh')));
      expect(rawSettings, isNot(contains('Synthetic-password')));
      expect(rig.vault.values.values.single, 'synthetic-refresh-one');
      final request = rig.requests.singleWhere(
        (r) => r.url.path.endsWith('/auth/register'),
      );
      expect(jsonDecode(request.body)['client_kind'], 'native');
      expect(
        jsonDecode(request.body)['invite_token'],
        'Synthetic-invite-token-12345',
      );
      expect(request.followRedirects, isFalse);
    },
  );

  test(
    'restart discovers the same instance then rotates refresh before resuming',
    () async {
      await rig.signIn();
      final space = rig.identity.accountSpace!.id;
      await rig.restart();
      expect(rig.identity.online, isTrue);
      expect(rig.identity.accountSpace!.id, space);
      expect(rig.count('/auth/refresh'), 1);
      expect(rig.vault.values.values.single, 'synthetic-refresh-two');
    },
  );

  test(
    'two concurrent 401 requests share one refresh and retry with new access',
    () async {
      await rig.signIn();
      final gate = Completer<void>();
      rig.intercept = (request) async {
        if (request.url.path.endsWith('/probe') &&
            request.headers['Authorization'] == 'Bearer synthetic-access-one') {
          return rig.error('session_invalid');
        }
        if (request.url.path.endsWith('/auth/refresh')) {
          await gate.future;
          return rig.tokens(rotated: true);
        }
        return null;
      };
      final first = rig.identity.authorizedRequest('GET', '/probe');
      final second = rig.identity.authorizedRequest('GET', '/probe');
      await until(() => rig.count('/auth/refresh') == 1);
      gate.complete();
      final results = await Future.wait([first, second]);
      expect(results.every((r) => r['ok'] == true), isTrue);
      expect(rig.count('/auth/refresh'), 1);
    },
  );

  test(
    'invalid refresh clears online state and remembered credentials',
    () async {
      await rig.signIn();
      rig.intercept = (r) async => r.url.path.endsWith('/probe')
          ? rig.error('session_invalid')
          : r.url.path.endsWith('/auth/refresh')
          ? rig.error('refresh_reuse')
          : null;
      await expectLater(
        rig.identity.authorizedRequest('GET', '/probe'),
        throwsA(isA<ApiFailure>()),
      );
      expect(rig.identity.account, isNull);
      expect(rig.identity.online, isFalse);
      expect(rig.vault.values, isEmpty);
    },
  );

  test(
    'lost refresh reply removes stale refresh and never resends it',
    () async {
      await rig.signIn();
      rig.intercept = (r) async {
        if (r.url.path.endsWith('/probe')) return rig.error('session_invalid');
        if (r.url.path.endsWith('/auth/refresh')) {
          throw http.ClientException('synthetic lost reply');
        }
        return null;
      };
      await expectLater(
        rig.identity.authorizedRequest('GET', '/probe'),
        throwsA(isA<ApiFailure>()),
      );
      expect(rig.identity.online, isFalse);
      expect(rig.identity.status, IdentityStatus.offline);
      expect(rig.vault.values, isEmpty);
      await expectLater(
        rig.identity.authorizedRequest('GET', '/probe'),
        throwsA(isA<ApiFailure>()),
      );
      expect(rig.count('/auth/refresh'), 1);
    },
  );

  test(
    'different server instance never receives the old refresh value',
    () async {
      await rig.signIn();
      rig.instance = '10000000-0000-4000-8000-000000000002';
      await rig.restart();
      expect(rig.identity.status, IdentityStatus.serverChanged);
      expect(rig.identity.account, isNull);
      expect(rig.count('/auth/refresh'), 0);
      expect(rig.vault.values, isNotEmpty);
    },
  );

  test(
    'server switch cancels a late login before any credentials are persisted',
    () async {
      await rig.identity.configure(ServerAddress.parse(address));
      final gate = Completer<void>();
      rig.intercept = (r) async {
        if (r.url.path.endsWith('/auth/login')) {
          await gate.future;
          return rig.tokens();
        }
        return null;
      };
      final login = rig.identity.signIn(
        username: 'alice',
        password: 'Synthetic-password-123',
      );
      final rejected = expectLater(
        login,
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      await until(() => rig.count('/auth/login') == 1);
      final switched = rig.identity.configure(
        ServerAddress.parse('https://second.example.test'),
      );
      gate.complete();
      await rejected;
      await switched;
      expect(rig.identity.account, isNull);
      expect(rig.vault.values, isEmpty);
      expect(rig.count('/users/me'), 0);
    },
  );

  test(
    'expected space epoch and client leases reject before sending a request',
    () async {
      await rig.signIn();
      for (final values in [
        {
          'space': 'another-space',
          'epoch': epoch,
          'client': rig.identity.clientId,
        },
        {
          'space': rig.identity.accountSpace!.id,
          'epoch': 'another-epoch',
          'client': rig.identity.clientId,
        },
        {
          'space': rig.identity.accountSpace!.id,
          'epoch': epoch,
          'client': 'another-client',
        },
      ]) {
        await expectLater(
          rig.identity.authorizedRequest(
            'POST',
            '/probe',
            expectedSpaceId: values['space'],
            expectedEpoch: values['epoch'],
            expectedClientId: values['client'],
          ),
          throwsA(
            isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
          ),
        );
      }
      expect(rig.count('/probe'), 0);
    },
  );

  test(
    'a server switch while reading the vault cannot forward old refresh',
    () async {
      await rig.signIn();
      rig.vault.readGate = Completer<void>();
      rig.intercept = (r) async =>
          r.url.path.endsWith('/probe') ? rig.error('session_invalid') : null;
      final request = rig.identity.authorizedRequest('GET', '/probe');
      final rejected = expectLater(
        request,
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      await until(() => rig.vault.readPending);
      final change = rig.identity.configure(
        ServerAddress.parse('https://second.example.test'),
      );
      rig.vault.readGate!.complete();
      await rejected;
      await change;
      expect(rig.count('/auth/refresh'), 0);
      expect(rig.identity.account, isNull);
    },
  );

  test(
    'failed vault write cleanup stays on the issuing server after a switch',
    () async {
      await rig.identity.configure(ServerAddress.parse(address));
      rig.vault.writeGate = Completer<void>();
      rig.vault.failWrites = true;
      final login = rig.identity.signIn(
        username: 'alice',
        password: 'Synthetic-password-123',
      );
      final rejected = expectLater(login, throwsA(isA<ApiFailure>()));
      await until(() => rig.vault.writePending);
      final change = rig.identity.configure(
        ServerAddress.parse('https://second.example.test'),
      );
      rig.vault.writeGate!.complete();
      await rejected;
      await change;
      final logout = rig.requests.singleWhere(
        (r) => r.url.path.endsWith('/auth/logout'),
      );
      expect(logout.url.host, 'flowtrace.example.test');
      expect(
        rig.requests.where(
          (r) =>
              r.url.host == 'second.example.test' &&
              r.headers.containsKey('Authorization'),
        ),
        isEmpty,
      );
      expect(rig.identity.account, isNull);
    },
  );

  test(
    'frozen JSON is sent as identical UTF8 bytes across a refresh retry',
    () async {
      await rig.signIn();
      rig.intercept = (r) async =>
          r.url.path.endsWith('/probe') &&
              r.headers['Authorization'] == 'Bearer synthetic-access-one'
          ? rig.error('session_invalid')
          : null;
      const body =
          '{"operations":[{"remark":"合成🌊","amount_minor":"9007199254740993"}],"protocol_version":1}';
      await rig.identity.authorizedRequest(
        'POST',
        '/probe',
        bodyJson: body,
        expectedSpaceId: rig.identity.accountSpace!.id,
        expectedEpoch: epoch,
        expectedClientId: rig.identity.clientId,
      );
      final posts = rig.requests
          .where((r) => r.url.path.endsWith('/probe'))
          .toList();
      expect(posts, hasLength(2));
      expect(posts[0].bodyBytes, utf8.encode(body));
      expect(posts[1].bodyBytes, posts[0].bodyBytes);
    },
  );

  test(
    'offline logout forgets local credentials without claiming server revocation',
    () async {
      await rig.signIn();
      rig.intercept = (r) async {
        if (r.url.path.endsWith('/auth/logout')) {
          throw http.ClientException('synthetic offline');
        }
        return null;
      };
      await rig.identity.signOut();
      expect(rig.identity.account, isNull);
      expect(rig.vault.values, isEmpty);
      expect(rig.identity.message, contains('服务器撤销未确认'));
    },
  );

  test(
    'vault write failure revokes the issued session and never announces login',
    () async {
      rig.vault.failWrites = true;
      await expectLater(
        rig.signIn(),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'vault_unavailable'),
        ),
      );
      expect(rig.identity.online, isFalse);
      expect(rig.identity.account, isNull);
      expect(rig.count('/auth/logout'), 1);
    },
  );

  test(
    'vault deletion failure stops requests immediately and permits explicit retry',
    () async {
      await rig.signIn();
      rig.vault.failDeletes = true;
      await rig.identity.signOut();
      expect(rig.identity.account, isNull);
      expect(rig.identity.online, isFalse);
      expect(rig.identity.credentialCleanupFailed, isTrue);
      await expectLater(
        rig.identity.authorizedRequest('GET', '/probe'),
        throwsA(isA<ApiFailure>()),
      );
      expect(rig.count('/probe'), 0);
      rig.vault.failDeletes = false;
      await rig.identity.retryCredentialCleanup();
      expect(rig.identity.credentialCleanupFailed, isFalse);
      expect(rig.vault.values, isEmpty);
    },
  );

  test(
    'revoking the current session returns to the signed-out space',
    () async {
      await rig.signIn();
      await rig.identity.revokeSession(sessionId);
      expect(rig.identity.accountSpace, isNull);
      expect(rig.vault.values, isEmpty);
    },
  );

  test(
    'web never writes refresh or access to the native vault and sends CSRF',
    () async {
      await rig.close();
      rig = Rig(web: true);
      await rig.signIn();
      rig.intercept = (r) async =>
          r.url.path.endsWith('/probe') &&
              r.headers['Authorization'] == 'Bearer synthetic-access-one'
          ? rig.error('session_invalid')
          : null;
      await rig.identity.authorizedRequest(
        'POST',
        '/probe',
        body: {'synthetic': true},
      );
      final refresh = rig.requests.singleWhere(
        (r) => r.url.path.endsWith('/auth/refresh'),
      );
      expect(jsonDecode(refresh.body), {'client_kind': 'web'});
      expect(refresh.headers['X-CSRF-Token'], 'synthetic-csrf');
      expect(rig.vault.calls, 0);
    },
  );

  test(
    'same-user relogin invalidates an already pending request generation',
    () async {
      await rig.signIn();
      final originalGeneration = rig.identity.sessionGeneration;
      final originalSpace = rig.identity.accountSpace!.id;
      final gate = Completer<void>();
      rig.intercept = (r) async {
        if (r.url.path.endsWith('/probe')) {
          await gate.future;
          return rig.jsonResponse({'ok': true});
        }
        return null;
      };
      final request = rig.identity.authorizedRequest(
        'GET',
        '/probe',
        expectedSpaceId: originalSpace,
      );
      final rejected = expectLater(
        request,
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      await until(() => rig.count('/probe') == 1);
      await rig.identity.signOut();
      await rig.identity.signIn(
        username: 'alice',
        password: 'Synthetic-password-123',
      );
      expect(rig.identity.accountSpace!.id, originalSpace);
      expect(rig.identity.sessionGeneration, greaterThan(originalGeneration));
      gate.complete();
      await rejected;
    },
  );

  test(
    'explicit recovery rotation preserves local drafts and requires new login',
    () async {
      await rig.signIn();
      final space = rig.identity.accountSpace!;
      final generation = rig.identity.sessionGeneration;
      final oldClient = rig.identity.clientId;
      await LocalRepository(rig.db).registerSpace(space);
      await LocalRepository(
        rig.db,
      ).saveDraft(space, 'Synthetic recovery draft');
      await rig.identity.rotateClientForRecovery(
        expectedSpaceId: space.id,
        expectedGeneration: generation,
      );
      expect(rig.identity.online, isFalse);
      expect(rig.identity.account, isNull);
      expect(rig.identity.clientId, isNot(oldClient));
      expect(rig.identity.sessionGeneration, greaterThan(generation));
      expect(
        (await LocalRepository(rig.db).drafts(space)).single.body,
        'Synthetic recovery draft',
      );
      expect(rig.vault.values, isEmpty);
    },
  );

  test(
    'stale recovery confirmation cannot revoke the current identity',
    () async {
      await rig.signIn();
      await expectLater(
        rig.identity.rotateClientForRecovery(
          expectedSpaceId: rig.identity.accountSpace!.id,
          expectedGeneration: rig.identity.sessionGeneration - 1,
        ),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      expect(rig.identity.online, isTrue);
      expect(rig.count('/auth/logout'), 0);
    },
  );

  test(
    'binary upload freezes bytes and media type across refresh retry',
    () async {
      await rig.signIn();
      final gate = Completer<void>();
      rig.intercept = (r) async {
        if (r.url.path.endsWith('/binary-probe') &&
            r.headers['Authorization'] == 'Bearer synthetic-access-one') {
          return rig.error('session_invalid');
        }
        if (r.url.path.endsWith('/auth/refresh')) {
          await gate.future;
          return rig.tokens(rotated: true);
        }
        return null;
      };
      final bytes = Uint8List.fromList([137, 80, 78, 71, 0, 255]);
      final upload = rig.identity.authorizedRequest(
        'PUT',
        '/binary-probe',
        bodyBytes: bytes,
        contentType: 'image/png',
      );
      await until(() => rig.count('/auth/refresh') == 1);
      bytes[0] = 99;
      gate.complete();
      await upload;
      final attempts = rig.requests
          .where((r) => r.url.path.endsWith('/binary-probe'))
          .toList();
      expect(attempts, hasLength(2));
      expect(attempts[0].bodyBytes, [137, 80, 78, 71, 0, 255]);
      expect(attempts[1].bodyBytes, attempts[0].bodyBytes);
      expect(attempts[1].headers['Content-Type'], 'image/png');
    },
  );

  test(
    'authorized binary download refreshes once and enforces the size bound',
    () async {
      await rig.signIn();
      rig.intercept = (r) async {
        if (r.url.path.endsWith('/content-probe')) {
          if (r.headers['Authorization'] == 'Bearer synthetic-access-one') {
            return rig.error('session_invalid');
          }
          return http.Response.bytes(
            [137, 80, 78, 71, 255],
            200,
            headers: {'Content-Type': 'image/png'},
          );
        }
        return null;
      };
      expect(
        await rig.identity.authorizedDownload('/content-probe', maxBytes: 5),
        [137, 80, 78, 71, 255],
      );
      expect(rig.count('/auth/refresh'), 1);
      await expectLater(
        rig.identity.authorizedDownload('/content-probe', maxBytes: 4),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'response_too_large'),
        ),
      );
      expect(rig.count('/auth/refresh'), 1);
    },
  );

  test(
    'a binary response is discarded after switching server identity',
    () async {
      await rig.signIn();
      final gate = Completer<void>();
      rig.intercept = (r) async {
        if (r.url.path.endsWith('/content-probe')) {
          await gate.future;
          return http.Response.bytes([1, 2, 3], 200);
        }
        return null;
      };
      final download = rig.identity.authorizedDownload('/content-probe');
      final rejected = expectLater(
        download,
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      await until(() => rig.count('/content-probe') == 1);
      await rig.identity.configure(
        ServerAddress.parse('https://second.example.test'),
      );
      gate.complete();
      await rejected;
    },
  );

  test(
    'POST download freezes exact filters across refresh and returns bounded bytes',
    () async {
      await rig.signIn();
      final refresh = Completer<void>();
      rig.intercept = (request) async {
        if (request.url.path.endsWith('/auth/refresh')) await refresh.future;
        if (request.url.path.endsWith('/data-tools/exports/xlsx')) {
          if (request.headers['Authorization'] ==
              'Bearer synthetic-access-one') {
            return rig.error('session_invalid');
          }
          return http.Response.bytes([80, 75, 3, 4], 200);
        }
        return null;
      };
      final body = <String, Object?>{
        'scope_ids': [userId],
        'include_images': 'links',
      };
      final frozen = jsonEncode(body);
      final download = rig.identity.authorizedDownload(
        '/data-tools/exports/xlsx',
        method: 'POST',
        body: body,
        maxBytes: 4,
        expectedSpaceId: rig.identity.accountSpace!.id,
        expectedEpoch: epoch,
        expectedClientId: rig.identity.clientId,
      );
      await until(() => rig.count('/auth/refresh') == 1);
      (body['scope_ids'] as List).clear();
      refresh.complete();
      expect(await download, [80, 75, 3, 4]);
      final attempts = rig.requests
          .where((r) => r.url.path.endsWith('/data-tools/exports/xlsx'))
          .toList();
      expect(attempts, hasLength(2));
      for (final request in attempts) {
        expect(request.method, 'POST');
        expect(request.body, frozen);
        expect(request.headers['Content-Type'], 'application/json');
        expect(request.bodyBytes, utf8.encode(frozen));
      }
      await expectLater(
        rig.identity.authorizedDownload(
          '/data-tools/exports/xlsx',
          method: 'POST',
          bodyJson: frozen,
          maxBytes: 3,
        ),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'response_too_large'),
        ),
      );
    },
  );

  test(
    'download rejects contradictory bodies and unsupported methods before transport',
    () async {
      await rig.signIn();
      expect(
        () => rig.identity.authorizedDownload(
          '/download',
          method: 'POST',
          body: {},
          bodyJson: '{}',
        ),
        throwsArgumentError,
      );
      expect(
        () => rig.identity.authorizedDownload('/download', method: 'DELETE'),
        throwsArgumentError,
      );
      expect(
        () => rig.identity.authorizedDownload('/download', bodyJson: '{}'),
        throwsArgumentError,
      );
      expect(rig.count('/download'), 0);
    },
  );

  test(
    'JSON and binary request bodies are mutually exclusive before sending',
    () async {
      await rig.signIn();
      expect(
        () => rig.identity.authorizedRequest(
          'PUT',
          '/probe',
          body: {'test': true},
          bodyBytes: Uint8List(1),
        ),
        throwsArgumentError,
      );
      expect(rig.count('/probe'), 0);
    },
  );

  test(
    'diagnostic response metadata is bound to the captured account space',
    () async {
      await rig.signIn();
      final expectedSpace = rig.identity.accountSpace!.id;
      final observedSpaces = <String>[];
      final observed = <ApiRequestMetadata>[];
      rig.identity.onRequestMetadata = (space, metadata) {
        observedSpaces.add(space.id);
        observed.add(metadata);
      };
      rig.intercept = (r) async => r.url.path.endsWith('/sync/metadata-probe')
          ? http.Response(
              '{"ok":true}',
              200,
              headers: {'x-request-id': '12345678-abcd-4000-8000-1234567890ab'},
            )
          : null;
      await rig.identity.authorizedRequest(
        'GET',
        '/sync/metadata-probe?private=query',
        diagnosticOperationId: '87654321-abcd-4000-8000-1234567890ab',
      );
      expect(observedSpaces, [expectedSpace]);
      expect(observed.single.category, ApiCategory.sync);
      expect(observed.single.requestId, '12345678-abcd-4000-8000-1234567890ab');
      expect(
        observed.single.operationId,
        '87654321-abcd-4000-8000-1234567890ab',
      );
    },
  );

  test(
    'a late response cannot write diagnostics into a replacement identity',
    () async {
      await rig.signIn();
      final gate = Completer<void>();
      final observed = <ApiRequestMetadata>[];
      rig.identity.onRequestMetadata = (space, metadata) =>
          observed.add(metadata);
      rig.intercept = (r) async {
        if (r.url.path.endsWith('/sync/metadata-probe')) {
          await gate.future;
          return http.Response(
            '{"ok":true}',
            200,
            headers: {'x-request-id': '12345678-abcd-4000-8000-1234567890ab'},
          );
        }
        return null;
      };
      final request = rig.identity.authorizedRequest(
        'GET',
        '/sync/metadata-probe',
        diagnosticOperationId: '87654321-abcd-4000-8000-1234567890ab',
      );
      final rejected = expectLater(
        request,
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      await until(() => rig.count('/sync/metadata-probe') == 1);
      await rig.identity.configure(
        ServerAddress.parse('https://second.example.test'),
      );
      gate.complete();
      await rejected;
      expect(observed, isEmpty);
    },
  );

  test('invalid diagnostic operation data never enters the request', () async {
    await rig.signIn();
    final observed = <ApiRequestMetadata>[];
    rig.identity.onRequestMetadata = (space, metadata) =>
        observed.add(metadata);
    await rig.identity.authorizedRequest(
      'GET',
      '/sync/metadata-probe',
      diagnosticOperationId: 'private-invalid-operation-data',
    );
    expect(observed.single.operationId, isNull);
    final request = rig.requests.last;
    expect(request.body, isEmpty);
    expect(request.url.query, isEmpty);
    expect(
      request.headers.values,
      isNot(contains('private-invalid-operation-data')),
    );
    expect(rig.identity.online, isTrue);
  });

  test(
    'failing identity diagnostics never fail an authorized operation',
    () async {
      await rig.signIn();
      rig.identity.onRequestMetadata = (space, metadata) async {
        throw StateError('Synthetic diagnostics failure');
      };
      expect(
        await rig.identity.authorizedRequest('GET', '/sync/metadata-probe'),
        {'ok': true},
      );
      await Future<void>.delayed(Duration.zero);
      expect(rig.identity.online, isTrue);
    },
  );
}
