import 'package:flowtrace/data/data_tools/stage_import_mutation_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart' show qid;

Map<String, Object?> releasedFixture() => {
  'stage_id': qid(70),
  'batch_id': qid(72),
  'request_id': qid(83),
  'stage_version': 1,
  'source_released': true,
  'source_released_at': '2026-10-23T01:00:00Z',
  'reserved_bytes_released': 524305,
  'deleted_source_bytes': 524305,
  'deleted_source_chunks': 2,
  'deleted_preview_rows': 202,
  'deleted_requirement_rows': 4,
  'replayed': false,
};

void main() {
  test('typed释放回执仅replayed可异，原件与行数不可忽略', () {
    final first = StageImportSourceReleased.parse(releasedFixture());
    final replay = StageImportSourceReleased.parse({
      ...releasedFixture(),
      'replayed': true,
    });
    expect(first.stable, replay.stable);
    expect(first.body['replayed'], isFalse);
    final changed = StageImportSourceReleased.parse({
      ...releasedFixture(),
      'deleted_preview_rows': 201,
    });
    expect(first.stable, isNot(changed.stable));
    for (final patch in [
      {'deleted_source_bytes': 524306},
      {'deleted_source_chunks': 0},
      {'source_released': false},
      {'replayed': 'true'},
    ]) {
      expect(
        () => StageImportSourceReleased.parse({...releasedFixture(), ...patch}),
        throwsFormatException,
      );
    }
  });

  test('旧无requirements计数字段只在typed比较扩零，不改原回执', () {
    final raw = releasedFixture()..remove('deleted_requirement_rows');
    final old = StageImportSourceReleased.parse(raw);
    expect(old.body.containsKey('deleted_requirement_rows'), isFalse);
    expect(old.stable['deleted_requirement_rows'], 0);
  });

  test('迁移预览分页保错误原行且要求显式continuation', () {
    final row = {
      'position': 1,
      'source_line': 200002,
      'source_id': null,
      'row': null,
      'target_entity_id': null,
      'status': 'invalid',
      'warning': null,
      'errors': [
        {'row': 200002, 'field': 'amount', 'code': 'invalid_exact_amount'},
      ],
    };
    final raw = {
      'stage_id': qid(70),
      'stage_version': 1,
      'rows': [row],
      'has_more': true,
      'next_cursor': 'next',
    };
    final page = StageImportRowsPage.parse(raw);
    expect(page.rows.single.sourceLine, 200002);
    expect(page.rows.single.errors.single.code, 'invalid_exact_amount');
    expect(
      () => StageImportRowsPage.parse({...raw, 'next_cursor': null}),
      throwsFormatException,
    );
    expect(
      () => StageImportRowsPage.parse({...raw, 'rows': []}),
      throwsFormatException,
    );
    expect(
      () => StageImportRowsPage.parse({
        ...raw,
        'rows': [
          {...row, 'errors': []},
        ],
      }),
      throwsFormatException,
    );
  });
}
