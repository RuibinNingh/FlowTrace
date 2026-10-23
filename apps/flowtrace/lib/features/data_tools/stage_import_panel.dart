import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/network/api_failure.dart';
import '../../core/money/money.dart';
import '../../data/data_tools/data_tools_models.dart';
import '../../data/data_tools/stage_import_coordinator.dart';
import '../../data/data_tools/stage_import_commands.dart';
import '../../data/data_tools/stage_import_draft.dart';
import '../../data/data_tools/stage_import_lease.dart';
import '../../data/data_tools/stage_import_jobs.dart';
import '../../data/data_tools/stage_import_models.dart';
import '../../data/data_tools/stage_import_mutation_models.dart';
import '../../data/data_tools/stage_import_requirements.dart';
import '../../data/data_tools/stage_import_source_books.dart';
import '../../data/data_tools/stage_import_store.dart';

final class StageImportDestination {
  const StageImportDestination({
    required this.id,
    required this.name,
    required this.timezone,
    required this.currency,
    required this.currencyScale,
  });
  final String id, name, timezone, currency;
  final int currencyScale;
}

final class StageImportResourceOption {
  const StageImportResourceOption({
    required this.id,
    required this.name,
    required this.kind,
    required this.scopeId,
  });
  final String id, name, kind, scopeId;
}

/// The source is committed before uploading. The panel displays actual stage
/// and job metadata; a parse result never implies a financial import succeeded.
class StageImportPanel extends StatefulWidget {
  const StageImportPanel({
    super.key,
    required this.store,
    required this.captureLease,
    required this.authority,
    required this.authorityKey,
    this.chooseFile,
    this.destinations = const [],
    this.resources = const [],
    this.refreshProjection,
    this.uploadImage,
    this.chooseImage,
  });
  final StageImportStore store;
  final FutureOr<StageImportLease> Function() captureLease;
  final Listenable authority;
  final String? Function() authorityKey;
  final Future<XFile?> Function()? chooseFile;
  final List<StageImportDestination> destinations;
  final List<StageImportResourceOption> resources;
  final StageProjectionRefresh? refreshProjection;
  final Future<String> Function(StageImportLease, Uint8List, String)?
  uploadImage;
  final Future<XFile?> Function()? chooseImage;
  @override
  State<StageImportPanel> createState() => StageImportPanelState();
}

class StageImportPanelState extends State<StageImportPanel> {
  late final StageImportCoordinator _coordinator = StageImportCoordinator(
    widget.store,
  );
  late final StageImportCommands _commands = StageImportCommands(
    widget.store,
    refreshProjection:
        widget.refreshProjection ??
        (_) async {
          throw const ApiFailure(
            'stage_projection_unavailable',
            '资料同步尚未就绪，服务器回执已保留，请稍后刷新。',
          );
        },
  );
  ImportFileKind _format = ImportFileKind.qianjiCsv;
  List<StageImportRecord> _records = [];
  StageImportRecord? _selected;
  StageImportRequirementsReader? _reader;
  StageImportRequirementsPage? _requirements;
  StageImportMappingDraft? _draft;
  StageImportSourceBooksReader? _sourceBooksReader;
  StageImportSourceBooksPage? _sourceBooksPage;
  StageImportRowsPage? _previewPage;
  StageImportJobs? _jobs;
  int _previewPosition = 0;
  final _imageBooks = <String, String>{};
  String? _userScope;
  String? _message, _authorityKey;
  String? _destinationId;
  bool _busy = false, _supported = false;
  int _generation = 0;

  Future<bool> prepareForUpdate() async =>
      !_busy && !widget.store.busy && !_hasPendingImageBook;

  String? _savedImageBook(StageImportRequirement item) {
    final proofs = _draft?.value['images'];
    final proof = proofs == null
        ? null
        : dataToolsObject(proofs)[stageRequirementKey(item)];
    return proof == null
        ? null
        : dataToolsObject(proof)['target_book_id'] as String?;
  }

  bool get _hasPendingImageBook => _imageBooks.entries.any((entry) {
    final proofs = _draft?.value['images'];
    final proof = proofs == null ? null : dataToolsObject(proofs)[entry.key];
    return proof == null ||
        dataToolsObject(proof)['target_book_id'] != entry.value;
  });

  void _clearDetail() {
    _reader = null;
    _requirements = null;
    _draft = null;
    _sourceBooksReader = null;
    _sourceBooksPage = null;
    _previewPage = null;
    _previewPosition = 0;
    _jobs = null;
    _imageBooks.clear();
  }

  @override
  void initState() {
    super.initState();
    _authorityKey = widget.authorityKey();
    _destinationId = widget.destinations.firstOrNull?.id;
    widget.authority.addListener(_authorityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void didUpdateWidget(covariant StageImportPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.destinations.any((item) => item.id == _destinationId)) {
      _destinationId = widget.destinations.firstOrNull?.id;
    }
  }

  @override
  void dispose() {
    widget.authority.removeListener(_authorityChanged);
    super.dispose();
  }

  void _authorityChanged() {
    final key = widget.authorityKey();
    if (key == _authorityKey || !mounted) {
      return;
    }
    _generation++;
    setState(() {
      _authorityKey = key;
      _records = [];
      _selected = null;
      _clearDetail();
      _message = '账号或资料空间已变化。原始文件仍保留在原资料空间。';
      _supported = false;
    });
  }

  Future<void> _run(Future<void> Function(StageImportLease) action) async {
    if (_busy) {
      return;
    }
    final generation = _generation;
    setState(() {
      _busy = true;
      _message = null;
    });
    StageImportLease? lease;
    try {
      lease = await widget.captureLease();
      lease.check();
      if (mounted && generation == _generation) {
        setState(() {
          _supported = lease!.supportsStages;
          _userScope = lease.data.space.userId;
        });
      }
      await action(lease);
    } catch (error) {
      if (mounted &&
          generation == _generation &&
          (lease == null || lease.data.isCurrent())) {
        setState(() {
          _message = error is ApiFailure
              ? error.message
              : error is FormatException
              ? '文件或回执未通过校验，请保留原件并重新核对。'
              : '操作未完成。已保存的原始文件与上传位置仍保留，可再次继续。';
        });
      }
    } finally {
      if (mounted &&
          generation == _generation &&
          lease != null &&
          lease.data.isCurrent()) {
        try {
          await _showRecords(lease);
        } catch (_) {
          // Preserve the original action message; a local read failure never
          // turns a confirmed remote operation into a fabricated success.
        }
      }
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _showRecords(StageImportLease lease, {String? selectId}) async {
    final rows = await widget.store.list(lease.data.space);
    lease.check();
    if (!mounted) {
      return;
    }
    setState(() {
      _records = rows;
      final id = selectId ?? _selected?.stageId;
      _selected = rows.where((row) => row.stageId == id).firstOrNull;
    });
  }

  Future<void> _load() => _run((lease) => _showRecords(lease));
  Future<void> _choose() => _run((lease) async {
    final destination = widget.destinations
        .where((item) => item.id == _destinationId)
        .firstOrNull;
    if (_format.isQianji && destination == null) {
      throw const ApiFailure('stage_destination_required', '请先选择目标账本，再保存钱迹原件。');
    }
    final file =
        await (widget.chooseFile?.call() ??
            openFile(
              acceptedTypeGroups: const [
                XTypeGroup(label: '账单数据', extensions: ['csv', 'xlsx', 'json']),
              ],
            ));
    lease.check();
    if (file == null) {
      return;
    }
    final length = await file.length();
    if (length < 1 || length > stageImportSourceLimit) {
      throw const ApiFailure('stage_file_too_large', '请选择不超过50MiB的非空数据文件。');
    }
    final bytes = await file.readAsBytes();
    lease.check();
    if (bytes.length != length) {
      throw const FormatException('选择期间文件已变化。');
    }
    final saved = await widget.store.stage(
      lease,
      bytes: bytes,
      format: _format,
      fileName: file.name,
      mapping: _format.isQianji
          ? {
              'template_mapping': {
                'scope_id': destination!.id,
                'timezone': destination.timezone,
                'currency': destination.currency,
                'currency_scale': destination.currencyScale,
              },
            }
          : const {},
    );
    await _showRecords(lease, selectId: saved.stageId);
    if (mounted && lease.data.isCurrent()) {
      setState(() {
        _clearDetail();
        _message = '原始文件已保存在本机，可开始上传或稍后继续。';
      });
    }
  });
  Future<void> _upload() => _run((lease) async {
    final id = _selected!.stageId;
    await _coordinator.uploadAndSeal(lease, id);
    await _showRecords(lease, selectId: id);
  });
  Future<void> _refresh() => _run((lease) async {
    final previous = _selected!, id = previous.stageId;
    await _commands.refresh(lease, id);
    await _showRecords(lease, selectId: id);
    final jobs = await _commands.jobs(lease, id);
    if (mounted) {
      setState(() {
        if (_selected!.version != previous.version ||
            _selected!.remote?.body['requirements_hash'] !=
                previous.remote?.body['requirements_hash']) {
          _clearDetail();
        }
        _jobs = jobs;
      });
    }
  });
  Future<void> _refreshJobs() => _run((lease) async {
    final jobs = await _commands.jobs(lease, _selected!.stageId);
    if (mounted) {
      setState(() {
        _jobs = jobs;
      });
    }
  });
  Future<void> _nextRequirements() => _run((lease) async {
    if (_hasPendingImageBook) {
      throw const ApiFailure(
        'stage_image_choice_pending',
        '请先完成原图上传并保存所属账本，或放弃尚未保存的选择。',
      );
    }
    final record = await widget.store.require(lease, _selected!.stageId);
    final reader =
        _reader ?? StageImportRequirementsReader(widget.store, record);
    final page = await reader.next(lease);
    lease.check();
    var draft = _draft ?? record.mappingDraft;
    if (draft == null || !draft.matches(record.version, reader.hash)) {
      final previous = record.mappingDraft;
      final mapping =
          previous != null &&
              previous.desiredHash == record.remote?.body['mapping_hash']
          ? previous.mapping
          : dataToolsObject(record.createBody['mapping']);
      draft = StageImportMappingDraft.create(
        version: record.version,
        requirementsHash: reader.hash,
        mapping: mapping,
      );
      if (previous != null &&
          previous.desiredHash == record.remote?.body['mapping_hash']) {
        draft = StageImportMappingDraft.parse({
          ...draft.body,
          'choices': previous.choices,
          if (previous.body['images'] != null)
            'images': previous.body['images'],
        });
      }
    }
    draft = draft.withPage(page);
    await widget.store.saveMappingDraft(lease, record.stageId, draft);
    if (!mounted) {
      return;
    }
    setState(() {
      _reader = reader;
      _requirements = page;
      _draft = draft;
    });
  });

  Future<void> _chooseResource(StageImportRequirement item, String target) =>
      _run((lease) async {
        final draft = _draft!.withChoice(item, target);
        await widget.store.saveMappingDraft(lease, _selected!.stageId, draft);
        lease.check();
        if (mounted) {
          setState(() {
            _draft = draft;
          });
        }
      });

  Future<void> _sourceBooks() => _run((lease) async {
    final record = await widget.store.require(lease, _selected!.stageId);
    final reader =
        _sourceBooksReader ??
        StageImportSourceBooksReader(widget.store, record);
    final page = await reader.next(lease);
    lease.check();
    if (mounted) {
      setState(() {
        _sourceBooksReader = reader;
        _sourceBooksPage = page;
      });
    }
  });

  Future<void> _chooseOriginal(StageImportRequirement item) => _run((
    lease,
  ) async {
    final upload = widget.uploadImage;
    if (upload == null) {
      throw const ApiFailure('stage_image_unavailable', '原图上传尚未就绪，请稍后重试。');
    }
    final template = _draft!.mapping['template_mapping'];
    final destination = item.sourceKind == 'name'
        ? dataToolsObject(template)['scope_id'] as String
        : _imageBooks[stageRequirementKey(item)] ?? _savedImageBook(item);
    if (destination == null) {
      throw const ApiFailure('stage_image_book_required', '请先明确选择这张原图所属的账本。');
    }
    final file =
        await (widget.chooseImage?.call() ??
            openFile(
              acceptedTypeGroups: const [
                XTypeGroup(
                  label: '账单原图',
                  extensions: ['png', 'jpg', 'jpeg', 'webp'],
                ),
              ],
            ));
    lease.check();
    if (file == null) {
      return;
    }
    final length = await file.length();
    if (length < 1 || length > 10 * 1024 * 1024) {
      throw const ApiFailure('attachment_too_large', '请选择不超过10MiB的原图。');
    }
    final bytes = await file.readAsBytes();
    lease.check();
    final expected = item.attachment;
    final media =
        expected?.mediaType ??
        switch (file.name.toLowerCase().split('.').last) {
          'png' => 'image/png',
          'jpg' || 'jpeg' => 'image/jpeg',
          'webp' => 'image/webp',
          _ => throw const FormatException('图片类型无效。'),
        };
    if (bytes.length != length ||
        expected != null &&
            (expected.sizeBytes != bytes.length ||
                expected.sha256 != sha256.convert(bytes).toString())) {
      throw const ApiFailure('stage_image_mismatch', '所选原图与导出清单不一致，请选择原始图片。');
    }
    final uploaded = dataToolsUuid(await upload(lease, bytes, media));
    lease.check();
    final draft = _draft!.withImageChoice(
      item,
      uploadedId: uploaded,
      targetBookId: destination,
      selectedBytes: bytes,
      mediaType: media,
    );
    await widget.store.saveMappingDraft(lease, _selected!.stageId, draft);
    if (mounted) {
      setState(() {
        _draft = draft;
      });
    }
  });

  bool get _allSelected =>
      !_hasPendingImageBook &&
      _reader?.complete == true &&
      _draft != null &&
      _selected?.stageId == _reader?.record.stageId &&
      _selected?.version == _reader?.record.version &&
      _draft!.matches(
        _selected!.version,
        _selected!.remote?.body['requirements_hash'] as String?,
      ) &&
      _draft!.choiceCount == _reader!.count &&
      (_requirements?.items.every((item) => _draft!.choice(item) != null) ??
          false);

  Future<void> _saveMapping() => _run((lease) async {
    if (!_allSelected) {
      throw const ApiFailure(
        'stage_mapping_incomplete',
        '请完整核对每页资源并完成全部选择，再保存。',
      );
    }
    await _commands.changeMapping(
      lease,
      _selected!.stageId,
      _draft!.mapping,
      _reader!,
    );
    await _showRecords(lease);
    if (mounted) {
      setState(() {
        _clearDetail();
        _message = '资源选择已保存，服务器正在重新解析。请刷新状态后重新核对清单并生成预览。';
      });
    }
  });

  Future<void> _preview() => _run((lease) async {
    await _commands.requestPreview(lease, _selected!.stageId, _reader!);
    await _showRecords(lease);
    if (mounted) {
      setState(() {
        _previewPage = null;
        _previewPosition = 0;
        _message = '已提交预览请求，请刷新服务器状态查看结果。';
      });
    }
  });

  Future<void> _previewRows() => _run((lease) async {
    final record = await widget.store.require(lease, _selected!.stageId);
    final page = await _commands.rows(
      lease,
      record.stageId,
      version: record.version,
      cursor: _previewPage?.nextCursor,
      after: _previewPosition,
    );
    lease.check();
    if (mounted) {
      setState(() {
        _previewPage = page;
        _previewPosition = page.rows.lastOrNull?.position ?? 0;
      });
    }
  });

  Future<bool> _confirm(String title, String detail, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _apply() => _run((lease) async {
    final record = await widget.store.require(lease, _selected!.stageId);
    final jobs = await _commands.jobs(lease, record.stageId);
    if (jobs.active || jobs.forAction('apply') != null) {
      throw const ApiFailure(
        'stage_job_exists',
        '服务器已有导入任务，请刷新查看实际结果；不会重复提交或自动重排。',
      );
    }
    if (await _confirm(
      '确认导入',
      '将“${record.stored.fileName}”的${record.remote!.rowCount}行作为一个批次处理。'
          '服务器会再次核对资源、权限和预览；成功后同步最新资料。',
      '确认导入整个批次',
    )) {
      await _commands.apply(
        lease,
        record.stageId,
        version: record.version,
        previewHash: record.remote!.previewHash!,
      );
      await _showRecords(lease);
    }
  });
  Future<void> _undo() => _run((lease) async {
    final record = await widget.store.require(lease, _selected!.stageId);
    final jobs = await _commands.jobs(lease, record.stageId);
    if (jobs.active || jobs.forAction('undo') != null) {
      throw const ApiFailure(
        'stage_job_exists',
        '服务器已有撤销任务，请刷新查看实际结果；不会重复提交或自动重排。',
      );
    }
    if (await _confirm(
      '确认撤销',
      '撤销“${record.stored.fileName}”的这次正式导入。'
          '已有后续修改或新引用时，服务器会拒绝整个撤销。',
      '确认撤销这个批次',
    )) {
      await _commands.undo(
        lease,
        record.stageId,
        version: record.version,
        batchId: record.batchId!,
      );
      await _showRecords(lease);
    }
  });
  Future<void> _releaseServer() => _run((lease) async {
    final record = await widget.store.require(lease, _selected!.stageId);
    if (await _confirm(
      '释放服务器原件',
      '删除“${record.stored.fileName}”在服务器的原始文件与解析清单。'
          '正式账目和撤销记录保留。本机原件暂时保留。',
      '确认释放服务器原件',
    )) {
      await _commands.releaseSource(lease, record.stageId);
      await _showRecords(lease);
    }
  });
  Future<void> _releaseLocal() => _run((lease) async {
    if (await _confirm(
      '释放本机原件',
      '删除当前资料空间内这份本机原始文件副本。'
          '正式账目、操作记录和已有独立恢复备份保留。',
      '确认释放本机副本',
    )) {
      await widget.store.releaseLocalSource(lease, _selected!.stageId);
      await _showRecords(lease);
    }
  });
  Future<void> _reauthorize() => _run((lease) async {
    final plan = await _commands.inspectReauthorization(
      lease,
      _selected!.stageId,
    );
    if (plan.metadata.status == 'cancelled' ||
        plan.metadata.expired &&
            !{'applied', 'undoing', 'undone'}.contains(plan.metadata.status)) {
      throw const ApiFailure(
        'stage_reauthorization_unavailable',
        '这份暂存已取消或过期。原文件保持，可明确放弃暂存并释放副本；正式导入不会重做。',
      );
    }
    if (await _confirm(
      '重新授权继续处理',
      '已核对服务器原件与本机“${plan.record.stored.fileName}”一致。'
          '使用当前登录继续处理，原资源预览将重新核对；原正式导入不会重复执行。',
      '明确重新授权',
    )) {
      await _commands.confirmReauthorization(lease, plan);
      await _showRecords(lease);
      if (mounted) {
        setState(() {
          _clearDetail();
          _message = '已续接当前登录，请刷新状态后重新核对资源或正式撤销。';
        });
      }
    }
  });

  Future<void> _discard() => _run((lease) async {
    final plan = await _commands.inspectReauthorization(
      lease,
      _selected!.stageId,
    );
    if (await _confirm(
      '放弃这次暂存',
      '将“${plan.record.stored.fileName}”未正式导入的服务器暂存与本机原件副本删除。'
          '原始选择和操作记录、已有独立恢复备份保留。正式处理中或已发布的批次不能执行此操作。',
      '确认放弃并释放两处原件',
    )) {
      await _commands.discard(lease, plan);
      await _showRecords(lease);
      if (mounted) {
        setState(() {
          _clearDetail();
          _message = '已确认取消暂存并释放本机原件；原登录绑定与操作历史保持。';
        });
      }
    }
  });

  Map<String, String> _options(StageImportRequirement item) {
    final result = <String, String>{};
    if (item.kind == 'scope') {
      if (item.resourceType == 'user' && _userScope != null) {
        result[_userScope!] = '当前个人范围';
      } else if (item.resourceType == 'book') {
        for (final book in widget.destinations) {
          result[book.id] = book.name;
        }
      }
    } else {
      final kind = item.sourceKind == 'name' ? item.kind : item.resourceType;
      final template = _draft?.mapping['template_mapping'];
      final targetScope = template == null
          ? null
          : dataToolsObject(template)['scope_id'];
      for (final option in widget.resources) {
        if (option.kind != kind) {
          continue;
        }
        if (item.sourceKind == 'name' &&
            option.scopeId != targetScope &&
            !(kind == 'account' && option.scopeId == _userScope)) {
          continue;
        }
        result[option.id] = option.name;
      }
    }
    return result;
  }

  Widget _resourceField(StageImportRequirement item) {
    if (item.kind == 'image') {
      return _imageField(item);
    }
    final options = _options(item);
    final selected = _draft?.choice(item);
    final label = item.sourceKind == 'name'
        ? '${_kindLabel(item.kind)}：${item.sourceKey}'
        : '${_kindLabel(item.resourceType ?? item.kind)} · 原文件第${item.firstLine}行';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: DropdownButtonFormField<String>(
        key: ValueKey('${stageRequirementKey(item)}:$selected'),
        initialValue: options.containsKey(selected) ? selected : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          helperText: options.isEmpty
              ? '暂无可用目标。请先建立或取得对应资源的使用权限，再重新载入。'
              : '选择会自动保存在本机草稿',
        ),
        items: [
          for (final entry in options.entries)
            DropdownMenuItem(value: entry.key, child: Text(entry.value)),
        ],
        onChanged: _busy
            ? null
            : (value) {
                if (value != null) _chooseResource(item, value);
              },
      ),
    );
  }

  Widget _imageField(StageImportRequirement item) {
    final chosen = _draft?.choice(item);
    final targets = <String, String>{
      for (final book in widget.destinations) book.id: '现有账本：${book.name}',
      for (final book in _sourceBooksPage?.items ?? <StageImportSourceBook>[])
        book.sourceId: '原文件账本：${book.name}',
    };
    final previousBook = _savedImageBook(item);
    final selectedBook = _imageBooks[stageRequirementKey(item)] ?? previousBook;
    if (selectedBook != null && !targets.containsKey(selectedBook)) {
      targets[selectedBook] = '上次选择的原文件账本（可重新核对）';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              item.sourceKind == 'name'
                  ? '原图：${item.sourceKey}'
                  : '原图 · 原文件第${item.firstLine}行',
            ),
            Text(
              item.attachment == null
                  ? '没有原图校验清单，请本人选择对应图片；不会自动访问原链接。'
                  : '将核对所选原图的内容、大小和格式。',
            ),
            if (item.sourceKind == 'identifier')
              DropdownButtonFormField<String>(
                key: ValueKey(
                  'image-book:${stageRequirementKey(item)}:$selectedBook',
                ),
                initialValue: selectedBook,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '明确选择这张原图所属的账本'),
                items: [
                  for (final entry in targets.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() {
                            _imageBooks[stageRequirementKey(item)] = value;
                          });
                        }
                      },
              ),
            if (item.sourceKind == 'identifier')
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: _busy || _sourceBooksReader?.complete == true
                        ? null
                        : _sourceBooks,
                    child: Text(
                      _sourceBooksReader == null ? '读取原文件内账本' : '下一页原文件账本',
                    ),
                  ),
                ],
              ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _chooseOriginal(item),
              icon: const Icon(Icons.image),
              label: Text(chosen == null ? '选择并上传原图' : '重新选择原图'),
            ),
            if (chosen != null) const Text('原图已上传并保存选择。修改所属账本后，请重新选择原图完成保存。'),
            if (_imageBooks.containsKey(stageRequirementKey(item)))
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _imageBooks.remove(stageRequirementKey(item));
                      }),
                child: const Text('放弃尚未保存的所属账本选择'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _previewRow(StageImportPreviewRow item) {
    final row = item.row;
    final amount = row?.entityType == 'bill'
        ? Money.fromJson(row!.payload['money'], positive: true)
        : null;
    return ListTile(
      title: Text(
        '原文件第${item.sourceLine}行 · ${switch (item.status) {
          'new' => '待新增',
          'duplicate' => '已有相同来源',
          'parsed' => '等待预览',
          'invalid' => '需要处理',
          _ => '来源需要核对',
        }}',
      ),
      subtitle: Text(
        item.errors.isNotEmpty
            ? '这行未通过校验，请核对原文件、资源选择与当前使用权限。'
            : row == null
            ? '请核对原文件。'
            : row.entityType == 'bill'
            ? '${row.payload['business_date']} · ${_billLabel(row.payload['bill_type'])}'
            : '${_kindLabel(row.entityType)}${row.payload['name'] == null ? '' : '：${row.payload['name']}'}',
      ),
      trailing: amount == null
          ? null
          : Text('${amount.currency} ${amount.display()}'),
    );
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        '大文件导入',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text(
        '原件先保存在当前资料空间，再分片上传。关闭页面或暂时离线后，可选择同一原件继续。解析和资源核对完成后，仍需单独确认导入。',
      ),
      if (!_supported)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('当前服务器尚未开放大文件导入。你仍可保存原件到本机，普通导入与导出继续可用。'),
        ),
      if (_busy) const LinearProgressIndicator(),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(_message!),
        ),
      DropdownButtonFormField<ImportFileKind>(
        initialValue: _format,
        decoration: const InputDecoration(labelText: '原始文件格式'),
        items: [
          for (final kind in ImportFileKind.values)
            DropdownMenuItem(value: kind, child: Text(kind.label)),
        ],
        onChanged: _busy
            ? null
            : (value) {
                if (value != null) {
                  setState(() {
                    _format = value;
                  });
                }
              },
      ),
      const SizedBox(height: 12),
      if (_format.isQianji) ...[
        DropdownButtonFormField<String>(
          initialValue: _destinationId,
          decoration: const InputDecoration(labelText: '目标账本'),
          items: [
            for (final target in widget.destinations)
              DropdownMenuItem(value: target.id, child: Text(target.name)),
          ],
          onChanged: _busy
              ? null
              : (value) {
                  setState(() {
                    _destinationId = value;
                  });
                },
        ),
        const SizedBox(height: 12),
      ],
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: _busy ? null : _choose,
            icon: const Icon(Icons.file_open),
            label: const Text('选择并保存原件'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _load,
            child: const Text('载入本机原件'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      for (final row in _records)
        Card(
          child: ListTile(
            selected: row.stageId == _selected?.stageId,
            title: Text(row.stored.fileName),
            subtitle: Text(
              '${_sizeLabel(row.stored.expectedBytes)} · ${_statusLabel(row.remote?.status)}'
              '${row.localReleased ? ' · 本机原件已释放' : ''}',
            ),
            onTap: _busy
                ? null
                : () {
                    if (_hasPendingImageBook) {
                      setState(() {
                        _message = '先保存原图所属账本或放弃尚未保存的选择，再切换原件。';
                      });
                      return;
                    }
                    setState(() {
                      _selected = row;
                      _clearDetail();
                    });
                  },
          ),
        ),
      if (_selected case final selected?) ...[
        const Divider(),
        Text(
          selected.stored.fileName,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          '已上传 ${_sizeLabel((selected.nextChunk * stageImportChunkBytes).clamp(0, selected.stored.expectedBytes))}'
          ' / ${_sizeLabel(selected.stored.expectedBytes)}；${_statusLabel(selected.remote?.status)}',
        ),
        if (selected.remote case final remote?)
          Text('解析行数：${remote.rowCount}；错误项：${remote.errorCount}'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: _busy || !_supported || selected.localReleased
                  ? null
                  : _upload,
              child: const Text('继续上传与解析'),
            ),
            OutlinedButton(
              onPressed: _busy || !_supported || selected.batchId == null
                  ? null
                  : _refresh,
              child: const Text('获取服务器状态'),
            ),
            OutlinedButton(
              onPressed: _busy || !_supported || selected.batchId == null
                  ? null
                  : _refreshJobs,
              child: const Text('刷新任务状态'),
            ),
            OutlinedButton(
              onPressed:
                  _busy ||
                      !_supported ||
                      selected.remote?.body['requirements_version'] !=
                          selected.version ||
                      _reader?.complete == true
                  ? null
                  : _nextRequirements,
              child: Text(_reader == null ? '查看原始资源清单' : '下一页原始资源'),
            ),
            if (_reader != null)
              TextButton(
                onPressed: _busy || _hasPendingImageBook
                    ? null
                    : () {
                        setState(() {
                          _reader = null;
                          _requirements = null;
                        });
                      },
                child: const Text('从首重新核对资源（选择保留）'),
              ),
          ],
        ),
        if (_jobs case final jobs?) ...[
          const SizedBox(height: 12),
          const Text('服务器任务（手工刷新）'),
          if (jobs.jobs.isEmpty) const Text('当前没有已提交任务。'),
          for (final job in jobs.jobs)
            ListTile(
              dense: true,
              title: Text(
                '${_actionLabel(job.action)}：${_jobLabel(job.status)}',
              ),
              subtitle: Text(
                job.status == 'failed'
                    ? '处理未完成，原件与操作回执保留。不会自动重排金融操作，请核对资源、权限和服务器任务。'
                    : job.status == 'retry_wait'
                    ? '服务器等待按原任务重试；请稍后手工刷新。'
                    : job.status == 'succeeded'
                    ? '任务已完成；正式结果以文件状态及同步后的资料为准。'
                    : '尝试次数：${job.attempt}',
              ),
            ),
        ],
        if (selected.remote?.status == 'applied')
          Text(
            selected.state['projection_version'] == selected.version
                ? '已导入并同步最新资料。'
                : '服务器已导入，请获取服务器状态以同步最新资料。',
          ),
        if (selected.remote?.status == 'undone')
          Text(
            selected.state['projection_version'] == selected.version
                ? '已撤销并同步最新资料。'
                : '服务器已撤销，请获取服务器状态以同步最新资料。',
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed:
                  _busy ||
                      !_supported ||
                      selected.remote?.sourceReleased == true ||
                      !{
                        'parsed',
                        'ready',
                        'failed',
                      }.contains(selected.remote?.status) ||
                      !_allSelected ||
                      _jobs?.active == true
                  ? null
                  : _saveMapping,
              child: const Text('保存资源选择并重新解析'),
            ),
            OutlinedButton(
              onPressed:
                  _busy ||
                      !_supported ||
                      !_allSelected ||
                      !{'parsed', 'ready'}.contains(selected.remote?.status) ||
                      selected.remote?.errorCount != 0 ||
                      _jobs?.active == true
                  ? null
                  : _preview,
              child: const Text('生成完整导入预览'),
            ),
            OutlinedButton(
              onPressed:
                  _busy ||
                      !_supported ||
                      selected.remote?.sourceReleased == true ||
                      selected.remote == null ||
                      selected.remote!.rowCount == 0 ||
                      _previewPage != null && !_previewPage!.hasMore
                  ? null
                  : _previewRows,
              child: Text(_previewPage == null ? '查看逐行预览' : '下一页逐行预览'),
            ),
            FilledButton(
              onPressed:
                  _busy ||
                      !_supported ||
                      selected.remote?.status != 'ready' ||
                      selected.remote?.errorCount != 0 ||
                      selected.remote?.previewHash == null ||
                      _jobs == null ||
                      _jobs!.active ||
                      _jobs!.forAction('apply') != null
                  ? null
                  : _apply,
              child: const Text('确认正式导入'),
            ),
            OutlinedButton(
              onPressed:
                  _busy ||
                      !_supported ||
                      selected.remote?.status != 'applied' ||
                      _jobs == null ||
                      _jobs!.active ||
                      _jobs!.forAction('undo') != null
                  ? null
                  : _undo,
              child: const Text('撤销这次正式导入'),
            ),
          ],
        ),
        if (selected.remote?.status == 'ready' && _jobs == null)
          const Text('先刷新任务状态，再核对预览并确认正式导入。'),
        ExpansionTile(
          title: const Text('原件、续接与清理'),
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '退出登录或更换会话后，原件仍保留。'
                '必须本人明确重新授权；已取消或过期的未发布暂存可单独放弃，不会自动重做导入。',
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed:
                      _busy ||
                          !_supported ||
                          selected.localReleased &&
                              !{
                                'applied',
                                'undoing',
                                'undone',
                              }.contains(selected.remote?.status) ||
                          selected.batchId == null
                      ? null
                      : _reauthorize,
                  child: const Text('核对原件并重新授权'),
                ),
                OutlinedButton(
                  onPressed:
                      _busy ||
                          !_supported ||
                          selected.remote?.sourceReleased == true ||
                          !{
                            'applied',
                            'undoing',
                            'undone',
                          }.contains(selected.remote?.status)
                      ? null
                      : _releaseServer,
                  child: const Text('释放服务器原件'),
                ),
                OutlinedButton(
                  onPressed:
                      _busy ||
                          selected.localReleased ||
                          !(selected.remote?.sourceReleased == true ||
                              selected.remote?.status == 'cancelled')
                      ? null
                      : _releaseLocal,
                  child: const Text('释放本机原件副本'),
                ),
                OutlinedButton(
                  onPressed:
                      _busy ||
                          !_supported ||
                          selected.localReleased ||
                          selected.batchId == null ||
                          {
                            'applying',
                            'applied',
                            'undoing',
                            'undone',
                          }.contains(selected.remote?.status)
                      ? null
                      : _discard,
                  child: const Text('放弃暂存并释放原件'),
                ),
              ],
            ),
          ],
        ),
      ],
      if (_requirements case final page?) ...[
        const SizedBox(height: 16),
        Text(
          '原始资源清单：已核对 ${_reader!.loaded}/${_reader!.count} 项'
          '${_reader!.complete ? '，清单已完整核对' : '，请继续读取剩余清单'}',
        ),
        Text('已保存${_draft?.choiceCount ?? 0}项选择。重新打开后会从首核对完整清单，原选择保留。'),
        const Text('完整资源选择的请求上限为1MiB；超过上限时保留本机草稿，需要先整理原文件。'),
        for (final item in page.items) _resourceField(item),
        if (_reader!.complete && !_allSelected)
          const Text('清单读取完毕，仍有资源未选择或原图所属账本尚未保存。'),
      ],
      if (_previewPage case final page?) ...[
        const Divider(),
        Text(
          '逐行预览（共${_selected?.remote?.rowCount ?? 0}行，当前页${page.rows.length}行）',
        ),
        for (final item in page.rows) _previewRow(item),
        if (!page.hasMore) const Text('逐行预览已到末页。'),
      ],
    ],
  );
}

String _statusLabel(String? status) => switch (status) {
  null => '尚未上传',
  'uploading' => '正在上传',
  'uploaded' => '等待解析',
  'parsing' => '正在解析',
  'parsed' => '已解析，等待资源核对',
  'previewing' => '正在预览',
  'ready' => '预览完成，等待确认',
  'applying' => '正在导入',
  'applied' => '服务器已导入',
  'undoing' => '正在撤销',
  'undone' => '服务器已撤销',
  'failed' => '处理失败，原件保留',
  'cancelled' => '已取消',
  'expired' => '暂存已过期',
  _ => '请获取服务器状态',
};
String _kindLabel(String kind) => switch (kind) {
  'account' => '账户',
  'category' => '分类',
  'tag' => '标签',
  'image' => '原图',
  'scope' => '账本或个人范围',
  'resource' => '资源',
  'book' => '账本',
  'user' => '个人范围',
  'bill' => '账单',
  'budget' => '预算',
  'account_group' => '账户分组',
  _ => '引用',
};
String _billLabel(Object? kind) => switch (kind) {
  'expense' => '支出',
  'income' => '收入',
  'transfer' => '转账',
  'refund' => '退款',
  'reimbursement' => '报销回款',
  _ => '账单',
};
String _actionLabel(String action) => switch (action) {
  'parse' => '原件解析',
  'preview' => '导入预览',
  'apply' => '正式导入',
  _ => '正式撤销',
};
String _jobLabel(String status) => switch (status) {
  'pending' => '已排队',
  'running' => '正在执行',
  'retry_wait' => '等待原任务重试',
  'succeeded' => '已完成',
  'failed' => '执行失败',
  _ => '已取消',
};
String _sizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes 字节';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
