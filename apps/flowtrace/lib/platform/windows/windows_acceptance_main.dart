// Explicit standalone QA target. The ordinary main never imports this file.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../../core/config/server_address.dart';
import '../../core/security/platform_vault.dart';
import '../../data/attachments/attachment_repository.dart';
import '../../data/attachments/byte_store_platform.dart';
import '../../data/local/app_database.dart';
import '../../data/local/local_repository.dart';
import '../../data/ledger/ledger_repository.dart';
import '../../data/sync/sync_store.dart';
import 'windows_runtime.dart';

const _run = String.fromEnvironment('QA_WINDOWS_RUN');
const _build = String.fromEnvironment('QA_WINDOWS_BUILD', defaultValue: 'one');
const _uuid = Uuid();
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFElEQVR4nGPUaXnNAAZMEIqBgQEAHGMBn0OjIGsAAAAASUVORK5CYII=';

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String _sha(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
Map<String, Object?> _object(Object? value) =>
    (value as Map).cast<String, Object?>();
Map<String, Object?> _money(String value) => {
  'currency': 'CNY',
  'currency_scale': 2,
  'amount_minor': value,
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: WindowsAcceptancePage()));
}

class WindowsAcceptancePage extends StatefulWidget {
  const WindowsAcceptancePage({super.key});
  @override
  State<WindowsAcceptancePage> createState() => _WindowsAcceptancePageState();
}

class _WindowsAcceptancePageState extends State<WindowsAcceptancePage> {
  String _message = 'Windows 隔离验收正在启动';
  final _repaint = GlobalKey();
  @override
  void initState() {
    super.initState();
    _runChecks();
  }

  Future<void> _runChecks() async {
    Directory? directory;
    AppDatabase? database;
    try {
      _check(
        RegExp(r'^[0-9a-f-]{36}$').hasMatch(_run),
        'explicit_run_required',
      );
      directory = await WindowsRuntime.dataDirectory();
      _check(
        p.basename(directory.path) == 'data-$_run',
        'explicit_isolated_directory_required',
      );
      final manifestFile = File(p.join(directory.path, 'qa-manifest.json'));
      final readyFile = File(p.join(directory.path, 'qa-ready.json'));
      final fresh = !await manifestFile.exists();
      final manifest = fresh
          ? <String, Object?>{
              'run': _run,
              'instance': _uuid.v4(),
              'user': _uuid.v4(),
              'book': _uuid.v4(),
              'account': _uuid.v4(),
              'bill': _uuid.v4(),
              'draft': _uuid.v4(),
              'client': _uuid.v4(),
              'epoch': _uuid.v4(),
              'attachment': _uuid.v4(),
            }
          : _object(jsonDecode(await manifestFile.readAsString()));
      _check(manifest['run'] == _run, 'manifest_run_mismatch');
      if (fresh) {
        await manifestFile.create(exclusive: true);
        await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
      } else {
        _check(
          await readyFile.exists(),
          'incomplete_fixture_preserved_no_reseed',
        );
        _check(
          await File(p.join(directory.path, 'flowtrace.sqlite')).exists(),
          'database_missing_no_reseed',
        );
      }
      database = AppDatabase();
      final local = LocalRepository(database);
      final ledger = LedgerRepository(local);
      final store = SyncStore(local);
      final bytes = await openAttachmentBytes();
      final attachments = AttachmentRepository(local, bytes);
      final space = DataSpace(
        server: ServerAddress.parse('http://127.0.0.1:18099'),
        serverInstanceId: manifest['instance'] as String,
        userId: manifest['user'] as String,
      );
      final book = manifest['book'] as String;
      final account = manifest['account'] as String;
      if (fresh) {
        await local.registerSpace(space);
        await store.configure(
          space,
          manifest['client'] as String,
          manifest['epoch'] as String,
        );
        await ledger.save(
          space,
          entityType: 'book',
          scopeId: space.userId,
          entityId: book,
          payload: {
            'name': 'Windows隔离账本',
            'currency': 'CNY',
            'timezone': 'Asia/Shanghai',
            'month_start_day': 1,
          },
        );
        await ledger.save(
          space,
          entityType: 'account',
          scopeId: space.userId,
          entityId: account,
          payload: {
            'name': 'Windows合成现金',
            'kind': 'cash',
            'opening': _money('9007199254740993'),
            'include_in_net_assets': true,
            'hidden': false,
          },
        );
        final attachment = await attachments.stage(
          space,
          manifest['epoch'] as String,
          book,
          base64Decode(_png),
          mediaType: 'image/png',
          attachmentId: manifest['attachment'] as String,
        );
        await ledger.save(
          space,
          entityType: 'bill',
          scopeId: book,
          entityId: manifest['bill'] as String,
          payload: {
            'bill_type': 'expense',
            'money': _money('125'),
            'book_id': book,
            'account_id': account,
            'business_date': '2026-10-22',
            'business_timezone': 'Asia/Shanghai',
            'note': 'Windows offline exact integer',
            'attachment_ids': [attachment.id],
          },
        );
        await ledger.saveDraft(
          space,
          bookId: book,
          draftId: manifest['draft'] as String,
          payload: {
            'bill_type': 'expense',
            'book_id': book,
            'account_id': account,
            'note': '未完成 Windows 草稿',
            'attachment_ids': [attachment.id],
          },
          ui: {'expression': '12+', 'currency': 'CNY', 'currency_scale': 2},
        );
        _check(await store.nextPush(space) != null, 'frozen_body_missing');
        await local.writeSetting('qa.windows.setting', 'preserved-$_run');
      }
      final snapshot = await database.readSnapshot(() async {
        final view = await ledger.read(space);
        _check(
          view.balances[account]?.value?.minor.toString() == '9007199254740868',
          'exact_64bit_balance_changed',
        );
        final queued = await local.pending(space);
        _check(queued.length == 3, 'outbox_count_changed');
        _check(
          queued.where((row) => row.frozenRequestJson != null).length == 1,
          'frozen_count_changed',
        );
        final draft = await ledger.readDraft(
          space,
          manifest['draft'] as String,
        );
        _check(draft?.ui['expression'] == '12+', 'complete_draft_changed');
        final images = await attachments.list(space);
        _check(images.length == 1, 'attachment_count_changed');
        final original = await attachments.original(space, images.single);
        _check(
          sha256.convert(original).toString() ==
              sha256.convert(base64Decode(_png)).toString(),
          'attachment_checksum_changed',
        );
        return <String, Object?>{
          'balance': view.balances[account]?.value?.minor.toString(),
          'outbox': [
            for (final row in queued)
              {
                'id': row.operationId,
                'body': row.operationJson,
                'frozen': row.frozenRequestJson,
              },
          ],
          'draft': draft?.payload,
          'ui': draft?.ui,
          'attachment': images.single.toJson(),
          'sha256': sha256.convert(original).toString(),
          'setting': await local.readSetting('qa.windows.setting'),
        };
      });
      final snapshotSha = _sha(snapshot);
      final vault = createSessionVault();
      final vaultKey = 'flowtrace.qa.windows.$_run';
      if (fresh) await vault.write(vaultKey, 'synthetic-only-$_run');
      _check(
        await vault.read(vaultKey) == 'synthetic-only-$_run',
        'secure_storage_reopen_failed',
      );
      if (_build == 'two') {
        await vault.delete(vaultKey);
        _check(
          await vault.read(vaultKey) == null,
          'synthetic_key_cleanup_failed',
        );
      }
      final failures = fresh ? await _storageFailures(directory) : null;
      final receipt = <String, Object?>{
        'status': 'passed',
        'run': _run,
        'build': _build,
        'pid': pid,
        'fresh': fresh,
        'snapshot_sha256': snapshotSha,
        'snapshot': snapshot,
        'storage_failures': failures,
        'vault_synthetic_key_reopened': true,
        'own_synthetic_vault_key_deleted': _build == 'two',
        'network_tested': false,
        'system_reboot_tested': false,
      };
      if (fresh) {
        await readyFile.create(exclusive: true);
        await readyFile.writeAsString(jsonEncode(receipt), flush: true);
      } else {
        final before = _object(jsonDecode(await readyFile.readAsString()));
        _check(
          before['snapshot_sha256'] == snapshotSha,
          'reopen_changed_original_snapshot',
        );
        _check(before['pid'] != pid, 'different_process_required');
        final output = File(
          p.join(directory.path, 'qa-reopened-$_build-$pid.json'),
        );
        await output.create(exclusive: true);
        await output.writeAsString(jsonEncode(receipt), flush: true);
      }
      await bytes.close();
      await database.close();
      database = null;
      if (mounted) {
        setState(
          () => _message =
              '${fresh ? 'WINDOWS_READY' : 'WINDOWS_REOPENED'} · $_build\n账单 / 原件 / 完整草稿 / 冻结 outbox / 精确大整数 / 受控凭据均通过',
        );
        await WidgetsBinding.instance.endOfFrame;
        final boundary =
            _repaint.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          p.join(directory.path, 'qa-frame-$_build-$pid.png'),
        ).writeAsBytes(png!.buffer.asUint8List(), flush: true);
        image.dispose();
      }
    } catch (error, stack) {
      final failure = {
        'status': 'failed',
        'run': _run,
        'build': _build,
        'pid': pid,
        'error': '$error',
        'stack': '$stack',
      };
      if (directory != null) {
        await File(
          p.join(directory.path, 'qa-failed-$_build-$pid.json'),
        ).writeAsString(jsonEncode(failure), flush: true);
      }
      if (mounted) setState(() => _message = 'WINDOWS_FAILED\n$error');
    } finally {
      await database?.close();
    }
  }

  Future<Map<String, Object?>> _storageFailures(Directory directory) async {
    final file = File(p.join(directory.path, 'failure-probe.sqlite'));
    _check(!await file.exists(), 'failure_probe_not_fresh');
    final probe = AppDatabase(NativeDatabase(file));
    final repository = LocalRepository(probe);
    await repository.writeSetting('baseline', 'retained');
    await probe.customStatement('PRAGMA busy_timeout=80');
    final locker = sqlite.sqlite3.open(file.path);
    int? lockedCode, fullCode;
    try {
      locker.execute('BEGIN EXCLUSIVE');
      try {
        await repository.writeSetting('locked', 'must-not-succeed');
      } on sqlite.SqliteException catch (error) {
        lockedCode = error.resultCode;
      } finally {
        locker.execute('ROLLBACK');
      }
      _check(lockedCode == 5 || lockedCode == 6, 'actual_lock_error_required');
      _check(
        await repository.readSetting('locked') == null,
        'locked_write_was_reported_saved',
      );
      final pages =
          (await probe.customSelect('PRAGMA page_count').getSingle())
                  .data
                  .values
                  .single
              as int;
      await probe.customStatement('PRAGMA max_page_count=$pages');
      try {
        await repository.writeSetting('full', 'x' * (5 * 1024 * 1024));
      } on sqlite.SqliteException catch (error) {
        fullCode = error.resultCode;
      }
      _check(fullCode == 13, 'actual_sqlite_full_required');
      _check(
        await repository.readSetting('full') == null,
        'full_write_was_reported_saved',
      );
      _check(
        await repository.readSetting('baseline') == 'retained',
        'failed_write_lost_baseline',
      );
    } finally {
      locker.close();
      await probe.close();
    }
    return {
      'lock_result_code': lockedCode,
      'full_result_code': fullCode,
      'both_writes_rejected': true,
      'baseline_retained': true,
      'disk_quota_injection': 'SQLite max_page_count; host disk not filled',
    };
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: _repaint,
    child: Scaffold(
      appBar: AppBar(title: const Text('流迹 Windows 隔离验收')),
      body: Center(child: SelectableText(_message)),
    ),
  );
}
