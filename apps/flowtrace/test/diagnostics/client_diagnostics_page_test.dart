import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/data/diagnostics/client_diagnostics.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/features/diagnostics/client_diagnostics_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'empty state and explicit user copy reflect actual local records',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final diagnostics = ClientDiagnostics(LocalRepository(db));
      final space = DataSpace(
        server: ServerAddress.parse('http://127.0.0.1:18080'),
        serverInstanceId: 'diagnostics-ui-fixture',
        userId: 'synthetic-user',
      );
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ClientDiagnosticsPage(
              diagnostics: diagnostics,
              space: space,
              isCurrent: () => true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('暂无本机诊断记录'), findsOneWidget);
        expect(copied, isNull);
        await diagnostics.recordQuietly(
          space,
          'sync_receipt',
          requestId: '10000000-0000-4000-8000-000000000001',
          status: 200,
        );
        await tester.tap(find.byTooltip('刷新'));
        await tester.pumpAndSettle();
        expect(find.text('已核验同步回执'), findsOneWidget);
        expect(copied, isNull);
        await tester.tap(find.text('复制脱敏诊断'));
        await tester.pumpAndSettle();
        final lines = const LineSplitter().convert(copied!);
        expect(jsonDecode(lines.first)['count'], 1);
        expect(
          jsonDecode(lines.last)['request_id'],
          '10000000-0000-4000-8000-000000000001',
        );
        expect(find.text('已复制脱敏诊断'), findsOneWidget);
        final otherSpace = DataSpace(
          server: space.server,
          serverInstanceId: space.serverInstanceId,
          userId: 'another-synthetic-user',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ClientDiagnosticsPage(
              diagnostics: diagnostics,
              space: otherSpace,
              isCurrent: () => true,
            ),
          ),
        );
        expect(find.text('已核验同步回执'), findsNothing);
        await tester.pumpAndSettle();
        expect(find.text('暂无本机诊断记录'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        await db.close();
      }
    },
  );
}
