# FlowTrace 文档入口

先读根目录 [AGENTS.md](../AGENTS.md)，再按当前任务选择材料。

> **当前恢复入口（2026-10-24）**：Windows/APK `0.1.1+2`已重建，源代码默认服务器改为`https://home.ruibin-ningh.top:18473`，既有手动地址与资料保留。先读[当前进度](plans/flowtrace/progress.md)及[原生重建记录](logs/2026-10-24_native-client-rebuild.md)。生产仍为已上线的钱迹兼容/日志修复包，见[生产部署模块](modules/production-deployment.md)及[Linux手册](../deployment/linux/README.md)；本包未替换生产Web/后端，安卓设备测试仍取消。

| 当前任务 | 阅读入口 |
|---|---|
| 内置生产地址、Windows/APK 0.1.1+2与升级边界 | [原生重建记录](logs/2026-10-24_native-client-rebuild.md)、[客户端](modules/client.md)、[Windows](modules/windows.md) |
| 钱迹原始导出、105条完整导入、退款与错误定位 | [导出兼容契约](../contracts/qianji-export-v1.md)、[数据工具](modules/data-tools.md)、[本包记录](logs/2026-10-24_qianji-export-import-fix.md) |
| 当前 Linux 生产部署、验证与 Alpha 收尾 | [当前进度](plans/flowtrace/progress.md)、[生产部署模块](modules/production-deployment.md)、[Linux 运行手册](../deployment/linux/README.md) |
| 了解流迹目标、后台面板与完整实施顺序 | [完整开发计划](plans/flowtrace/plan.md) |
| 接续流迹开发计划 | 先读 [当前进度](plans/flowtrace/progress.md)，再按任务进入计划分册 |
| 当前Alpha范围、额度控制与逐包交付 | [Alpha里程碑](plans/flowtrace/alpha-milestones.md)；生产Alpha已部署交付，未验项保留，下一包由用户决定 |
| 已冻结的Windows/Web/APK及配套后端 | [M1候选清单](plans/flowtrace/alpha-candidates.md)，包含实际产物、hash与验证边界 |
| 最终Windows/Web/APK交付与当前生产部署条件 | [最终交付分册](plans/flowtrace/delivery-local-test.md)，文件名保留原本机测试任务来源 |
| 旧 Windows 本机测试方案的准备、启停、私有配置与精确静态入口 | [本机部署模块](modules/local-test-deployment.md)、[部署工具](../deployment/local-test/windows/README.md)；不是当前生产恢复入口 |
| 了解工作区、现有材料与运行能力 | [工作区说明](modules/workspace.md) |
| 账务/权限/API 契约与固定样本 | [共享契约](modules/contracts.md)、[证据矩阵](plans/flowtrace/evidence-matrix.md) |
| 平台工具链与页面映射 | [平台验证](plans/flowtrace/platform-validation.md) |
| Python 服务端的安装、接口、迁移与验证 | [服务端模块](modules/server.md) |
| 管理员登录、邀请、用户与会话管理 | [后台模块](modules/admin.md)、[浏览器验收](../tests/e2e/admin/README.md) |
| Flutter 工程、本地库、草稿与平台适配 | [客户端模块](modules/client.md) |
| 数据迁移、授权导出、备份与隔离恢复 | [数据工具](modules/data-tools.md) |
| 大文件迁移暂存、worker与跨页原子发布 | [大批迁移分册](plans/flowtrace/large-import-implementation.md) |
| 固定pull跨页组、客户端原子安装与旧协议兼容 | [跨页同步分册](plans/flowtrace/group-sync-implementation.md) |
| 备份保护、保留候选与受控隔离清理 | [保留清理分册](plans/flowtrace/backup-retention-controlled-cleanup.md) |
| 持久任务、租约与独立worker | [作业模块](modules/jobs.md) |
| 配置版本、运行策略、私有密钥与固定连接检查 | [配置模块](modules/configuration.md) |
| Web离线资源壳与多标签更新保护 | [Web模块](modules/web.md) |
| Windows原生目录、单实例、打包与升级 | [Windows模块](modules/windows.md) |
| 本机外观/功能偏好与Web、Windows应用保护 | [偏好与保护](modules/preferences.md) |
| 首页、基础账户、精确计算器与记账编辑器 | [记账界面](modules/entry.md) |
| 个人资产、净资产估值与账户扩展 | [资产模块](modules/assets.md) |
| 退款报销追踪、来源授权/因果读取、预览与单笔确认 | [退款报销模块](modules/reimbursements.md) |
| 币种目录、偏好与日期化手工估值 | [币种模块](modules/currencies.md) |
| 本地账本读写、余额投影与完整记账草稿 | [本地账务](modules/ledger-data.md) |
| 账本模板、分类层级、标签分组与排序 | [配置管理](modules/management.md) |
| 账单搜索、实时详情与批量维护 | [流水维护](modules/transactions.md) |
| 客户端离线队列、冲突和快照恢复 | [客户端同步模块](modules/client-sync.md) |
| 服务端同步、权限投影、回执和分页 | [同步模块](modules/sync.md)、[真实HTTP联测](../tests/e2e/sync/README.md) |
| 附件上传、授权下载与回收 | [附件模块](modules/attachments.md) |
| 有界诊断记录与脱敏导出 | [诊断模块](modules/diagnostics.md) |
| 两端精确金额与账务参考计算 | [领域模块](modules/ledger.md) |
| 统计、日历、预算界面与精确投影及报表接口 | [报表模块](modules/reporting.md) |
| 新建、续写或核验维护任务记录 | [任务日志约定](logs/README.md) |
| 制定跨轮计划或中断后恢复 | [计划约定](plans/README.md)，然后读对应主题的进度文件 |
| 调整协作与日志方法、取用模板 | [repo-collaboration-logging skill](../.agents/skills/repo-collaboration-logging/SKILL.md) |

文档职责由根目录协作规则定义，改动到文档映射只在 `AGENTS.md` 维护。本目录不复制另一份映射或已知缺口清单。

目前任务记录较少，直接按日期和主题定位 `AI/logs/` 中的文件；尚未引入派生任务索引或索引生成器。
