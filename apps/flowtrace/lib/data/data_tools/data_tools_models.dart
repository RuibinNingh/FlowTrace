import 'dart:convert';

import '../../core/money/money.dart';

const dataToolsFileLimit = 5 * 1024 * 1024;
const dataToolsJsonLimit = 1024 * 1024;
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _digest = RegExp(r'^[0-9a-f]{64}$');

String dataToolsUuid(Object? value) {
  if (value is! String || !_uuid.hasMatch(value)) {
    throw const FormatException('数据标识无效。');
  }
  return value;
}

Map<String, Object?> dataToolsObject(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('数据结构无效。');
  }
  return value.cast<String, Object?>();
}

void dataToolsKeys(
  Map<String, Object?> value,
  Set<String> required, [
  Set<String> optional = const {},
]) {
  if (!value.keys.toSet().containsAll(required) ||
      value.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      )) {
    throw const FormatException('数据字段与接口不一致。');
  }
}

void _exact(Object? value, [int depth = 0]) {
  if (depth > 32) throw const FormatException('数据层级过深。');
  if (value == null || value is bool) return;
  if (value is String) {
    if (value.contains('\u0000') ||
        String.fromCharCodes(value.runes) != value) {
      throw const FormatException('文字编码无效。');
    }
    return;
  }
  if (value is int && value >= 0 && value <= 2147483647) return;
  if (value is List) {
    for (final item in value) {
      _exact(item, depth + 1);
    }
    return;
  }
  if (value is Map && value.keys.every((key) => key is String)) {
    for (final entry in value.entries) {
      _exact(entry.key, depth + 1);
      _exact(entry.value, depth + 1);
    }
    return;
  }
  throw const FormatException('金额需使用精确字符串，控制值需使用有界整数。');
}

String dataToolsFrozenJson(Object? value, {int maxBytes = dataToolsJsonLimit}) {
  _exact(value);
  final result = jsonEncode(value);
  if (utf8.encode(result).length > maxBytes) {
    throw const FormatException('数据超过当前处理大小。');
  }
  return result;
}

String _text(Object? value, {int max = 2000}) {
  if (value is! String || value.length > max) {
    throw const FormatException('文字字段无效。');
  }
  return value;
}

List<Object?> _list(Object? value, {int max = 1000}) {
  if (value is! List || value.length > max) {
    throw const FormatException('列表字段无效。');
  }
  return value.cast<Object?>();
}

int _count(Object? value, {int min = 0, int max = 2147483647}) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('数量字段无效。');
  }
  return value;
}

bool _bool(Object? value) {
  if (value is! bool) throw const FormatException('状态字段无效。');
  return value;
}

void _revision(Object? value) {
  if (value is! String || !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
    throw const FormatException('修订字段无效。');
  }
  parseMinor(value);
}

enum ImportFileKind {
  flowtraceJson('flowtrace_json', '流迹 JSON'),
  flowtraceCsv('flowtrace_csv', '流迹 CSV'),
  flowtraceXlsx('flowtrace_xlsx', '流迹 Excel'),
  qianjiCsv('qianji_csv', '钱迹 CSV（原始导出 / 公开模板）'),
  qianjiXlsx('qianji_xlsx', '钱迹 Excel（原始导出 / 公开模板）');

  const ImportFileKind(this.wire, this.label);
  final String wire, label;
  bool get isQianji => wire.startsWith('qianji_');
  static ImportFileKind parse(Object? value) => values.firstWhere(
    (kind) => kind.wire == value,
    orElse: () => throw const FormatException('导入格式无效。'),
  );
}

final class DataImportRow {
  DataImportRow.fromJson(Map<String, Object?> value)
    : sourceId = dataToolsUuid(value['source_id']),
      scopeId = dataToolsUuid(value['scope_id']),
      entityType = _text(value['entity_type'], max: 16),
      _payload = dataToolsFrozenJson(dataToolsObject(value['payload'])) {
    dataToolsKeys(value, {'source_id', 'scope_id', 'entity_type', 'payload'});
    if (!{
      'book',
      'account',
      'category',
      'tag',
      'bill',
      'budget',
    }.contains(entityType)) {
      throw const FormatException('导入对象类型无效。');
    }
    if (entityType == 'bill') Money.fromJson(payload['money'], positive: true);
    if (entityType == 'account') Money.fromJson(payload['opening']);
  }
  final String sourceId, scopeId, entityType, _payload;
  Map<String, Object?> get payload => dataToolsObject(jsonDecode(_payload));
  Map<String, Object?> toJson() => {
    'source_id': sourceId,
    'scope_id': scopeId,
    'entity_type': entityType,
    'payload': payload,
  };
}

final class DataImportDocument {
  DataImportDocument.fromJson(Map<String, Object?> value)
    : namespace = _text(value['source_namespace'], max: 80),
      rows = List.unmodifiable(
        _list(
          value['rows'],
          max: 50,
        ).map((row) => DataImportRow.fromJson(dataToolsObject(row))),
      ),
      _hints = dataToolsFrozenJson(
        value['posting_hints'] ?? <String, Object?>{},
      ) {
    dataToolsKeys(
      value,
      {'format', 'source_namespace', 'rows'},
      {'posting_hints'},
    );
    if (value['format'] != 'flowtrace-data-v1' ||
        namespace.isEmpty ||
        rows.isEmpty ||
        rows.map((row) => row.sourceId).toSet().length != rows.length) {
      throw const FormatException('导入文档格式无效。');
    }
    for (final entry in postingHints.entries) {
      dataToolsUuid(entry.key);
      final hint = dataToolsObject(entry.value);
      dataToolsKeys(hint, {'signed_principal_minor'});
      final matching = rows
          .where((row) => row.sourceId == entry.key)
          .firstOrNull;
      final signed = parseMinor(hint['signed_principal_minor']);
      if (matching == null ||
          matching.entityType != 'bill' ||
          matching.payload['bill_type'] != 'balance_adjustment' ||
          signed == BigInt.zero ||
          signed.abs() !=
              Money.fromJson(matching.payload['money'], positive: true).minor) {
        throw const FormatException('历史余额调整的变动不一致。');
      }
    }
  }
  final String namespace, _hints;
  final List<DataImportRow> rows;
  Map<String, Object?> get postingHints => dataToolsObject(jsonDecode(_hints));
  Map<String, Object?> toJson() => {
    'format': 'flowtrace-data-v1',
    'source_namespace': namespace,
    'rows': rows.map((row) => row.toJson()).toList(),
    'posting_hints': postingHints,
  };
}

final class DataImportError {
  DataImportError.fromJson(Map<String, Object?> value)
    : row = value['row'] == null ? null : _count(value['row'], min: 1),
      field = value['field'] == null ? null : _text(value['field'], max: 200),
      code = _text(value['code'], max: 100) {
    dataToolsKeys(value, {'row', 'field', 'code'});
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(code)) {
      throw const FormatException('错误码无效。');
    }
  }
  final int? row;
  final String? field;
  final String code;
}

final class DataMappingRequirement {
  DataMappingRequirement.fromJson(Map<String, Object?> value)
    : kind = _text(value['kind'], max: 16),
      sourceValue = _text(value['source_value']),
      rows = List.unmodifiable(
        _list(
          value['rows'],
          max: 50,
        ).map((row) => _count(row, min: 2, max: 51)),
      ) {
    dataToolsKeys(value, {'kind', 'source_value', 'rows'});
    if (!{'account', 'category', 'tag', 'image'}.contains(kind) ||
        sourceValue.isEmpty ||
        rows.isEmpty) {
      throw const FormatException('映射要求无效。');
    }
  }
  final String kind, sourceValue;
  final List<int> rows;
}

final class DataImportParseResult {
  DataImportParseResult.fromJson(Map<String, Object?> value)
    : kind = ImportFileKind.parse(value['format']),
      requestId = value['request_id'] == null
          ? null
          : dataToolsUuid(value['request_id']),
      sourceSha256 = _text(value['source_sha256'], max: 64),
      document = value['document'] == null
          ? null
          : DataImportDocument.fromJson(dataToolsObject(value['document'])),
      errors = List.unmodifiable(
        _list(
          value['errors'],
        ).map((row) => DataImportError.fromJson(dataToolsObject(row))),
      ),
      attachmentSources = List.unmodifiable(
        _list(
          value['attachment_sources'] ?? [],
          max: 1000,
        ).map((row) => DataAttachmentSource.fromJson(dataToolsObject(row))),
      ),
      mappings = List.unmodifiable(
        _list(
          value['mapping_requirements'] ?? [],
          max: 6000,
        ).map((row) => DataMappingRequirement.fromJson(dataToolsObject(row))),
      ) {
    dataToolsKeys(
      value,
      {'format', 'source_sha256', 'document', 'errors'},
      {'mapping_requirements', 'attachment_sources', 'request_id'},
    );
    if (!_digest.hasMatch(sourceSha256) ||
        (document != null && errors.isNotEmpty)) {
      throw const FormatException('文件解析回执无效。');
    }
    final sources = attachmentSources.map((source) => source.sourceId).toSet();
    final referenced = {
      for (final row in document?.rows ?? <DataImportRow>[])
        if (row.entityType == 'bill')
          ...((row.payload['attachment_ids'] as List?) ?? []).map(
            dataToolsUuid,
          ),
    };
    if (sources.length != attachmentSources.length ||
        (sources.isNotEmpty &&
            (sources.length != referenced.length ||
                !sources.every(referenced.contains)))) {
      throw const FormatException('原图清单与导入记录不一致。');
    }
  }
  final ImportFileKind kind;
  final String sourceSha256;
  final String? requestId;
  final DataImportDocument? document;
  final List<DataImportError> errors;
  final List<DataMappingRequirement> mappings;
  final List<DataAttachmentSource> attachmentSources;
}

final class DataAttachmentSource {
  DataAttachmentSource.fromJson(Map<String, Object?> value)
    : sourceId = dataToolsUuid(value['source_id']),
      sha256 = _text(value['sha256'], max: 64),
      sizeBytes = _count(value['size_bytes'], min: 1, max: 10 * 1024 * 1024),
      mediaType = _text(value['media_type'], max: 20) {
    dataToolsKeys(value, {'source_id', 'sha256', 'size_bytes', 'media_type'});
    if (!_digest.hasMatch(sha256) ||
        !{'image/jpeg', 'image/png', 'image/webp'}.contains(mediaType)) {
      throw const FormatException('原图校验清单无效。');
    }
  }
  final String sourceId, sha256, mediaType;
  final int sizeBytes;
}

final class DataImportPreview {
  DataImportPreview.fromJson(Map<String, Object?> value)
    : batchId = dataToolsUuid(value['batch_id']),
      contentHash = _text(value['content_hash'], max: 64),
      canApply = _bool(value['can_apply']),
      fingerprintScanComplete = _bool(value['fingerprint_scan_complete']),
      errors = List.unmodifiable(
        _list(
          value['errors'],
        ).map((row) => DataImportError.fromJson(dataToolsObject(row))),
      ),
      _rows = dataToolsFrozenJson(_list(value['rows'], max: 50)) {
    dataToolsKeys(value, {
      'batch_id',
      'content_hash',
      'can_apply',
      'fingerprint_scan_complete',
      'errors',
      'rows',
    });
    if (!_digest.hasMatch(contentHash) || (canApply && errors.isNotEmpty)) {
      throw const FormatException('导入预览回执无效。');
    }
    for (final row in rows) {
      dataToolsKeys(row, {
        'row',
        'source_id',
        'entity_id',
        'status',
        'warning',
      });
      _count(row['row'], min: 1, max: 50);
      dataToolsUuid(row['source_id']);
      dataToolsUuid(row['entity_id']);
      if (!{
            'new',
            'duplicate',
            'source_conflict',
            'previously_undone',
            'source_modified',
          }.contains(row['status']) ||
          (row['warning'] != null &&
              !{
                'same_content_distinct_source',
                'possible_existing_content_distinct_source',
              }.contains(row['warning']))) {
        throw const FormatException('导入行状态无效。');
      }
      if (canApply && !{'new', 'duplicate'}.contains(row['status'])) {
        throw const FormatException('导入行冲突与整体状态不一致。');
      }
    }
  }
  final String batchId, contentHash, _rows;
  final bool canApply, fingerprintScanComplete;
  final List<DataImportError> errors;
  List<Map<String, Object?>> get rows =>
      (jsonDecode(_rows) as List).map(dataToolsObject).toList();
}

final class DataImportApplied {
  DataImportApplied.fromJson(Map<String, Object?> value)
    : batchId = dataToolsUuid(value['batch_id']),
      status = _text(value['status'], max: 16),
      created = List.unmodifiable(
        _list(value['created'], max: 50).map(dataToolsUuid),
      ),
      duplicates = List.unmodifiable(
        _list(value['duplicates'], max: 50).map(dataToolsUuid),
      ),
      replayed = _bool(value['replayed']),
      _json = dataToolsFrozenJson(value) {
    dataToolsKeys(
      value,
      {
        'batch_id',
        'status',
        'created',
        'duplicates',
        'commit_id',
        'scope_revisions',
        'replayed',
      },
      {'attachment_transfers'},
    );
    if (!{'applied', 'undone'}.contains(status) ||
        created.toSet().length != created.length ||
        duplicates.toSet().length != duplicates.length ||
        created.toSet().intersection(duplicates.toSet()).isNotEmpty) {
      throw const FormatException('导入确认回执无效。');
    }
    if (value['commit_id'] != null) dataToolsUuid(value['commit_id']);
    if (created.isNotEmpty &&
        (value['commit_id'] == null ||
            dataToolsObject(value['scope_revisions']).isEmpty)) {
      throw const FormatException('正式导入缺少同步回执。');
    }
    for (final entry in dataToolsObject(value['scope_revisions']).entries) {
      dataToolsUuid(entry.key);
      _revision(entry.value);
    }
    for (final item in _list(value['attachment_transfers'] ?? [], max: 100)) {
      final row = dataToolsObject(item);
      dataToolsKeys(row, {
        'attachment_id',
        'from_scope_id',
        'to_scope_id',
        'permission_version',
        'sha256',
        'size_bytes',
        'media_type',
      });
      for (final field in ['attachment_id', 'from_scope_id', 'to_scope_id']) {
        dataToolsUuid(row[field]);
      }
      _revision(row['permission_version']);
      if (!_digest.hasMatch(_text(row['sha256'], max: 64)) ||
          !{
            'image/jpeg',
            'image/png',
            'image/webp',
          }.contains(row['media_type'])) {
        throw const FormatException('附件采纳回执无效。');
      }
      _count(row['size_bytes'], min: 1, max: 10 * 1024 * 1024);
    }
  }
  final String batchId, status, _json;
  final List<String> created, duplicates;
  final bool replayed;
  Map<String, Object?> toJson() => dataToolsObject(jsonDecode(_json));
}

final class DataImportHistoryItem {
  DataImportHistoryItem.fromJson(Map<String, Object?> value)
    : batchId = dataToolsUuid(value['batch_id']),
      status = _text(value['status'], max: 16),
      sourceNamespace = _text(value['source_namespace'], max: 80),
      createdAt = DateTime.parse(_text(value['created_at'], max: 40)),
      createdCount = _count(value['created_count']),
      duplicateCount = _count(value['duplicate_count']) {
    dataToolsKeys(value, {
      'batch_id',
      'status',
      'source_namespace',
      'created_at',
      'created_count',
      'duplicate_count',
    });
    if (!{'applied', 'undone'}.contains(status)) {
      throw const FormatException('导入历史状态无效。');
    }
  }
  final String batchId, status, sourceNamespace;
  final DateTime createdAt;
  final int createdCount, duplicateCount;
}

final class DataImportHistoryPage {
  DataImportHistoryPage.fromJson(Map<String, Object?> value)
    : items = List.unmodifiable(
        _list(
          value['batches'],
          max: 100,
        ).map((row) => DataImportHistoryItem.fromJson(dataToolsObject(row))),
      ),
      limit = _count(value['limit'], min: 1, max: 100),
      hasMore = _bool(value['has_more']),
      nextCursor = value['next_cursor'] == null
          ? null
          : _text(value['next_cursor'], max: 256) {
    dataToolsKeys(value, {'batches', 'limit', 'has_more', 'next_cursor'});
    if (items.length > limit ||
        hasMore != (nextCursor != null) ||
        items.map((item) => item.batchId).toSet().length != items.length) {
      throw const FormatException('导入历史分页无效。');
    }
  }
  final List<DataImportHistoryItem> items;
  final int limit;
  final bool hasMore;
  final String? nextCursor;
}

final class DataImportUndoPreview {
  DataImportUndoPreview.fromJson(Map<String, Object?> value)
    : batchId = dataToolsUuid(value['batch_id']),
      status = _text(value['status'], max: 16),
      canUndo = _bool(value['can_undo']),
      createdCount = _count(value['created_count']),
      conflictCount =
          _list(value['conflicts'], max: 50).length +
          _list(value['attachment_conflicts'], max: 100).length {
    dataToolsKeys(value, {
      'batch_id',
      'status',
      'can_undo',
      'created_count',
      'conflicts',
      'attachment_conflicts',
    });
    if (!{'applied', 'undone'}.contains(status) ||
        (canUndo && (status != 'applied' || conflictCount != 0))) {
      throw const FormatException('撤销预览无效。');
    }
    for (final item in _list(value['conflicts'], max: 50)) {
      final row = dataToolsObject(item);
      dataToolsKeys(row, {'source_id', 'entity_id', 'code'});
      dataToolsUuid(row['source_id']);
      dataToolsUuid(row['entity_id']);
      if (row['code'] != 'modified_or_deleted') {
        throw const FormatException('撤销冲突无效。');
      }
    }
    for (final item in _list(value['attachment_conflicts'], max: 100)) {
      final row = dataToolsObject(item);
      dataToolsKeys(row, {'attachment_id', 'code'});
      dataToolsUuid(row['attachment_id']);
      if (row['code'] != 'attachment_modified') {
        throw const FormatException('附件撤销冲突无效。');
      }
    }
    if (status == 'undone' && (canUndo || conflictCount != 0)) {
      throw const FormatException('已撤销的操作预览无效。');
    }
  }
  final String batchId, status;
  final bool canUndo;
  final int createdCount, conflictCount;
}
