import '../../core/network/api_failure.dart';
import 'data_tools_models.dart';
import 'stage_import_lease.dart';
import 'stage_import_models.dart';
import 'stage_import_store.dart';

/// Display metadata from an actual uploaded native book definition. The source
/// UUID is a same-batch image destination, not an existing-book write grant.
final class StageImportSourceBook extends StageImportWire {
  StageImportSourceBook._(super.value);
  int get position => value['position'] as int;
  String get sourceId => value['source_id'] as String;
  String get name => value['name'] as String;
  String get currency => value['currency'] as String;
  String get timezone => value['timezone'] as String;
  factory StageImportSourceBook.parse(Object? input) {
    final raw = dataToolsObject(input);
    dataToolsKeys(raw, {
      'position',
      'source_id',
      'name',
      'currency',
      'timezone',
    });
    stageInteger(raw['position'], 1, 200000);
    dataToolsUuid(raw['source_id']);
    final name = raw['name'],
        currency = raw['currency'],
        timezone = raw['timezone'];
    if (name is! String ||
        name.isEmpty ||
        name.runes.length > 80 ||
        timezone is! String ||
        timezone.isEmpty ||
        timezone.runes.length > 128 ||
        currency is! String ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      throw const FormatException('原文件账本信息无效。');
    }
    return StageImportSourceBook._(raw);
  }
}

final class StageImportSourceBooksPage extends StageImportWire {
  StageImportSourceBooksPage._(super.value);
  String get stageId => value['stage_id'] as String;
  int get version => value['stage_version'] as int;
  int get count => value['count'] as int;
  bool get hasMore => value['has_more'] as bool;
  String? get nextCursor => value['next_cursor'] as String?;
  List<StageImportSourceBook> get items => (value['items'] as List)
      .map(StageImportSourceBook.parse)
      .toList(growable: false);
  factory StageImportSourceBooksPage.parse(Map<String, Object?> raw) {
    dataToolsKeys(raw, {
      'stage_id',
      'stage_version',
      'count',
      'items',
      'has_more',
      'next_cursor',
    });
    dataToolsUuid(raw['stage_id']);
    stageInteger(raw['stage_version'], 1, 2147483647);
    final count = stageInteger(raw['count'], 0, 200000);
    final items = raw['items'], cursor = raw['next_cursor'];
    if (items is! List ||
        items.length > 100 ||
        items.length > count ||
        raw['has_more'] is! bool ||
        raw['has_more'] != (cursor != null) ||
        raw['has_more'] == true && items.isEmpty ||
        cursor != null &&
            (cursor is! String || cursor.isEmpty || cursor.length > 512)) {
      throw const FormatException('原文件账本分页不完整。');
    }
    var previous = 0;
    final ids = <String>{};
    for (final item in items.map(StageImportSourceBook.parse)) {
      if (item.position <= previous || !ids.add(item.sourceId)) {
        throw const FormatException('原文件账本分页顺序无效。');
      }
      previous = item.position;
    }
    return StageImportSourceBooksPage._(raw);
  }
}

final class StageImportSourceBooksReader {
  StageImportSourceBooksReader(this.store, this.record);
  final StageImportStore store;
  final StageImportRecord record;
  int? _count;
  int _position = 0, _loaded = 0;
  String? _cursor;
  bool _complete = false, _busy = false;
  bool get complete => _complete;
  int get loaded => _loaded;
  Future<StageImportSourceBooksPage> next(
    StageImportLease lease,
  ) => store.track(() async {
    lease.requireCapability();
    if (_busy || _complete) {
      throw const ApiFailure('stage_source_books_state', '原文件账本分页状态已变化，请重新载入。');
    }
    _busy = true;
    try {
      final current = await store.require(lease, record.stageId);
      if (current.version != record.version ||
          current.remote?.sourceReleased == true) {
        throw const ApiFailure('stage_remote_changed', '原文件版本已变化，请重新核对。');
      }
      final suffix = _cursor == null
          ? ''
          : '&cursor=${Uri.encodeQueryComponent(_cursor!)}';
      final page = StageImportSourceBooksPage.parse(
        await lease.data.request(
          'GET',
          '/data-tools/import-stages/${record.stageId}/source-books?stage_version=${record.version}&limit=100$suffix',
        ),
      );
      lease.check();
      if (page.stageId != record.stageId ||
          page.version != record.version ||
          _count != null && page.count != _count) {
        throw const FormatException('原文件账本分页绑定不匹配。');
      }
      var position = _position;
      for (final item in page.items) {
        if (item.position <= position) {
          throw const FormatException('原文件账本分页存在重复。');
        }
        position = item.position;
      }
      final loaded = _loaded + page.items.length;
      if (loaded > page.count ||
          page.hasMore != (loaded < page.count) ||
          page.hasMore && page.nextCursor == _cursor) {
        throw const FormatException('原文件账本分页终点不匹配。');
      }
      _position = position;
      _count = page.count;
      _loaded = loaded;
      _cursor = page.nextCursor;
      _complete = !page.hasMore;
      return page;
    } finally {
      _busy = false;
    }
  });
}
