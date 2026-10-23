import 'data_tools_models.dart';
import 'stage_import_models.dart';

/// Read-only queue metadata, separate from the immutable command ACK and the
/// stage's financial state. A ready stage can still have a failed apply job.
final class StageImportJobMetadata extends StageImportWire {
  StageImportJobMetadata._(super.value);
  String get action => value['action'] as String;
  String get jobId => value['job_id'] as String;
  int get version => value['stage_version'] as int;
  String get status => value['status'] as String;
  int get attempt => value['attempt'] as int;
  String? get errorCode => value['error_code'] as String?;
  bool get active => {'pending', 'running', 'retry_wait'}.contains(status);
  factory StageImportJobMetadata.parse(Object? input) {
    final raw = dataToolsObject(input);
    dataToolsKeys(raw, {
      'action',
      'job_id',
      'stage_version',
      'status',
      'attempt',
      'error_code',
      'available_at',
      'lease_until',
    });
    dataToolsUuid(raw['job_id']);
    stageInteger(raw['stage_version'], 1, 2147483647);
    stageInteger(raw['attempt'], 0, 5);
    stageInstant(raw['available_at']);
    if (raw['lease_until'] != null) {
      stageInstant(raw['lease_until']);
    }
    final code = raw['error_code'];
    if (!{'parse', 'preview', 'apply', 'undo'}.contains(raw['action']) ||
        !{
          'pending',
          'running',
          'succeeded',
          'retry_wait',
          'failed',
          'cancelled',
        }.contains(raw['status']) ||
        code != null &&
            (code is! String ||
                !RegExp(r'^[a-z][a-z0-9_.-]{0,63}$').hasMatch(code))) {
      throw const FormatException('服务器任务元数据无效。');
    }
    return StageImportJobMetadata._(raw);
  }
}

final class StageImportJobs extends StageImportWire {
  StageImportJobs._(super.value);
  String get stageId => value['stage_id'] as String;
  int get version => value['stage_version'] as int;
  List<StageImportJobMetadata> get jobs => (value['jobs'] as List)
      .map(StageImportJobMetadata.parse)
      .toList(growable: false);
  StageImportJobMetadata? forAction(String action) =>
      jobs.where((job) => job.action == action).firstOrNull;
  bool get active => jobs.any((job) => job.active);
  factory StageImportJobs.parse(Map<String, Object?> raw) {
    dataToolsKeys(raw, {'stage_id', 'stage_version', 'jobs'});
    dataToolsUuid(raw['stage_id']);
    final version = stageInteger(raw['stage_version'], 1, 2147483647);
    final items = raw['jobs'];
    if (items is! List || items.length > 4) {
      throw const FormatException('服务器任务列表无效。');
    }
    final actions = <String>{}, ids = <String>{};
    for (final job in items.map(StageImportJobMetadata.parse)) {
      if (job.version > version ||
          !actions.add(job.action) ||
          !ids.add(job.jobId)) {
        throw const FormatException('服务器任务绑定无效。');
      }
    }
    return StageImportJobs._(raw);
  }
}
