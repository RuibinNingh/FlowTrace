import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:http/http.dart' as http;

import '../core/config/data_space.dart';
import '../core/config/server_address.dart';
import '../data/local/app_database.dart';
import '../data/local/local_repository.dart';
import '../data/ledger/ledger_repository.dart';
import '../data/preferences/preferences_controller.dart';
import '../data/attachments/attachment_repository.dart';
import '../data/attachments/attachment_transfer.dart';
import '../data/attachments/byte_store_platform.dart';
import '../data/diagnostics/client_diagnostics.dart';
import '../data/data_tools/data_tools_repository.dart';
import '../data/data_tools/stage_import_store.dart';
import '../data/receipts/receipt_read_repository.dart';
import '../data/receipts/receipt_command_repository.dart';
import '../data/sync/sync_engine.dart';
import '../data/sync/sync_store.dart';
import '../features/identity/identity_controller.dart';
import '../features/protection/protection_controller.dart';
import '../features/protection/protection_store.dart';

final class AppController extends ChangeNotifier {
  AppController(this.database, {this.identity})
    : repository = LocalRepository(database) {
    identity?.addListener(_identityChanged);
    preferences.addListener(_preferencesChanged);
    identity?.onRequestMetadata = (captured, metadata) async {
      await diagnostics.recordQuietly(
        captured,
        'http_response',
        operationId: metadata.operationId,
        requestId: metadata.requestId,
        status: metadata.status,
        durationMs: metadata.durationMs,
        category: metadata.category.name,
        method: metadata.method,
      );
    };
  }

  final AppDatabase database;
  final LocalRepository repository;
  late final preferences = PreferencesController(repository);
  late final protection = ProtectionController(
    store: LocalProtectionStore(repository),
    supported: kIsWeb || defaultTargetPlatform == TargetPlatform.windows,
    beforeLock: flushActiveDrafts,
  );

  void _preferencesChanged() {
    themeMode = preferences.value.themeMode;
    _changed();
  }

  Future<bool> flushActiveDrafts() async {
    if (dataTools.busy || stageImports.busy) return false;
    final partition = _spaceGeneration;
    final session = identity?.sessionGeneration;
    try {
      for (final participant in List.of(_updateParticipants.values)) {
        if (!await participant.prepare()) return false;
        if (_disposed ||
            partition != _spaceGeneration ||
            session != identity?.sessionGeneration) {
          return false;
        }
      }
      return !_disposed && !dataTools.busy && !stageImports.busy;
    } catch (_) {
      return false;
    }
  }

  late final ledger = LedgerRepository(repository);
  late final receiptReads = ReceiptReadRepository(repository);
  late final receiptCommands = ReceiptCommandRepository(
    reader: receiptReads,
    ledger: ledger,
  );
  final _receiptAuthority = StreamController<void>.broadcast(sync: true);
  int _receiptGeneration = 0;

  /// Captures the last confirmed offline identity without requiring transport.
  /// A retained controlled view must use receiptReads.watch with this lease.
  Future<ReceiptReadLease> captureReceiptReadLease() async {
    final owner = identity;
    final captured = space;
    final client = owner?.clientId;
    if (_disposed ||
        switchingSpace ||
        owner == null ||
        captured == null ||
        !captured.verified ||
        client == null ||
        owner.accountSpace?.id != captured.id) {
      throw StateError('Receipt identity is unavailable');
    }
    final session = owner.sessionGeneration;
    final generation = _receiptGeneration;
    final partition = _spaceGeneration;
    bool current() =>
        !_disposed &&
        !switchingSpace &&
        generation == _receiptGeneration &&
        partition == _spaceGeneration &&
        owner.sessionGeneration == session &&
        space?.id == captured.id &&
        owner.accountSpace?.id == captured.id &&
        owner.clientId == client;
    final state = await SyncStore(repository).state(captured);
    if (!current() ||
        state == null ||
        state.status != 'active' ||
        state.clientId != client ||
        (owner.serverIdentity != null &&
            owner.serverIdentity!.syncEpoch != state.epoch)) {
      throw StateError('Receipt sync identity is unavailable');
    }
    return ReceiptReadLease(
      space: captured,
      clientId: client,
      epoch: state.epoch,
      isCurrent: () =>
          current() &&
          (owner.serverIdentity == null ||
              owner.serverIdentity!.syncEpoch == state.epoch),
      invalidations: _receiptAuthority.stream,
    );
  }

  late final diagnostics = ClientDiagnostics(repository);
  late final dataTools = DataToolsRepository(repository);
  late final stageImports = StageImportStore(repository);
  late final syncEngine = SyncEngine(
    SyncStore(repository),
    diagnostics: diagnostics,
    onScopeRevoked: (space, scope) async =>
        (await attachments()).repository.revokeScope(space, scope),
    beforePush: (lease, command) async {
      if (command['entity_type'] != 'bill' || command['action'] == 'delete') {
        return;
      }
      final payload = command['payload'] as Map;
      final ids =
          (payload['attachment_ids'] as List?)?.cast<String>() ?? <String>[];
      if (ids.isEmpty) return;
      lease.check();
      final current = identity;
      if (current == null) throw StateError('Missing identity');
      final attachmentLease = AttachmentLease.capture(current);
      final transfer = await attachments();
      lease.check();
      await transfer.ensureReady(
        attachmentLease,
        command['move'] is Map
            ? (command['move'] as Map)['target_scope_id'] as String
            : command['scope_id'] as String,
        ids,
      );
      lease.check();
    },
  );

  Future<void> refreshAttachmentPermissions(
    AttachmentLease attachmentLease,
  ) async {
    attachmentLease.check();
    final current = identity;
    if (current == null) throw StateError('Missing identity');
    final captured = SyncLease.capture(current);
    if (captured.space.id != attachmentLease.space.id ||
        captured.clientId != attachmentLease.clientId ||
        captured.epoch != attachmentLease.epoch ||
        current.sessionGeneration != attachmentLease.generation) {
      throw StateError('Attachment permission lease changed');
    }
    await syncEngine.refreshScopes(
      SyncLease(
        space: captured.space,
        clientId: captured.clientId,
        epoch: captured.epoch,
        supportsGroupPull: captured.supportsGroupPull,
        request: captured.request,
        isCurrent: () => attachmentLease.isCurrent() && captured.isCurrent(),
      ),
    );
    attachmentLease.check();
  }

  Future<AttachmentTransfer>? _attachmentTransfer;
  Future<AttachmentTransfer> attachments() =>
      _attachmentTransfer ??= _openAttachments();
  Future<AttachmentTransfer> _openAttachments() async {
    try {
      return AttachmentTransfer(
        AttachmentRepository(repository, await openAttachmentBytes()),
      );
    } catch (_) {
      _attachmentTransfer = null;
      rethrow;
    }
  }

  final IdentityController? identity;
  DataSpace? space;
  List<StoredDraft> drafts = const [];
  ThemeMode themeMode = ThemeMode.dark;
  bool loading = true;
  bool checkingConnection = false;
  bool switchingSpace = false;
  String? startupError;
  String? connectionMessage;
  bool _disposed = false;
  bool preparingUpdate = false;
  int _updateGeneration = 0;
  bool _updateCallRunning = false;
  final Map<Object, ({Route<dynamic>? route, Future<bool> Function() prepare})>
  _updateParticipants = {};

  void registerUpdateParticipant(
    Object owner, {
    required Route<dynamic>? route,
    required Future<bool> Function() prepare,
  }) => _updateParticipants[owner] = (route: route, prepare: prepare);

  void unregisterUpdateParticipant(Object owner) =>
      _updateParticipants.remove(owner);

  bool get _localUpdateBusy =>
      dataTools.busy ||
      stageImports.busy ||
      preferences.saving ||
      (protection.supported &&
          (!protection.ready || protection.locked || protection.busy));

  /// Unknown dialogs and editors veto an update; only registered routes can
  /// promise that their complete input has reached durable local storage.
  Future<bool> prepareForUpdate(
    Iterable<Route<dynamic>> routes, {
    bool Function()? navigationCurrent,
  }) async {
    if (_updateCallRunning ||
        preparingUpdate ||
        _disposed ||
        loading ||
        startupError != null ||
        _localUpdateBusy ||
        switchingSpace ||
        checkingConnection ||
        identity?.busy == true ||
        syncEngine.busy) {
      return false;
    }
    final capturedRoutes = routes.toList(growable: false);
    final participants = Map.of(_updateParticipants);
    if (capturedRoutes
        .skip(1)
        .any(
          (route) => !participants.values.any(
            (participant) => identical(participant.route, route),
          ),
        )) {
      return false;
    }
    _updateCallRunning = true;
    final generation = ++_updateGeneration;
    final partition = _spaceGeneration;
    final session = identity?.sessionGeneration;
    preparingUpdate = true;
    _changed();
    bool current() =>
        !_disposed &&
        preparingUpdate &&
        generation == _updateGeneration &&
        partition == _spaceGeneration &&
        session == identity?.sessionGeneration &&
        !switchingSpace &&
        !_localUpdateBusy &&
        (navigationCurrent?.call() ?? true) &&
        identity?.busy != true &&
        !syncEngine.busy;
    var prepared = false;
    try {
      for (final participant in participants.values) {
        if (!current() || !await participant.prepare()) return false;
      }
      if (!current() ||
          participants.length != _updateParticipants.length ||
          participants.keys.any(
            (key) => !_updateParticipants.containsKey(key),
          )) {
        return false;
      }
      if (!await database.writeGate.pauseAndDrain() || !current()) return false;
      prepared = true;
      return true;
    } catch (_) {
      return false;
    } finally {
      _updateCallRunning = false;
      if (!prepared && generation == _updateGeneration) resumeAfterUpdate();
    }
  }

  void resumeAfterUpdate() {
    ++_updateGeneration;
    database.writeGate.resume();
    if (preparingUpdate) {
      preparingUpdate = false;
      _changed();
    }
  }

  int _spaceGeneration = 0;
  String? _configuredIdentityKey, _openingIdentityKey;
  bool get canSync =>
      identity?.online == true &&
      identity?.busy == false &&
      space?.id == identity?.accountSpace?.id &&
      !switchingSpace;

  Future<void> initialize() async {
    loading = true;
    startupError = null;
    _changed();
    try {
      final address =
          await repository.readSetting('active_server') ??
          'http://127.0.0.1:18080';
      space = DataSpace.provisional(ServerAddress.parse(address));
      await repository.registerSpace(space!);
      await preferences.initialize();
      await protection.initialize();
      await reloadDrafts();
      if (identity != null) unawaited(identity!.configure(space!.server));
    } catch (error) {
      startupError = '本地存储尚未就绪，草稿未被标记为已保存。请重试。';
      debugPrint('FlowTrace storage startup failed: ${error.runtimeType}');
    } finally {
      loading = false;
      _changed();
    }
  }

  Future<void> reloadDrafts() async {
    final current = space;
    if (current == null) return;
    final generation = _spaceGeneration;
    final values = await repository.drafts(current);
    if (_disposed ||
        generation != _spaceGeneration ||
        space?.id != current.id) {
      return;
    }
    drafts = _legacyDrafts(values);
    _changed();
  }

  Future<void> saveDraft(String body, {String? draftId}) async {
    final current = space;
    if (current == null) throw StateError('资料空间尚未就绪。');
    await repository.saveDraft(current, body, draftId: draftId);
    await reloadDrafts();
  }

  Future<void> deleteDraft(String id) async {
    final current = space;
    if (current == null) throw StateError('资料空间尚未就绪。');
    await repository.deleteDraft(current, id);
    await reloadDrafts();
  }

  Future<void> setServerAddress(String input) async {
    final address = ServerAddress.parse(input);
    ++_receiptGeneration;
    _receiptAuthority.add(null);
    final next = DataSpace.provisional(address);
    final nextDrafts = await database.atomicWrite(() async {
      await repository.registerSpace(next);
      final values = await repository.drafts(next);
      await repository.writeSetting('active_server', address.toString());
      return values;
    });
    space = next;
    drafts = _legacyDrafts(nextDrafts);
    connectionMessage = null;
    _changed();
    await identity?.configure(address);
  }

  void _identityChanged() {
    if (!_disposed) _receiptAuthority.add(null);
    final current = space;
    final identityServer = identity?.server;
    if (_disposed ||
        current == null ||
        identityServer == null ||
        current.server.toString() != identityServer.toString()) {
      return;
    }
    final next =
        identity!.accountSpace ?? DataSpace.provisional(identityServer);
    final client = next.verified ? identity!.clientId : null;
    final epoch = next.verified ? identity!.serverIdentity?.syncEpoch : null;
    final key = '${next.id}:$client:$epoch';
    if (_openingIdentityKey == key) return;
    if (current.id == next.id &&
        !switchingSpace &&
        _configuredIdentityKey == key) {
      _changed();
      return;
    }
    final generation = ++_spaceGeneration;
    switchingSpace = true;
    _openingIdentityKey = key;
    _changed();
    unawaited(_openIdentitySpace(next, generation, key, client, epoch));
  }

  Future<void> _openIdentitySpace(
    DataSpace next,
    int generation,
    String key,
    String? client,
    String? epoch,
  ) async {
    bool isCurrent() =>
        !_disposed &&
        generation == _spaceGeneration &&
        identity?.server.toString() == next.server.toString() &&
        (identity?.accountSpace?.id ?? DataSpace.provisional(next.server).id) ==
            next.id;
    try {
      final values = await database.atomicWrite(() async {
        await repository.registerSpace(next);
        return repository.drafts(next);
      });
      if (!isCurrent()) return;
      if (next.verified && client != null && epoch != null) {
        final store = SyncStore(repository);
        try {
          await store.configure(next, client, epoch, isCurrent: isCurrent);
        } on StateError {
          if (!isCurrent() ||
              (await store.state(next))?.status != 'recovery_required') {
            rethrow;
          }
        }
      }
      if (!isCurrent()) {
        return;
      }
      space = next;
      _configuredIdentityKey = key;
      drafts = _legacyDrafts(values);
      startupError = null;
    } catch (_) {
      if (!_disposed && generation == _spaceGeneration) {
        startupError = '账号资料空间尚未就绪，请重试；原空间资料未被搬动。';
      }
    } finally {
      if (!_disposed && generation == _spaceGeneration) {
        _openingIdentityKey = null;
        switchingSpace = false;
        _changed();
      }
    }
  }

  Future<void> setTheme(ThemeMode mode) async {
    await preferences.update(preferences.value.copyWith(themeMode: mode));
  }

  Future<void> checkConnection() async {
    final current = space;
    if (current == null || checkingConnection) return;
    checkingConnection = true;
    connectionMessage = null;
    _changed();
    try {
      final response = await http
          .get(current.server.resolve('/health/live'))
          .timeout(const Duration(seconds: 4));
      connectionMessage = response.statusCode == 200
          ? '服务器可以连接。'
          : '服务器返回 ${response.statusCode}，草稿仍保存在本机。';
    } on TimeoutException {
      connectionMessage = '连接超时，草稿仍保存在本机。';
    } catch (_) {
      connectionMessage = '暂时无法连接服务器，草稿仍保存在本机。';
    } finally {
      checkingConnection = false;
      _changed();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  List<StoredDraft> _legacyDrafts(List<StoredDraft> values) =>
      values.where((draft) {
        try {
          final value = jsonDecode(draft.body);
          return !(value is Map &&
              value['kind'] == 'ledger_draft' &&
              value['version'] == 1 &&
              value['payload'] is Map &&
              value['ui'] is Map &&
              value.containsKey('book_id'));
        } on FormatException {
          return true;
        }
      }).toList();

  @override
  void dispose() {
    resumeAfterUpdate();
    _updateParticipants.clear();
    _disposed = true;
    ++_receiptGeneration;
    _receiptAuthority.add(null);
    unawaited(_receiptAuthority.close());
    ++_spaceGeneration;
    identity?.removeListener(_identityChanged);
    identity?.dispose();
    preferences.removeListener(_preferencesChanged);
    preferences.dispose();
    protection.dispose();
    final attachmentTransfer = _attachmentTransfer;
    if (attachmentTransfer != null) {
      unawaited(
        attachmentTransfer
            .then<void>((value) => value.repository.bytes.close())
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }
}
