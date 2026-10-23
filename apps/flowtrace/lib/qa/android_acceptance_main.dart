// Dedicated local-only Android acceptance entry. Never opens the normal app DB,
// credentials or network. Build with an explicit, fresh QA_ANDROID_RUN UUID.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../app/app_theme.dart';
import '../core/config/data_space.dart';
import '../core/config/server_address.dart';
import '../data/attachments/attachment_repository.dart';
import '../data/attachments/byte_store_native.dart';
import '../data/ledger/ledger_repository.dart';
import '../data/local/app_database.dart';
import '../data/local/local_repository.dart';
import '../data/sync/sync_store.dart';
import '../features/attachments/attachment_panel.dart';
import '../features/attachments/image_attachment_selector.dart';

const run = String.fromEnvironment('QA_ANDROID_RUN');
const _uuid = Uuid();
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFElEQVR4nGPUaXnNAAZMEIqBgQEAHGMBn0OjIGsAAAAASUVORK5CYII=';

String _sha(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
Map<String, Object?> _map(Object? value) =>
    (value as Map).cast<String, Object?>();
Map<String, Object?> _money(String minor) => {
  'currency': 'CNY',
  'currency_scale': 2,
  'amount_minor': minor,
};
void _require(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

/// Drift's native executor starts ordinary transactions with BEGIN IMMEDIATE.
/// A genuine query_only connection rejects that lock intent. This QA-only
/// adapter keeps the production projection readers unchanged, but wraps their
/// complete read snapshot in SQLite's deferred, read-only transaction instead.
/// All attempted writes still fail at the SQLite query_only boundary.
final class _QueryOnlyDatabase extends AppDatabase {
  _QueryOnlyDatabase(File file)
    : super(
        NativeDatabase(
          file,
          enableMigrations: false,
          setup: (sqlite) => sqlite.execute('PRAGMA query_only = ON'),
        ),
      );

  final _readZone = Object();
  bool _reading = false;

  @override
  Future<T> readSnapshot<T>(Future<T> Function() action) async {
    if (Zone.current[_readZone] == true) return action();
    _require(!_reading, 'concurrent_qa_read_snapshot');
    _reading = true;
    var began = false;
    try {
      await customStatement('BEGIN DEFERRED');
      began = true;
      final result = await runZoned(action, zoneValues: {_readZone: true});
      await customStatement('COMMIT');
      began = false;
      return result;
    } finally {
      if (began) await customStatement('ROLLBACK');
      _reading = false;
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: AndroidAcceptancePage()));
}

class AndroidAcceptancePage extends StatefulWidget {
  const AndroidAcceptancePage({super.key});
  @override
  State<AndroidAcceptancePage> createState() => _AndroidAcceptancePageState();
}

class _AndroidAcceptancePageState extends State<AndroidAcceptancePage> {
  AppDatabase? _database;
  late LocalRepository _local;
  late LedgerRepository _ledger;
  late NativeAttachmentBytes _bytes;
  late AttachmentRepository _attachments;
  late Directory _directory;
  late Map<String, Object?> _manifest;
  late DataSpace _space;
  List<String> _ids = [];
  String _status = '正在读取本轮独立资料';
  String? _error;
  bool _loaded = false, _busy = true, _readOnly = false;
  Map<String, Object?>? _selectedBaseline;
  String get _book => _manifest['book_id'] as String;
  String get _account => _manifest['account_id'] as String;
  String get _draft => _manifest['draft_id'] as String;
  String get _epoch => _manifest['epoch'] as String;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<Map<String, Object?>> _read(String name) async => _map(
    jsonDecode(await File(p.join(_directory.path, name)).readAsString()),
  );
  Future<void> _write(String name, Map<String, Object?> data) async {
    final file = File(p.join(_directory.path, name));
    // A receipt is never silently replaced by a second action.
    _require(!await file.exists(), 'receipt_already_exists:$name');
    await file.create(exclusive: true);
    await file.writeAsString(jsonEncode(data), flush: true);
  }

  Future<void> _open() async {
    try {
      _require(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(run),
        'explicit_fresh_v4_run_required',
      );
      final support = await getApplicationSupportDirectory();
      _directory = Directory(
        p.join(support.path, 'flowtrace-qa', 'android-$run'),
      );
      final manifest = File(p.join(_directory.path, 'manifest.json'));
      final fresh = !await _directory.exists();
      if (fresh) {
        await _directory.create(recursive: true);
        _manifest = {
          'version': 1,
          'run_id': run,
          'local_only': true,
          'instance_id': _uuid.v4(),
          'user_id': _uuid.v4(),
          'book_id': _uuid.v4(),
          'account_id': _uuid.v4(),
          'bill_id': _uuid.v4(),
          'draft_id': _uuid.v4(),
          'client_id': _uuid.v4(),
          'epoch': _uuid.v4(),
          'png_sha256': sha256.convert(base64Decode(_png)).toString(),
          'opening_minor': '10000',
          'expense_minor': '125',
          'expected_balance_minor': '9875',
        };
        await _write('manifest.json', _manifest);
      } else {
        _require(
          await manifest.exists(),
          'existing_directory_without_manifest',
        );
        _manifest = await _read('manifest.json');
        _require(
          _manifest['run_id'] == run && _manifest['local_only'] == true,
          'manifest_mismatch',
        );
        _require(
          await File(p.join(_directory.path, 'seeded.json')).exists(),
          'incomplete_seed_preserved_no_reseed',
        );
      }
      _space = DataSpace(
        server: ServerAddress.parse('http://127.0.0.1:18099'),
        serverInstanceId: _manifest['instance_id'] as String,
        userId: _manifest['user_id'] as String,
      );
      _readOnly = await File(p.join(_directory.path, 'ready.json')).exists();
      final dbFile = File(p.join(_directory.path, 'acceptance.sqlite'));
      if (!fresh) _require(await dbFile.exists(), 'database_missing_no_reseed');
      final db = _readOnly
          ? _QueryOnlyDatabase(dbFile)
          : AppDatabase(NativeDatabase(dbFile));
      _database = db;
      _local = LocalRepository(db);
      _ledger = LedgerRepository(_local);
      _bytes = NativeAttachmentBytes(
        Directory(p.join(_directory.path, 'originals')),
      );
      _attachments = AttachmentRepository(_local, _bytes);
      if (fresh) {
        await _seed();
        await _write('seeded.json', {
          'run_id': run,
          'pid': pid,
          'snapshot': await _snapshot(),
        });
      }
      final draft = await _ledger.readDraft(_space, _draft);
      _require(draft != null, 'draft_missing');
      _ids = (draft!.payload['attachment_ids'] as List).cast<String>();
      if (_readOnly) {
        final mode = await db.customSelect('PRAGMA query_only').getSingle();
        _require(mode.read<int>('query_only') == 1, 'database_not_query_only');
        final ready = await _read('ready.json');
        final recheck = await File(
          p.join(_directory.path, 'ready-recheck.json'),
        ).exists();
        final attemptReady = recheck
            ? await _read('ready-recheck.json')
            : ready;
        _require(
          attemptReady['snapshot_sha256'] == ready['snapshot_sha256'],
          'recheck_changed_original_snapshot',
        );
        final current = await _snapshot();
        _require(
          _sha(current) == ready['snapshot_sha256'],
          'reopen_snapshot_changed',
        );
        _require(attemptReady['pid'] != pid, 'new_process_required');
        await _write(recheck ? 'reopened-recheck.json' : 'reopened.json', {
          'run_id': run,
          'status': 'passed',
          'old_pid': attemptReady['pid'],
          'original_ready_pid': ready['pid'],
          'pid': pid,
          'attempt': recheck ? 2 : 1,
          'qa_read_adapter_repaired_before_this_attempt': !recheck,
          'query_only': true,
          'snapshot_sha256': _sha(current),
          'balance_minor': '9875',
          'attachment_count': _ids.length,
          'network_tested': false,
          'reseeded': false,
        });
        _status = recheck
            ? 'REOPEN_RECHECK_PASSED · 同包终止后只读恢复通过 · 余额 98.75'
            : 'REOPEN_PASSED · QA修复包只读恢复通过 · 余额 98.75';
      } else {
        _status = 'PICKER_READY · 仅本轮合成资料';
      }
      if (mounted) {
        setState(() {
          _loaded = true;
          _busy = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _busy = false;
        });
      }
    }
  }

  Future<void> _seed() async {
    await _local.registerSpace(_space);
    await SyncStore(
      _local,
    ).configure(_space, _manifest['client_id'] as String, _epoch);
    await _ledger.save(
      _space,
      entityType: 'book',
      scopeId: _space.userId,
      entityId: _book,
      payload: {
        'name': 'Android合成验收',
        'currency': 'CNY',
        'timezone': 'Asia/Shanghai',
        'month_start_day': 1,
      },
    );
    await _ledger.save(
      _space,
      entityType: 'account',
      scopeId: _space.userId,
      entityId: _account,
      payload: {
        'name': '独立合成现金',
        'kind': 'cash',
        'opening': _money('10000'),
        'include_in_net_assets': true,
        'hidden': false,
      },
    );
    await _ledger.save(
      _space,
      entityType: 'bill',
      scopeId: _book,
      entityId: _manifest['bill_id'] as String,
      payload: {
        'bill_type': 'expense',
        'money': _money('125'),
        'book_id': _book,
        'account_id': _account,
        'business_date': '2026-10-22',
        'business_timezone': 'Asia/Shanghai',
        'note': 'Android force-stop 合成正式意图',
      },
    );
    final frozen = await SyncStore(_local).nextPush(_space);
    _require(frozen != null, 'no_frozen_operation');
    await _persistDraft(const []);
  }

  Future<void> _persistDraft(List<String> ids) => _ledger
      .saveDraft(
        _space,
        bookId: _book,
        draftId: _draft,
        payload: {
          'bill_type': 'expense',
          'book_id': _book,
          'account_id': _account,
          'business_date': '2026-10-22',
          'business_timezone': 'Asia/Shanghai',
          'note': '未完成的合成草稿，禁止重播种',
          'attachment_ids': ids,
        },
        ui: {'expression': '12+', 'currency': 'CNY', 'currency_scale': 2},
      )
      .then((_) {});

  Future<Map<String, Object?>> _snapshot() =>
      _database!.readSnapshot(_snapshotRows);

  Future<Map<String, Object?>> _snapshotRows() async {
    final db = _database!;
    final state = await SyncStore(_local).state(_space);
    _require(
      state != null &&
          state.epoch == _epoch &&
          state.clientId == _manifest['client_id'] &&
          state.status == 'active',
      'persisted_sync_identity_missing_or_changed',
    );
    final view = await _ledger.read(_space);
    final balance = view.balances[_account]?.value?.minor.toString();
    _require(balance == '9875', 'balance_expected_9875_actual_$balance');
    final entities = await (db.select(db.localEntities)).get();
    entities.sort((a, b) => a.entityId.compareTo(b.entityId));
    final ops = await _local.pending(_space);
    _require(
      ops.length == 3 &&
          ops.where((o) => o.frozenRequestJson != null).length == 1,
      'expected_three_intents_one_frozen',
    );
    final draft = (await _local.drafts(_space)).single;
    final attachments = await _attachments.list(_space);
    final originals = <Map<String, Object?>>[];
    for (final item in attachments) {
      final original = await _attachments.original(_space, item);
      final dimensions = await validateAttachmentPixels(original);
      _require(
        sha256.convert(original).toString() == _manifest['png_sha256'],
        'original_checksum',
      );
      _require(dimensions == (3, 2), 'original_dimensions');
      originals.add({
        'record': item.toJson(),
        'sha256': sha256.convert(original).toString(),
        'width': dimensions.$1,
        'height': dimensions.$2,
      });
    }
    return {
      'space_id': _space.id,
      'epoch': _epoch,
      'sync_state': {
        'client_id': state!.clientId,
        'epoch': state.epoch,
        'status': state.status,
        'cursors_json': state.cursorsJson,
        'revoked_scopes_json': state.revokedScopesJson,
      },
      'balance_minor': balance,
      'entities': [
        for (final e in entities)
          {
            'entity_id': e.entityId,
            'type': e.entityType,
            'scope_id': e.scopeId,
            'data_json': e.dataJson,
            'revision': e.serverRevision,
            'deleted': e.deleted,
          },
      ],
      'operations': [
        for (final o in ops)
          {
            'operation_id': o.operationId,
            'entity_id': o.entityId,
            'operation_json': o.operationJson,
            'frozen_request_json': o.frozenRequestJson,
            'state': o.state,
            'attempt_count': o.attemptCount,
            'sequence': o.sequence,
          },
      ],
      'draft_id': draft.id,
      'draft_body': draft.body,
      'attachments': originals,
    };
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy || _readOnly) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      _error = '$error';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _verifySelected() => _action(() async {
    _require(_ids.length == 1, 'pick_exactly_one_synthetic_png');
    final snapshot = await _snapshot();
    _require(
      (snapshot['attachments'] as List).length == 1,
      'one_original_required',
    );
    _selectedBaseline = snapshot;
    await _write('picker-selected.json', {
      'run_id': run,
      'status': 'passed',
      'pid': pid,
      'snapshot_sha256': _sha(snapshot),
      'snapshot': snapshot,
      'real_picker_evidence_required': true,
    });
    _status = 'PICK_SELECTED_PASSED · 原件与完整草稿一致';
  });

  Future<void> _unchanged(String name) => _action(() async {
    final selected =
        _selectedBaseline ??
        _map((await _read('picker-selected.json'))['snapshot']);
    final current = await _snapshot();
    _require(_sha(current) == _sha(selected), 'selection_changed_after_$name');
    await _write('$name.json', {
      'run_id': run,
      'status': 'passed',
      'pid': pid,
      'snapshot_sha256': _sha(current),
      'attachment_count': _ids.length,
      'host_ui_evidence_required': true,
    });
    _status = '$name PASSED · 草稿、原件和待传意图未变化';
  });

  Future<void> _ready() => _action(() async {
    for (final receipt in [
      'picker-selected.json',
      'picker-cancelled.json',
      'picker-oversized.json',
    ]) {
      _require(
        (await _read(receipt))['status'] == 'passed',
        'missing_passed_$receipt',
      );
    }
    final snapshot = await _snapshot();
    _require(_ids.length == 1, 'one_reference_required');
    await _write('ready.json', {
      'run_id': run,
      'status': 'READY',
      'pid': pid,
      'snapshot_sha256': _sha(snapshot),
      'snapshot': snapshot,
      'network_tested': false,
    });
    _status = 'READY · 可执行本包 OS force-stop';
    _readOnly = true;
  });

  Future<void> _prepareRecheck() async {
    if (_busy || !_loaded || !_readOnly) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final mode = await _database!
          .customSelect('PRAGMA query_only')
          .getSingle();
      _require(mode.read<int>('query_only') == 1, 'database_not_query_only');
      final original = await _read('ready.json');
      final current = await _snapshot();
      _require(
        _sha(current) == original['snapshot_sha256'],
        'recheck_changed_original_snapshot',
      );
      await _write('ready-recheck.json', {
        'run_id': run,
        'status': 'READY_RECHECK',
        'pid': pid,
        'original_ready_pid': original['pid'],
        'query_only': true,
        'snapshot_sha256': _sha(current),
        'snapshot': current,
        'database_mutated': false,
        'network_tested': false,
      });
      _status = 'READY_RECHECK · 同一修复包可执行第二次 OS force-stop';
    } catch (error) {
      _error = '$error';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: AppTheme.light(),
    child: Scaffold(
      appBar: AppBar(title: const Text('流迹 Android 隔离验收')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('run: $run'),
            const SizedBox(height: 8),
            Text(_status),
            const Text('仅本机合成库 · 未联网 · 现金 98.75 · 草稿 12+'),
            if (_error != null)
              Text(
                'FAILED: $_error',
                style: const TextStyle(color: Colors.red),
              ),
            if (_loaded) ...[
              const SizedBox(height: 16),
              AttachmentPanel(
                repository: _attachments,
                space: _space,
                epoch: _epoch,
                scopeId: _book,
                attachmentIds: _ids,
                readOnly: _readOnly,
                isCurrent: () => mounted,
                onBusyChanged: (value) {
                  if (mounted) setState(() => _busy = value);
                },
                onChanged: (ids) async {
                  await _persistDraft(ids);
                  if (mounted) setState(() => _ids = ids);
                },
              ),
              const SizedBox(height: 12),
              if (!_readOnly) ...[
                FilledButton(
                  onPressed: _busy ? null : _verifySelected,
                  child: const Text('核验选图'),
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _unchanged('picker-cancelled'),
                  child: const Text('核验取消'),
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _unchanged('picker-oversized'),
                  child: const Text('核验超限'),
                ),
                FilledButton(
                  onPressed: _busy ? null : _ready,
                  child: const Text('写入终止前 READY'),
                ),
              ],
              if (_readOnly && _status.startsWith('REOPEN_PASSED'))
                FilledButton(
                  onPressed: _busy ? null : _prepareRecheck,
                  child: const Text('写入只读复验 READY'),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}
