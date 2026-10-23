import 'package:flowtrace/data/data_tools/stage_import_reauthorization.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart' show qid;

Map<String, Object?> stageReauthorizationFixture() => {
  'stage_id': qid(70),
  'batch_id': qid(72),
  'stage_version': 2,
  'format': 'qianji_csv',
  'expected_bytes': 30,
  'source_sha256': List.filled(64, 'a').join(),
  'mapping_hash': List.filled(64, 'b').join(),
  'status': 'parsed',
  'source_released': false,
  'expired': false,
};

void main() {
  test('只读预检只包含本人原件匹配字段，不接受原session或mapping正文', () {
    final value = StageImportReauthorization.parse(
      stageReauthorizationFixture(),
    );
    expect(value.version, 2);
    expect(value.expectedBytes, 30);
    for (final extra in [
      {'origin_session_id': qid(80)},
      {'mapping': {}},
      {'password': 'not-allowed'},
    ]) {
      expect(
        () => StageImportReauthorization.parse({
          ...stageReauthorizationFixture(),
          ...extra,
        }),
        throwsFormatException,
      );
    }
  });

  test('published源TTL到期与正式状态分别表达，来源hash/容量闭合', () {
    final value = StageImportReauthorization.parse({
      ...stageReauthorizationFixture(),
      'status': 'applied',
      'expired': true,
      'source_released': true,
    });
    expect(value.expired, isTrue);
    expect(value.status, 'applied');
    for (final patch in [
      {'source_sha256': 'invalid'},
      {'expected_bytes': 0},
      {'expired': 'false'},
      {'source_released': true, 'status': 'parsed'},
    ]) {
      expect(
        () => StageImportReauthorization.parse({
          ...stageReauthorizationFixture(),
          ...patch,
        }),
        throwsFormatException,
      );
    }
  });
}
