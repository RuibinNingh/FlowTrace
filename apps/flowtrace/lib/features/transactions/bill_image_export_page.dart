import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../../data/attachments/attachment_transfer.dart';
import '../../data/ledger/ledger_image_export.dart';
import '../../data/ledger/ledger_models.dart';

class BillImageExportPage extends StatefulWidget {
  const BillImageExportPage({
    required this.app,
    required this.space,
    required this.ids,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final Set<String> ids;
  @override
  State<BillImageExportPage> createState() => _BillImageExportPageState();
}

class _BillImageExportPageState extends State<BillImageExportPage> {
  late final _stream = widget.app.ledger.watch(
    widget.space,
    query: const LedgerQuery(includeArchived: true),
  );
  LedgerImageExportService? _service;
  LedgerImageExportPreview? _preview;
  bool _busy = false, _loading = true;
  String? _message;
  bool get _current =>
      mounted &&
      widget.app.space?.id == widget.space.id &&
      !widget.app.switchingSpace;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_current || _busy) return;
    setState(() {
      _loading = true;
      _message = null;
      _preview = null;
    });
    try {
      final transfer = await widget.app.attachments();
      if (!_current) return;
      final service = _service ??= LedgerImageExportService(
        widget.app.ledger,
        transfer.repository,
        transfer: transfer,
      );
      final preview = await service.preview(widget.space, widget.ids);
      if (_current) setState(() => _preview = preview);
    } on ApiFailure catch (error) {
      if (_current) setState(() => _message = error.message);
    } catch (_) {
      if (_current) setState(() => _message = '图片资料读取失败，请同步后重试。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _export() async {
    final preview = _preview,
        service = _service,
        identity = widget.app.identity;
    if (_busy ||
        preview == null ||
        !preview.canExport ||
        service == null ||
        identity == null ||
        !_current) {
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final captured = AttachmentLease.capture(identity);
      final lease = AttachmentLease(
        space: captured.space,
        epoch: captured.epoch,
        clientId: captured.clientId,
        generation: captured.generation,
        isCurrent: () => _current && captured.isCurrent(),
        request: captured.request,
        download: captured.download,
      );
      final result = await service.export(lease, preview);
      if (_current) {
        setState(
          () => _message = switch (result.status) {
            LedgerImageExportStatus.saved =>
              '已保存 ${result.imageCount} 张原图：${result.fileName}',
            LedgerImageExportStatus.downloadStarted =>
              '已开始下载 ${result.imageCount} 张原图，请查看浏览器下载。',
            LedgerImageExportStatus.cancelled => '已取消保存。',
          },
        );
      }
    } on ApiFailure catch (error) {
      if (_current) setState(() => _message = error.message);
    } catch (_) {
      if (_current) setState(() => _message = '导出未完成，请核对权限、文件位置后重新预览。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('批量导出图片')),
        body: !_current
            ? const Center(child: Text('资料空间已切换。'))
            : StreamBuilder<LedgerView>(
                stream: _stream,
                builder: (context, snapshot) {
                  final view = snapshot.data;
                  if (snapshot.hasError) {
                    return const Center(child: Text('账单资料读取失败。'));
                  }
                  if (view == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (widget.ids.any((id) => view.find('bill', id) == null)) {
                    return const Center(child: Text('所选账单或权限已变化，请返回重新选择。'));
                  }
                  final preview = _preview;
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 700),
                      child: ListView(
                        padding: const EdgeInsets.all(24),
                        children: [
                          const Icon(Icons.folder_zip_outlined, size: 64),
                          const SizedBox(height: 24),
                          Text(
                            '导出所选账单的原图',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 12),
                          const Text('重复引用只保存一次，ZIP内使用序号图片名。原图内容保持原样。'),
                          const SizedBox(height: 16),
                          if (_loading) const LinearProgressIndicator(),
                          if (preview != null) ...[
                            Text(
                              '${preview.selectedBillCount} 笔账单 · ${preview.imageCount} 张图片',
                              key: const Key('image-export-count'),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '已知原件大小 ${preview.knownOriginalBytes} 字节${preview.unknownSizeCount > 0 ? '，另有${preview.unknownSizeCount}张需联网读取后核对大小' : ''}',
                            ),
                            const SizedBox(height: 12),
                            if (preview.issues.isNotEmpty)
                              Text(
                                preview.issues.any(
                                      (issue) =>
                                          issue.code ==
                                          'image_export_no_images',
                                    )
                                    ? '所选账单没有图片。请返回选择带图片的账单。'
                                    : '当前选择含不可导出的图片、冲突或失效资料，请同步核对后重新选择。',
                              ),
                          ],
                          const SizedBox(height: 12),
                          const Text(
                            '每次最多1000笔、100张，原图合计20 MiB。导出前会联网复核权限；任一图片不可读时停止整包导出。',
                          ),
                          if (_message != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Text(_message!),
                            ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            key: const Key('confirm-image-export'),
                            onPressed:
                                _busy ||
                                    _loading ||
                                    preview?.canExport != true ||
                                    widget.app.identity?.online != true
                                ? null
                                : _export,
                            icon: const Icon(Icons.download_outlined),
                            label: Text(_busy ? '正在核对并导出…' : '选择位置并导出ZIP'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: _busy || _loading ? null : _load,
                            child: const Text('重新预览'),
                          ),
                          if (widget.app.identity?.online != true)
                            const Text('请联网登录后导出图片。'),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    ),
  );
}
