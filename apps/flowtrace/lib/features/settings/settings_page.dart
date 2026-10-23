import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import '../../core/config/build_profile.dart';
import '../../core/money/money.dart';
import '../../data/preferences/app_preferences.dart';
import '../../data/preferences/preferences_controller.dart';
import '../protection/protection_controller.dart';
import '../protection/protection_settings_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.controller,
    this.preferences,
    this.protection,
    super.key,
  });
  final AppController controller;
  final PreferencesController? preferences;
  final ProtectionController? protection;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _address;
  String? _addressError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _address = TextEditingController(
      text: widget.controller.space?.server.toString(),
    );
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller,
      if (widget.preferences != null) widget.preferences!,
    ]),
    builder: (context, _) => _scaffold(context),
  );

  Widget _scaffold(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置')),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (localTestBuild) ...[
              const Card(
                child: ListTile(
                  leading: Icon(Icons.science_outlined),
                  title: Text('本机测试构建'),
                  subtitle: Text('可连接本机或局域网的 HTTP 测试服务；公网服务仍须使用 HTTPS。'),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (widget.preferences != null) ..._preferenceCards(context),
            if (widget.protection?.supported == true) ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('本机应用保护'),
                  subtitle: const Text('启动和后台遮盖界面，保留完整草稿'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ProtectionSettingsPage(
                        controller: widget.protection!,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Card(
              child: ListTile(
                leading: const Icon(Icons.monitor_heart_outlined),
                title: const Text('本机诊断'),
                subtitle: const Text('查看连接与同步记录，复制脱敏诊断'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pushNamed(context, '/diagnostics'),
              ),
            ),
            const SizedBox(height: 16),
            if (widget.controller.identity != null) ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.import_export_rounded),
                  title: const Text('数据迁移与导出'),
                  subtitle: const Text('预览导入、下载账目、查看与撤销本人迁移批次'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.pushNamed(context, '/data-tools'),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.person_outline_rounded),
                  title: Text(
                    widget.controller.identity!.account?.username ?? '登录账号',
                  ),
                  subtitle: Text(
                    widget.controller.identity!.online
                        ? '账号、可访问账本与登录设备'
                        : '邀请码注册、登录和会话管理',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.pushNamed(context, '/account'),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '自建服务器',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    const Text('切换地址会打开独立资料空间，原地址的草稿仍保留在本机。'),
                    const SizedBox(height: 20),
                    TextField(
                      key: const Key('server-address'),
                      controller: _address,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: '服务器地址',
                        hintText: 'https://your-server.example',
                        errorText: _addressError,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const Key('save-server'),
                      onPressed: _saving
                          ? null
                          : () async {
                              setState(() {
                                _saving = true;
                                _addressError = null;
                              });
                              try {
                                await widget.controller.setServerAddress(
                                  _address.text,
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('地址已保存；已切换到对应资料空间。'),
                                    ),
                                  );
                                }
                              } on FormatException catch (error) {
                                if (mounted) {
                                  setState(() => _addressError = error.message);
                                }
                              } catch (_) {
                                if (mounted) {
                                  setState(
                                    () => _addressError = '保存失败，原资料空间保持不变。',
                                  );
                                }
                              } finally {
                                if (mounted) setState(() => _saving = false);
                              }
                            },
                      child: const Text('保存地址'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: widget.controller.checkingConnection
                          ? null
                          : widget.controller.checkConnection,
                      child: Text(
                        widget.controller.checkingConnection ? '正在检查…' : '检查连接',
                      ),
                    ),
                    if (widget.controller.connectionMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(widget.controller.connectionMessage!),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (widget.preferences == null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: DropdownButtonFormField<ThemeMode>(
                    key: ValueKey(widget.controller.themeMode),
                    initialValue: widget.controller.themeMode,
                    decoration: const InputDecoration(labelText: '外观'),
                    items: const [
                      DropdownMenuItem(
                        value: ThemeMode.dark,
                        child: Text('深色'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.light,
                        child: Text('浅色'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.system,
                        child: Text('跟随系统'),
                      ),
                    ],
                    onChanged: (mode) async {
                      if (mode == null) return;
                      try {
                        await widget.controller.setTheme(mode);
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('外观设置未能保存。')),
                          );
                        }
                      }
                    },
                  ),
                ),
              ),
            const SizedBox(height: 24),
            const Text(
              '流迹 FlowTrace · 0.1.0\n离线记账 · 多端同步 · 自建服务器',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _savePreferences(AppPreferences next) async {
    try {
      await widget.preferences!.update(next);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.preferences?.error ?? '本机设置未能保存，仍使用上次已保存的设置。'),
          ),
        );
      }
    }
  }

  Widget _switch(
    String key,
    String title,
    String subtitle,
    bool value,
    AppPreferences Function(bool) change,
  ) => SwitchListTile.adaptive(
    key: Key(key),
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged:
        !widget.preferences!.ready ||
            widget.preferences!.saving ||
            widget.preferences!.needsRecovery
        ? null
        : (next) => _savePreferences(change(next)),
  );

  List<Widget> _preferenceCards(BuildContext context) {
    final controller = widget.preferences!;
    final value = controller.value;
    final enabled =
        controller.ready && !controller.saving && !controller.needsRecovery;
    final preview = BillPresentation.create(
      preferences: value,
      category: '晚餐',
      parentCategory: '餐饮',
      note: '和朋友一起吃饭',
    );
    final sample = Money('CNY', 2, BigInt.from(123456));
    return [
      const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Text(
          '以下外观、显示与功能入口设置仅保存在此设备或浏览器，不随账号同步。账本币种、月起始日、分类等业务设置在对应账本管理并同步。',
        ),
      ),
      if (controller.error != null) ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(controller.error!),
                if (controller.needsRecovery) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(
                    key: const Key('preferences-restore-defaults'),
                    onPressed: !controller.ready || controller.saving
                        ? null
                        : () async {
                            try {
                              await controller.restoreDefaults();
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('设置恢复未能完成，原始值仍保留。'),
                                  ),
                                );
                              }
                            }
                          },
                    child: const Text('保存默认设置，并保留原值备份'),
                  ),
                ],
                if (!controller.ready) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(
                    key: const Key('preferences-reload'),
                    onPressed: controller.saving
                        ? null
                        : () async {
                            try {
                              await controller.initialize();
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('本机设置仍不能读取，原值未改动。'),
                                  ),
                                );
                              }
                            }
                          },
                    child: const Text('重新读取本机设置'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('主题与显示', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              DropdownButtonFormField<ThemeMode>(
                key: ValueKey('preferences-theme-${value.themeMode.name}'),
                initialValue: value.themeMode,
                decoration: const InputDecoration(labelText: '外观'),
                items: const [
                  DropdownMenuItem(value: ThemeMode.dark, child: Text('深色')),
                  DropdownMenuItem(value: ThemeMode.light, child: Text('浅色')),
                  DropdownMenuItem(
                    value: ThemeMode.system,
                    child: Text('跟随系统'),
                  ),
                ],
                onChanged: !enabled
                    ? null
                    : (mode) {
                        if (mode != null) {
                          _savePreferences(value.copyWith(themeMode: mode));
                        }
                      },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<IncomeExpenseColors>(
                key: ValueKey(
                  'preferences-colors-${value.incomeExpenseColors.name}',
                ),
                initialValue: value.incomeExpenseColors,
                decoration: const InputDecoration(labelText: '收支颜色'),
                items: const [
                  DropdownMenuItem(
                    value: IncomeExpenseColors.expenseRed,
                    child: Text('支出红色 · 收入绿色'),
                  ),
                  DropdownMenuItem(
                    value: IncomeExpenseColors.incomeRed,
                    child: Text('收入红色 · 支出绿色'),
                  ),
                ],
                onChanged: !enabled
                    ? null
                    : (colors) {
                        if (colors != null) {
                          _savePreferences(
                            value.copyWith(incomeExpenseColors: colors),
                          );
                        }
                      },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<bool>(
                key: ValueKey('preferences-week-${value.weekStartsMonday}'),
                initialValue: value.weekStartsMonday,
                decoration: const InputDecoration(labelText: '每周第一天'),
                items: const [
                  DropdownMenuItem(value: true, child: Text('星期一')),
                  DropdownMenuItem(value: false, child: Text('星期日')),
                ],
                onChanged: !enabled
                    ? null
                    : (monday) {
                        if (monday != null) {
                          _savePreferences(
                            value.copyWith(weekStartsMonday: monday),
                          );
                        }
                      },
              ),
              _switch(
                'preferences-thousands',
                '金额千分位',
                '显示分组，不改变账务金额或输入格式',
                value.groupThousands,
                (next) => value.copyWith(groupThousands: next),
              ),
              _switch(
                'preferences-hide-amounts',
                '隐藏金额',
                '在汇总与账单列表中遮盖金额',
                value.hideAmounts,
                (next) => value.copyWith(hideAmounts: next),
              ),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('语言'),
                subtitle: Text('简体中文（当前支持）'),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Text(
                  '账单显示效果',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              ListTile(
                key: const Key('preferences-bill-preview'),
                leading: value.showCategoryIcons
                    ? const Icon(Icons.restaurant_outlined)
                    : null,
                title: Text(preview.title),
                subtitle: preview.subtitle == null
                    ? null
                    : Text(preview.subtitle!),
                trailing: Text(
                  '${value.hideAmounts ? '' : '-'}${value.formatMoney(sample)}',
                  style: TextStyle(color: value.expenseColor),
                ),
              ),
              _switch(
                'preferences-icons',
                '分类图标',
                '账单列表显示分类图标',
                value.showCategoryIcons,
                (next) => value.copyWith(showCategoryIcons: next),
              ),
              _switch(
                'preferences-full-category',
                '完整分类',
                '同时显示一级和二级分类',
                value.showFullCategory,
                (next) => value.copyWith(showFullCategory: next),
              ),
              _switch(
                'preferences-note-first',
                '备注优先',
                '有备注时在标题位置展示备注',
                value.preferNote,
                (next) => value.copyWith(preferNote: next),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                '首页卡片',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            _switch(
              'preferences-home-summary',
              '收支汇总',
              '首页显示本期收入、支出和结余',
              value.showHomeSummary,
              (next) => value.copyWith(showHomeSummary: next),
            ),
            _switch(
              'preferences-home-budget',
              '预算卡片',
              '首页显示预算使用情况',
              value.showHomeBudget,
              (next) => value.copyWith(showHomeBudget: next),
            ),
            _switch(
              'preferences-home-trend',
              '趋势卡片',
              '首页显示本期每日收支趋势',
              value.showHomeTrend,
              (next) => value.copyWith(showHomeTrend: next),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                '功能入口',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text('关闭只简化新建时的入口，已有账单字段和历史记录保留。'),
            ),
            _switch(
              'preferences-assets',
              '资产管理',
              '显示私人资产及账户相关入口',
              value.assetsEnabled,
              (next) => value.copyWith(assetsEnabled: next),
            ),
            _switch(
              'preferences-currencies',
              '多币种',
              '新建账单可选择其他币种',
              value.multiCurrencyEnabled,
              (next) => value.copyWith(multiCurrencyEnabled: next),
            ),
            _switch(
              'preferences-reimbursements',
              '报销',
              '显示报销相关入口',
              value.reimbursementsEnabled,
              (next) => value.copyWith(reimbursementsEnabled: next),
            ),
            _switch(
              'preferences-discount',
              '优惠',
              '新建支出可填写优惠金额',
              value.discountEnabled,
              (next) => value.copyWith(discountEnabled: next),
            ),
            _switch(
              'preferences-bill-time',
              '账单时间',
              '新建账单可精确到具体时刻',
              value.billTimeEnabled,
              (next) => value.copyWith(billTimeEnabled: next),
            ),
            _switch(
              'preferences-images',
              '账单图片',
              '新建账单可添加图片',
              value.billImagesEnabled,
              (next) => value.copyWith(billImagesEnabled: next),
            ),
            _switch(
              'preferences-flags',
              '账单标记',
              '新建账单可独立设置收支与预算标记',
              value.billFlagsEnabled,
              (next) => value.copyWith(billFlagsEnabled: next),
            ),
            _switch(
              'preferences-tags',
              '标签',
              '新建账单可添加标签',
              value.tagsEnabled,
              (next) => value.copyWith(tagsEnabled: next),
            ),
            _switch(
              'preferences-quick-entry',
              '秒开记账',
              '启动并解锁后进入当前账本的记账页',
              value.quickEntry,
              (next) => value.copyWith(quickEntry: next),
            ),
          ],
        ),
      ),
      if (kIsWeb || defaultTargetPlatform == TargetPlatform.windows) ...[
        const SizedBox(height: 16),
        const Card(
          child: ListTile(
            leading: Icon(Icons.devices_outlined),
            title: Text('平台能力'),
            subtitle: Text('此平台使用文件选择与本机保护密码，不提供 Android 桌面小部件、震动反馈或系统生物解锁。'),
          ),
        ),
      ],
      const SizedBox(height: 16),
    ];
  }
}
