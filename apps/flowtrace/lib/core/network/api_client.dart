import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../config/server_address.dart';
import 'api_failure.dart';
import 'api_request_metadata.dart';

export 'api_request_metadata.dart';

final class ApiClient {
  ApiClient(this.client, {this.timeout = const Duration(seconds: 8)});
  final http.Client client;
  final Duration timeout;

  Future<Map<String, Object?>> request(
    ServerAddress server,
    String method,
    String path, {
    Map<String, Object?>? body,
    String? bodyJson,
    Uint8List? bodyBytes,
    String? contentType,
    String? chunkSha256,
    String? accessToken,
    String? csrfToken,
    ApiMetadataObserver? onMetadata,
  }) async {
    final response = await _send(
      server,
      method,
      path,
      body: body,
      bodyJson: bodyJson,
      bodyBytes: bodyBytes,
      contentType: contentType,
      chunkSha256: chunkSha256,
      accessToken: accessToken,
      csrfToken: csrfToken,
      onMetadata: onMetadata,
      maxBytes: 1024 * 1024,
    );
    if (response.statusCode == 204) return const {};
    try {
      final raw = jsonDecode(utf8.decode(response.bodyBytes));
      if (raw is! Map<String, dynamic>) throw const FormatException();
      return raw;
    } on FormatException {
      throw const ApiFailure('invalid_response', '服务器返回了无法识别的响应。');
    }
  }

  Future<Uint8List> download(
    ServerAddress server,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? bodyJson,
    int maxBytes = 10 * 1024 * 1024,
    String? accessToken,
    String? csrfToken,
    ApiMetadataObserver? onMetadata,
  }) async {
    if (maxBytes < 1) throw ArgumentError('下载上限必须大于零。');
    if (!{'GET', 'POST'}.contains(method) ||
        (method == 'GET' && (body != null || bodyJson != null))) {
      throw ArgumentError('下载只支持GET或带筛选正文的POST。');
    }
    final response = await _send(
      server,
      method,
      path,
      body: body,
      bodyJson: bodyJson,
      accessToken: accessToken,
      csrfToken: csrfToken,
      onMetadata: onMetadata,
      maxBytes: maxBytes,
    );
    return Uint8List.fromList(response.bodyBytes);
  }

  Future<http.Response> _send(
    ServerAddress server,
    String method,
    String path, {
    Map<String, Object?>? body,
    String? bodyJson,
    Uint8List? bodyBytes,
    String? contentType,
    String? chunkSha256,
    String? accessToken,
    String? csrfToken,
    ApiMetadataObserver? onMetadata,
    required int maxBytes,
  }) async {
    if ([body, bodyJson, bodyBytes].where((v) => v != null).length > 1) {
      throw ArgumentError('body、bodyJson和bodyBytes只能提供一种。');
    }
    if (chunkSha256 != null) {
      final endpoint = RegExp(
        r'^/data-tools/import-stages/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/chunks/(0|[1-9][0-9]?)\?stage_version=([1-9][0-9]{0,9})$',
      ).firstMatch(path);
      if (method != 'PUT' ||
          endpoint == null ||
          int.parse(endpoint.group(2)!) > 2147483647 ||
          bodyBytes == null ||
          bodyBytes.isEmpty ||
          bodyBytes.length > 512 * 1024 ||
          (contentType != null && contentType != 'application/octet-stream') ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(chunkSha256) ||
          sha256.convert(bodyBytes).toString() != chunkSha256) {
        throw ArgumentError('分片散列只允许匹配的固定暂存二进制上传。');
      }
    }
    final request = http.Request(method, server.resolve('/api/v1$path'))
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    if (accessToken != null) {
      request.headers['Authorization'] = 'Bearer $accessToken';
    }
    if (csrfToken != null) request.headers['X-CSRF-Token'] = csrfToken;
    if (chunkSha256 != null) request.headers['X-Chunk-SHA256'] = chunkSha256;
    if (body != null || bodyJson != null || bodyBytes != null) {
      request.headers['Content-Type'] =
          contentType ??
          (bodyBytes == null ? 'application/json' : 'application/octet-stream');
      request.encoding = utf8;
      if (bodyBytes != null) {
        request.bodyBytes = Uint8List.fromList(bodyBytes);
      } else {
        request.body = bodyJson ?? jsonEncode(body);
      }
    }
    final elapsed = Stopwatch()..start();
    int? status;
    String? requestId;
    try {
      final response = await client.send(request).timeout(timeout);
      status = response.statusCode;
      requestId = response.headers.entries
          .where((entry) => entry.key.toLowerCase() == 'x-request-id')
          .firstOrNull
          ?.value;
      final successful =
          response.statusCode >= 200 && response.statusCode < 300;
      final limit = successful ? maxBytes : 64 * 1024;
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(timeout)) {
        if (bytes.length + chunk.length > limit) {
          if (!successful) {
            throw ApiFailure.server('request_failed', response.statusCode);
          }
          throw const ApiFailure('response_too_large', '服务器响应超出允许大小，未保存为完整文件。');
        }
        bytes.addAll(chunk);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        Object? raw;
        try {
          raw = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          raw = null;
        }
        final error = raw is Map ? raw['error'] : null;
        final code = error is Map && error['code'] is String
            ? error['code'] as String
            : 'request_failed';
        // Only a bounded protocol code is retained; never a server message/input.
        throw ApiFailure.server(
          RegExp(r'^[a-z0-9_]{1,64}$').hasMatch(code) ? code : 'request_failed',
          response.statusCode,
        );
      }
      return http.Response.bytes(
        bytes,
        response.statusCode,
        headers: response.headers,
      );
    } on ApiFailure {
      rethrow;
    } on FormatException {
      throw const ApiFailure('invalid_response', '服务器返回了无法识别的响应。');
    } catch (_) {
      throw const ApiFailure(
        'network_unavailable',
        '暂时无法连接服务器，本机资料仍保留。请检查网络后重试。',
        offline: true,
      );
    } finally {
      elapsed.stop();
      if (onMetadata != null) {
        final metadata = ApiRequestMetadata.project(
          path: path,
          method: method,
          durationMs: elapsed.elapsedMilliseconds,
          requestId: requestId,
          status: status,
        );
        if (metadata != null) {
          // A failed/slow diagnostics sink cannot change a business response.
          unawaited(
            Future<void>.sync(
              () => onMetadata(metadata),
            ).catchError((Object _) {}),
          );
        }
      }
    }
  }

  void close() => client.close();
}
