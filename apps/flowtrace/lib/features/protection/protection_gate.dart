import 'dart:async';

import 'package:flutter/material.dart';

import 'protection_controller.dart';

/// Place outside the Navigator (MaterialApp.builder). Its child remains mounted
/// while concealed, so even a failed draft flush does not dispose user input.
class AppProtectionGate extends StatefulWidget {
  const AppProtectionGate({
    required this.controller,
    required this.child,
    super.key,
  });
  final ProtectionController controller;
  final Widget child;
  @override
  State<AppProtectionGate> createState() => _AppProtectionGateState();
}

class _AppProtectionGateState extends State<AppProtectionGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (widget.controller.enabled || widget.controller.busy) {
        FocusManager.instance.primaryFocus?.unfocus();
        unawaited(widget.controller.lock());
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final concealed =
          widget.controller.supported &&
          (!widget.controller.ready || widget.controller.locked);
      return SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            FocusScope(
              canRequestFocus: !concealed,
              child: ExcludeSemantics(
                excluding: concealed,
                child: Offstage(offstage: concealed, child: widget.child),
              ),
            ),
            if (concealed)
              Positioned.fill(
                child: BlockSemantics(
                  child: Overlay.wrap(
                    child: _UnlockView(controller: widget.controller),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _UnlockView extends StatefulWidget {
  const _UnlockView({required this.controller});
  final ProtectionController controller;
  @override
  State<_UnlockView> createState() => _UnlockViewState();
}

class _UnlockViewState extends State<_UnlockView> {
  final _password = TextEditingController();
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final input = _password.text;
    _password.clear();
    await widget.controller.unlock(input);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final cooldown =
        controller.retryAfter.inSeconds +
        (controller.retryAfter.inMilliseconds % 1000 == 0 ? 0 : 1);
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 52,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '流迹已锁定',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '输入本机保护密码继续。此密码与服务器登录密码独立。',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (controller.ready &&
                      controller.enabled &&
                      controller.available) ...[
                    TextField(
                      key: const Key('protection-unlock-password'),
                      controller: _password,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      maxLength: 128,
                      enabled: !controller.busy && cooldown == 0,
                      decoration: const InputDecoration(
                        labelText: '本机保护密码',
                        counterText: '',
                      ),
                      onSubmitted: (_) => _unlock(),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const Key('protection-unlock'),
                      onPressed: controller.busy || cooldown > 0
                          ? null
                          : _unlock,
                      child: Text(
                        controller.busy
                            ? '正在验证…'
                            : cooldown > 0
                            ? '$cooldown秒后重试'
                            : '解锁',
                      ),
                    ),
                  ],
                  if (controller.error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      controller.error!,
                      key: const Key('protection-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (controller.draftWarning != null) ...[
                    const SizedBox(height: 12),
                    Text(controller.draftWarning!),
                  ],
                  if (!controller.ready ||
                      !controller.enabled ||
                      !controller.available) ...[
                    const SizedBox(height: 16),
                    OutlinedButton(
                      key: const Key('protection-retry-load'),
                      onPressed: controller.busy ? null : controller.initialize,
                      child: const Text('重新读取保护设置'),
                    ),
                  ],
                  const SizedBox(height: 24),
                  const Text(
                    '本机锁只遮盖应用界面，不替代系统用户安全或数据加密。忘记密码时请保留本地资料，联系维护者恢复；清除站点或应用数据会丢失未同步内容。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
