import 'dart:convert';

import 'data_tools_models.dart';

const stageImportSourceLimit = 50 * 1024 * 1024;
const stageImportChunkBytes = 512 * 1024;
const stageImportMaxSources = 8;
const stageImportSpaceBytes = 200 * 1024 * 1024;
const stageImportMaxCommands = 128;
const stageImportCommandBytes = 16 * 1024 * 1024;
const stageImportStatuses = {
  'uploading',
  'uploaded',
  'parsing',
  'parsed',
  'previewing',
  'ready',
  'applying',
  'applied',
  'undoing',
  'undone',
  'failed',
  'cancelled',
  'expired',
};

int stageInteger(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    throw const FormatException('暂存计数无效。');
  }
  return value;
}

String stageDigest(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const FormatException('暂存摘要无效。');
  }
  return value;
}

DateTime stageInstant(Object? value) {
  if (value is! String ||
      value.length > 48 ||
      !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(value)) {
    throw const FormatException('暂存时间无效。');
  }
  return DateTime.parse(value).toUtc();
}

int stageChunkCount(int sourceBytes) =>
    (sourceBytes + stageImportChunkBytes - 1) ~/ stageImportChunkBytes;

Map<String, Object?> stageMapping(Map<String, Object?> raw) {
  dataToolsKeys(raw, {}, {
    'source_namespace',
    'template_mapping',
    'scope_mapping',
    'resource_mapping',
    'attachment_transfers',
  });
  final namespace = raw['source_namespace'];
  if (namespace != null &&
      (namespace is! String ||
          namespace.isEmpty ||
          namespace.runes.length > 80)) {
    throw const FormatException('暂存来源命名空间无效。');
  }
  for (final name in [
    'scope_mapping',
    'resource_mapping',
    'attachment_transfers',
  ]) {
    final mapping = dataToolsObject(raw[name] ?? <String, Object?>{});
    if (mapping.length > 200000) throw const FormatException('暂存映射超出范围。');
    for (final entry in mapping.entries) {
      dataToolsUuid(entry.key);
      dataToolsUuid(entry.value);
    }
  }
  if (raw['template_mapping'] != null) {
    final template = dataToolsObject(raw['template_mapping']);
    dataToolsKeys(
      template,
      {'scope_id', 'timezone'},
      {
        'currency',
        'currency_scale',
        'account_names',
        'category_names',
        'tag_names',
        'image_urls',
      },
    );
    dataToolsUuid(template['scope_id']);
    if (template['timezone'] is! String ||
        (template['timezone'] as String).isEmpty ||
        (template['timezone'] as String).runes.length > 100) {
      throw const FormatException('暂存时区无效。');
    }
    final currency = template['currency'];
    if (currency != null &&
        (currency is! String || !RegExp(r'^[A-Z]{3}$').hasMatch(currency))) {
      throw const FormatException('暂存币种无效。');
    }
    if (template['currency_scale'] != null) {
      stageInteger(template['currency_scale'], 0, 6);
    }
    for (final name in [
      'account_names',
      'category_names',
      'tag_names',
      'image_urls',
    ]) {
      final names = dataToolsObject(template[name] ?? <String, Object?>{});
      if (names.length > 200000) throw const FormatException('暂存名称映射超出范围。');
      for (final entry in names.entries) {
        if (entry.key.isEmpty ||
            entry.key.runes.length > 2000 ||
            entry.key.contains('\u0000')) {
          throw const FormatException('暂存来源名称无效。');
        }
        dataToolsUuid(entry.value);
      }
    }
  }
  return dataToolsObject(jsonDecode(dataToolsFrozenJson(raw)));
}

abstract base class StageImportWire {
  StageImportWire(Map<String, Object?> value)
    : encoded = dataToolsFrozenJson(value);
  final String encoded;
  Map<String, Object?> get value => body;
  Map<String, Object?> get body => dataToolsObject(jsonDecode(encoded));
}

final class StageImportCreated extends StageImportWire {
  StageImportCreated._(super.value);
  String get stageId => value['stage_id'] as String;
  String get batchId => value['batch_id'] as String;
  int get version => value['stage_version'] as int;
  int get expectedChunks => value['expected_chunks'] as int;

  factory StageImportCreated.parse(Map<String, Object?> raw) {
    dataToolsKeys(raw, {
      'stage_id',
      'batch_id',
      'stage_version',
      'chunk_bytes',
      'expected_chunks',
      'expires_at',
    });
    dataToolsUuid(raw['stage_id']);
    dataToolsUuid(raw['batch_id']);
    stageInteger(raw['stage_version'], 1, 2147483647);
    stageInteger(
      raw['chunk_bytes'],
      stageImportChunkBytes,
      stageImportChunkBytes,
    );
    stageInteger(raw['expected_chunks'], 1, 100);
    stageInstant(raw['expires_at']);
    return StageImportCreated._(raw);
  }
}

final class StageImportChunkReceipt extends StageImportWire {
  StageImportChunkReceipt._(super.value);
  String get stageId => value['stage_id'] as String;
  int get version => value['stage_version'] as int;
  int get index => value['chunk_index'] as int;
  String get sha256 => value['chunk_sha256'] as String;
  int get sizeBytes => value['size_bytes'] as int;
  int get nextIndex => value['next_chunk_index'] as int;
  int get receivedBytes => value['received_bytes'] as int;
  int get expectedBytes => value['expected_bytes'] as int;

  factory StageImportChunkReceipt.parse(Map<String, Object?> raw) {
    dataToolsKeys(raw, {
      'stage_id',
      'stage_version',
      'chunk_index',
      'chunk_sha256',
      'size_bytes',
      'next_chunk_index',
      'received_bytes',
      'expected_bytes',
      'replayed',
    });
    dataToolsUuid(raw['stage_id']);
    stageInteger(raw['stage_version'], 1, 2147483647);
    final index = stageInteger(raw['chunk_index'], 0, 99);
    stageDigest(raw['chunk_sha256']);
    final size = stageInteger(raw['size_bytes'], 1, stageImportChunkBytes);
    final next = stageInteger(raw['next_chunk_index'], 1, 100);
    final total = stageInteger(
      raw['expected_bytes'],
      1,
      stageImportSourceLimit,
    );
    final received = stageInteger(
      raw['received_bytes'],
      1,
      stageImportSourceLimit,
    );
    final expectedSize = (total - index * stageImportChunkBytes).clamp(
      0,
      stageImportChunkBytes,
    );
    if (raw['replayed'] is! bool ||
        index >= next ||
        next > stageChunkCount(total) ||
        size != expectedSize ||
        received != (next * stageImportChunkBytes).clamp(0, total)) {
      throw const FormatException('暂存分片回执不完整。');
    }
    return StageImportChunkReceipt._(raw);
  }
}

final class StageImportStatus extends StageImportWire {
  StageImportStatus._(super.value);
  String get stageId => value['stage_id'] as String;
  String get batchId => value['batch_id'] as String;
  int get version => value['stage_version'] as int;
  String get status => value['status'] as String;
  int get expectedBytes => value['expected_bytes'] as int;
  int get receivedBytes => value['received_bytes'] as int;
  int get receivedChunks => value['received_chunks'] as int;
  int get rowCount => value['row_count'] as int;
  int get errorCount => value['error_count'] as int;
  String? get previewHash => value['preview_hash'] as String?;
  bool get sourceReleased => value['source_released'] as bool;

  factory StageImportStatus.parse(Map<String, Object?> raw) {
    dataToolsKeys(
      raw,
      {
        'stage_id',
        'batch_id',
        'stage_version',
        'format',
        'status',
        'expected_bytes',
        'received_bytes',
        'received_chunks',
        'row_count',
        'error_count',
        'preview_hash',
        'parse_job_id',
        'preview_job_id',
        'apply_job_id',
        'undo_job_id',
        'created_at',
        'updated_at',
        'expires_at',
        'source_released',
        'source_released_at',
      },
      {
        'requirements_version',
        'requirements_hash',
        'requirements_count',
        'mapping_hash',
      },
    );
    dataToolsUuid(raw['stage_id']);
    dataToolsUuid(raw['batch_id']);
    stageInteger(raw['stage_version'], 1, 2147483647);
    ImportFileKind.parse(raw['format']);
    if (!stageImportStatuses.contains(raw['status'])) {
      throw const FormatException('暂存状态无效。');
    }
    final expected = stageInteger(
      raw['expected_bytes'],
      1,
      stageImportSourceLimit,
    );
    final received = stageInteger(
      raw['received_bytes'],
      0,
      stageImportSourceLimit,
    );
    final chunks = stageInteger(raw['received_chunks'], 0, 100);
    stageInteger(raw['row_count'], 0, 200000);
    stageInteger(raw['error_count'], 0, 20000000);
    for (final key in [
      'parse_job_id',
      'preview_job_id',
      'apply_job_id',
      'undo_job_id',
    ]) {
      if (raw[key] != null) dataToolsUuid(raw[key]);
    }
    for (final key in ['created_at', 'updated_at', 'expires_at']) {
      stageInstant(raw[key]);
    }
    if (raw['preview_hash'] != null) stageDigest(raw['preview_hash']);
    if (raw['mapping_hash'] != null) stageDigest(raw['mapping_hash']);
    final released = raw['source_released'];
    if (released is! bool ||
        released != (raw['source_released_at'] != null) ||
        received > expected ||
        chunks > stageChunkCount(expected) ||
        received != (chunks * stageImportChunkBytes).clamp(0, expected) ||
        ({'ready', 'applying'}.contains(raw['status']) &&
            raw['preview_hash'] == null) ||
        (released &&
            (!{'applied', 'undoing', 'undone'}.contains(raw['status']) ||
                received != expected ||
                chunks != stageChunkCount(expected)))) {
      throw const FormatException('暂存状态与容量不一致。');
    }
    if (released) stageInstant(raw['source_released_at']);
    final requirementVersion = raw['requirements_version'];
    final requirementHash = raw['requirements_hash'];
    final requirementCount = stageInteger(
      raw['requirements_count'] ?? 0,
      0,
      200000,
    );
    if ((requirementVersion == null) != (requirementHash == null) ||
        (requirementVersion == null && requirementCount != 0) ||
        (requirementVersion != null && released)) {
      throw const FormatException('暂存资源清单状态无效。');
    }
    if (requirementVersion != null) {
      stageInteger(requirementVersion, 1, raw['stage_version'] as int);
      stageDigest(requirementHash);
    }
    return StageImportStatus._(raw);
  }
}

final class StageImportJob extends StageImportWire {
  StageImportJob._(super.value);
  String get stageId => value['stage_id'] as String;
  int get version => value['stage_version'] as int;
  String get jobId => value['job_id'] as String;
  String get status => value['status'] as String;

  factory StageImportJob.parse(Map<String, Object?> raw) {
    dataToolsKeys(raw, {'stage_id', 'stage_version', 'job_id', 'status'});
    dataToolsUuid(raw['stage_id']);
    dataToolsUuid(raw['job_id']);
    stageInteger(raw['stage_version'], 1, 2147483647);
    if (!stageImportStatuses.contains(raw['status'])) {
      throw const FormatException('暂存作业状态无效。');
    }
    return StageImportJob._(raw);
  }
}
