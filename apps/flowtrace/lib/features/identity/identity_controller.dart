import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../../core/config/build_profile.dart';
import '../../core/config/server_address.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_failure.dart';
import '../../core/network/platform_client.dart';
import '../../core/security/session_vault.dart';
import '../../data/local/local_repository.dart';
import 'identity_models.dart';

enum IdentityStatus { signedOut, restoring, online, offline, serverChanged }

typedef IdentityRequestObserver =
    FutureOr<void> Function(DataSpace space, ApiRequestMetadata metadata);

/// Access tokens live only in memory; native refresh values live in a vault.
/// Cached profile metadata does not grant online authorization.
final class IdentityController extends ChangeNotifier {
  IdentityController({
    required this.repository,
    required this.api,
    required this.vault,
    this.isWeb = kIsWeb,
    bool? allowLocalHttp,
    String? Function()? csrfReader,
    this.deviceName = 'FlowTrace',
    this.onRequestMetadata,
  }) : allowLocalHttp =
           allowLocalHttp ??
           allowsLocalHttp(
             debug: kDebugMode,
             web: kIsWeb,
             webHost: kIsWeb ? Uri.base.host : '',
           ),
       csrfReader = csrfReader ?? browserCsrfToken;

  final LocalRepository repository;
  final ApiClient api;
  final SessionVault vault;
  final bool isWeb;
  final bool allowLocalHttp;
  final String? Function() csrfReader;
  final String deviceName;
  IdentityRequestObserver? onRequestMetadata;
  ServerAddress? server;
  ServerIdentity? serverIdentity;
  IdentityAccount? account;
  IdentityStatus status = IdentityStatus.signedOut;
  List<DeviceSession> sessions = const [];
  List<BookBrief> books = const [];
  String? message;
  bool busy = false;
  String? clientId;
  TokenPair? _tokens;
  String? _csrf;
  int _generation = 0;
  bool _disposed = false;
  Future<void> _transitionTail = Future.value();
  Future<void>? _refreshing;
  String? _pendingProfileErase;
  String? _pendingVaultErase;
  bool credentialCleanupFailed = false;
  DataSpace? get accountSpace =>
      account == null || server == null ? null : account!.space(server!);
  bool get online => status == IdentityStatus.online && _tokens != null;
  int get sessionGeneration => _generation;
  String get _originKey =>
      sha256.convert(utf8.encode(server.toString())).toString();
  String get _profileKey => 'identity.profile.$_originKey';
  String _vaultKey(IdentityAccount value) =>
      'flowtrace.refresh.v1.${value.space(server!).id}';

  Future<void> _serial(Future<void> Function() action) {
    final next = _transitionTail.then((_) => action());
    _transitionTail = next.catchError((Object _) {});
    return next;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _checkGeneration(int generation) {
    if (_disposed || generation != _generation) {
      throw const ApiFailure('identity_changed', '账号或服务器已切换，请重试。');
    }
  }

  void _requireTransport() {
    if (server!.uri.scheme != 'https' && !allowLocalHttp) {
      throw const ApiFailure('https_required', '账号登录需要HTTPS服务器；本地HTTP仅供开发调试。');
    }
  }

  Future<void> configure(ServerAddress address) {
    final generation = ++_generation;
    server = address;
    account = null;
    serverIdentity = null;
    _tokens = null;
    _csrf = null;
    _refreshing = null;
    sessions = const [];
    books = const [];
    message = null;
    busy = true;
    status = IdentityStatus.restoring;
    _changed();
    return _serial(() async {
      try {
        _checkGeneration(generation);
        if (credentialCleanupFailed) {
          await retryCredentialCleanup();
          if (credentialCleanupFailed) {
            throw const ApiFailure(
              'vault_unavailable',
              '旧登录凭据尚未清除，请先重试清除后再登录。',
            );
          }
        }
        final cachedId = await repository.readSetting(
          'identity.client.$_originKey',
        );
        _checkGeneration(generation);
        clientId = cachedId != null && Uuid.isValidUUID(fromString: cachedId)
            ? cachedId
            : const Uuid().v4();
        await repository.writeSetting('identity.client.$_originKey', clientId!);
        final raw = await repository.readSetting(_profileKey);
        _checkGeneration(generation);
        if (raw == null || raw.isEmpty) {
          status = IdentityStatus.signedOut;
          return;
        }
        try {
          account = IdentityAccount.fromJson(
            (jsonDecode(raw) as Map).cast<String, Object?>(),
          );
        } catch (_) {
          await repository.writeSetting(_profileKey, '');
          status = IdentityStatus.signedOut;
          return;
        }
        status = IdentityStatus.offline;
        _changed();
        _requireTransport();
        await _loadServerIdentity(generation, expected: account!.instanceId);
        await _refresh(generation);
        await loadOverview();
      } on ApiFailure catch (error) {
        if (generation == _generation) {
          message = error.message;
          if (status == IdentityStatus.restoring) {
            status = IdentityStatus.signedOut;
          }
        }
      } catch (_) {
        if (generation == _generation) {
          message = '本地身份资料暂不可用，请重试；不会改用明文存储。';
          account = null;
          status = IdentityStatus.signedOut;
        }
      } finally {
        if (generation == _generation) {
          busy = false;
          _changed();
        }
      }
    });
  }

  Future<void> _loadServerIdentity(int generation, {String? expected}) async {
    final data = await api.request(server!, 'GET', '/server-info');
    _checkGeneration(generation);
    final identity = ServerIdentity.fromJson(data);
    if (expected != null && identity.instanceId != expected) {
      _tokens = null;
      account = null;
      status = IdentityStatus.serverChanged;
      throw const ApiFailure(
        'server_instance_changed',
        '此地址的服务器实例已更换。原资料仍保留在独立空间，请重新登录。',
      );
    }
    serverIdentity = identity;
  }

  Future<void> signIn({
    required String username,
    required String password,
    String? inviteToken,
  }) {
    if (busy) throw const ApiFailure('busy', '当前操作尚未完成。');
    final generation = ++_generation;
    final loginServer = server!;
    _refreshing = null;
    busy = true;
    message = null;
    _tokens = null;
    status = account == null
        ? IdentityStatus.signedOut
        : IdentityStatus.offline;
    _changed();
    return _serial(() async {
      try {
        _checkGeneration(generation);
        if (credentialCleanupFailed) {
          await retryCredentialCleanup();
          if (credentialCleanupFailed) {
            throw const ApiFailure(
              'vault_unavailable',
              '旧登录凭据尚未清除，请先重试清除后再登录。',
            );
          }
        }
        _requireTransport();
        await _loadServerIdentity(generation);
        final values = await api.request(
          server!,
          'POST',
          inviteToken == null ? '/auth/login' : '/auth/register',
          body: {
            'username': username.trim(),
            'password': password,
            'client_id': clientId,
            'client_kind': isWeb ? 'web' : 'native',
            'device_name': deviceName,
            if (inviteToken != null) 'invite_token': inviteToken.trim(),
          },
        );
        _checkGeneration(generation);
        final tokens = TokenPair.fromJson(values);
        final profile = await api.request(
          server!,
          'GET',
          '/users/me',
          accessToken: tokens.access,
        );
        _checkGeneration(generation);
        if (uuidField(profile, 'id') != tokens.userId ||
            profile['enabled'] != true) {
          throw invalidIdentityResponse();
        }
        final next = IdentityAccount(
          instanceId: serverIdentity!.instanceId,
          userId: tokens.userId,
          username: stringField(profile, 'username'),
          sessionId: tokens.sessionId,
        );
        final credentialKey =
            'flowtrace.refresh.v1.${next.space(loginServer).id}';
        try {
          if (!isWeb) {
            if (tokens.refresh == null) throw invalidIdentityResponse();
            await vault.write(credentialKey, tokens.refresh!);
          }
          _checkGeneration(generation);
          await repository.writeSetting(_profileKey, jsonEncode(next.toJson()));
          _checkGeneration(generation);
        } catch (error) {
          if (!isWeb) {
            try {
              await vault.delete(credentialKey);
            } catch (_) {}
          }
          try {
            await api.request(
              loginServer,
              'POST',
              '/auth/logout',
              accessToken: tokens.access,
              csrfToken: isWeb ? tokens.csrf : null,
            );
          } catch (_) {}
          if (error is ApiFailure) rethrow;
          throw const ApiFailure(
            'vault_unavailable',
            '系统安全存储不可用，登录未保留。请检查后重试。',
          );
        }
        account = next;
        _tokens = tokens;
        _csrf = tokens.csrf;
        status = IdentityStatus.online;
        _changed();
        try {
          await loadOverview();
        } on ApiFailure {
          if (!online) rethrow;
          // Login is durable even when ancillary device/book reads fail.
        }
      } on ApiFailure catch (error) {
        if (generation == _generation) message = error.message;
        rethrow;
      } finally {
        if (generation == _generation) {
          busy = false;
          _changed();
        }
      }
    });
  }

  Future<void> _refresh(int generation) {
    final current = _refreshing;
    if (current != null) return current;
    final future = isWeb
        ? withBrowserRefreshLock(
            'flowtrace.refresh.$_originKey',
            () => _performRefresh(generation),
          )
        : _performRefresh(generation);
    _refreshing = future;
    return future.whenComplete(() {
      if (identical(_refreshing, future)) _refreshing = null;
    });
  }

  Future<void> _performRefresh(int generation) async {
    _checkGeneration(generation);
    final previous = account;
    if (previous == null) {
      throw const ApiFailure('session_invalid', '请先登录。', status: 401);
    }
    final refreshServer = server!;
    final refreshKey = _vaultKey(previous);
    await _loadServerIdentity(generation, expected: previous.instanceId);
    final refresh = isWeb ? null : await vault.read(refreshKey);
    _checkGeneration(generation);
    if ((!isWeb && refresh == null) || (isWeb && csrfReader() == null)) {
      await _expire(generation);
      throw const ApiFailure('session_invalid', '请重新登录。', status: 401);
    }
    try {
      final result = await api.request(
        refreshServer,
        'POST',
        '/auth/refresh',
        body: {
          'client_kind': isWeb ? 'web' : 'native',
          if (!isWeb) 'refresh_token': refresh,
        },
        csrfToken: isWeb ? csrfReader() : null,
      );
      _checkGeneration(generation);
      final tokens = TokenPair.fromJson(result);
      if (tokens.userId != previous.userId ||
          tokens.sessionId != previous.sessionId) {
        throw invalidIdentityResponse();
      }
      if (!isWeb) {
        if (tokens.refresh == null) throw invalidIdentityResponse();
        await vault.write(refreshKey, tokens.refresh!);
      }
      _checkGeneration(generation);
      _tokens = tokens;
      _csrf = tokens.csrf ?? _csrf ?? (isWeb ? csrfReader() : null);
      status = IdentityStatus.online;
      _changed();
    } on ApiFailure catch (error) {
      if (generation != _generation) rethrow;
      if (error.status == 401 ||
          error.status == 403 ||
          error.code == 'invalid_response') {
        await _expire(generation);
      } else {
        // The server may have rotated before a reply was lost. Never resend the
        // old refresh value and risk revoking an otherwise valid new session.
        _tokens = null;
        status = IdentityStatus.offline;
        if (!isWeb) {
          try {
            await vault.delete(refreshKey);
          } catch (_) {
            _pendingVaultErase = refreshKey;
            credentialCleanupFailed = true;
          }
        }
        message = '刷新结果未确认，已停止重用旧凭据；本机资料保留，联网后请重新登录。';
        _changed();
      }
      rethrow;
    } catch (_) {
      if (generation == _generation) {
        _tokens = null;
        status = IdentityStatus.offline;
        if (!isWeb) {
          try {
            await vault.delete(refreshKey);
          } catch (_) {
            _pendingVaultErase = refreshKey;
            credentialCleanupFailed = true;
          }
        }
        message = '安全凭据未能更新，请重新登录；不会保存到普通数据库。';
        _changed();
      }
      throw const ApiFailure('vault_unavailable', '安全凭据未能更新，请重新登录。');
    }
  }

  Future<void> _expire(int generation) async {
    _checkGeneration(generation);
    final old = account;
    _pendingProfileErase = _profileKey;
    if (old != null && !isWeb) _pendingVaultErase = _vaultKey(old);
    account = null;
    _tokens = null;
    _csrf = null;
    sessions = const [];
    books = const [];
    status = IdentityStatus.signedOut;
    message = '会话已失效，请重新登录。原资料保留在对应账号空间。';
    _changed();
    await retryCredentialCleanup();
  }

  Future<void> retryCredentialCleanup() async {
    final profileKey = _pendingProfileErase;
    final vaultKey = _pendingVaultErase;
    if (profileKey != null) {
      try {
        await repository.writeSetting(profileKey, '');
        _pendingProfileErase = null;
      } catch (_) {}
    }
    if (vaultKey != null) {
      try {
        await vault.delete(vaultKey);
        _pendingVaultErase = null;
      } catch (_) {}
    }
    credentialCleanupFailed =
        _pendingProfileErase != null || _pendingVaultErase != null;
    if (credentialCleanupFailed) {
      message = '本机登录已停止，但保存的凭据尚未完整清除。请重试清除，不要直接交出此设备。';
    }
    _changed();
  }

  /// Used by current account pages and the separately owned sync transport.
  Future<Map<String, Object?>> authorizedRequest(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? bodyJson,
    Uint8List? bodyBytes,
    String? contentType,
    String? chunkSha256,
    String? expectedSpaceId,
    String? expectedEpoch,
    String? expectedClientId,
    String? diagnosticOperationId,
  }) {
    if ([body, bodyJson, bodyBytes].where((v) => v != null).length > 1) {
      throw ArgumentError('body、bodyJson和bodyBytes只能提供一种。');
    }
    final frozenJson = bodyJson ?? (body == null ? null : jsonEncode(body));
    final frozenBytes = bodyBytes == null
        ? null
        : Uint8List.fromList(bodyBytes);
    return _authorized(
      (address, access, csrf, observe) => api.request(
        address,
        method,
        path,
        bodyJson: frozenJson,
        bodyBytes: frozenBytes,
        contentType: contentType,
        chunkSha256: chunkSha256,
        accessToken: access,
        csrfToken: csrf,
        onMetadata: observe,
      ),
      expectedSpaceId: expectedSpaceId,
      expectedEpoch: expectedEpoch,
      expectedClientId: expectedClientId,
      diagnosticOperationId: diagnosticOperationId,
    );
  }

  Future<Uint8List> authorizedDownload(
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? bodyJson,
    int maxBytes = 10 * 1024 * 1024,
    String? expectedSpaceId,
    String? expectedEpoch,
    String? expectedClientId,
  }) {
    if (body != null && bodyJson != null) {
      throw ArgumentError('body和bodyJson只能提供一种。');
    }
    if (!{'GET', 'POST'}.contains(method) ||
        (method == 'GET' && (body != null || bodyJson != null))) {
      throw ArgumentError('下载只支持GET或带筛选正文的POST。');
    }
    final frozenJson = bodyJson ?? (body == null ? null : jsonEncode(body));
    return _authorized(
      (address, access, csrf, observe) => api.download(
        address,
        path,
        method: method,
        bodyJson: frozenJson,
        maxBytes: maxBytes,
        accessToken: access,
        csrfToken: csrf,
        onMetadata: observe,
      ),
      expectedSpaceId: expectedSpaceId,
      expectedEpoch: expectedEpoch,
      expectedClientId: expectedClientId,
    );
  }

  Future<T> _authorized<T>(
    Future<T> Function(
      ServerAddress address,
      String access,
      String? csrf,
      ApiMetadataObserver? observe,
    )
    send, {
    String? expectedSpaceId,
    String? expectedEpoch,
    String? expectedClientId,
    String? diagnosticOperationId,
  }) async {
    final generation = _generation;
    final requestServer = server;
    final capturedSpaceId = expectedSpaceId ?? accountSpace?.id;
    void checkLease() {
      _checkGeneration(generation);
      if (capturedSpaceId == null ||
          accountSpace?.id != capturedSpaceId ||
          (expectedEpoch != null &&
              serverIdentity?.syncEpoch != expectedEpoch) ||
          (expectedClientId != null && clientId != expectedClientId)) {
        throw const ApiFailure('identity_changed', '资料空间或会话已切换，原请求未发送。');
      }
    }

    checkLease();
    if (!online) {
      throw const ApiFailure('session_invalid', '请先联网登录。', status: 401);
    }
    final first = _tokens!.access;
    final capturedSpace = accountSpace;
    final observer = onRequestMetadata;
    final ApiMetadataObserver? observe =
        capturedSpace == null || observer == null
        ? null
        : (metadata) {
            // Do not assign an old account's late response to the current UI.
            if (_disposed ||
                generation != _generation ||
                accountSpace?.id != capturedSpace.id) {
              return Future<void>.value();
            }
            return Future<void>.sync(
              () => observer(
                capturedSpace,
                metadata.withOperationId(diagnosticOperationId),
              ),
            );
          };
    try {
      checkLease();
      final result = await send(
        requestServer!,
        first,
        isWeb ? (_csrf ?? csrfReader()) : null,
        observe,
      );
      checkLease();
      return result;
    } on ApiFailure catch (error) {
      checkLease();
      if (error.status != 401) rethrow;
      if (_tokens?.access == first) await _refresh(generation);
      checkLease();
      if (!online) {
        throw const ApiFailure('session_invalid', '会话已失效，请重新登录。', status: 401);
      }
      try {
        checkLease();
        final result = await send(
          requestServer!,
          _tokens!.access,
          isWeb ? (_csrf ?? csrfReader()) : null,
          observe,
        );
        checkLease();
        return result;
      } on ApiFailure catch (retryError) {
        if (retryError.status == 401) await _expire(generation);
        rethrow;
      }
    }
  }

  Future<void> loadOverview() async {
    if (!online) return;
    final generation = _generation;
    try {
      final me = await authorizedRequest('GET', '/users/me');
      _checkGeneration(generation);
      if (me['id'] != account!.userId || me['enabled'] != true) {
        await _expire(generation);
        throw invalidIdentityResponse();
      }
      final devices = await authorizedRequest('GET', '/sessions');
      _checkGeneration(generation);
      final ledgers = await authorizedRequest('GET', '/books');
      _checkGeneration(generation);
      sessions = (devices['items'] as List)
          .map(
            (e) => DeviceSession.fromJson((e as Map).cast<String, Object?>()),
          )
          .toList();
      books = (ledgers['items'] as List)
          .map((e) => BookBrief.fromJson((e as Map).cast<String, Object?>()))
          .toList();
      message = null;
      _changed();
    } on ApiFailure catch (error) {
      if (generation == _generation) {
        message = error.message;
        _changed();
      }
      rethrow;
    }
  }

  Future<void> revokeSession(String id) async {
    final generation = _generation;
    await authorizedRequest('DELETE', '/sessions/$id');
    _checkGeneration(generation);
    if (id == account?.sessionId) {
      await _expire(generation);
    } else {
      await loadOverview();
    }
  }

  Future<void> signOut() {
    if (busy) throw const ApiFailure('busy', '当前操作尚未完成。');
    final generation = ++_generation;
    _refreshing = null;
    busy = true;
    _changed();
    return _serial(() async {
      var remotelyRevoked = false;
      try {
        if (online) {
          await authorizedRequest('POST', '/auth/logout');
          remotelyRevoked = true;
        }
      } on ApiFailure {
        // Local logout must remain possible when the server cannot be reached.
      } finally {
        if (generation == _generation) {
          await _expire(generation);
          if (!credentialCleanupFailed) {
            message = remotelyRevoked
                ? '已退出并撤销此设备会话。'
                : '已退出本机。服务器撤销未确认，可稍后从其他已登录设备撤销。';
          }
          busy = false;
          _changed();
        }
      }
    });
  }

  /// Call only after the recovery UI has preserved data and received the user's
  /// explicit confirmation. Never edits local bills, outbox, shadows or backups.
  Future<void> rotateClientForRecovery({
    required String expectedSpaceId,
    int? expectedGeneration,
  }) async {
    if (accountSpace?.id != expectedSpaceId ||
        (expectedGeneration != null && expectedGeneration != _generation)) {
      throw const ApiFailure('identity_changed', '身份已切换，请重新核对恢复资料。');
    }
    final clientKey = 'identity.client.$_originKey';
    final logout = signOut();
    final generation = _generation;
    await logout;
    _checkGeneration(generation);
    if (credentialCleanupFailed) {
      throw const ApiFailure('vault_unavailable', '请先清除旧登录凭据，再更换设备标识。');
    }
    final revocationUnconfirmed = message?.contains('服务器撤销未确认') == true;
    final next = const Uuid().v4();
    await repository.writeSetting(clientKey, next);
    _checkGeneration(generation);
    clientId = next;
    message =
        '已更换设备标识，请重新登录。原空间资料与恢复备份保留。${revocationUnconfirmed ? '服务器旧会话撤销未确认，可从其他设备撤销。' : ''}';
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    api.close();
    super.dispose();
  }
}
