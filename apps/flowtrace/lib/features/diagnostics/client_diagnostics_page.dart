import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/config/data_space.dart';
import '../../data/diagnostics/client_diagnostics.dart';

class ClientDiagnosticsPage extends StatefulWidget {
  const ClientDiagnosticsPage({
    super.key,
    required this.diagnostics,
    required this.space,
    required this.isCurrent,
  });
  final ClientDiagnostics diagnostics;
  final DataSpace space;
  final bool Function() isCurrent;
  @override
  State<ClientDiagnosticsPage> createState() => _ClientDiagnosticsPageState();
}

class _ClientDiagnosticsPageState extends State<ClientDiagnosticsPage> {
  List<Map<String, Object?>>? _records;
  String? _error;
  int _generation = 0;
  bool _copying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ClientDiagnosticsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.space.id != widget.space.id ||
        oldWidget.diagnostics != widget.diagnostics) {
      _records = null;
      _error = null;
      _copying = false;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final records = await widget.diagnostics.read(widget.space);
      if (!mounted || generation != _generation || !widget.isCurrent()) return;
      setState(() {
        _records = records;
        _error = null;
      });
    } catch (_) {
      if (mounted && generation == _generation && widget.isCurrent()) {
        setState(() {
          _error = '本机诊断暂时不可读，请重试。';
        });
      }
    }
  }

  Future<void> _copy() async {
    if (_copying || !widget.isCurrent()) return;
    final generation = _generation;
    setState(() => _copying = true);
    try {
      final text = await widget.diagnostics.exportJsonl(widget.space);
      if (!mounted || generation != _generation || !widget.isCurrent()) return;
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted && generation == _generation && widget.isCurrent()) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已复制脱敏诊断')));
      }
    } catch (_) {
      if (mounted && generation == _generation && widget.isCurrent()) {
        setState(() => _error = '诊断未复制，请重试。');
      }
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  static const _labels = {
    'http_response': '网络请求',
    'attachment_staged': '附件已本机暂存',
    'attachment_ready': '附件已上传',
    'attachment_upload_failed': '附件上传未完成',
    'attachment_downloaded': '附件已校验下载',
    'scope_revoked': '范围权限已撤销',
    'sync_started': '同步开始',
    'sync_completed': '同步结束',
    'sync_failed': '同步未完成',
    'sync_conflict': '同步待处理冲突',
    'sync_receipt': '已核验同步回执',
    'recovery_required': '本机资料待恢复核对',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('本机诊断'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('仅保存本机辅助元数据，最多100条、32 KiB。没有图片、账单正文或登录凭据。'),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _copying ? null : _copy,
          icon: const Icon(Icons.copy),
          label: Text(_copying ? '正在复制…' : '复制脱敏诊断'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error!),
          ),
        if (_records == null && _error == null)
          const Center(child: CircularProgressIndicator()),
        if (_records?.isEmpty == true)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Text('暂无本机诊断记录'),
          ),
        for (final record
            in (_records ?? const <Map<String, Object?>>[]).reversed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_labels[record['event']] ?? '诊断事件'),
            subtitle: Text(
              [
                record['time_utc'],
                record['code'],
                if (record['request_id'] != null) '请求 ${record['request_id']}',
                if (record['operation_id'] != null)
                  '操作 ${record['operation_id']}',
                if (record['status'] != null) 'HTTP ${record['status']}',
              ].whereType<String>().join('\n'),
            ),
          ),
      ],
    ),
  );
}
