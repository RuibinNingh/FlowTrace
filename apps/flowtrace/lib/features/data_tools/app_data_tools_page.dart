import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/money/currency_catalog.dart';
import '../../core/network/api_failure.dart';
import '../../data/attachments/attachment_transfer.dart';
import '../../data/assets/asset_config_repository.dart';
import '../../data/assets/asset_config_store.dart';
import '../../data/data_tools/data_tools_models.dart';
import '../../data/data_tools/data_tools_repository.dart';
import '../../data/data_tools/local_refresh.dart';
import '../../data/data_tools/stage_import_lease.dart';
import '../../data/sync/sync_engine.dart';
import '../../domain/assets/asset_config.dart';
import 'data_tools_page.dart';

/// Ordinary app wiring. Remote receipts do not fabricate local ledger entities;
/// the normal authorized snapshot/pull materializes confirmed business data.
class AppDataToolsPage extends StatefulWidget {
  const AppDataToolsPage({required this.app, super.key});
  final AppController app;
  @override
  State<AppDataToolsPage> createState() => _AppDataToolsPageState();
}

class _AppDataToolsPageState extends State<AppDataToolsPage> {
  final _page = GlobalKey<DataToolsPageState>();
  AppController get app => widget.app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    app.registerUpdateParticipant(
      this,
      route: ModalRoute.of(context),
      prepare: () async => await _page.currentState?.prepareForUpdate() ?? true,
    );
  }

  @override
  void dispose() {
    app.unregisterUpdateParticipant(this);
    super.dispose();
  }

  String? _authorityKey() {
    final owner = app.identity;
    if (!app.canSync || owner == null) return null;
    return '${app.space!.id}:${owner.serverIdentity?.syncEpoch}:'
        '${owner.clientId}:${owner.sessionGeneration}';
  }

  DataToolsLease _capture() {
    final owner = app.identity;
    if (!app.canSync || owner == null || app.preparingUpdate) {
      throw const ApiFailure('identity_changed', '请先联网登录当前资料空间。');
    }
    final captured = DataToolsLease.capture(owner);
    return DataToolsLease(
      space: captured.space,
      clientId: captured.clientId,
      epoch: captured.epoch,
      generation: captured.generation,
      supportsGroupPull: captured.supportsGroupPull,
      request: captured.request,
      download: captured.download,
      isCurrent: () =>
          mounted &&
          app.canSync &&
          app.space?.id == captured.space.id &&
          captured.isCurrent(),
    );
  }

  SyncLease _sync(DataToolsLease lease) => lease.toSyncLease();

  StageImportLease _captureStage() {
    final owner = app.identity;
    if (!app.canSync || owner == null || app.preparingUpdate) {
      throw const ApiFailure('identity_changed', '请先联网登录当前资料空间。');
    }
    final captured = StageImportLease.capture(owner);
    final data = captured.data;
    return StageImportLease(
      data: DataToolsLease(
        space: data.space,
        clientId: data.clientId,
        epoch: data.epoch,
        generation: data.generation,
        supportsGroupPull: data.supportsGroupPull,
        request: data.request,
        download: data.download,
        isCurrent: () =>
            mounted &&
            app.canSync &&
            !app.preparingUpdate &&
            app.space?.id == data.space.id &&
            data.isCurrent(),
      ),
      sessionId: captured.sessionId,
      supportsStages: captured.supportsStages,
      upload: captured.upload,
    );
  }

  Future<void> _stageChanged(StageImportLease lease) async {
    lease.check();
    if (!lease.data.supportsGroupPull) {
      throw const ApiFailure('group_capability_required', '当前服务器尚未支持完整导入刷新。');
    }
    await app.syncEngine.pullLatest(
      lease.toSyncLease(),
      requireFreshGroup: true,
    );
    lease.check();
  }

  Future<DataToolsCatalog> _catalog(DataToolsLease lease) async {
    lease.check();
    // A different device may already have undone a previously acknowledged
    // import. Recheck its authoritative operation metadata before skipping a
    // completed local attachment-adoption marker.
    for (final batch in await app.dataTools.list(lease.space)) {
      lease.check();
      final transfers = batch.result?.toJson()['attachment_transfers'] as List?;
      if (batch.phase == 'applied' &&
          batch.epoch == lease.epoch &&
          batch.clientId == lease.clientId &&
          transfers != null &&
          transfers.isNotEmpty) {
        await app.dataTools.refreshRemoteUndo(lease, batch.batchId);
      }
    }
    await app.syncEngine.pullLatest(_sync(lease));
    lease.check();
    final remaining = await DataToolsLocalRefresh(app.dataTools).reconcile(
      lease,
      adopt: (receipt, undo) => _adopt(lease, receipt, undo: undo),
    );
    lease.check();
    if (remaining > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && lease.isCurrent()) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$remaining 个已确认批次的本机刷新尚未完成，回执与原件已保留。可使用页面刷新重试。'),
            ),
          );
        }
      });
    }
    var groups = const <AssetGroup>[];
    if (app.identity?.serverIdentity?.supportsStagedImports == true) {
      final config = AssetConfigRepository(
        AssetConfigStore(app.repository),
        refreshPermissions: app.syncEngine.refreshScopes,
      );
      final snapshot = await config.refresh(
        _sync(lease),
        AssetConfigSection.groups,
      );
      lease.check();
      groups = snapshot.groups;
    }
    final view = await app.ledger.read(lease.space);
    lease.check();
    return DataToolsCatalog(
      books: [
        for (final book in view.books.where(
          (item) =>
              !item.effectiveArchived &&
              !item.pending &&
              !item.conflicted &&
              view.canCreate('bill', item.id),
        ))
          DataToolsBookOption(
            id: book.id,
            name: book.name,
            currency: book.payload['currency'] as String,
            currencyScale: currencyScales[book.payload['currency']]!,
            timezone: book.payload['timezone'] as String,
          ),
      ],
      resources: [
        for (final item in [...view.accounts, ...view.categories, ...view.tags])
          if (!item.effectiveArchived)
            DataToolsResourceOption(
              id: item.id,
              kind: item.type,
              name: item.name,
              scopeId: item.scopeId,
            ),
        for (final item in [...view.books, ...view.bills, ...view.budgets])
          if (!item.deleted &&
              !item.effectiveArchived &&
              !item.pending &&
              !item.conflicted)
            DataToolsResourceOption(
              id: item.id,
              kind: item.type,
              name: item.name.isNotEmpty
                  ? item.name
                  : '${item.payload['occurred_at'] ?? '账单'} · ${item.id.substring(0, 8)}',
              scopeId: item.scopeId,
            ),
        for (final group in groups)
          DataToolsResourceOption(
            id: group.id,
            kind: 'account_group',
            name: group.name,
            scopeId: lease.space.userId,
          ),
      ],
    );
  }

  AttachmentLease _attachmentLease(DataToolsLease lease) {
    lease.check();
    final captured = AttachmentLease.capture(app.identity!);
    if (captured.space.id != lease.space.id ||
        captured.epoch != lease.epoch ||
        captured.clientId != lease.clientId ||
        captured.generation != lease.generation) {
      throw const ApiFailure('identity_changed', '账号身份已变化，请重新打开迁移页面。');
    }
    return AttachmentLease(
      space: captured.space,
      epoch: captured.epoch,
      clientId: captured.clientId,
      generation: captured.generation,
      request: captured.request,
      download: captured.download,
      isCurrent: () => captured.isCurrent() && lease.isCurrent(),
    );
  }

  Future<void> _changed(
    DataToolsLease lease,
    DataImportApplied? result, {
    required bool undo,
  }) async {
    lease.check();
    var effectiveUndo = undo;
    if (result != null) {
      await app.dataTools.refreshRemoteUndo(lease, result.batchId);
      lease.check();
      final current = await app.dataTools.read(lease.space, result.batchId);
      lease.check();
      effectiveUndo = undo || current?.phase == 'undone';
    }
    await app.syncEngine.pullLatest(_sync(lease));
    lease.check();
    if (result == null) return;
    await DataToolsLocalRefresh(app.dataTools).acknowledge(
      lease,
      result,
      undo: effectiveUndo,
      adopt: (receipt, reversing) => _adopt(lease, receipt, undo: reversing),
    );
  }

  Future<void> _adopt(
    DataToolsLease lease,
    DataImportApplied result, {
    required bool undo,
  }) async {
    lease.check();
    final raw = result.toJson()['attachment_transfers'] as List? ?? const [];
    if (raw.isEmpty) return;
    final attachmentLease = _attachmentLease(lease);
    final transfer = await app.attachments();
    lease.check();
    for (final receipt in raw) {
      await transfer.adoptImportReceipt(
        attachmentLease,
        dataToolsObject(receipt),
        reverse: undo,
      );
      lease.check();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => _authorityKey() == null
        ? Scaffold(
            appBar: AppBar(title: const Text('数据迁移与导出')),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('请联网登录当前账号后使用数据迁移。未完成批次与原件保留在原资料空间。'),
              ),
            ),
          )
        : DataToolsPage(
            key: _page,
            repository: app.dataTools,
            captureLease: _capture,
            loadCatalog: _catalog,
            onMutation: _changed,
            authority: app,
            authorityKey: _authorityKey,
            stageStore: app.stageImports,
            captureStageLease: _captureStage,
            refreshStageProjection: _stageChanged,
            uploadImage: (lease, bytes, mediaType) async {
              final captured = _attachmentLease(lease);
              final transfer = await app.attachments();
              lease.check();
              final staged = await transfer.repository.stage(
                lease.space,
                lease.epoch,
                lease.space.userId,
                bytes,
                mediaType: mediaType,
              );
              lease.check();
              final uploaded = await transfer.upload(captured, staged.id);
              lease.check();
              return uploaded.id;
            },
          ),
  );
}
