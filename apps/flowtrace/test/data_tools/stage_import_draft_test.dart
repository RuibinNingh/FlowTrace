import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/stage_import_draft.dart';
import 'package:flowtrace/data/data_tools/stage_import_requirements.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart' show qid;
import '../attachments/attachment_repository_test.dart' show picture;

Map<String, Object?> draftRequirement(int position, String name) => {
  'position': position,
  'kind': 'account',
  'source_kind': 'name',
  'source_key': name,
  'resource_type': null,
  'first_line': position + 1,
  'attachment_source': null,
};

void main() {
  final hash = List.filled(64, 'a').join();
  test('跨页选择和原review cursor完整序列化，不只保最后页', () {
    var draft = StageImportMappingDraft.create(
      version: 1,
      requirementsHash: hash,
      mapping: {
        'template_mapping': {'scope_id': qid(2), 'timezone': 'UTC'},
      },
    );
    final first = StageImportRequirement.parse(draftRequirement(1, '原现金'));
    final second = StageImportRequirement.parse(draftRequirement(2, '原银行'));
    draft = draft.withChoice(first, qid(10));
    draft = draft.withPage(
      StageImportRequirementsPage.parse({
        'stage_id': qid(70),
        'stage_version': 1,
        'requirements_hash': hash,
        'items': [first.body],
        'has_more': true,
        'next_cursor': 'next-2',
      }),
    );
    final reopened = StageImportMappingDraft.parse(
      dataToolsObject(jsonDecode(draft.encoded)),
    );
    expect(reopened.choice(first), qid(10));
    expect(reopened.reviewedPosition, 1);
    expect(reopened.nextCursor, 'next-2');
    draft = reopened.withChoice(second, qid(11));
    expect((draft.mapping['template_mapping'] as Map)['account_names'], {
      '原现金': qid(10),
      '原银行': qid(11),
    });
    expect(draft.choice(first), qid(10));
    expect(draft.choice(second), qid(11));
    expect(draft.matches(2, hash), isFalse);
    expect(draft.matches(1, hash), isTrue);
    expect(draft.requestBytes, greaterThan(0));
  });

  test('native外部标识选择分scope/resource闭集保存', () {
    var draft = StageImportMappingDraft.create(
      version: 1,
      requirementsHash: hash,
      mapping: {},
    );
    for (final (kind, type, source, target) in [
      ('scope', 'book', qid(1), qid(2)),
      ('resource', 'account', qid(10), qid(11)),
    ]) {
      final item = StageImportRequirement.parse({
        'position': 1,
        'kind': kind,
        'source_kind': 'identifier',
        'source_key': source,
        'resource_type': type,
        'first_line': 2,
        'attachment_source': null,
      });
      draft = draft.withChoice(item, target);
    }
    expect(draft.mapping['scope_mapping'], {qid(1): qid(2)});
    expect(draft.mapping['resource_mapping'], {qid(10): qid(11)});
    expect(draft.mapping.containsKey('attachment_transfers'), isFalse);
    expect(draft.choices, hasLength(2));
  });

  test('图片必须选真原件并形成source→upload→book双映射，普通选择拒image', () {
    final bytes = picture();
    final raw = {
      'position': 1,
      'kind': 'image',
      'source_kind': 'identifier',
      'source_key': qid(20),
      'resource_type': null,
      'first_line': 2,
      'attachment_source': {
        'source_id': qid(20),
        'sha256': sha256.convert(bytes).toString(),
        'size_bytes': bytes.length,
        'media_type': 'image/png',
      },
    };
    final item = StageImportRequirement.parse(raw);
    final initial = StageImportMappingDraft.create(
      version: 1,
      requirementsHash: hash,
      mapping: {},
    );
    expect(() => initial.withChoice(item, qid(21)), throwsFormatException);
    final chosen = initial.withImageChoice(
      item,
      uploadedId: qid(21),
      targetBookId: qid(2),
      selectedBytes: bytes,
      mediaType: 'image/png',
    );
    expect(chosen.mapping['resource_mapping'], {qid(20): qid(21)});
    expect(chosen.mapping['attachment_transfers'], {qid(21): qid(2)});
    expect(chosen.choice(item), qid(21));
    final mismatched = StageImportRequirement.parse({
      ...raw,
      'attachment_source': {
        ...(raw['attachment_source'] as Map),
        'sha256': List.filled(64, 'f').join(),
      },
    });
    expect(
      () => initial.withImageChoice(
        mismatched,
        uploadedId: qid(21),
        targetBookId: qid(2),
        selectedBytes: bytes,
        mediaType: 'image/png',
      ),
      throwsFormatException,
    );
    final replaced = chosen.withImageChoice(
      item,
      uploadedId: qid(22),
      targetBookId: qid(2),
      selectedBytes: bytes,
      mediaType: 'image/png',
    );
    expect(replaced.mapping['attachment_transfers'], {qid(22): qid(2)});
    expect((chosen.mapping['attachment_transfers'] as Map)[qid(21)], qid(2));
  });

  test('草稿仅含原资源选择，不接受金额或URL抓取参数', () {
    final draft = StageImportMappingDraft.create(
      version: 1,
      requirementsHash: hash,
      mapping: {},
    );
    expect(
      () => StageImportMappingDraft.parse({
        ...draft.body,
        'source_url': 'http://invalid',
      }),
      throwsFormatException,
    );
    expect(
      () => StageImportMappingDraft.parse({
        ...draft.body,
        'reviewed_position': 1.0,
      }),
      throwsFormatException,
    );
    expect(
      () => StageImportMappingDraft.parse({
        ...draft.body,
        'choices': {'bad': qid(1)},
      }),
      throwsFormatException,
    );
    expect(
      () => StageImportMappingDraft.parse({...draft.body, 'next_cursor': ''}),
      throwsFormatException,
    );
  });
}
