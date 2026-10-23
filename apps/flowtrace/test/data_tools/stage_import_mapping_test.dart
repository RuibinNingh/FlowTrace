import 'dart:convert';
import 'dart:io';

import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/stage_import_mapping.dart';
import 'package:flowtrace/data/data_tools/stage_import_models.dart';
import 'package:flowtrace/data/data_tools/stage_import_requirements.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart' show qid;

void main() {
  final fixture = dataToolsObject(
    jsonDecode(
      File(
        '../../server/tests/data_tools/fixtures/stage_mapping_golden.json',
      ).readAsStringSync(),
    ),
  );
  for (final row in fixture['cases'] as List) {
    final sample = dataToolsObject(row);
    test('与Python同一真实黄金规范化及SHA：${sample['name']}', () {
      final input = dataToolsObject(sample['input']);
      final original = jsonEncode(input);
      final normalized = normalizeStageMapping(input);
      expect(normalized, sample['normalized']);
      expect(canonicalStageJson(normalized), sample['canonical_json']);
      expect(stageMappingHash(input), sample['sha256']);
      expect(jsonEncode(input), original);
    });
  }

  test('2000个emoji资源原名与80个emoji命名空间按Unicode字符限额', () {
    final name = List.filled(2000, '😀').join();
    final namespace = List.filled(80, '🧾').join();
    final item = StageImportRequirement.parse({
      'position': 1,
      'kind': 'account',
      'source_kind': 'name',
      'source_key': name,
      'resource_type': null,
      'first_line': 2,
      'attachment_source': null,
    });
    expect(item.sourceKey, name);
    final mapping = {
      'source_namespace': namespace,
      'template_mapping': {
        'scope_id': qid(1),
        'timezone': 'UTC',
        'account_names': {name: qid(2)},
      },
    };
    expect(stageMapping(mapping), mapping);
    expect(stageMappingHash(mapping), hasLength(64));
    expect(
      () =>
          StageImportRequirement.parse({...item.body, 'source_key': '$name😀'}),
      throwsFormatException,
    );
    expect(
      () => stageMapping({...mapping, 'source_namespace': '$namespace🧾'}),
      throwsFormatException,
    );
  });
}
