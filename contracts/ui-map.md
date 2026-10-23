# 客户端页面、状态与适配映射 v1

日期：2026-10-21；状态：P0 UI 契约，路由/组件为 FlowTrace 设计，尚非已实现页面。原应用 S 状态只证明相应采集条件中的界面，提交结果仍待补测。来源：[产品范围](../AI/plans/flowtrace/product-scope.md)、[证据矩阵](../AI/plans/flowtrace/evidence-matrix.md)、[机器证据](fixtures/parity/states.json)、[平台预研](../AI/plans/flowtrace/platform-validation.md)。

## 路由与组件约定

- S01–S56 是截图状态，不是56个独立页面。表中的面板/菜单保留触发与返回语义；同一路由的底部面板不强制生成独立全屏页。
- 路由参数 `:bookId/:billId/:planId` 使用规范业务UUID；原型可用命名合成ID，正式API不发送这些命名标签。选中月份、筛选等由状态/查询参数表达，不把本地修改写入浏览器URL。
- 首次服务器入口 `/setup/server`，邀请注册 `/auth/invite`，登录 `/auth/login`，会话 `/settings/sessions`，同步/冲突 `/settings/sync`。自建服务器/用户/资料空间共同隔离本地库和outbox。
- 私人资产入口 `/assets` 与账本成员权限分离；账号退出/服务器切换先处理未传内容；无权限深链接进入安全错误状态，不展示残留私人金额。
- Android窄屏使用抽屉、底部详情和选择面板；宽屏使用相同路由与状态机，可将详情放侧栏、统计与明细并列。键盘焦点/关闭/取消必须回到触发控件，不能因宽屏丢掉确认/校验步骤。

| 组件 | 共用结构与不变量 | 适配/验收 |
|---|---|---|
| LedgerShell/PeriodPicker | 当前账本、月份起始日、汇总/流水；选择期间不改变业务日期 | Android保留抽屉/选择面板；宽屏常驻导航与同一过滤状态 |
| EntryEditor/CategoryGrid/AmountPad | 支出/收入/转账；五列分类，二级插入所在行下，四列金额键盘 | 支持精确输入、保存/再记/取消；Web/Windows数字键盘映射不改金额算法 |
| BillDetailSheet/SelectionToolbar | 详情、复制修改退款删除；批量默认“不变” | 小屏底部面板、宽屏详情区；选择集合/失败项始终可见 |
| MoneyField/MoneyText | amount_minor字符串、币种精度、BigInt、有界范围 | 不用double格式化后再写账；超过2^53及0/2/3位币种验证 |
| ReportDrilldown/BudgetEditor | 图→分类→明细；预算/统计两标记独立 | 空态/零分母/未换汇明确；宽屏不另算报表口径 |
| PlanWizard/JobHistory | 计划预览、发生实例、已执行/未执行、失败状态 | 分期三步、存钱七模式；前后切换保留输入，不把预览当正式入账 |
| RecognitionDraft | 识别→可编辑候选→用户确认→正式保存 | 未确认无账单；Android原生入口和Web/Windows文件入口分别适配 |
| SyncBanner/ConflictReview | 本地保存/待传/已确认/冲突/失败分开呈现 | 旧回执不能覆盖后续本地输入；恢复换epoch先保存完整本地快照 |

## S01–S56 全状态映射

下表的验证点包括界面结构和交互入口；真正保存/同步/账务成功另执行 J/E 场景。面板标题是实现标识，不声称原应用内部类名。

| 状态 | 页面/面板 | 目标路由与局部状态 | 关键对照及验证 |
|---|---|---|---|
| S01 首页 | HomePage | `/books/:bookId/home` | 月汇总、预算、趋势、按日流水、快捷新增 |
| S02 左侧导航 | LedgerDrawer | 首页 drawer | 账本/预算/报销/搜索/任务/存钱/设置入口与返回 |
| S03 月份范围 | PeriodRangeSheet | 首页 period-range | 显示方式、月份起始日、年/月；选择后汇总同步变化 |
| S04 日历/首次提示 | CalendarPage | `/books/:bookId/calendar` | 收支模式、当日流水；首次滑动提示有条件显示 |
| S05 支出编辑 | EntryEditor | `/books/:bookId/entry?type=expense` | 资产关，两页签、五列分类、金额键盘 |
| S06 开资产支出 | EntryEditor | 同上，assets enabled | 账户选择、转账页签与旧记录完整保留 |
| S07 收入编辑 | EntryEditor | `/books/:bookId/entry?type=income` | 收入分类和类型相关工具项 |
| S08 转账编辑 | TransferEditor | `/books/:bookId/entry?type=transfer` | 两账户、方向交换、手续费及权限 |
| S09 二级分类 | ExpandedCategoryRow | 编辑器 category-expanded | 子分类插在对应一级行下，选择/收起保持位置 |
| S10 账单标记 | BillFlagsSheet | 编辑器 flags | 不计收支/不计预算为独立开关 |
| S11 账单详情 | BillDetailSheet | `/books/:bookId/bills/:billId` | 复制、退款、修改、删除；关闭回到原列表位置 |
| S12 退款表单 | RefundEditor | `/books/:bookId/bills/:billId/refund` | 源单、到账账户/日期/金额/备注/图片；结果另测 |
| S13 批量选择 | BillSelection | 首页/搜索 selection | 多选、工具栏、数量和取消选择 |
| S14 批量修改 | BatchEditSheet | 选择态 batch-edit | 默认不变，作用集合与修改字段预览 |
| S15 分类管理 | CategoryManager | `/books/:bookId/categories` | 收支分栏、层级、长按排序、行菜单 |
| S16 新增分类 | CategoryEditor | 分类 create | 名称/批量、图标分类/检索；编辑/删除/转换补测 |
| S17 标签管理 | TagManager | `/books/:bookId/tags` | 启用/归档、标签/分组入口 |
| S18 新增标签 | TagEditor | 标签 create | 名称与颜色；取消不保存 |
| S19 月度统计 | StatisticsPage | `/books/:bookId/statistics` | 汇总、每日图、分类图 |
| S20 统计下半 | StatisticsPage | 同页 category/daily sections | 分类占比、环比、日报，滚动位置与下钻 |
| S21 分类明细 | CategoryBillsSheet | 统计 category-details | 该分类账单列表/返回，金额能追溯 |
| S22 单分类统计 | CategoryTrendPage | `/books/:bookId/statistics/category/:categoryId` | 年/月、笔数、均值和明细 |
| S23 预算总览 | BudgetPage | `/books/:bookId/budgets` | 月/年、总/分类预算与趋势 |
| S24 预算金额 | BudgetAmountSheet | 预算 edit-amount | 输入、取消、校验及保存结果另测 |
| S25 账本管理 | BookManager | `/books` | 账本卡片、当前账本、新增 |
| S26 新增方式 | BookCreateMethodSheet | 账本 create-method | 新建、仅复制设置、加入他人账本 |
| S27 新建账本 | BookEditor | `/books/new` | 封面/类型/名称/显示/月起始日 |
| S28 账本模板 | BookTemplatePicker | 新建 template | 日常/旅行/装修/婚礼/出差等；不复制流水 |
| S29 分期管理 | ScheduledPlansPage | `/plans/installments` | 分期/周期为页签，保留各自状态 |
| S30 分期第一步 | InstallmentWizard | `/plans/installments/new` step1 | 三步指示、名称和扣款账户；后续布局为C |
| S31 周期表单 | RecurringEditor | `/plans/recurring/new` | 开始/周期/结束、账本分类金额等 |
| S32 重复周期 | RecurrencePicker | 周期 repeat-picker | 天周月年/N天/法定工作日；日历不可用显式提示 |
| S33 结束方式 | RecurrenceEndPicker | 周期 end-picker | 永不、日期、次数三种 |
| S34 存钱空态 | SavingsPage | `/plans/savings` | 空态说明与新增，不显示伪进度 |
| S35 存钱模式 | SavingsModePicker | 存钱 create-mode | 灵活/365/52周/逆向/定额/12存单/36存单 |
| S36 灵活存钱 | SavingsEditor | `/plans/savings/new?mode=flexible` | 目标、币种、开始/截止；其他模式需补测 |
| S37 资产总览 | AssetsPage | `/assets` | 净资产/资产/负债/借入/借出，私人权限 |
| S38 账户类型上 | AccountTypePicker | 资产 account-type | 资金与信用卡 |
| S39 账户类型下 | AccountTypePicker | 同面板 lower-section | 充值/投资/债务 |
| S40 银行搜索 | BankPicker | `/assets/new?type=credit_card` bank | 银行检索选择，取消保留账户草稿 |
| S41 信用卡字段 | CreditAccountEditor | 同路由 fields | 额度/欠款/账单日/还款日/计入总资产 |
| S42 自动记账入口 | AutoEntryHub | `/settings/auto-entry` | 无障碍/截图两入口及通用设置 |
| S43 无障碍配置 | AccessibilitySetup | `/settings/auto-entry/accessibility` | 权限、后台、可选AI和适配说明；不默认开启 |
| S44 截图配置 | ScreenshotSetup | `/settings/auto-entry/screenshot` | 分享、本地OCR、脱敏；进入候选草稿 |
| S45 设置上半 | SettingsPage | `/settings` | 主题、小部件、功能开关 |
| S46 数据工具 | SettingsPage | 同页 data section | 标签、导入导出、保护、显示 |
| S47 显示效果 | BillDisplaySettings | `/settings/bill-display` | 图标/完整分类/备注优先与示例预览 |
| S48 导入入口 | ImportPage | `/data/import` | 教程、历史、文件选择；预览不写账 |
| S49 导出选项 | ExportPage | `/data/export` | 格式、排序、账本、高级筛选 |
| S50 导出格式 | ExportFormatSheet | 导出 format-picker | 已观察XLSX/JSON；CSV导出不伪称原UI选项 |
| S51 报销升级提示 | Reimbursement/MigrationGate | `/books/:bookId/reimbursements` | 参照只见旧数据升级门槛；流迹新库不伪造升级，真实迁移才显示兼容说明 |
| S52 实验室 | DiagnosticsPage | `/settings/diagnostics` | 同步诊断/日志/连接状态，用户不见密钥或私人原文 |
| S53 资产操作 | AssetsActions | 资产 actions-menu | 新增/分组/已隐藏账户 |
| S54 自动适配说明 | SupportedSourcesPage | `/settings/auto-entry/sources` | 支持应用/页面范围与限制，未实测不标已适配 |
| S55 搜索账单 | BillSearchPage | `/search` | 时间/账本/关键词、结果汇总/按日流水 |
| S56 搜索筛选 | BillFilterSheet | 搜索 filters | 标签分类金额图片来源类型及统计标记 |

## 通用状态、桌面与管理端

ST01–ST10 的权威定义在产品分册。各页面按适用性覆盖空态、加载、校验、失败、离线、只读/撤权、冲突、未保存返回、处理中/完成及平台能力受限；禁止用一次静态截图证明这些状态均通过。保存按钮忙态仍由operation_id保障幂等，不能只靠禁按钮。

Web/Windows沿用同一页面/状态机，主明细并列后仍保留源账本/币种/权限边界。系统文件选择/拖入、键盘输入、焦点/返回、深链接刷新和窗口重开分别验收；Web不调用dart:io，不将Android原生权限开关伪装可用。

新增服务器后台位于 `/admin`，由 Python/Jinja2 实现。A01–A07分别有登录概况、用户邀请、角色、同步作业、备份恢复、存储配置、审计诊断的真实浏览器旅程。后台导航、权限与用户Flutter路由独立，普通管理员不能因看到状态就下载原始备份/恢复或读取私人账单。

实际验收使用 [J01–J12合成场景](fixtures/scenarios/journeys.json)、[任务E01–E20](../AI/plans/flowtrace/tasks.md)与 [测试入口](../tests/README.md)；每个状态的本地证据及U项保持可追溯。
