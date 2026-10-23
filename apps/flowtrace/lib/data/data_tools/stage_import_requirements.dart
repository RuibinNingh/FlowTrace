import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/network/api_failure.dart';
import '../sync/snapshot_protocol.dart' show canonicalSyncJson;
import 'data_tools_models.dart';
import 'stage_import_lease.dart';
import 'stage_import_models.dart';
import 'stage_import_store.dart';

final class StageImportRequirement extends StageImportWire {
  StageImportRequirement._(super.value);
  int get position => value['position'] as int;
  String get kind => value['kind'] as String;
  String get sourceKind => value['source_kind'] as String;
  String get sourceKey => value['source_key'] as String;
  String? get resourceType => value['resource_type'] as String?;
  int get firstLine => value['first_line'] as int;
  String get identity =>
      canonicalSyncJson([kind, sourceKind, resourceType, sourceKey]);
  DataAttachmentSource? get attachment => value['attachment_source'] == null
      ? null
      : DataAttachmentSource.fromJson(
          dataToolsObject(value['attachment_source']),
        );

  factory StageImportRequirement.parse(Object? input) {
    final raw = dataToolsObject(input);
    dataToolsKeys(raw, {
      'position',
      'kind',
      'source_kind',
      'source_key',
      'resource_type',
      'first_line',
      'attachment_source',
    });
    stageInteger(raw['position'], 1, 200000);
    // The server allows int64, while the client deliberately keeps control
    // integers <= int32. A 50MiB source cannot contain that many physical lines.
    stageInteger(raw['first_line'], 1, 2147483647);
    final key = raw['source_key'];
    if (key is! String ||
        key.isEmpty ||
        key.runes.length > 2000 ||
        key.contains('\u0000')) {
      throw const FormatException('原始资源引用无效。');
    }
    final kind = raw['kind'], type = raw['resource_type'];
    if (raw['source_kind'] == 'name') {
      if (!{'account', 'category', 'tag', 'image'}.contains(kind) ||
          type != null ||
          raw['attachment_source'] != null) {
        throw const FormatException('原始名称引用组合无效。');
      }
    } else if (raw['source_kind'] == 'identifier') {
      dataToolsUuid(key);
      if (!(kind == 'image' && type == null ||
          kind == 'scope' && {'book', 'user'}.contains(type) ||
          kind == 'resource' &&
              {
                'book',
                'account',
                'category',
                'tag',
                'bill',
                'budget',
                'account_group',
              }.contains(type))) {
        throw const FormatException('原始标识引用组合无效。');
      }
    } else {
      throw const FormatException('原始引用种类无效。');
    }
    if (raw['attachment_source'] != null) {
      final image = DataAttachmentSource.fromJson(
        dataToolsObject(raw['attachment_source']),
      );
      if (kind != 'image' ||
          raw['source_kind'] != 'identifier' ||
          type != null ||
          image.sourceId != key) {
        throw const FormatException('原图来源清单不匹配。');
      }
    }
    return StageImportRequirement._(raw);
  }
}

final class StageImportRequirementsPage extends StageImportWire {
  StageImportRequirementsPage._(super.value);
  String get stageId => value['stage_id'] as String;
  int get version => value['stage_version'] as int;
  String get hash => value['requirements_hash'] as String;
  bool get hasMore => value['has_more'] as bool;
  String? get nextCursor => value['next_cursor'] as String?;
  List<StageImportRequirement> get items => (value['items'] as List)
      .map(StageImportRequirement.parse)
      .toList(growable: false);

  factory StageImportRequirementsPage.parse(Map<String, Object?> raw) {
    dataToolsKeys(raw, {
      'stage_id',
      'stage_version',
      'requirements_hash',
      'items',
      'has_more',
      'next_cursor',
    });
    dataToolsUuid(raw['stage_id']);
    stageInteger(raw['stage_version'], 1, 2147483647);
    stageDigest(raw['requirements_hash']);
    final items = raw['items'];
    final cursor = raw['next_cursor'];
    if (items is! List ||
        items.length > 100 ||
        raw['has_more'] is! bool ||
        raw['has_more'] != (cursor != null) ||
        (raw['has_more'] == true && items.isEmpty) ||
        (cursor != null &&
            (cursor is! String || cursor.isEmpty || cursor.length > 512))) {
      throw const FormatException('原始资源分页不完整。');
    }
    var previous = 0;
    for (final item in items.map(StageImportRequirement.parse)) {
      if (item.position <= previous) throw const FormatException('原始资源分页顺序无效。');
      previous = item.position;
    }
    return StageImportRequirementsPage._(raw);
  }
}

final class _RequirementHashSink implements Sink<Digest> {
  Digest? result;
  @override
  void add(Digest value) {
    result = value;
  }

  @override
  void close() {}
}

/// Reads one private metadata page per action. Only a complete, contiguous and
/// hash-verified list can authorize mapping confirmation; invalid financial rows
/// are never used to reconstruct original resource names.
final class StageImportRequirementsReader {
  StageImportRequirementsReader(this.store, this.record) {
    final remote = record.remote;
    final raw = remote?.body;
    if (remote == null ||
        raw!['requirements_version'] != record.version ||
        raw['requirements_hash'] == null ||
        remote.sourceReleased) {
      throw const ApiFailure(
        'stage_requirements_pending',
        '资源清单尚未派生，请等待解析完成后重新载入。',
      );
    }
    hash = stageDigest(raw['requirements_hash']);
    count = stageInteger(raw['requirements_count'], 0, 200000);
    _conversion = sha256.startChunkedConversion(_sink)..add(utf8.encode('['));
  }
  final StageImportStore store;
  final StageImportRecord record;
  late final String hash;
  late final int count;
  final _sink = _RequirementHashSink();
  late final ByteConversionSink _conversion;
  int _position = 0;
  String? _cursor;
  bool _complete = false, _failed = false, _busy = false;
  bool get complete => _complete;
  int get loaded => _position;

  Future<StageImportRequirementsPage> next(
    StageImportLease lease,
  ) => store.track(() async {
    lease.requireCapability();
    if (_complete || _failed || _busy) {
      throw const ApiFailure('stage_requirements_state', '资源清单读取状态已变化，请重新载入。');
    }
    _busy = true;
    try {
      final current = await store.require(lease, record.stageId);
      if (current.version != record.version ||
          current.batchId != record.batchId) {
        throw const ApiFailure('stage_remote_changed', '资源清单版本已变化，请重新载入。');
      }
      final suffix = _cursor == null
          ? ''
          : '&cursor=${Uri.encodeQueryComponent(_cursor!)}';
      final raw = await lease.data.request(
        'GET',
        '/data-tools/import-stages/${record.stageId}/requirements?stage_version=${record.version}&limit=100$suffix',
      );
      lease.check();
      final page = StageImportRequirementsPage.parse(raw);
      if (page.stageId != record.stageId ||
          page.version != record.version ||
          page.hash != hash) {
        throw const FormatException('原始资源分页绑定不匹配。');
      }
      final items = page.items;
      var position = _position;
      for (final item in items) {
        if (item.position != ++position || position > count) {
          throw const FormatException('原始资源分页存在缺项或重复。');
        }
      }
      if (page.hasMore != (position < count) ||
          (page.hasMore && page.nextCursor == _cursor)) {
        throw const FormatException('原始资源分页终点不匹配。');
      }
      for (final item in items) {
        if (_position > 0) _conversion.add(utf8.encode(','));
        _conversion.add(utf8.encode(canonicalSyncJson(item.body)));
        _position++;
      }
      if (!page.hasMore) {
        _conversion.add(utf8.encode(']'));
        _conversion.close();
        if (_sink.result?.toString() != hash) {
          throw const FormatException('完整原始资源清单摘要不一致。');
        }
        _complete = true;
      }
      _cursor = page.nextCursor;
      return page;
    } on FormatException {
      _failed = true;
      rethrow;
    } finally {
      _busy = false;
    }
  });
}
