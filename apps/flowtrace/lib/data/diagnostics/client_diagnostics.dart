import 'dart:convert';

import '../../core/config/data_space.dart';
import '../local/local_repository.dart';

/// Auxiliary local metadata only. Formal receipts and original files never
/// depend on these best-effort writes.
final class ClientDiagnostics {
  ClientDiagnostics(this.local, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final LocalRepository local;
  final DateTime Function() _now;
  static const maxRecords = 100;
  static const maxStoredBytes = 32 * 1024;
  static const maxExportBytes = 64 * 1024;
  static const events = {
    'http_response',
    'attachment_staged',
    'attachment_ready',
    'attachment_upload_failed',
    'attachment_downloaded',
    'scope_revoked',
    'sync_started',
    'sync_completed',
    'sync_failed',
    'sync_conflict',
    'sync_receipt',
    'recovery_required',
  };
  static const codes = {
    'network_unavailable',
    'network_error',
    'offline',
    'timeout',
    'identity_changed',
    'session_invalid',
    'session_revoked',
    'user_disabled',
    'csrf_invalid',
    'origin_invalid',
    'scope_forbidden',
    'scope_revoked',
    'entity_not_found',
    'revision_conflict',
    'operation_mismatch',
    'attachment_missing',
    'attachment_not_ready',
    'attachment_mismatch',
    'attachment_scope_mismatch',
    'attachment_transfer_failed',
    'local_attachment_missing',
    'hash_mismatch',
    'upload_expired',
    'attachment_storage_failed',
    'response_too_large',
    'service_unavailable',
    'recovery_required',
    'epoch_changed',
    'sync_failed',
    'validation_error',
  };
  static const _categories = {
    'health',
    'identity',
    'books',
    'sync',
    'attachments',
    'admin',
    'dataTools',
    'other',
  };
  static const _methods = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'};
  static final _uuid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
  );

  String _key(DataSpace space) => 'diagnostics.v1.${space.id}.ring';

  Map<String, Object?>? _project(Object? raw) {
    if (raw is! Map || raw['version'] != 1 || !events.contains(raw['event'])) {
      return null;
    }
    final time = raw['time_utc'];
    if (time is! String || time.length > 32) return null;
    final parsed = DateTime.tryParse(time);
    if (parsed == null ||
        !parsed.isUtc ||
        parsed.year < 1970 ||
        parsed.year > 2100) {
      return null;
    }
    final value = <String, Object?>{
      'version': 1,
      'time_utc': parsed.toIso8601String(),
      'event': raw['event'],
    };
    for (final name in [
      'operation_id',
      'request_id',
      'scope_id',
      'entity_id',
    ]) {
      final id = raw[name];
      if (id is String && _uuid.hasMatch(id)) value[name] = id;
    }
    if (codes.contains(raw['code'])) value['code'] = raw['code'];
    if (_categories.contains(raw['category'])) {
      value['category'] = raw['category'];
    }
    if (_methods.contains(raw['method'])) value['method'] = raw['method'];
    final status = raw['status'];
    if (status is int && status >= 100 && status <= 599) {
      value['status'] = status;
    }
    final duration = raw['duration_ms'];
    if (duration is int && duration >= 0 && duration <= 86400000) {
      value['duration_ms'] = duration;
    }
    return Map.unmodifiable(value);
  }

  List<Map<String, Object?>> _decode(String? raw) {
    if (raw == null || utf8.encode(raw).length > maxStoredBytes) return [];
    try {
      final items = jsonDecode(raw);
      if (items is! List) return [];
      final records = items
          .map(_project)
          .whereType<Map<String, Object?>>()
          .toList();
      return records.length <= maxRecords
          ? records
          : records.sublist(records.length - maxRecords);
    } catch (_) {
      return [];
    }
  }

  Future<bool> recordQuietly(
    DataSpace space,
    String event, {
    String? operationId,
    String? requestId,
    String? scopeId,
    String? entityId,
    String? code,
    int? status,
    int? durationMs,
    String? category,
    String? method,
  }) async {
    try {
      if (!events.contains(event)) return false;
      final projected = _project({
        'version': 1,
        'time_utc': _now().toUtc().toIso8601String(),
        'event': event,
        'operation_id': operationId,
        'request_id': requestId,
        'scope_id': scopeId,
        'entity_id': entityId,
        'code': code,
        'status': status,
        'duration_ms': durationMs,
        'category': category,
        'method': method,
      });
      if (projected == null) return false;
      await local.database.atomicWrite(() async {
        final records = _decode(await local.readSetting(_key(space)))
          ..add(projected);
        while (records.length > maxRecords ||
            utf8.encode(jsonEncode(records)).length > maxStoredBytes) {
          records.removeAt(0);
        }
        await local.writeSetting(_key(space), jsonEncode(records));
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, Object?>>> read(DataSpace space) async =>
      List.unmodifiable(_decode(await local.readSetting(_key(space))));

  /// Re-projects persisted records; no raw-file archive or arbitrary path input.
  Future<String> exportJsonl(DataSpace space) async {
    final records = await read(space);
    final lines = <String>[
      jsonEncode({
        'format': 'flowtrace-client-diagnostics-v1',
        'count': records.length,
      }),
      ...records.map(jsonEncode),
    ];
    final output = '${lines.join('\n')}\n';
    if (utf8.encode(output).length > maxExportBytes) {
      throw const FormatException('Diagnostic export limit exceeded');
    }
    return output;
  }
}
