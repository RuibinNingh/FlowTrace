import 'dart:async';

enum ApiCategory {
  health,
  identity,
  books,
  sync,
  attachments,
  admin,
  dataTools,
  other,
}

/// An allowlisted projection, never a request URL, body, token or response text.
final class ApiRequestMetadata {
  const ApiRequestMetadata._({
    required this.category,
    required this.method,
    required this.durationMs,
    this.requestId,
    this.operationId,
    this.status,
  });

  final ApiCategory category;
  final String method;
  final String? requestId;
  final String? operationId;
  final int? status;
  final int durationMs;

  static const _methods = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'};
  static final _uuid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
  );

  /// Operation correlation is supplied separately by the frozen-command owner;
  /// transport never extracts it from a body or URL. Invalid values are dropped.
  ApiRequestMetadata withOperationId(String? value) => ApiRequestMetadata._(
    category: category,
    method: method,
    durationMs: durationMs,
    requestId: requestId,
    status: status,
    operationId: value != null && value.length == 36 && _uuid.hasMatch(value)
        ? value
        : null,
  );

  static ApiCategory _category(String path) {
    final segment = path.split('?').first.split('/').elementAtOrNull(1);
    return switch (segment) {
      'health' || 'server-info' => ApiCategory.health,
      'auth' || 'users' || 'sessions' => ApiCategory.identity,
      'books' => ApiCategory.books,
      'sync' => ApiCategory.sync,
      'attachments' => ApiCategory.attachments,
      'admin' => ApiCategory.admin,
      'data-tools' => ApiCategory.dataTools,
      _ => ApiCategory.other,
    };
  }

  /// Called by transport only; rejects all non-protocol method/header values.
  static ApiRequestMetadata? project({
    required String path,
    required String method,
    required int durationMs,
    String? requestId,
    int? status,
  }) {
    if (!_methods.contains(method)) return null;
    final normalized = requestId != null && requestId.length == 36
        ? requestId.toLowerCase()
        : null;
    return ApiRequestMetadata._(
      category: _category(path),
      method: method,
      durationMs: durationMs.clamp(0, 86400000).toInt(),
      requestId: normalized != null && _uuid.hasMatch(normalized)
          ? normalized
          : null,
      status: status != null && status >= 100 && status <= 599 ? status : null,
    );
  }
}

typedef ApiMetadataObserver =
    FutureOr<void> Function(ApiRequestMetadata metadata);
