# FlowTrace 仓库协作准则

> **当前生产包授权（2026-10-24，Asia/Shanghai）**：用户已明确授权连接 `root@192.168.0.145` 读取服务器 wiki，并将 Alpha 部署至 `home.ruibin-ningh.top`。这覆盖此前本包“不部署生产”的限制；本轮安卓测试已取消，复用已冻结 APK 交付。当前按 Alpha 最终部署收尾，不代表完整钱迹功能或长期 P0–P8 已全部完成。恢复时先读 [当前进度](AI/plans/flowtrace/progress.md)，再读 [生产部署模块](AI/modules/production-deployment.md) 与 [Linux 运行手册](deployment/linux/README.md)。已授权本地恢复提交，未授权 Git 推送。

## 开始任务前

- 从 [AI/README.md](AI/README.md) 按任务定位文档，先读相关模块的速查头。
- 运行 `git status --short --branch`，保留用户已有修改。没有提交时，以实际工作区文件为基线，明确说明尚无提交基线。
- 续作跨轮计划时，先读 `AI/plans/主题/progress.md` 的当前状态与下一步，再读对应的 `plan.md`。
- 当前代码、测试和配置提供现状证据；未实施目标放在计划中。发现相关文档过时，在本任务同步。
- 项目文档默认使用简体中文，任务日期采用 `Asia/Shanghai`。

## 执行范围

按用户要求和实际工具能力连续完成工作，常规实现选择自行判断。保留用户原话与验收目标，额外改进单列为可选；缺少必需信息时说明事实差异与阻碍。

保护已有调研材料和无关修改。测试使用隔离数据和独立端口。提交、推送、外部发布及生产操作遵循用户已有授权，不能仅凭工具可用推定授权。

### 当前 Alpha 里程碑约束（2026-10-24）

当前目标为复用已冻结 Windows、Web、Android APK 完成 Linux 生产部署与 Alpha 最终交付；原独立本地测试服务方案保留为历史。完整功能计划保留为后续目标，暂停交付非必需的新功能。当前工作包和接收条件见[Alpha里程碑](AI/plans/flowtrace/alpha-milestones.md)。

- 已授权建立可恢复的本地提交及上述 Linux 生产包；不推送。此前“不部署生产”是已被最新授权覆盖的历史限制。
- 每批同时最多2个子代理，每位只负责一个明确工作包；不得自行扩大范围。
- 修改后先做针对性验证，完整回归只在阶段集成执行，已有证据不无故重跑。
- 必须处理严重账务一致性、安全及启动问题；非阻断项集中记入工作区待办，不阻碍Alpha交付。
- 仅在工作包完成或关键阻断时更新日志和计划，不反复改写历史记录。
- 当前已授权生产包内连续完成必要验证与收尾；完成后返回实际产物、验证、遗留问题和当前额度，再由用户决定是否进入下一包；不得连续开启其他工作包。
- 复杂故障最多两轮有证据的定位与修复；仍失败则停止扩大调查，交付阻断和复现步骤。
- 额度不足时停止扩展，先保存成果与交接；额度接口不可用时明确未知，不估算为充足。

## 文档与任务记录

- 模块文档描述当前行为，标题后保留职责、入口、不变量、必跑测试、相关材料五行速查。
- 仓库发生持久化改动时，在 `AI/logs/` 新建或续写当前任务记录，格式和历史保护规则以 [任务日志约定](AI/logs/README.md) 为准。
- 只读答疑不制造空日志。模块文档、任务日志和计划进度各自维护现状、任务证据和恢复位置。
- 跨阶段任务按 [计划约定](AI/plans/README.md) 保存用户目标、范围、验收、进度和下一项具体动作。
- 可复用模板位于 [项目内 skill](.agents/skills/repo-collaboration-logging/SKILL.md)。模板占位符只允许留在模板中，实际项目文档必须填入事实。
- 已知缺口集中登记在 [工作区说明](AI/modules/workspace.md)；其他文档通过链接引用。

## 改动到文档映射

下表是唯一映射入口。逐份核对相关文档；内容确实受影响时同步，仍准确时在任务记录说明核对结果，不为满足映射制造空改动。

| 改动范围 | 必须核对并同步的文档 | 条件附加项 |
|---|---|---|
| 根目录结构、`README.md`、`.gitignore` | `AI/modules/workspace.md` | 导航入口变化时同步 `AI/README.md` |
| `AGENTS.md`、`.agents/skills/repo-collaboration-logging/` | `AI/README.md` | 日志或计划规则变化时同步对应目录的 `README.md` |
| `AI/modules/` | `AI/README.md` | 模块职责或路径变化时更新本表 |
| 任务日志格式与生命周期 | `AI/logs/README.md` | 不追溯改写已交付历史 |
| 计划与进度约定 | `AI/plans/README.md` | 有进行中计划时同步其目标与恢复入口 |
| `contracts/`、`tests/contracts/` | `AI/modules/contracts.md` | 接口实现变化核对服务端导出契约；范围变化更新计划与进度 |
| `server/` | `AI/modules/server.md` | API 导出变化同步 `contracts/openapi.json`，共享规则核对 contracts 模块 |
| `server/src/flowtrace_server/jobs/`、`server/src/flowtrace_server/worker/`、`server/tests/jobs/` | `AI/modules/jobs.md` | 租约/状态核对作业契约；真实业务handler复核当前授权、幂等和同事务效果；管理页面另核对后台模块 |
| `server/src/flowtrace_server/configuration/`、`server/tests/configuration/`、`server/src/flowtrace_server/admin/configuration_forms.py` | `AI/modules/configuration.md` | 配置只有闭集字段/版本CAS；实际消费者核对身份/附件/jobs；密钥不回显，后台页面需真实浏览器验证 |
| `deployment/local-test/`、`server/src/flowtrace_server/tools/local_test_service.py`、`tests/e2e/local-test/` | `AI/modules/local-test-deployment.md` | 准备与真实安装/启动/自启分开；独立cluster/端口/资料，核对产物hash、进程身份与受控备份，实际持久性须最终验收 |
| `deployment/linux/` | `AI/modules/production-deployment.md` | 生产操作按具体授权；核对独立数据库/身份、版本与hash、systemd、HTTPS及网络入口，配置持久化与实际重启/恢复验收分开 |
| `server/src/flowtrace_server/imports/`、`server/src/flowtrace_server/exports/`、`server/src/flowtrace_server/backups/`、`server/src/flowtrace_server/persistence/maintenance.py`、`server/tests/data_tools/`、`server/tests/backup_retention/`、`tests/e2e/import_restore/`、`apps/flowtrace/lib/data/data_tools/`、`apps/flowtrace/lib/features/data_tools/`、`apps/flowtrace/test/data_tools/` | `AI/modules/data-tools.md` | 金融/附件移转核对同步与附件规则；备份恢复须全新隔离目标与维护窗口证据；客户端回执/本机刷新分开，文件选择与下载需真实平台验证 |
| `server/src/flowtrace_server/admin/`、`tests/e2e/admin/` | `AI/modules/admin.md` | 访问权限变化核对服务端/权限契约；页面用真实浏览器验证 |
| `server/src/flowtrace_server/sync/`、`server/tests/sync/`、`tests/e2e/sync/` | `AI/modules/sync.md` | 对照客户端同步模块、共享协议及实际OpenAPI |
| `server/src/flowtrace_server/attachments/`、`apps/flowtrace/lib/data/attachments/`、`apps/flowtrace/lib/features/attachments/` | `AI/modules/attachments.md` | 上传票据/清理策略核对附件契约与迁移 |
| `server/src/flowtrace_server/diagnostics/`、`apps/flowtrace/lib/data/diagnostics/`、`apps/flowtrace/lib/features/diagnostics/`、`apps/flowtrace/test/diagnostics/` | `AI/modules/diagnostics.md` | 导出路径需授权/脱敏验证，私有运行数据不入版本 |
| `apps/flowtrace/`、`tests/e2e/client-web/` | `AI/modules/client.md` | 平台/持久化改变核对平台验证与共享契约 |
| `apps/flowtrace/lib/data/preferences/`、`apps/flowtrace/lib/features/settings/`、`apps/flowtrace/lib/features/protection/`、`apps/flowtrace/test/preferences/`、`apps/flowtrace/test/protection/` | `AI/modules/preferences.md` | 本机/同步区分、失败草稿和跨标签保护核对；功能显示开关需实际业务页消费 |
| `apps/flowtrace/web/`、`apps/flowtrace/tool/web_release/`、`apps/flowtrace/lib/platform/web/`、`deployment/web/`、`tests/e2e/web/` | `AI/modules/web.md` | 实际Flutter离线/更新与多标签验证，不以合成壳替代业务 |
| `apps/flowtrace/windows/`、`apps/flowtrace/lib/platform/windows/`、`apps/flowtrace/test/windows/`、`deployment/windows/`、`tests/e2e/windows/` | `AI/modules/windows.md` | 正式数据目录/租约、原生包清单与升级保持核对；签名/发布状态明示 |
| `apps/flowtrace/lib/features/home/`、`apps/flowtrace/lib/features/entry/`、`apps/flowtrace/lib/features/assets/`、`apps/flowtrace/test/entry/` | `AI/modules/entry.md` | 正式写入核对本地账务与同步模块，主路径需Android实测 |
| `apps/flowtrace/lib/data/ledger/`、`apps/flowtrace/test/ledger/` | `AI/modules/ledger-data.md` | 离线余额与完整草稿核对领域、同步及恢复备份 |
| `contracts/refund-reimbursement-v1.md`、`server/tests/sync/test_receipt_tracking.py`、`apps/flowtrace/lib/domain/receipts/`、`apps/flowtrace/lib/data/receipts/`、`apps/flowtrace/test/receipts/`、`apps/flowtrace/test/domain/receipt_state_test.dart` | `AI/modules/reimbursements.md` | 追踪仅metadata，source summary核对当前授权/修订与守恒；旧raw/hash/冻结请求兼容，完整回款UI和原子重构单独验收 |
| `apps/flowtrace/lib/domain/assets/`、`apps/flowtrace/lib/data/assets/`、`apps/flowtrace/lib/features/assets/`、`apps/flowtrace/test/assets/`、`server/src/flowtrace_server/assets/` | `AI/modules/assets.md` | 私有分组/资产明细核对权限与恢复备份；历史日期、估值和信用卡规则核对资产契约及黄金样本 |
| `apps/flowtrace/lib/features/currencies/`、`apps/flowtrace/lib/core/money/currency_catalog.dart`、`apps/flowtrace/tool/update_currency_catalog.py`、`server/src/flowtrace_server/currencies/`、`contracts/fixtures/assets/catalogs.json` | `AI/modules/currencies.md` | 两端冻结目录/精度一致，历史交易汇率与资产估值分离；私人配置核对资产模块与恢复备份 |
| `apps/flowtrace/lib/features/management/`、`apps/flowtrace/test/management/` | `AI/modules/management.md` | 管理字段/角色核对共享契约，模板只复制设置 |
| `apps/flowtrace/lib/features/search/`、`apps/flowtrace/lib/features/transactions/`、`apps/flowtrace/test/entry/search_page_test.dart`、`apps/flowtrace/test/entry/book_move_page_test.dart` | `AI/modules/transactions.md` | 预览/确认与查询口径核对本地账务模块及Android操作证据 |
| `apps/flowtrace/lib/data/local/`、`apps/flowtrace/lib/data/sync/`、`apps/flowtrace/lib/features/sync/`、`apps/flowtrace/test/data/`、`apps/flowtrace/test/sync/` | `AI/modules/client-sync.md` | 持久化及同步变化核对协议与真实两端联测 |
| 两端 `domain/` 与客户端 `core/money/` | `AI/modules/ledger.md` | 规则变更同时核对共享夹具与两端测试 |
| `server/src/flowtrace_server/reports/`、`server/src/flowtrace_server/domain/reporting.py`、`apps/flowtrace/lib/domain/reporting/` | `AI/modules/reporting.md` | 读取授权核对sync scope与实际OpenAPI，金额口径核对黄金样本 |
| `apps/flowtrace/lib/features/statistics/`、`apps/flowtrace/lib/features/calendar/`、`apps/flowtrace/lib/features/budgets/` | `AI/modules/reporting.md` | 首页与统计/日历/预算共用本地生产投影，补记日期与月份起始日需widget/Android交叉核对 |

新增业务模块时，同时建立对应模块文档，并将真实代码路径登记到本表。

## 交付前

1. 复核本次实际差异，核对映射中的全部相关文档。
2. 执行与风险相称的验证。页面行为变更应通过隔离服务和真实浏览器主路径验证。
3. 补齐任务日志和必要的计划进度，分别记录实际执行的命令、结果，以及未执行事项和原因。
4. 当前没有持久化文档门禁，采用人工核对及任务内实际执行的检查；不得声称模板自带自动门禁。
5. 报告本地完成内容、验证结果与遗留限制，分别说明提交、推送或部署状态。
