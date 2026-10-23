import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/stage_import_draft.dart';
import 'package:flowtrace/data/data_tools/stage_import_requirements.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import '../ledger/query_fixtures.dart' show qid;

void main() {
  final source = File(
    '../../server/tests/data_tools/fixtures/stage_image_mapping_golden.json',
  );
  final fixture = dataToolsObject(jsonDecode(source.readAsStringSync()));
  final results = <Map<String, Object?>>[];
  final requirementHash = List.filled(64, 'a').join();
  for (final item in fixture['cases'] as List) {
    final sample = dataToolsObject(item);
    final requirement = StageImportRequirement.parse(sample['requirement']);
    final selected = dataToolsObject(sample['selected']);
    final bytes = base64Decode(selected['base64'] as String);
    test('生产plan_transfers共享黄金：${sample['name']}', () {
      expect(bytes.length, 77);
      expect(sha256.convert(bytes).toString(), selected['sha256']);
      final initial = StageImportMappingDraft.create(
        version: 1,
        requirementsHash: requirementHash,
        mapping: dataToolsObject(sample['base_mapping']),
      );
      final result = initial.withImageChoice(
        requirement,
        uploadedId: sample['uploaded_id'] as String,
        targetBookId: sample['target_book_id'] as String,
        selectedBytes: bytes,
        mediaType: selected['media_type'] as String,
      );
      expect(result.mapping, sample['expected_mapping']);
      expect(result.choice(requirement), sample['uploaded_id']);
      results.add({
        'source_case': sample['name'],
        'scenario': 'first_selection',
        'mapping': result.mapping,
      });
    });

    test('重解析无images proof重选原图，旧无引用transfer必须清除：${sample['name']}', () {
      final initial = StageImportMappingDraft.create(
        version: 2,
        requirementsHash: requirementHash,
        mapping: dataToolsObject(sample['expected_mapping']),
      );
      final result = initial.withImageChoice(
        requirement,
        uploadedId: qid(99),
        targetBookId: sample['target_book_id'] as String,
        selectedBytes: bytes,
        mediaType: selected['media_type'] as String,
      );
      final transfers = dataToolsObject(result.mapping['attachment_transfers']);
      expect(transfers.containsKey(sample['uploaded_id']), isFalse);
      expect(transfers, {qid(99): sample['target_book_id']});
      results.add({
        'source_case': sample['name'],
        'scenario': 'replacement_without_local_proof',
        'mapping': result.mapping,
      });
    });
  }
  tearDownAll(() async {
    // Synthetic mappings are returned to the Python production planner for an
    // independent reverse check. Every run writes its own receipt, not history.
    final directory = Directory('../../outputs/validation/P5/stage-image-dart');
    await directory.create(recursive: true);
    final path =
        '${directory.path}${Platform.pathSeparator}${const Uuid().v4()}.json';
    await File(path).writeAsString(
      jsonEncode({
        'format': 'flowtrace-stage-image-dart-v1',
        'source_sha256': sha256.convert(source.readAsBytesSync()).toString(),
        'results': results,
      }),
    );
  });
}
