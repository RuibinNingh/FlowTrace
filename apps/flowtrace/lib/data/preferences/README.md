# 本机偏好

`AppPreferences` 是版本1的显示与入口配置，使用 `LocalRepository` 的 `app.preferences.v1` 设置保存，不产生 outbox。账本币种、月起始日、分类、私人资产设置仍遵循原有业务同步模型。

`PreferencesController.initialize()` 兼容原 `theme_mode`；成功保存时新 JSON 与旧主题键在一个 `atomicWrite` 中写入，失败不更改界面已生效值。未知版本/损坏 JSON 不自动覆盖，恢复默认时把原值保存到 `app.preferences.recovery.v1`。`AppPreferencesScope.of(context)` 供页面响应偏好变化。

两个标签/页面的 controller 不会用旧整份 JSON 静默覆盖对方修改：每次加载在一致快照读两键，保存/恢复时在事务内对两份原始值做 compare-and-set。冲突不写值或备份，事务外重新读取最新设置并提示重试；用户在新状态上重试后可保留先前页面的选择。旧版本仅修改 `theme_mode` 的写入也会使旧预期失效。此机制防丢更新，不表示账号跨设备设置同步。

`formatMoney(Money)` 只处理精确十进制字符串，支持千分位和金额遮盖；不把分组后的文本写回账务，不经过 double。`BillPresentation.create()` 共用于设置预览和真实账单行的分类/备注优先规则。

| 字段组 | 页面接线点 |
|---|---|
| themeMode | `AppController.setTheme`、`FlowTraceApp.themeMode` |
| incomeExpenseColors/groupThousands/hideAmounts | 首页流水、统计/预算/日历/资产及账单详情的展示；输入仍用原始精确格式 |
| weekStartsMonday | `LedgerCalendar.weekStartsMonday/onWeekStartChanged` |
| showCategoryIcons/showFullCategory/preferNote | 首页与搜索/详情账单行；父分类只取当前已授权实体 |
| showHomeSummary/showHomeBudget/showHomeTrend | 首页汇总和卡片 |
| assets/multiCurrency/reimbursements/discount/time/images/flags/tags | 新建入口、记账可选工具；关闭时原账单字段、历史与资金分录保留 |
| quickEntry | 启动并完成解锁后一次性进入当前可写账本编辑器，不能绕过加载/身份/权限 |

模型与设置页已实现，所有业务页面的实际消费由共享入口/页面集成单独验证。当前界面语言仅简体中文；Web/Windows不显示假震动/小部件/系统生物识别开关。此说明不宣称完整 F19 或全部平台已验收。

测试：`flutter test --no-pub test/preferences`；单独覆盖大整数/精度、预览规则、版本边界、重开、原子失败回滚与保留坏值恢复。

2026-10-22本机偏好9项及保护16项合计25项通过，目标分析无问题（7.1秒）。两独立controller共用真实Drift库的主题/分组竞争、旧恢复覆盖和legacy仅写主题竞争均验证拒绝后重试；它们不代替真实浏览器多标签及全部业务页面显示验收。
