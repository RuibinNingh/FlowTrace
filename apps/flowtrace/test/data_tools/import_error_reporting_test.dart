import 'dart:convert';

import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/data_tools/data_tools_models.dart';
import 'package:flowtrace/data/data_tools/stage_import_mutation_models.dart';
import 'package:flowtrace/features/data_tools/import_error_labels.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../ledger/query_fixtures.dart';

void main() {
  test('parse correlation is optional, closed and validated as a UUID', () {
    final raw = <String, Object?>{
      'format': 'qianji_xlsx',
      'source_sha256': 'b' * 64,
      'document': null,
      'errors': [
        {'row': 1, 'field': null, 'code': 'unsupported_qianji_columns'},
      ],
    };
    expect(DataImportParseResult.fromJson(raw).requestId, isNull);
    expect(
      DataImportParseResult.fromJson({...raw, 'request_id': qa}).requestId,
      qa,
    );
    expect(
      () => DataImportParseResult.fromJson({
        ...raw,
        'request_id': 'private text',
      }),
      throwsFormatException,
    );
    expect(
      () => DataImportParseResult.fromJson({...raw, 'message': 'private text'}),
      throwsFormatException,
    );
  });

  test(
    'row reasons retain field and code without rendering untrusted fields',
    () {
      final missing = DataImportError.fromJson({
        'row': 106,
        'field': '关联账单',
        'code': 'qianji_reference_missing',
      });
      final label = importErrorDescription(missing);
      expect(label, contains('第106行'));
      expect(label, contains('字段：关联账单'));
      expect(label, contains('原支出不在当前文件'));
      expect(label, contains('错误码：qianji_reference_missing'));
      expect(importErrorReason('too_many_rows'), contains('完整导入'));
      expect(importErrorReason('qianji_duplicate_id'), contains('重复账单ID'));
      expect(
        importErrorReason('qianji_source_currency_mismatch'),
        contains('币种不一致'),
      );
      expect(
        importErrorReason('qianji_refund_exceeds_source'),
        contains('超过原支出'),
      );
      final unsafe = importErrorDescription(
        DataImportError.fromJson({
          'row': null,
          'field': 'https://invalid.example/private?token=secret',
          'code': 'unrecognized_safe_code',
        }),
      );
      expect(unsafe, contains('unrecognized_safe_code'));
      expect(unsafe, isNot(contains('token')));
    },
  );

  test('stage row correlation is opt-in compatible with old receipts', () {
    final raw = <String, Object?>{
      'stage_id': qa,
      'stage_version': 1,
      'rows': [],
      'has_more': false,
      'next_cursor': null,
    };
    expect(StageImportRowsPage.parse(raw).requestId, isNull);
    expect(StageImportRowsPage.parse({...raw, 'request_id': qb}).requestId, qb);
    expect(
      () => StageImportRowsPage.parse({...raw, 'request_id': 'private text'}),
      throwsFormatException,
    );
  });

  test(
    'transport keeps safe error correlation and a data-tools category',
    () async {
      final observed = <ApiRequestMetadata>[];
      final api = ApiClient(
        MockClient(
          (request) async => http.Response(
            jsonEncode({
              'error': {
                'code': 'validation_error',
                'message': 'private response body must not be rendered',
                'request_id': qa,
                'details': {'password': 'private password'},
              },
            }),
            422,
            headers: {'X-Request-ID': qa, 'Content-Type': 'application/json'},
          ),
        ),
      );
      addTearDown(api.close);
      try {
        await api.request(
          ServerAddress.parse('https://flowtrace.example.test'),
          'POST',
          '/data-tools/imports/parse',
          body: {'private': 'source data must not be logged'},
          onMetadata: observed.add,
        );
        fail('expected validation failure');
      } on ApiFailure catch (error) {
        expect(error.requestId, qa);
        final label = importFailureDescription(error);
        expect(label, contains('错误码：validation_error'));
        expect(label, contains('请求ID：$qa'));
        expect(label, isNot(contains('private')));
        expect(error.toString(), 'ApiFailure(validation_error)');
      }
      expect(observed.single.category, ApiCategory.dataTools);
      expect(observed.single.requestId, qa);
      expect(
        ApiFailure.server(
          'validation_error',
          422,
          requestId: 'private password',
        ).requestId,
        isNull,
      );
    },
  );
}
