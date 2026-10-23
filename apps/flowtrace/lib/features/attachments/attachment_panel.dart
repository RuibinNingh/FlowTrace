import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../../data/attachments/attachment_repository.dart';
import '../../data/attachments/attachment_transfer.dart';
import 'attachment_models.dart';
import 'image_attachment_selector.dart';

/// A controlled editor field. onChanged must persist the draft references
/// before completing. Removing a reference never deletes a user's original.
class AttachmentPanel extends StatefulWidget {
  const AttachmentPanel({
    super.key,
    required this.repository,
    required this.space,
    required this.epoch,
    required this.scopeId,
    required this.attachmentIds,
    required this.onChanged,
    required this.isCurrent,
    this.transfer,
    this.lease,
    this.readOnly = false,
    this.picker,
    this.contextChanges,
    this.onBusyChanged,
  });
  final AttachmentRepository repository;
  final DataSpace space;
  final String epoch, scopeId;
  final List<String> attachmentIds;
  final Future<void> Function(List<String>) onChanged;
  final bool Function() isCurrent;
  final AttachmentTransfer? transfer;
  final AttachmentLease Function()? lease;
  final bool readOnly;
  final AttachmentImagePicker? picker;
  final Listenable? contextChanges;
  final ValueChanged<bool>? onBusyChanged;
  @override
  State<AttachmentPanel> createState() => _AttachmentPanelState();
}

class _AttachmentPanelState extends State<AttachmentPanel> {
  late Future<List<LocalAttachment?>> _items;
  int _generation = 0;
  int _action = 0;
  bool _busy = false;
  String? _error;
  String? _unlinkedId;
  final _previewInvalidations = StreamController<void>.broadcast();
  @override
  void initState() {
    super.initState();
    widget.contextChanges?.addListener(_contextChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant AttachmentPanel old) {
    super.didUpdateWidget(old);
    if (old.contextChanges != widget.contextChanges) {
      old.contextChanges?.removeListener(_contextChanged);
      widget.contextChanges?.addListener(_contextChanged);
    }
    final contextChanged =
        old.space.id != widget.space.id ||
        old.epoch != widget.epoch ||
        old.scopeId != widget.scopeId ||
        old.repository != widget.repository ||
        old.readOnly != widget.readOnly;
    if (contextChanged ||
        !listEquals(old.attachmentIds, widget.attachmentIds)) {
      _generation++;
      _previewInvalidations.add(null);
      if (contextChanged) {
        _action++;
        _error = null;
        _unlinkedId = null;
        _busy = false;
      }
      _load();
    }
  }

  void _contextChanged() {
    if (mounted && !widget.isCurrent()) {
      _generation++;
      _action++;
      _previewInvalidations.add(null);
      setState(() {
        _busy = false;
        _error = null;
        _unlinkedId = null;
      });
    }
  }

  @override
  void dispose() {
    widget.contextChanges?.removeListener(_contextChanged);
    _generation++;
    _action++;
    // Asynchronous stream delivery avoids notifying another route while the
    // framework is finalizing this widget's disposal.
    _previewInvalidations.add(null);
    unawaited(_previewInvalidations.close());
    super.dispose();
  }

  void _finish(int action) {
    if (mounted && action == _action) {
      setState(() {
        _busy = false;
        _load();
      });
      _notifyBusy(false, action);
    }
  }

  void _notifyBusy(bool busy, int action) {
    if (!mounted || action != _action || !widget.isCurrent()) return;
    try {
      widget.onBusyChanged?.call(busy);
    } catch (_) {
      /* UI observer only. */
    }
  }

  void _load() {
    _items = Future.wait(
      widget.attachmentIds.map((id) => widget.repository.get(widget.space, id)),
    );
  }

  bool _current(int token) =>
      mounted && widget.isCurrent() && token == _generation;
  bool get _editable =>
      !widget.readOnly && !_busy && widget.isCurrent() && widget.space.verified;

  Future<void> _link(String id, int token, int action) async {
    if (!_current(token)) return;
    final ids = List<String>.from(widget.attachmentIds);
    if (ids.contains(id)) {
      _unlinkedId = null;
      return;
    }
    if (ids.length >= 20) {
      throw const ApiFailure('attachment_limit', '一笔记录最多20张图片。');
    }
    _unlinkedId = id;
    await widget.onChanged(List.unmodifiable([...ids, id]));
    if (mounted && widget.isCurrent() && action == _action) {
      _unlinkedId = null;
      _error = null;
    }
  }

  Future<void> _pick() async {
    if (!_editable) return;
    if (widget.attachmentIds.length >= 20) {
      setState(() => _error = '一笔记录最多20张图片。');
      return;
    }
    final token = _generation;
    final action = ++_action;
    final repository = widget.repository, space = widget.space;
    final epoch = widget.epoch, scope = widget.scopeId;
    setState(() {
      _busy = true;
      _error = null;
    });
    _notifyBusy(true, action);
    try {
      final selected =
          await (widget.picker ?? const ImageAttachmentSelector().pick)();
      if (selected == null || !_current(token)) return;
      final staged = await repository.stage(
        space,
        epoch,
        scope,
        selected.bytes,
        mediaType: selected.mediaType,
      );
      if (!_current(token)) return;
      await _link(staged.id, token, action);
    } on ApiFailure catch (error) {
      if (_current(token)) setState(() => _error = error.message);
    } catch (_) {
      if (_current(token)) {
        setState(
          () => _error = _unlinkedId == null
              ? '图片没有添加，请重试。'
              : '图片已在本机暂存，草稿关联尚未保存，可重新关联。',
        );
      }
    } finally {
      _finish(action);
    }
  }

  Future<void> _retryLink() async {
    if (!_editable || _unlinkedId == null) return;
    final token = _generation;
    final action = ++_action;
    setState(() => _busy = true);
    _notifyBusy(true, action);
    try {
      await _link(_unlinkedId!, token, action);
      if (_current(token)) setState(() => _error = null);
    } catch (_) {
      if (_current(token)) setState(() => _error = '草稿关联仍未保存，本机原件保留。');
    } finally {
      _finish(action);
    }
  }

  Future<void> _remove(String id) async {
    if (!_editable) return;
    final token = _generation;
    final action = ++_action;
    setState(() => _busy = true);
    _notifyBusy(true, action);
    try {
      await widget.onChanged(
        List.unmodifiable(widget.attachmentIds.where((item) => item != id)),
      );
      if (_current(token)) setState(() => _error = null);
    } catch (_) {
      if (_current(token)) setState(() => _error = '草稿引用尚未移除，请重试；本机原件保留。');
    } finally {
      _finish(action);
    }
  }

  Future<Uint8List> _bytes(String id, int token) async {
    final space = widget.space, epoch = widget.epoch, scope = widget.scopeId;
    final repository = widget.repository,
        transfer = widget.transfer,
        lease = widget.lease;
    await repository.requireAllowed(space, epoch, scope);
    final local = await repository.get(space, id);
    if (!_current(token)) {
      throw const ApiFailure('identity_changed', '资料空间已变化，请返回。');
    }
    if (local != null) {
      if (local.scopeId != scope || local.epoch != epoch) {
        throw const ApiFailure('attachment_scope_mismatch', '图片不属于当前账本。');
      }
      return repository.original(space, local);
    }
    final cached = await repository.cached(space, epoch, id, 'original');
    if (!_current(token)) {
      throw const ApiFailure('identity_changed', '资料空间已变化，请返回。');
    }
    if (cached != null) return cached;
    if (transfer == null || lease == null) {
      throw const ApiFailure('attachment_offline', '图片未缓存在本机，请联网后查看。');
    }
    return transfer.downloadOriginal(lease(), scope, id);
  }

  Future<void> _preview(String id) async {
    final token = _generation;
    if (!_current(token)) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AttachmentPreviewPage(
          load: () => _bytes(id, token),
          isCurrent: () => _current(token),
          contextChanges: widget.contextChanges,
          accessChanges: widget.repository.watchAllowed(
            widget.space,
            widget.epoch,
            widget.scopeId,
          ),
          invalidations: _previewInvalidations.stream,
        ),
      ),
    );
  }

  Future<void> _retryUpload(String id) async {
    if (!_editable || widget.transfer == null || widget.lease == null) return;
    final token = _generation;
    final action = ++_action;
    setState(() {
      _busy = true;
      _error = null;
    });
    _notifyBusy(true, action);
    try {
      await widget.transfer!.upload(widget.lease!(), id);
    } on ApiFailure catch (error) {
      if (_current(token)) setState(() => _error = error.message);
    } catch (_) {
      if (_current(token)) setState(() => _error = '上传未完成，本机原件保留。');
    } finally {
      _finish(action);
    }
  }

  String _label(LocalAttachment? item) => switch (item?.phase) {
    AttachmentPhase.ready => '已上传',
    AttachmentPhase.failed => '待上传，可重试',
    AttachmentPhase.revoked => '权限已变化，本机原件保留',
    AttachmentPhase.recoveryRequired => '待核对恢复，本机原件保留',
    null => '已关联图片，按需下载预览',
    _ => '已存本机，随记录同步上传',
  };

  @override
  Widget build(BuildContext context) {
    if (!widget.isCurrent()) return const Text('资料空间已变化，请重新打开记录。');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '图片附件',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text('${widget.attachmentIds.length}/20'),
          ],
        ),
        const SizedBox(height: 8),
        const Text('JPEG、PNG、WebP，每张最多10 MiB；移除仅取消本笔引用。'),
        const SizedBox(height: 10),
        if (!widget.space.verified) const Text('先登录建立账号资料空间，即可暂存图片。'),
        if (!widget.readOnly)
          OutlinedButton.icon(
            key: const Key('attachment-add'),
            onPressed: _editable ? _pick : null,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(_busy ? '正在处理图片…' : '添加图片'),
          ),
        if (_error != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        if (_unlinkedId != null)
          TextButton(
            onPressed: _editable ? _retryLink : null,
            child: const Text('重新关联已暂存图片'),
          ),
        FutureBuilder<List<LocalAttachment?>>(
          future: _items,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Padding(
                padding: EdgeInsets.all(8),
                child: Text('附件暂时不可读，本机原件保留。'),
              );
            }
            final items =
                snapshot.connectionState == ConnectionState.done &&
                    snapshot.data?.length == widget.attachmentIds.length
                ? snapshot.data
                : null;
            return Column(
              children: [
                for (
                  var index = 0;
                  index < widget.attachmentIds.length;
                  index++
                )
                  Card(
                    key: ValueKey('attachment-${widget.attachmentIds[index]}'),
                    margin: const EdgeInsets.only(top: 8),
                    child: ListTile(
                      leading: const Icon(Icons.image_outlined),
                      title: Text('图片 ${index + 1}'),
                      subtitle: Text(
                        _label(items == null ? null : items[index]),
                      ),
                      onTap: () => _preview(widget.attachmentIds[index]),
                      trailing: Wrap(
                        children: [
                          if (items != null &&
                              items[index]?.phase == AttachmentPhase.failed &&
                              widget.transfer != null &&
                              widget.lease != null)
                            IconButton(
                              tooltip: '重试上传图片${index + 1}',
                              onPressed: _editable
                                  ? () => _retryUpload(
                                      widget.attachmentIds[index],
                                    )
                                  : null,
                              icon: const Icon(Icons.refresh),
                            ),
                          IconButton(
                            tooltip: '预览图片${index + 1}',
                            onPressed: () =>
                                _preview(widget.attachmentIds[index]),
                            icon: const Icon(Icons.zoom_in),
                          ),
                          if (!widget.readOnly)
                            IconButton(
                              tooltip: '从本笔移除图片${index + 1}',
                              onPressed: _editable
                                  ? () => _remove(widget.attachmentIds[index])
                                  : null,
                              icon: const Icon(Icons.close),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class AttachmentPreviewPage extends StatefulWidget {
  const AttachmentPreviewPage({
    super.key,
    required this.load,
    required this.isCurrent,
    this.contextChanges,
    this.accessChanges,
    this.invalidations,
  });
  final Future<Uint8List> Function() load;
  final bool Function() isCurrent;
  final Listenable? contextChanges;
  final Stream<bool>? accessChanges;
  final Stream<void>? invalidations;
  @override
  State<AttachmentPreviewPage> createState() => _AttachmentPreviewPageState();
}

class _AttachmentPreviewPageState extends State<AttachmentPreviewPage> {
  Uint8List? _bytes;
  String? _error;
  bool _blocked = false;
  bool _accessReady = false;
  StreamSubscription<bool>? _accessSubscription;
  StreamSubscription<void>? _invalidationSubscription;
  @override
  void initState() {
    super.initState();
    _accessReady = widget.accessChanges == null;
    _accessSubscription = widget.accessChanges?.listen((allowed) {
      if (!allowed) {
        _block();
      } else if (mounted && !_blocked) {
        setState(() => _accessReady = true);
      }
    }, onError: (Object _) => _block());
    _invalidationSubscription = widget.invalidations?.listen((_) => _block());
    _load();
  }

  void _block() {
    if (!mounted || _blocked) return;
    setState(() {
      _blocked = true;
      _bytes = null;
      _error = null;
    });
  }

  @override
  void dispose() {
    unawaited(_accessSubscription?.cancel());
    unawaited(_invalidationSubscription?.cancel());
    _bytes = null;
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.load();
      if (!mounted || _blocked || !widget.isCurrent()) return;
      await validateAttachmentPixels(bytes);
      if (mounted && !_blocked && widget.isCurrent()) {
        setState(() => _bytes = Uint8List.fromList(bytes));
      }
    } on ApiFailure catch (error) {
      if (mounted && !_blocked && widget.isCurrent()) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted && !_blocked && widget.isCurrent()) {
        setState(() => _error = '图片暂时无法预览，本机原件保留。');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('图片预览')),
    body: widget.contextChanges == null
        ? _body()
        : ListenableBuilder(
            listenable: widget.contextChanges!,
            builder: (context, _) => _body(),
          ),
  );

  Widget _body() => _blocked || !widget.isCurrent()
      ? const Center(child: Text('资料空间已变化，请返回。'))
      : !_accessReady
      ? const Center(child: CircularProgressIndicator())
      : _error != null
      ? Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!),
          ),
        )
      : _bytes == null
      ? const Center(child: CircularProgressIndicator())
      : Center(
          child: InteractiveViewer(
            minScale: .5,
            maxScale: 4,
            child: Image.memory(
              _bytes!,
              cacheWidth: 1280,
              errorBuilder: (context, error, stack) =>
                  const Text('图片无法显示，本机原件保留。'),
            ),
          ),
        );
}
