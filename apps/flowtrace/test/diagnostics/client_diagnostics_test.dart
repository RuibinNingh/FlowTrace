import 'dart:convert';
import 'dart:io';

import 'package:flowtrace/data/diagnostics/client_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../attachments/attachment_repository_test.dart'
    show AttachmentHarness, attachmentId, scope;

void main() {
  late AttachmentHarness harness;
  late ClientDiagnostics diagnostics;
  setUp(() async {
    harness = AttachmentHarness(
      await Directory.systemTemp.createTemp('flowtrace-diagnostics-test-'),
    );
    await harness.open();
    diagnostics = ClientDiagnostics(
      harness.local,
      now: () => DateTime.utc(2026, 10, 21),
    );
  });
  tearDown(() async {
    await harness.close();
    final absolute = p.normalize(p.absolute(harness.directory.path));
    if (!p.isWithin(p.absolute(Directory.systemTemp.path), absolute) ||
        !p.basename(absolute).startsWith('flowtrace-diagnostics-test-')) {
      throw StateError('Unsafe diagnostics test directory');
    }
    await Directory(absolute).delete(recursive: true);
  });

  test(
    'only actual metadata persists across close/reopen and unknown values are omitted',
    () async {
      expect(await diagnostics.read(harness.space), isEmpty);
      expect(
        await diagnostics.recordQuietly(
          harness.space,
          'sync_receipt',
          operationId: attachmentId,
          requestId: scope,
          status: 200,
          durationMs: 15,
          code: 'password=synthetic-secret',
          category: 'https://private.invalid?token=secret',
          method: 'POST',
        ),
        isTrue,
      );
      await harness.close();
      await harness.open();
      diagnostics = ClientDiagnostics(harness.local);
      final records = await diagnostics.read(harness.space);
      expect(records, hasLength(1));
      expect(records.single['operation_id'], attachmentId);
      expect(records.single['request_id'], scope);
      expect(records.single['code'], isNull);
      expect(records.single['category'], isNull);
      expect(
        await diagnostics.exportJsonl(harness.space),
        isNot(contains('synthetic-secret')),
      );
    },
  );

  test(
    '100-record and 32KiB caps survive concurrent writes with valid JSON export',
    () async {
      await Future.wait(
        List.generate(
          130,
          (index) => diagnostics.recordQuietly(
            harness.space,
            'http_response',
            requestId: attachmentId,
            scopeId: scope,
            status: 200,
            durationMs: index,
            category: 'sync',
            method: 'POST',
          ),
        ),
      );
      final records = await diagnostics.read(harness.space);
      expect(records, hasLength(100));
      expect(records.first['duration_ms'], 30);
      final stored = (await harness.local.readSetting(
        'diagnostics.v1.${harness.space.id}.ring',
      ))!;
      expect(
        utf8.encode(stored).length,
        lessThanOrEqualTo(ClientDiagnostics.maxStoredBytes),
      );
      final exported = await diagnostics.exportJsonl(harness.space);
      expect(
        utf8.encode(exported).length,
        lessThanOrEqualTo(ClientDiagnostics.maxExportBytes),
      );
      final decoded = const LineSplitter()
          .convert(exported)
          .map(jsonDecode)
          .toList();
      expect(decoded, hasLength(101));
      expect(decoded.first['count'], 100);
    },
  );

  test(
    'export reprojects existing malicious nested text and invalid UUID/status',
    () async {
      const secret = 'synthetic-token-body-image-DO-NOT-EXPORT';
      await harness.local.writeSetting(
        'diagnostics.v1.${harness.space.id}.ring',
        jsonEncode([
          {
            'version': 1,
            'time_utc': '2026-10-21T00:00:00.000Z',
            'event': 'sync_failed',
            'operation_id': attachmentId,
            'request_id': secret,
            'status': 999,
            'duration_ms': -1,
            'code': 'hash_mismatch',
            'path': '/?token=$secret',
            'password': secret,
            'body': {'note': secret, 'image': secret},
            'access_token': secret,
          },
          {
            'version': 1,
            'time_utc': 'invalid $secret',
            'event': 'sync_receipt',
          },
        ]),
      );
      final exported = await diagnostics.exportJsonl(harness.space);
      expect(exported, isNot(contains(secret)));
      for (final forbidden in [
        'password',
        'access_token',
        'body',
        'image',
        'path',
        'request_id',
        'status',
        'duration_ms',
      ]) {
        expect(exported, isNot(contains('"$forbidden"')));
      }
      expect(await diagnostics.read(harness.space), hasLength(1));
    },
  );

  test(
    'closed database and corrupt records do not turn committed business into failure',
    () async {
      await harness.local.writeSetting('business-fixture', 'committed');
      expect(
        await diagnostics.recordQuietly(
          harness.space,
          'unknown-sensitive-text',
        ),
        isFalse,
      );
      await harness.local.writeSetting(
        'diagnostics.v1.${harness.space.id}.ring',
        'corrupt JSON',
      );
      expect(
        await diagnostics.recordQuietly(harness.space, 'sync_completed'),
        isTrue,
      );
      expect(await harness.local.readSetting('business-fixture'), 'committed');
      await harness.db.close();
      expect(
        await diagnostics.recordQuietly(harness.space, 'sync_completed'),
        isFalse,
      );
      // Reopen for common cleanup rather than pretending diagnostics is durable.
      await harness.open();
    },
  );
}
