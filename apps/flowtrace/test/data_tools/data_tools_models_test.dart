import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart';

Map<String, Object?> documentJson({String amount = '9007199254740993'}) => {
  'format': 'flowtrace-data-v1',
  'source_namespace': 'synthetic',
  'rows': [
    {
      'source_id': qa,
      'scope_id': qBook,
      'entity_type': 'bill',
      'payload': {
        'bill_type': 'expense',
        'money': qmoney(amount),
        'business_date': '2026-10-22',
        'business_timezone': 'Asia/Shanghai',
        'note': '合成备注',
      },
    },
  ],
};

void main() {
  test('original image manifest is closed and matches document references', () {
    final source = documentJson();
    (((source['rows'] as List).single as Map)['payload']
        as Map)['attachment_ids'] = [
      qd,
    ];
    final manifest = {
      'source_id': qd,
      'sha256': 'a' * 64,
      'size_bytes': 77,
      'media_type': 'image/png',
    };
    final result = {
      'format': 'flowtrace_json',
      'source_sha256': 'b' * 64,
      'document': source,
      'errors': [],
      'attachment_sources': [manifest],
    };
    expect(
      DataImportParseResult.fromJson(result).attachmentSources.single.sizeBytes,
      77,
    );
    expect(
      () => DataImportParseResult.fromJson({
        ...result,
        'attachment_sources': [manifest, manifest],
      }),
      throwsFormatException,
    );
    expect(
      () => DataAttachmentSource.fromJson({
        ...manifest,
        'url': 'https://invalid/never-fetch',
      }),
      throwsFormatException,
    );
    expect(
      () => DataAttachmentSource.fromJson({...manifest, 'size_bytes': true}),
      throwsFormatException,
    );
  });
  test('money remains a string and callers cannot mutate stored payload', () {
    final source = documentJson();
    final document = DataImportDocument.fromJson(source);
    ((source['rows'] as List).first as Map)['payload']['note'] =
        'external mutation';
    final copy = document.rows.first.payload;
    copy['note'] = 'second external mutation';
    expect(document.rows.first.payload['note'], '合成备注');
    expect(
      (document.rows.first.payload['money'] as Map)['amount_minor'],
      '9007199254740993',
    );
    expect(
      document.rows.first.payload.containsKey('reimbursement_tracking'),
      isFalse,
    );
    expect(
      () => dataToolsFrozenJson({'amount_minor': 1.25}),
      throwsFormatException,
    );
  });

  test('historical signed posting validates magnitude and source kind', () {
    final source = documentJson(amount: '125');
    final row = (source['rows'] as List).first as Map;
    final payload = row['payload'] as Map;
    payload.addAll(<String, Object>{
      'bill_type': 'balance_adjustment',
      'account_id': qCash,
      'target_balance_minor': '10000',
    });
    source['posting_hints'] = {
      qa: {'signed_principal_minor': '-125'},
    };
    expect(
      DataImportDocument.fromJson(source).postingHints,
      source['posting_hints'],
    );
    source['posting_hints'] = {
      qa: {'signed_principal_minor': '-124'},
    };
    expect(() => DataImportDocument.fromJson(source), throwsFormatException);
  });

  test('mapping requirements and operation-only history remain closed', () {
    final requirement = DataMappingRequirement.fromJson({
      'kind': 'account',
      'source_value': '合成现金',
      'rows': [2, 3],
    });
    expect(requirement.rows, [2, 3]);
    expect(
      () => DataMappingRequirement.fromJson({
        'kind': 'account',
        'source_value': '现金',
        'rows': [1],
      }),
      throwsFormatException,
    );
    final history = {
      'batch_id': qa,
      'status': 'undone',
      'source_namespace': 'synthetic',
      'created_at': '2026-10-22T10:00:00+00:00',
      'created_count': 3,
      'duplicate_count': 0,
    };
    expect(DataImportHistoryItem.fromJson(history).status, 'undone');
    expect(
      () => DataImportHistoryItem.fromJson({...history, 'payload': {}}),
      throwsFormatException,
    );
  });
}
