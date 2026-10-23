import 'package:flutter/material.dart';

import 'protection_controller.dart';

class ProtectionSettingsPage extends StatefulWidget {
  const ProtectionSettingsPage({required this.controller, super.key});
  final ProtectionController controller;
  @override
  State<ProtectionSettingsPage> createState() => _ProtectionSettingsPageState();
}

class _ProtectionSettingsPageState extends State<ProtectionSettingsPage> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  String? _validation;
  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save({bool disable = false}) async {
    if (!disable && _next.text != _confirm.text) {
      setState(() => _validation = '两次输入的保护密码不一致。');
      return;
    }
    setState(() => _validation = null);
    final current = _current.text, next = _next.text;
    _current.clear();
    _next.clear();
    _confirm.clear();
    final saved = disable
        ? await widget.controller.disable(current)
        : await widget.controller.setPassword(next, currentPassword: current);
    if (!mounted) return;
    if (saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(disable ? '已关闭本机保护。' : '本机保护密码已保存。')),
      );
    }
  }

  Widget _field(String key, String label, TextEditingController editor) =>
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: TextField(
          key: Key(key),
          controller: editor,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: 128,
          enabled: !widget.controller.busy,
          decoration: InputDecoration(labelText: label, counterText: ''),
        ),
      );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      return Scaffold(
        appBar: AppBar(title: const Text('本机应用保护')),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          controller.enabled ? '本机保护已开启' : '本机保护未开启',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '仅此设备或浏览器。开启后，启动和切到后台会遮盖应用界面；已有页面与未保存草稿保留，解锁后继续。',
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '本机保护不加密账单数据库，也不替代服务器权限。Web资料可被同源脚本或有权访问浏览器资料的人读取；请继续使用可信网站与系统账号。当前 Web/Windows 使用保护密码，不调用系统生物识别。',
                        ),
                        if (!controller.supported) ...[
                          const SizedBox(height: 12),
                          const Text('当前平台的专属保护适配尚未启用。'),
                        ] else ...[
                          if (controller.enabled)
                            _field(
                              'protection-current-password',
                              '当前本机保护密码',
                              _current,
                            ),
                          _field(
                            'protection-new-password',
                            '新保护密码（8–128个字符）',
                            _next,
                          ),
                          _field(
                            'protection-confirm-password',
                            '再次输入新保护密码',
                            _confirm,
                          ),
                          if (_validation != null ||
                              controller.error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _validation ?? controller.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          FilledButton(
                            key: const Key('protection-save-password'),
                            onPressed: controller.busy || !controller.ready
                                ? null
                                : () => _save(),
                            child: Text(
                              controller.busy
                                  ? '正在处理…'
                                  : controller.enabled
                                  ? '更改保护密码'
                                  : '开启本机保护',
                            ),
                          ),
                          if (controller.enabled) ...[
                            const SizedBox(height: 8),
                            OutlinedButton(
                              key: const Key('protection-disable'),
                              onPressed: controller.busy
                                  ? null
                                  : () => _save(disable: true),
                              child: const Text('验证当前密码并关闭保护'),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              key: const Key('protection-lock-now'),
                              onPressed: controller.busy
                                  ? null
                                  : controller.lock,
                              icon: const Icon(Icons.lock_outline),
                              label: const Text('立即锁定'),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
