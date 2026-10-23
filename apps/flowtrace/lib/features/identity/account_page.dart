import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/network/api_failure.dart';
import 'identity_controller.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({required this.app, super.key});
  final AppController app;
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _invite = TextEditingController();
  bool _register = false;
  bool _submitting = false;
  String? _error;
  IdentityController get identity => widget.app.identity!;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _invite.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await action();
    } on ApiFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，请稍后重试。');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    await _perform(() async {
      await identity.signIn(
        username: _username.text,
        password: _password.text,
        inviteToken: _register ? _invite.text : null,
      );
      _password.clear();
      _invite.clear();
    });
  }

  Future<bool> _confirm(String title, String body) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor:
          DialogTheme.of(context).barrierColor ??
          Theme.of(context).dialogTheme.barrierColor ??
          Colors.black54,
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    final result = await navigator.push(route);
    // A popped result precedes the reverse animation and modal semantics
    // barrier removal. Replace identity-dependent controls only after both
    // the barrier and its focus scope have left the overlay.
    await route.completed;
    return mounted && result == true;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: identity,
    builder: (context, _) {
      final account = identity.account;
      final disabled = _submitting || identity.busy;
      return Scaffold(
        appBar: AppBar(title: const Text('账号与设备')),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              key: ValueKey(
                (account?.sessionId ?? 'signed-out') + identity.status.name,
              ),
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  identity.server.toString(),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                if (identity.busy) const LinearProgressIndicator(),
                if (_error != null || identity.message != null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _error ?? identity.message!,
                        key: const Key('identity-message'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (identity.credentialCleanupFailed)
                  OutlinedButton(
                    onPressed: disabled
                        ? null
                        : () => _perform(identity.retryCredentialCleanup),
                    child: const Text('重试清除保存的凭据'),
                  ),
                if (account != null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const CircleAvatar(
                                child: Icon(Icons.person_outline_rounded),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      account.username,
                                      key: const Key('signed-in-username'),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleLarge,
                                    ),
                                    Text(
                                      identity.online
                                          ? '已连接 · 此账号资料独立保存'
                                          : '离线 · 会话待验证',
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          const Text('未登录草稿保留在原资料空间；登录后不会自动搬入或提交。'),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: disabled
                                    ? null
                                    : () => _perform(
                                        identity.online
                                            ? identity.loadOverview
                                            : () => identity.configure(
                                                identity.server!,
                                              ),
                                      ),
                                child: Text(
                                  identity.online ? '刷新账号资料' : '重新联网验证',
                                ),
                              ),
                              TextButton(
                                key: const Key('sign-out'),
                                onPressed: disabled
                                    ? null
                                    : () async {
                                        if (await _confirm(
                                          '退出此设备？',
                                          '本机草稿仍保留在对应账号空间。联网时同时撤销此设备会话。',
                                        )) {
                                          await _perform(identity.signOut);
                                        }
                                      },
                                child: const Text('退出登录'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (account != null) ...[
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.sync_rounded),
                      title: const Text('同步与恢复'),
                      subtitle: const Text('待传记录、冲突处理与恢复备份'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pushNamed(context, '/sync'),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (!identity.online) _loginForm(disabled),
                if (identity.online) ...[
                  Text('可访问账本', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (identity.books.isEmpty)
                    const Card(
                      child: ListTile(
                        title: Text('还没有可访问账本'),
                        subtitle: Text('账本与成员功能按计划继续接入。'),
                      ),
                    ),
                  for (final book in identity.books)
                    Card(
                      child: ListTile(
                        leading: Icon(
                          book.shared
                              ? Icons.group_outlined
                              : Icons.book_outlined,
                        ),
                        title: Text(book.name),
                        subtitle: Text(
                          '${book.shared ? '共享账本' : '私人账本'} · ${switch (book.role) {
                            'owner' => '所有者',
                            'editor' => '可编辑',
                            'viewer' => '只读',
                            _ => '权限待确认',
                          }} · ${book.currency}',
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  Text('登录设备', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (final session in identity.sessions)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.devices_outlined),
                        title: Text(session.deviceName),
                        subtitle: Text(
                          (session.id == account?.sessionId ? '当前设备 · ' : '') +
                              (session.revoked
                                  ? '已撤销'
                                  : '有效至 ${session.expiresAt.toLocal().toIso8601String().substring(0, 16).replaceFirst('T', ' ')}'),
                        ),
                        trailing: session.revoked
                            ? null
                            : TextButton(
                                key: ValueKey('revoke-session-${session.id}'),
                                onPressed: disabled
                                    ? null
                                    : () async {
                                        if (await _confirm(
                                          session.id == account?.sessionId
                                              ? '撤销当前设备并退出？'
                                              : '撤销此设备会话？',
                                          '撤销后该会话的在线请求将被拒绝，本地已复制资料无法远程收回。',
                                        )) {
                                          await _perform(
                                            () => identity.revokeSession(
                                              session.id,
                                            ),
                                          );
                                        }
                                      },
                                child: const Text('撤销'),
                              ),
                      ),
                    ),
                ],
                const SizedBox(height: 24),
                const Text(
                  '密码不会保存到本机。账号与服务器切换使用独立资料空间。',
                  style: TextStyle(color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _loginForm(bool disabled) => Card(
    // Progress and status rows can change this child's sliver index. Keep the
    // form's card ancestor stable instead of grafting its global-key subtree.
    key: const Key('auth-form-card'),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('登录')),
                ButtonSegment(value: true, label: Text('邀请码注册')),
              ],
              selected: {_register},
              onSelectionChanged: disabled
                  ? null
                  : (value) => setState(() {
                      _register = value.single;
                      _error = null;
                    }),
            ),
            const SizedBox(height: 22),
            TextFormField(
              key: const Key('auth-username'),
              controller: _username,
              enabled: !disabled,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '用户名',
                helperText: '3–64位英文、数字、下划线、点或短横线',
              ),
              validator: (value) =>
                  value == null ||
                      !RegExp(
                        r'^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$',
                      ).hasMatch(value.trim())
                  ? '请输入符合格式的用户名'
                  : null,
            ),
            const SizedBox(height: 18),
            TextFormField(
              key: const Key('auth-password'),
              controller: _password,
              enabled: !disabled,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '密码',
                helperText: '12–256个字符',
              ),
              validator: (value) =>
                  value == null || value.length < 12 || value.length > 256
                  ? '密码长度应为12–256个字符'
                  : null,
              onFieldSubmitted: (_) => disabled ? null : _submit(),
            ),
            if (_register) ...[
              const SizedBox(height: 18),
              TextFormField(
                key: const Key('auth-invite'),
                controller: _invite,
                enabled: !disabled,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '一次性邀请码'),
                validator: (value) =>
                    value == null ||
                        value.trim().length < 20 ||
                        value.trim().length > 128
                    ? '请输入有效邀请码'
                    : null,
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('submit-auth'),
              onPressed: disabled ? null : _submit,
              child: Text(
                disabled
                    ? '正在处理…'
                    : _register
                    ? '兑换邀请码并注册'
                    : '登录',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
