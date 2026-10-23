import 'package:flowtrace/data/data_tools/stage_import_source_books.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart' show qid;
import 'stage_import_store_test.dart' show StageRig;
import 'stage_import_requirements_test.dart' show withRequirements, pageLease;

Map<String, Object?> sourceBook(int position) => {
  'position': position,
  'source_id': qid(position + 100),
  'name': '原文件账本$position',
  'currency': 'CNY',
  'timezone': 'Asia/Shanghai',
};
Map<String, Object?> booksPage(
  List<Map<String, Object?>> items, {
  String? cursor,
  int count = 2,
  int version = 1,
}) => {
  'stage_id': qid(70),
  'stage_version': version,
  'count': count,
  'items': items,
  'has_more': cursor != null,
  'next_cursor': cursor,
};

void main() {
  test('账本分页位置可稀疏，按实际书总数完成而不是最后行号', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final record = await withRequirements(rig, []);
    final reader = StageImportSourceBooksReader(rig.store, record);
    var calls = 0;
    final lease = pageLease(rig, (path) async {
      final uri = Uri.parse(path);
      expect(uri.path.endsWith('/source-books'), isTrue);
      expect(uri.queryParameters['stage_version'], '1');
      calls++;
      if (calls == 1) {
        return booksPage([sourceBook(2)], cursor: 'opaque+/=');
      }
      expect(uri.queryParameters['cursor'], 'opaque+/=');
      return booksPage([sourceBook(204)]);
    });
    expect((await reader.next(lease)).items.single.position, 2);
    expect(reader.complete, isFalse);
    expect((await reader.next(lease)).items.single.position, 204);
    expect(reader.complete, isTrue);
    expect(reader.loaded, 2);
    expect(
      await rig.fixture.db.select(rig.fixture.db.pendingOperations).get(),
      isEmpty,
    );
  });

  test('分页不得把缺书、旧版本、重复位置或未声明正文当成完整结果', () async {
    final rig = StageRig();
    await rig.init();
    addTearDown(rig.close);
    final record = await withRequirements(rig, []);
    for (final raw in [
      booksPage([sourceBook(2)]),
      booksPage([sourceBook(2)], version: 2),
      booksPage([sourceBook(2), sourceBook(2)]),
      booksPage([
        {...sourceBook(2), 'database_url': 'forbidden'},
      ], count: 1),
    ]) {
      final reader = StageImportSourceBooksReader(rig.store, record);
      await expectLater(
        reader.next(pageLease(rig, (_) async => raw)),
        throwsFormatException,
      );
      expect(reader.complete, isFalse);
    }
    final empty = StageImportSourceBooksReader(rig.store, record);
    await empty.next(pageLease(rig, (_) async => booksPage([], count: 0)));
    expect(empty.complete, isTrue);
  });
}
