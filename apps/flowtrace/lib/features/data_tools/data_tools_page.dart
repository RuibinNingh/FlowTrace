import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/money/money.dart';
import '../../core/network/api_failure.dart';
import '../../data/data_tools/data_tools_models.dart';
import '../../data/data_tools/data_tools_repository.dart';
import '../../data/data_tools/export_saver.dart';
import '../../data/data_tools/stage_import_lease.dart';
import '../../data/data_tools/stage_import_store.dart';
import 'stage_import_panel.dart';

final class DataToolsBookOption {
  const DataToolsBookOption({
    required this.id,
    required this.name,
    required this.currency,
    required this.currencyScale,
    required this.timezone,
  });
  final String id, name, currency, timezone;
  final int currencyScale;
}

final class DataToolsResourceOption {
  const DataToolsResourceOption({
    required this.id,
    required this.kind,
    required this.name,
    required this.scopeId,
  });
  final String id, kind, name, scopeId;
}

final class DataToolsCatalog {
  const DataToolsCatalog({required this.books, required this.resources});
  final List<DataToolsBookOption> books;
  final List<DataToolsResourceOption> resources;
}

typedef DataToolsMutationObserver =
    Future<void> Function(
      DataToolsLease lease,
      DataImportApplied? applied, {
      required bool undo,
    });
typedef DataToolsImageUpload =
    Future<String> Function(
      DataToolsLease lease,
      Uint8List bytes,
      String mediaType,
    );

/// Uses the shared app theme and business transport. The application supplies
/// its authorized catalog, attachment staging, and post-receipt sync operation.
final class DataToolsPage extends StatefulWidget {
  const DataToolsPage({
    super.key,
    required this.repository,
    required this.captureLease,
    required this.loadCatalog,
    required this.onMutation,
    required this.authority,
    required this.authorityKey,
    this.uploadImage,
    this.chooseFile,
    this.chooseImage,
    this.chooseExportDestination,
    this.stageStore,
    this.captureStageLease,
    this.refreshStageProjection,
  });
  final DataToolsRepository repository;
  final FutureOr<DataToolsLease> Function() captureLease;
  final Future<DataToolsCatalog> Function(DataToolsLease lease) loadCatalog;
  final DataToolsMutationObserver onMutation;
  final Listenable authority;
  final String? Function() authorityKey;
  final DataToolsImageUpload? uploadImage;
  final Future<XFile?> Function()? chooseFile, chooseImage;
  final Future<DataToolsExportDestination?> Function(String format)?
  chooseExportDestination;
  final StageImportStore? stageStore;
  final FutureOr<StageImportLease> Function()? captureStageLease;
  final Future<void> Function(StageImportLease)? refreshStageProjection;
  @override
  State<DataToolsPage> createState() => DataToolsPageState();
}

class DataToolsPageState extends State<DataToolsPage> {
  final _stagePanel = GlobalKey<StageImportPanelState>();
  bool get _hasStages =>
      widget.stageStore != null &&
      widget.captureStageLease != null &&
      widget.refreshStageProjection != null;
  DataToolsCatalog? _catalog;
  DataToolsLease? _viewLease;
  String? _authorityKey, _bookId, _fileName, _message;
  Uint8List? _fileBytes;
  ImportFileKind _kind = ImportFileKind.qianjiCsv;
  DataImportParseResult? _parsed;
  StoredDataImport? _draft;
  DataImportPreview? _preview;
  List<StoredDataImport> _pending = [];
  final _resourceMapping = <String, Map<String, String>>{};
  final _imageMapping = <String, String>{};
  final _scopeMapping = <String, String>{};
  final _exportScopes = <String>{};
  final _start = TextEditingController(), _end = TextEditingController();
  List<DataImportHistoryItem> _history = [];
  String? _historyCursor;
  bool _hasMore = false,
      _busy = false,
      _includeConfiguration = true,
      _embedded = false;
  String _format = 'json', _order = 'date_asc';

  /// Rejects version changes while unsaved file/mapping choices are in memory.
  /// Once staged, the complete request is already in the partitioned database.
  Future<bool> prepareForUpdate() async =>
      !_busy &&
      !widget.repository.busy &&
      !(widget.stageStore?.busy ?? false) &&
      (_fileBytes == null || _draft != null) &&
      (await _stagePanel.currentState?.prepareForUpdate() ?? true);

  @override
  void initState() {
    super.initState();
    _authorityKey = widget.authorityKey();
    widget.authority.addListener(_authorityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    widget.authority.removeListener(_authorityChanged);
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _authorityChanged() {
    final key = widget.authorityKey();
    if (key == _authorityKey || !mounted) return;
    setState(() {
      _authorityKey = key;
      _catalog = null;
      _viewLease = null;
      _fileBytes = null;
      _fileName = null;
      _bookId = null;
      _parsed = null;
      _draft = null;
      _preview = null;
      _history = [];
      _pending = [];
      _imageMapping.clear();
      _resourceMapping.clear();
      _scopeMapping.clear();
      _exportScopes.clear();
      _start.clear();
      _end.clear();
      _message = '账号或资料空间已变化，请重新载入。';
    });
  }

  Future<void> _run(Future<void> Function(DataToolsLease lease) action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    DataToolsLease? lease;
    try {
      lease = await widget.captureLease();
      lease.check();
      await action(lease);
    } catch (error) {
      if (mounted && (lease == null || lease.isCurrent())) {
        setState(() {
          _message = error is ApiFailure
              ? error.message
              : error is FormatException
              ? '文件或回执未通过校验，请核对后重试。'
              : '当前操作未完成，请重试；本机已固定的迁移请求仍保留。';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _load() => _run((lease) async {
    final catalog = await widget.loadCatalog(lease);
    final pending = await widget.repository.list(lease.space);
    final history = await widget.repository.history(lease);
    lease.check();
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _viewLease = lease;
      _bookId =
          catalog.books.where((book) => book.id == _bookId).firstOrNull?.id ??
          catalog.books.firstOrNull?.id;
      _pending = pending
          .where((row) => !{'applied', 'undone'}.contains(row.phase))
          .toList();
      _history = history.items;
      _historyCursor = history.nextCursor;
      _hasMore = history.hasMore;
      if (_exportScopes.isEmpty) {
        if (_bookId != null) _exportScopes.add(_bookId!);
        _exportScopes.add(lease.space.userId);
      }
    });
  });

  DataToolsBookOption? get _book =>
      _catalog?.books.where((book) => book.id == _bookId).firstOrNull;

  Future<void> _chooseFile() => _run((lease) async {
    final file =
        await (widget.chooseFile?.call() ??
            openFile(
              acceptedTypeGroups: const [
                XTypeGroup(label: '账单数据', extensions: ['csv', 'xlsx', 'json']),
              ],
            ));
    lease.check();
    if (file == null) return;
    if (await file.length() > dataToolsFileLimit) {
      throw const ApiFailure('import_file_too_large', '请选择不超过5MiB的数据文件。');
    }
    final bytes = await file.readAsBytes();
    lease.check();
    if (!mounted) return;
    setState(() {
      _fileBytes = bytes;
      _fileName = file.name;
      _draft = null;
      _preview = null;
      _parsed = null;
      _imageMapping.clear();
      _resourceMapping.clear();
      _scopeMapping.clear();
      if (file.name.toLowerCase().endsWith('.json')) {
        _kind = ImportFileKind.flowtraceJson;
      } else if (file.name.toLowerCase().endsWith('.xlsx') &&
          _kind == ImportFileKind.qianjiCsv) {
        _kind = ImportFileKind.qianjiXlsx;
      } else if (file.name.toLowerCase().endsWith('.csv') &&
          _kind == ImportFileKind.qianjiXlsx) {
        _kind = ImportFileKind.qianjiCsv;
      }
    });
    await _parse(lease);
  });

  Future<DataImportParseResult> _parse(DataToolsLease lease) async {
    final bytes = _fileBytes;
    if (bytes == null) {
      throw const ApiFailure('import_file_required', '请先选择数据文件。');
    }
    final book = _book;
    if (_kind.isQianji && book == null) {
      throw const ApiFailure('import_book_required', '请先选择目标账本。');
    }
    final options = <String, Object?>{
      if (!_kind.isQianji) 'source_namespace': 'flowtrace-export',
      if (_kind.isQianji)
        'template_mapping': {
          'scope_id': book!.id,
          'timezone': book.timezone,
          'currency': book.currency,
          'currency_scale': book.currencyScale,
          'account_names': _resourceMapping['account'] ?? <String, String>{},
          'category_names': _resourceMapping['category'] ?? <String, String>{},
          'tag_names': _resourceMapping['tag'] ?? <String, String>{},
          'image_urls': _imageMapping,
        },
    };
    final parsed = await widget.repository.parse(
      lease,
      bytes,
      _kind,
      options: options,
    );
    lease.check();
    if (!mounted) return parsed;
    setState(() {
      _parsed = parsed;
      _preview = null;
      final ids =
          parsed.document?.rows.map((row) => row.sourceId).toSet() ??
          <String>{};
      for (final row in parsed.document?.rows ?? <DataImportRow>[]) {
        if (!ids.contains(row.scopeId) &&
            row.entityType == 'account' &&
            !_catalog!.books.any((book) => book.id == row.scopeId)) {
          _scopeMapping.putIfAbsent(row.scopeId, () => lease.space.userId);
        }
      }
    });
    return parsed;
  }

  Set<String> get _nativeImageIds => {
    for (final row in _parsed?.document?.rows ?? <DataImportRow>[])
      if (row.entityType == 'bill')
        ...(row.payload['attachment_ids'] as List? ?? []).cast<String>(),
  };

  Future<void> _pickImage(String source) => _run((lease) async {
    final upload = widget.uploadImage;
    if (upload == null) {
      throw const ApiFailure('import_image_unavailable', '原图上传尚未就绪，请稍后重试。');
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
    if (file == null) return;
    if (await file.length() > 10 * 1024 * 1024) {
      throw const ApiFailure('attachment_too_large', '单张原图不能超过10MiB。');
    }
    final original = await file.readAsBytes();
    lease.check();
    final expected = _parsed?.attachmentSources
        .where((item) => item.sourceId == source)
        .firstOrNull;
    final suffix = file.name.toLowerCase().split('.').last;
    final media =
        expected?.mediaType ??
        switch (suffix) {
          'jpg' || 'jpeg' => 'image/jpeg',
          'png' => 'image/png',
          'webp' => 'image/webp',
          _ => throw const FormatException('图片类型无效。'),
        };
    if (expected != null &&
        (original.length != expected.sizeBytes ||
            sha256.convert(original).toString() != expected.sha256)) {
      throw const ApiFailure(
        'import_image_hash_mismatch',
        '所选图片与导出清单不一致，请选择原始图片。',
      );
    }
    final id = dataToolsUuid(await upload(lease, original, media));
    lease.check();
    if (!mounted) return;
    setState(() {
      _imageMapping[source] = id;
      _draft = null;
      _preview = null;
    });
  });

  Future<void> _prepare() => _run((lease) async {
    final parsed = await _parse(lease);
    final document = parsed.document;
    if (document == null) {
      throw const ApiFailure('import_mapping_required', '请完成资源选择并修正错误行。');
    }
    if (!_kind.isQianji && !_nativeImageIds.every(_imageMapping.containsKey)) {
      throw const ApiFailure('import_images_required', '请为每张账单原图选择对应文件。');
    }
    final transfers = <String, String>{};
    if (_kind.isQianji) {
      for (final id in _imageMapping.values) {
        transfers[id] = _book!.id;
      }
    } else {
      for (final entry in _imageMapping.entries) {
        final scopes = document.rows
            .where(
              (row) =>
                  row.entityType == 'bill' &&
                  (row.payload['attachment_ids'] as List? ?? []).contains(
                    entry.key,
                  ),
            )
            .map((row) => row.scopeId)
            .toSet();
        if (scopes.length != 1) throw const FormatException('一张原图的账本范围不明确。');
        transfers[entry.value] = scopes.single;
      }
    }
    final draft = await widget.repository.stage(
      lease,
      document,
      scopeMapping: _scopeMapping,
      resourceMapping: _kind.isQianji ? const {} : _imageMapping,
      attachmentTransfers: transfers,
    );
    final preview = await widget.repository.preview(lease, draft.batchId);
    lease.check();
    if (!mounted) return;
    setState(() {
      _draft = draft;
      _preview = preview;
    });
  });

  Future<void> _finishMutation(
    DataToolsLease lease,
    DataImportApplied? result, {
    required bool undo,
  }) async {
    lease.check();
    var effectiveUndo = undo;
    if (result != null) {
      final current = await widget.repository.read(lease.space, result.batchId);
      lease.check();
      effectiveUndo = undo || current?.phase == 'undone';
    }
    try {
      await widget.onMutation(lease, result, undo: effectiveUndo);
      lease.check();
      if (result != null) {
        final current = await widget.repository.read(
          lease.space,
          result.batchId,
        );
        lease.check();
        effectiveUndo = effectiveUndo || current?.phase == 'undone';
      }
      if (!mounted) return;
      setState(() {
        _message = effectiveUndo && !undo
            ? '该批次已在其他操作中撤销，本机账本已刷新。'
            : effectiveUndo
            ? '迁移已撤销，本机账本已刷新。'
            : '导入已确认，本机账本已刷新。';
      });
    } catch (_) {
      if (mounted && lease.isCurrent()) {
        setState(() {
          _message = effectiveUndo
              ? '服务端已撤销，本机同步尚未完成，请稍后同步查看。'
              : '服务端已确认导入，本机同步尚未完成，请稍后同步查看。';
        });
      }
    }
    if (!mounted || !lease.isCurrent()) return;
    final pending = await widget.repository.list(lease.space);
    final history = await widget.repository.history(lease);
    final catalog = await widget.loadCatalog(lease);
    lease.check();
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _bookId =
          catalog.books.where((book) => book.id == _bookId).firstOrNull?.id ??
          catalog.books.firstOrNull?.id;
      _pending = pending
          .where((row) => !{'applied', 'undone'}.contains(row.phase))
          .toList();
      _history = history.items;
      _historyCursor = history.nextCursor;
      _hasMore = history.hasMore;
      _preview = null;
      _fileBytes = null;
    });
  }

  Future<void> _confirm() async {
    final draft = _draft, preview = _preview;
    if (draft == null || preview == null || !preview.canApply || _busy) return;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认导入'),
        content: Text(
          '将按当前预览处理${preview.rows.length}条记录。重复来源会保留原记录，合法同额账单不会合并。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回核对'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return;
    await _run((lease) async {
      final result = await widget.repository.apply(
        lease,
        draft.batchId,
        preview,
      );
      await _finishMutation(lease, result, undo: false);
    });
  }

  Future<void> _resume(StoredDataImport draft) => _run((lease) async {
    if ({'sending', 'uncertain'}.contains(draft.phase)) {
      final result = await widget.repository.retryPending(lease, draft.batchId);
      await _finishMutation(lease, result, undo: false);
    } else {
      final preview = await widget.repository.preview(lease, draft.batchId);
      lease.check();
      if (!mounted) return;
      setState(() {
        _draft = draft;
        _preview = preview;
      });
    }
  });

  Future<void> _undo(DataImportHistoryItem item) => _run((lease) async {
    final preview = await widget.repository.undoPreview(lease, item.batchId);
    lease.check();
    if (!mounted) return;
    if (!preview.canUndo) {
      setState(() {
        _message = preview.status == 'undone'
            ? '该迁移已经撤销。'
            : '记录或原图已被后续使用、修改或共享，当前不能整体撤销。';
      });
      return;
    }
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销这次迁移？'),
        content: Text('将撤销该批次创建的${preview.createdCount}条记录，其他批次不会被清空。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认撤销'),
          ),
        ],
      ),
    );
    lease.check();
    if (agreed != true) return;
    final original = await widget.repository.read(lease.space, item.batchId);
    lease.check();
    await widget.repository.undo(lease, item.batchId);
    await _finishMutation(lease, original?.result, undo: true);
  });

  Future<void> _moreHistory() => _run((lease) async {
    final page = await widget.repository.history(lease, cursor: _historyCursor);
    lease.check();
    if (!mounted) return;
    setState(() {
      final known = _history.map((row) => row.batchId).toSet();
      _history = [
        ..._history,
        ...page.items.where((row) => !known.contains(row.batchId)),
      ];
      _historyCursor = page.nextCursor;
      _hasMore = page.hasMore;
    });
  });

  String? _date(TextEditingController controller) {
    final value = controller.text.trim();
    if (value.isEmpty) return null;
    final parsed = DateTime.tryParse(value);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
        parsed == null ||
        parsed.toIso8601String().substring(0, 10) != value) {
      throw const FormatException('日期无效。');
    }
    return value;
  }

  Future<void> _export() => _run((lease) async {
    if (_exportScopes.isEmpty) {
      throw const ApiFailure('export_scope_required', '请至少选择一个账本或个人账户范围。');
    }
    final from = _date(_start), to = _date(_end);
    if (from != null && to != null && from.compareTo(to) > 0) {
      throw const FormatException('日期范围无效。');
    }
    final target =
        await (widget.chooseExportDestination?.call(_format) ??
            chooseDataToolsExport(_format));
    lease.check();
    if (target == null) return;
    try {
      final bytes = await widget.repository.export(lease, _format, {
        'scope_ids': _exportScopes.toList(),
        'date_from': from,
        'date_to': to,
        'order': _order,
        'include_configuration': _includeConfiguration,
        'include_images': _format == 'xlsx' && _embedded ? 'embedded' : 'links',
      });
      final status = await target.write(bytes, guard: lease.check);
      if (mounted && lease.isCurrent()) {
        setState(() {
          _message = status == DataToolsExportStatus.saved
              ? '导出文件已保存。'
              : '已发起浏览器下载，请在下载列表查看文件。';
        });
      }
    } finally {
      await target.discard();
    }
  });

  Widget _card(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          for (final child in children) ...[child, const SizedBox(height: 12)],
        ],
      ),
    ),
  );

  List<DataToolsResourceOption> _choices(String kind) =>
      _catalog?.resources
          .where(
            (row) =>
                row.kind == kind &&
                (row.scopeId == _bookId ||
                    kind == 'account' &&
                        row.scopeId == _viewLease?.space.userId),
          )
          .toList() ??
      [];

  Widget _mappingField(DataMappingRequirement item) {
    if (item.kind == 'image') {
      return _imageField(item.sourceValue, '原图：${item.sourceValue}');
    }
    final choices = _choices(item.kind);
    final selected = _resourceMapping[item.kind]?[item.sourceValue];
    return DropdownButtonFormField<String>(
      key: ValueKey('${item.kind}:${item.sourceValue}:$selected'),
      initialValue: choices.any((row) => row.id == selected) ? selected : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText:
            '${switch (item.kind) {
              'account' => '账户',
              'category' => '分类',
              _ => '标签',
            }}：${item.sourceValue}',
      ),
      items: [
        for (final choice in choices)
          DropdownMenuItem(
            value: choice.id,
            child: Text(choice.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _busy
          ? null
          : (value) {
              if (value == null) return;
              setState(() {
                (_resourceMapping[item.kind] ??= {})[item.sourceValue] = value;
                _draft = null;
                _preview = null;
              });
            },
    );
  }

  Widget _imageField(String source, String label) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      _imageMapping.containsKey(source) ? '原图已选择并上传' : '请选择对应的原始图片',
    ),
    trailing: OutlinedButton(
      onPressed: _busy ? null : () => _pickImage(source),
      child: Text(_imageMapping.containsKey(source) ? '重选' : '选择原图'),
    ),
  );

  List<Widget> _nativeScopes() {
    final document = _parsed?.document;
    if (document == null || _kind.isQianji) return [];
    final internal = document.rows.map((row) => row.sourceId).toSet();
    final scopes = document.rows
        .map((row) => row.scopeId)
        .toSet()
        .where(
          (id) =>
              !internal.contains(id) &&
              id != _viewLease?.space.userId &&
              !_catalog!.books.any((book) => book.id == id),
        );
    return [
      for (final source in scopes)
        DropdownButtonFormField<String>(
          key: ValueKey('scope:$source:${_scopeMapping[source]}'),
          initialValue: _scopeMapping[source],
          isExpanded: true,
          decoration: const InputDecoration(labelText: '原资料范围映射到'),
          items: [
            if (document.rows
                .where((row) => row.scopeId == source)
                .every((row) => row.entityType == 'account'))
              DropdownMenuItem(
                value: _viewLease!.space.userId,
                child: const Text('我的个人资产与账户'),
              ),
            for (final book in _catalog!.books)
              DropdownMenuItem(value: book.id, child: Text(book.name)),
          ],
          onChanged: _busy
              ? null
              : (value) {
                  if (value != null) {
                    setState(() {
                      _scopeMapping[source] = value;
                      _draft = null;
                      _preview = null;
                    });
                  }
                },
        ),
    ];
  }

  Widget _importForm() => _card('选择文件与目标', [
    DropdownButtonFormField<ImportFileKind>(
      key: ValueKey(_kind),
      initialValue: _kind,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '文件格式'),
      items: [
        for (final kind in ImportFileKind.values)
          DropdownMenuItem(value: kind, child: Text(kind.label)),
      ],
      onChanged: _busy
          ? null
          : (value) {
              if (value != null) {
                setState(() {
                  _kind = value;
                  _parsed = null;
                  _draft = null;
                  _preview = null;
                  _imageMapping.clear();
                  _resourceMapping.clear();
                  _scopeMapping.clear();
                });
              }
            },
    ),
    DropdownButtonFormField<String>(
      key: ValueKey('book:$_bookId'),
      initialValue: _bookId,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '目标账本'),
      items: [
        for (final book in _catalog?.books ?? <DataToolsBookOption>[])
          DropdownMenuItem(value: book.id, child: Text(book.name)),
      ],
      onChanged: _busy
          ? null
          : (value) {
              setState(() {
                _bookId = value;
                _parsed = null;
                _draft = null;
                _preview = null;
                _resourceMapping.clear();
                _scopeMapping.clear();
              });
            },
    ),
    if (_book != null && _kind.isQianji)
      Text('时间按${_book!.timezone}解析，金额使用${_book!.currency}。'),
    OutlinedButton.icon(
      onPressed: _busy ? null : _chooseFile,
      icon: const Icon(Icons.upload_file),
      label: Text(_fileName ?? '选择数据文件'),
    ),
    if (_parsed != null) ...[
      for (final mapping in _parsed!.mappings) _mappingField(mapping),
      if (!_kind.isQianji) ...[
        ..._nativeScopes(),
        for (final id in _nativeImageIds)
          _imageField(id, '账单原图 ${_nativeImageIds.toList().indexOf(id) + 1}'),
      ],
      if (_parsed!.errors.isNotEmpty)
        Text('有${_parsed!.errors.length}项需要处理，完成资源选择后可重新预览。'),
    ],
    FilledButton.icon(
      onPressed: _busy || _fileBytes == null ? null : _prepare,
      icon: const Icon(Icons.fact_check_outlined),
      label: const Text('生成导入预览'),
    ),
    if (_pending.isNotEmpty) ...[
      const Divider(),
      const Text('本机未完成迁移'),
      for (final draft in _pending)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(draft.document.namespace),
          subtitle: Text(
            {
                  'sending': '上次结果待核对',
                  'uncertain': '上次结果待核对',
                  'prepared': '预览已保存',
                }[draft.phase] ??
                '请求已保存',
          ),
          trailing: TextButton(
            onPressed: _busy ? null : () => _resume(draft),
            child: Text(
              {'sending', 'uncertain'}.contains(draft.phase)
                  ? '按原批次重试'
                  : '继续预览',
            ),
          ),
        ),
    ],
  ]);

  Widget _previewPanel() {
    final document = _draft?.document ?? _parsed?.document;
    return _card('导入预览', [
      if (document == null) const Text('先选择文件和资源映射。预览通过后，再由你确认正式导入。'),
      for (final error in [...?_parsed?.errors, ...?_preview?.errors])
        Text(
          '${error.row == null ? '文件' : '第${error.row}行'}：${_errorLabel(error.code)}',
        ),
      if (document != null) ...[
        Text('共${document.rows.length}条记录'),
        if (_preview != null)
          Text(_preview!.canApply ? '校验通过，可以确认导入。' : '当前预览存在冲突，请核对错误。'),
        SizedBox(
          height: 320,
          child: ListView.builder(
            itemCount: document.rows.length,
            itemBuilder: (context, index) {
              final row = document.rows[index], payload = row.payload;
              final amount = row.entityType == 'bill'
                  ? Money.fromJson(payload['money'], positive: true)
                  : null;
              final status = _preview?.rows
                  .where((item) => item['source_id'] == row.sourceId)
                  .firstOrNull;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  row.entityType == 'bill'
                      ? '${_billLabel(payload['bill_type'])} · ${payload['business_date']}'
                      : '${_entityLabel(row.entityType)} · ${payload['name'] ?? ''}',
                ),
                subtitle: Text(
                  status?['status'] == 'duplicate'
                      ? '已有同来源记录，将保留原记录'
                      : status?['warning'] != null
                      ? '有内容相同的其他来源，请确认是独立账单'
                      : '按当前选择导入',
                ),
                trailing: amount == null
                    ? null
                    : Text('${amount.currency} ${amount.display()}'),
              );
            },
          ),
        ),
        FilledButton(
          onPressed: _busy || _preview?.canApply != true ? null : _confirm,
          child: const Text('确认正式导入'),
        ),
      ],
    ]);
  }

  Widget _imports() => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: constraints.maxWidth >= 1000
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 390, child: _importForm()),
                const SizedBox(width: 16),
                Expanded(child: _previewPanel()),
              ],
            )
          : Column(children: [_importForm(), _previewPanel()]),
    ),
  );

  Widget _exports() => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: _card('导出数据', [
          const Text('导出包含服务端已确认的数据。若本机还有未传账单，请先完成同步。'),
          for (final book in _catalog?.books ?? <DataToolsBookOption>[])
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _exportScopes.contains(book.id),
              title: Text(book.name),
              onChanged: _busy
                  ? null
                  : (selected) {
                      setState(() {
                        if (selected == true) {
                          _exportScopes.add(book.id);
                        } else {
                          _exportScopes.remove(book.id);
                        }
                      });
                    },
            ),
          if (_viewLease != null)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('个人资产与账户'),
              value: _exportScopes.contains(_viewLease!.space.userId),
              onChanged: _busy
                  ? null
                  : (selected) {
                      setState(() {
                        if (selected == true) {
                          _exportScopes.add(_viewLease!.space.userId);
                        } else {
                          _exportScopes.remove(_viewLease!.space.userId);
                        }
                      });
                    },
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _start,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: '起始日期',
                    hintText: 'YYYY-MM-DD',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _end,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: '结束日期',
                    hintText: 'YYYY-MM-DD',
                  ),
                ),
              ),
            ],
          ),
          DropdownButtonFormField<String>(
            initialValue: _order,
            decoration: const InputDecoration(labelText: '账单顺序'),
            items: const [
              DropdownMenuItem(value: 'date_asc', child: Text('日期从早到晚')),
              DropdownMenuItem(value: 'date_desc', child: Text('日期从晚到早')),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) {
                      setState(() {
                        _order = value;
                      });
                    }
                  },
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'json', label: Text('JSON')),
              ButtonSegment(value: 'xlsx', label: Text('Excel')),
            ],
            selected: {_format},
            onSelectionChanged: _busy
                ? null
                : (selection) {
                    setState(() {
                      _format = selection.single;
                      if (_format == 'json') _embedded = false;
                    });
                  },
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('包含账本、账户、分类等设置'),
            value: _includeConfiguration,
            onChanged: _busy
                ? null
                : (value) {
                    setState(() {
                      _includeConfiguration = value == true;
                    });
                  },
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('在Excel中嵌入原图'),
            subtitle: const Text('未嵌入时保留需要登录后访问的图片链接'),
            value: _embedded,
            onChanged: _busy || _format != 'xlsx'
                ? null
                : (value) {
                    setState(() {
                      _embedded = value == true;
                    });
                  },
          ),
          FilledButton.icon(
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.download),
            label: const Text('导出并保存'),
          ),
        ]),
      ),
    ),
  );

  Widget _historyView() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text('这里保留你自己的迁移操作记录。账本失权后仍可查看操作状态，撤销需要当前写入权限。'),
      if (_history.isEmpty)
        const Padding(padding: EdgeInsets.all(24), child: Text('还没有迁移记录。')),
      for (final item in _history)
        Card(
          child: ListTile(
            title: Text(item.sourceNamespace),
            subtitle: Text(
              '${item.createdAt.toLocal().toString().split('.').first} · 新增${item.createdCount}条 · 同来源${item.duplicateCount}条',
            ),
            trailing: item.status == 'undone'
                ? const Text('已撤销')
                : TextButton(
                    onPressed: _busy ? null : () => _undo(item),
                    child: const Text('查看撤销预览'),
                  ),
          ),
        ),
      if (_hasMore)
        OutlinedButton(
          onPressed: _busy ? null : _moreHistory,
          child: const Text('加载更多'),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: _hasStages ? 4 : 3,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('数据迁移与导出'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            tooltip: '重新载入',
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: TabBar(
          isScrollable: _hasStages,
          tabs: [
            const Tab(text: '导入'),
            const Tab(text: '导出'),
            const Tab(text: '操作历史'),
            if (_hasStages) const Tab(text: '大文件导入'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            MaterialBanner(
              content: Text(_message!),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _message = null;
                    });
                  },
                  child: const Text('知道了'),
                ),
              ],
            ),
          Expanded(
            child: _catalog == null
                ? Center(
                    child: _busy
                        ? const CircularProgressIndicator()
                        : FilledButton(
                            onPressed: _load,
                            child: const Text('联网载入数据工具'),
                          ),
                  )
                : TabBarView(
                    children: [
                      _imports(),
                      _exports(),
                      _historyView(),
                      if (_hasStages)
                        StageImportPanel(
                          key: _stagePanel,
                          store: widget.stageStore!,
                          captureLease: widget.captureStageLease!,
                          authority: widget.authority,
                          authorityKey: widget.authorityKey,
                          chooseFile: widget.chooseFile,
                          chooseImage: widget.chooseImage,
                          refreshProjection: widget.refreshStageProjection,
                          uploadImage: widget.uploadImage == null
                              ? null
                              : (lease, bytes, mediaType) =>
                                    widget.uploadImage!(
                                      lease.data,
                                      bytes,
                                      mediaType,
                                    ),
                          resources: [
                            for (final resource in _catalog!.resources)
                              StageImportResourceOption(
                                id: resource.id,
                                name: resource.name,
                                kind: resource.kind,
                                scopeId: resource.scopeId,
                              ),
                          ],
                          destinations: [
                            for (final book in _catalog!.books)
                              StageImportDestination(
                                id: book.id,
                                name: book.name,
                                timezone: book.timezone,
                                currency: book.currency,
                                currencyScale: book.currencyScale,
                              ),
                          ],
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}

String _errorLabel(String code) => switch (code) {
  'mapping_required' => '请选择对应的账户、分类、标签或原图',
  'source_modified' || 'import_source_modified' => '原来源记录已有后续修改',
  'import_attachment_transfer_conflict' => '原图状态或使用范围已变化',
  'invalid_exact_amount' => '金额精度或范围不正确',
  'too_many_rows' => '文件超过当前单批处理能力，请保留原件并分批核对',
  'unsupported_qianji_type' => '公开模板未定义此账单类型',
  'invalid_attachment_manifest' => '原图校验清单不完整或不正确',
  _ => '该行未通过校验，请核对原文件和资源选择',
};

String _entityLabel(String type) => switch (type) {
  'book' => '账本',
  'account' => '账户',
  'category' => '分类',
  'tag' => '标签',
  'budget' => '预算',
  _ => '记录',
};
String _billLabel(Object? type) => switch (type) {
  'expense' => '支出',
  'income' => '收入',
  'transfer' => '转账',
  'credit_repayment' => '信用卡还款',
  'loan_borrow' => '借入',
  'loan_lend' => '借出',
  'loan_collect' => '收债',
  'loan_repay' => '还债',
  'refund' => '退款',
  'reimbursement' => '报销入账',
  'balance_adjustment' => '余额调整',
  _ => '账单',
};
