import 'data_tools_models.dart';
import 'stage_import_models.dart';

final class StageImportSourceReleased extends StageImportWire {
  StageImportSourceReleased._(super.value);
  String get stageId => value['stage_id'] as String;
  String get batchId => value['batch_id'] as String;
  String get requestId => value['request_id'] as String;
  int get version => value['stage_version'] as int;
  int get reservedBytes => value['reserved_bytes_released'] as int;

  /// Replay truth is transport metadata. The first immutable receipt remains
  /// stored, while every byte/count/target/time field must stay identical.
  Map<String, Object?> get stable => {
    ...(body..remove('replayed')),
    'deleted_requirement_rows': value['deleted_requirement_rows'] ?? 0,
  };
  factory StageImportSourceReleased.parse(Map<String, Object?> raw) {
    dataToolsKeys(
      raw,
      {
        'stage_id',
        'batch_id',
        'request_id',
        'stage_version',
        'source_released',
        'source_released_at',
        'reserved_bytes_released',
        'deleted_source_bytes',
        'deleted_source_chunks',
        'deleted_preview_rows',
        'replayed',
      },
      {'deleted_requirement_rows'},
    );
    for (final key in ['stage_id', 'batch_id', 'request_id']) {
      dataToolsUuid(raw[key]);
    }
    stageInteger(raw['stage_version'], 1, 2147483647);
    stageInstant(raw['source_released_at']);
    final reserved = stageInteger(
      raw['reserved_bytes_released'],
      1,
      stageImportSourceLimit,
    );
    final bytes = stageInteger(raw['deleted_source_bytes'], 0, reserved);
    final chunks = stageInteger(
      raw['deleted_source_chunks'],
      0,
      stageChunkCount(reserved),
    );
    stageInteger(raw['deleted_preview_rows'], 0, 200000);
    stageInteger(raw['deleted_requirement_rows'] ?? 0, 0, 200000);
    if (raw['source_released'] != true ||
        raw['replayed'] is! bool ||
        (chunks == 0
            ? bytes != 0
            : bytes < chunks || bytes > chunks * stageImportChunkBytes)) {
      throw const FormatException('原件释放回执不完整。');
    }
    return StageImportSourceReleased._(raw);
  }
}

final class StageImportPreviewRow extends StageImportWire {
  StageImportPreviewRow._(super.value);
  int get position => value['position'] as int;
  int get sourceLine => value['source_line'] as int;
  String get status => value['status'] as String;
  DataImportRow? get row => value['row'] == null
      ? null
      : DataImportRow.fromJson(dataToolsObject(value['row']));
  List<DataImportError> get errors => (value['errors'] as List)
      .map((raw) => DataImportError.fromJson(dataToolsObject(raw)))
      .toList(growable: false);
  factory StageImportPreviewRow.parse(Object? input) {
    final raw = dataToolsObject(input);
    dataToolsKeys(raw, {
      'position',
      'source_line',
      'source_id',
      'row',
      'target_entity_id',
      'status',
      'warning',
      'errors',
    });
    stageInteger(raw['position'], 1, 200000);
    stageInteger(raw['source_line'], 1, 2147483647);
    for (final key in ['source_id', 'target_entity_id']) {
      if (raw[key] != null) dataToolsUuid(raw[key]);
    }
    if (!{
          'new',
          'duplicate',
          'source_conflict',
          'previously_undone',
          'source_modified',
          'invalid',
          'parsed',
        }.contains(raw['status']) ||
        !{
          null,
          'same_content_distinct_source',
          'possible_existing_content_distinct_source',
        }.contains(raw['warning'])) {
      throw const FormatException('迁移预览行状态无效。');
    }
    if (raw['row'] != null &&
        DataImportRow.fromJson(dataToolsObject(raw['row'])).sourceId !=
            raw['source_id']) {
      throw const FormatException('迁移预览行来源不匹配。');
    }
    final errors = raw['errors'];
    if (errors is! List ||
        errors.length > 100 ||
        (raw['status'] == 'invalid' && errors.isEmpty)) {
      throw const FormatException('迁移预览错误清单无效。');
    }
    for (final error in errors) {
      DataImportError.fromJson(dataToolsObject(error));
    }
    return StageImportPreviewRow._(raw);
  }
}

final class StageImportRowsPage extends StageImportWire {
  StageImportRowsPage._(super.value);
  String? get requestId => value['request_id'] as String?;
  String get stageId => value['stage_id'] as String;
  int get version => value['stage_version'] as int;
  bool get hasMore => value['has_more'] as bool;
  String? get nextCursor => value['next_cursor'] as String?;
  List<StageImportPreviewRow> get rows => (value['rows'] as List)
      .map(StageImportPreviewRow.parse)
      .toList(growable: false);
  factory StageImportRowsPage.parse(Map<String, Object?> raw) {
    dataToolsKeys(
      raw,
      {'stage_id', 'stage_version', 'rows', 'has_more', 'next_cursor'},
      {'request_id'},
    );
    if (raw['request_id'] != null) dataToolsUuid(raw['request_id']);
    dataToolsUuid(raw['stage_id']);
    stageInteger(raw['stage_version'], 1, 2147483647);
    final rows = raw['rows'], cursor = raw['next_cursor'];
    if (rows is! List ||
        rows.length > 100 ||
        raw['has_more'] is! bool ||
        raw['has_more'] != (cursor != null) ||
        (raw['has_more'] == true && rows.isEmpty) ||
        (cursor != null &&
            (cursor is! String || cursor.isEmpty || cursor.length > 256))) {
      throw const FormatException('迁移预览分页不完整。');
    }
    var previous = 0;
    for (final row in rows.map(StageImportPreviewRow.parse)) {
      if (row.position <= previous) throw const FormatException('迁移预览分页顺序无效。');
      previous = row.position;
    }
    return StageImportRowsPage._(raw);
  }
}
