import 'dart:convert';

import 'package:flowtrace/data/data_tools/stage_import_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart' show qid;

Map<String, Object?> stageStatusFixture() => {
  'stage_id': qid(70),
  'batch_id': qid(72),
  'stage_version': 1,
  'format': 'qianji_csv',
  'status': 'uploading',
  'expected_bytes': 524305,
  'received_bytes': 524288,
  'received_chunks': 1,
  'row_count': 0,
  'error_count': 0,
  'preview_hash': null,
  'parse_job_id': null,
  'preview_job_id': null,
  'apply_job_id': null,
  'undo_job_id': null,
  'created_at': '2026-10-23T00:00:00Z',
  'updated_at': '2026-10-23T00:00:01Z',
  'expires_at': '2026-10-30T00:00:00Z',
  'source_released': false,
  'source_released_at': null,
  'requirements_version': null,
  'requirements_hash': null,
  'requirements_count': 0,
};

void main() {
  test('metadata关闭未知字段，金额不能通过控制数混入', () {
    final value = StageImportStatus.parse(stageStatusFixture());
    expect(value.receivedChunks, 1);
    expect(
      () => StageImportStatus.parse({...stageStatusFixture(), 'payload': {}}),
      throwsFormatException,
    );
    expect(
      () =>
          StageImportStatus.parse({...stageStatusFixture(), 'row_count': 0.0}),
      throwsFormatException,
    );
    expect(
      () => StageImportStatus.parse({
        ...stageStatusFixture(),
        'stage_version': '1',
      }),
      throwsFormatException,
    );
  });

  test('metadata冻结传入及返回map，不允许调用者改变本机回执', () {
    final raw = stageStatusFixture();
    final value = StageImportStatus.parse(raw);
    raw['received_chunks'] = 2;
    final returned = value.body;
    returned['received_chunks'] = 2;
    expect(value.receivedChunks, 1);
    expect(jsonDecode(value.encoded), stageStatusFixture());
  });

  test('已收片与字节必须对应完整片前缀', () {
    for (final patch in [
      {'received_bytes': 1},
      {'received_chunks': 2},
      {'received_chunks': 101},
      {'received_bytes': 524306},
      {'expected_bytes': 0},
    ]) {
      expect(
        () => StageImportStatus.parse({...stageStatusFixture(), ...patch}),
        throwsFormatException,
      );
    }
  });

  test('source-release只可正式终态并保全部已收历史', () {
    final raw = {
      ...stageStatusFixture(),
      'source_released': true,
      'source_released_at': '2026-10-23T00:01:00Z',
      'status': 'applied',
      'received_bytes': 524305,
      'received_chunks': 2,
    };
    expect(StageImportStatus.parse(raw).sourceReleased, isTrue);
    expect(
      () => StageImportStatus.parse({...raw, 'status': 'parsed'}),
      throwsFormatException,
    );
    expect(
      () => StageImportStatus.parse({...raw, 'source_released_at': null}),
      throwsFormatException,
    );
    expect(
      () => StageImportStatus.parse({...raw, 'received_chunks': 1}),
      throwsFormatException,
    );
  });

  test('requirements未派生与真实空清单分别表达，旧版不冒充空清单', () {
    final legacy = stageStatusFixture()
      ..remove('requirements_version')
      ..remove('requirements_hash')
      ..remove('requirements_count');
    expect(
      StageImportStatus.parse(legacy).body['requirements_version'],
      isNull,
    );
    final derived = {
      ...stageStatusFixture(),
      'requirements_version': 1,
      'requirements_hash': List.filled(64, 'a').join(),
      'requirements_count': 0,
    };
    expect(StageImportStatus.parse(derived).body['requirements_version'], 1);
    for (final patch in [
      {'requirements_hash': null},
      {'requirements_version': 2},
      {
        'requirements_version': null,
        'requirements_hash': null,
        'requirements_count': 1,
      },
    ]) {
      expect(
        () => StageImportStatus.parse({...derived, ...patch}),
        throwsFormatException,
      );
    }
  });

  test('分片回执要求原片大小/SHA/连续前缀计数', () {
    final raw = {
      'stage_id': qid(70),
      'stage_version': 1,
      'chunk_index': 1,
      'chunk_sha256': List.filled(64, 'a').join(),
      'size_bytes': 17,
      'next_chunk_index': 2,
      'received_bytes': 524305,
      'expected_bytes': 524305,
      'replayed': false,
    };
    expect(StageImportChunkReceipt.parse(raw).sizeBytes, 17);
    for (final patch in [
      {'chunk_sha256': 'x'},
      {'size_bytes': 18},
      {'next_chunk_index': 1},
      {'received_bytes': 524304},
      {'replayed': 'false'},
    ]) {
      expect(
        () => StageImportChunkReceipt.parse({...raw, ...patch}),
        throwsFormatException,
      );
    }
  });

  test('受控中文名称映射深拷贝并拒额外字段或非UUID目标', () {
    final raw = <String, Object?>{
      'template_mapping': {
        'scope_id': qid(2),
        'timezone': 'Asia/Shanghai',
        'account_names': {'现金': qid(10)},
      },
    };
    final mapped = stageMapping(raw);
    (raw['template_mapping'] as Map)['timezone'] = 'UTC';
    expect((mapped['template_mapping'] as Map)['timezone'], 'Asia/Shanghai');
    expect(
      () => stageMapping({'source_path': 'C:/private.csv'}),
      throwsFormatException,
    );
    expect(
      () => stageMapping({
        'template_mapping': {
          'scope_id': qid(2),
          'timezone': 'UTC',
          'account_names': {'现金': 'cash'},
        },
      }),
      throwsFormatException,
    );
  });
}
