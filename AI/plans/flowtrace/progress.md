# 流迹开发计划进度

> **当前优先状态（2026-10-24）**
> - 用户要求：额度受控Alpha，优先可测试Windows/Web/APK与独立本地测试服务；暂停非交付必需的新功能。完整功能计划保留，不再自动沿P4–P8扩展。
> - M0：已核Git原无提交基线，保存本地恢复点和交接；当前0个活跃子代理，本包未派发，未新增业务代码/构建/部署。现有运行资料和失败现场保留。
> - 现成验证：取消页面相关最后一包35通过/48.37秒为已有回执，本包未重跑；新增历史读取源码仍未验证，group40001窄修未完成，均转交接。详细阻断与待办集中在workspace。
> - M1完成：Windows普通local-test ZIP、Web a3d9与旧普通Android debug APK已冻结到outputs/releases/alpha/m1-20261024；只补建缺入口的head0016后端wheel。文件hash/来源和6项wheel入口smoke通过；实际三端/DB联调尚未做，不称最终Alpha。
> - 下一项：M2必要的组合启动/同步/保持检查、阻断修复与Web ZIP/安装说明；**待用户决定是否进入，不自动启动**。候选细节见[清单](alpha-candidates.md)。
> - 额度：M1接收接口报告7天窗口已用1%、额外积分0；每包交付重新检查，不等同于包内token/费用。上限2个子代理，针对性验证优先，复杂故障两轮仍失败即交接。
> - 依据：[Alpha里程碑](alpha-milestones.md)、[本包记录](../../logs/2026-10-24_alpha-checkpoint.md)。仅本地提交，未推送/生产部署；三产物与持久服务尚未最终交付。

以下为2026-10-23的接收快照；其中“进行中/正在验”是当时状态，当前执行范围和恢复位置以上方Alpha里程碑为准。

> **2026-10-23状态快照**
> - 用户范围：继续非安卓P5–P7；安卓专属/ADB/安装暂停。完成后交付普通Windows/Web/APK并部署独立本机持久测试服务，详见[交付分册](delivery-local-test.md)。未最终打包、Install、持久Start或任务注册，整体goal active。
> - 当前动作：普通stage17/完整映射页已接；c462及新d1ba native各1/1通过。c462 followup因测试peek改变attempt_count失败，已修只读peek；d1ba followup实际group_unavailable失败，金融undo已成功但新group创建遇PG40001，正在新库可控并发复现并窄修共享预算重试，原现场不重发undo。普通Chrome独立8bb7正验。后台同深度2890 Chrome入队5/完成3与真实CLI Worker通过，641c无receipt partial保留；未领取取消PG25已验、root独立页面已接，HTTP/Chrome继续，不加DDL。
> - 客户端：schema5全量快照1009通过/6专用live默认跳过（59秒），完整analyze clean（8.1秒）；相关122和图片两端反核4分次通过。新stage TCP实际1/1、19秒：204items/101expense/2publication chunks，614400B两片，chunk/apply成功回复各丢1、磁盘离线重开2、原apply正文/原件/outbox保持，余额9007199254728368、原图hash、no push。后验active session0/18094 API-worker已关。此为VM+沙箱Windows目录bridge，非普通UI/runner secure vault/容量性能；续接清源undo及Chrome另验。
> - 服务端：稳定head0016，52表/原9trigger/6function及identity/config保持，旧QA不迁。隔离handler与管理executable已接，完整jobs新005e库68通过/1图片专用默认skip（17.02秒），新2a1图片另1/1（1.94秒）；首旧恢复替身漏before_read的6失败保留，修fixture真实SH/gate/hold后通过。stage普通main相关86/1新夹具误期望后单项1为分次证据，实际API72/176/79与合同21通过。
> - 大迁移：当前requirements/源释放相关同次168/168、0skip（79.71秒）；源释放120与0014非空8表真实恢复1、0015非空9表真实恢复1为分次证据，均保旧包/库。完整名称派生清单有界分页/hash，mapping_hash同Python/Dart黄金供丢回复核对；正式金融Batch/Items/Publication保持。早前完整169、四阶段jobs62及图片1、PublishedStageContext48/HTTP18为历史独立分项。公共导入50/导出1000和旧sync限制不改。
> - 备份保护：保护/reader/任务引用/候选HTTP14/Chrome7为此前证据。quarantine641c首次Chrome入队5通过、Worker在274字符目标普通读取失败，字节完整/无receipt partial与两reserved v2保留；扩展路径修复实际先红后17文件、27 PG/HTTP、24路径别名分次通过。同深度新2890 Chrome入队5/完成3、真实CLI Worker/哈希/回执/controls v3和审计一致，余三包未变，精确host/Chrome已关。合成PGDMP非pg_restore。未领取专用取消新9add25通过，只无效果才解除本intent预留；已领取/partial/retry/reconcile/purge/网页恢复未开放。
> - 后台：恢复生产pg_restore backend6检查、Chrome4+无registry专项1、postconditions与相关262/262通过；三个目标和partial保留，宿主/Chrome已精确关闭。原生ZIP短新profile重试仍204/无download事件，HTTP归档证明分开。七项配置消费者已接，诊断真实POST/export/OSfalse/审计与多app/async目标后相关158/158通过；保留清理、OCR/AI三项pending。
> - Web：新普通schema5候选web-stage-20261023-c5e8构建59.5秒/seal39资源，release e4d63f…e821c，main3431f0…e3101，184源前后同aab12e…d2301；尚待新Chrome stage旅程，非最终包。旧a3d9、提示/地址/离线及原ARIA失败/profile差异证据保留，不扩大为新候选或完整P6验收。
> - Windows与部署准备：普通0.1.0+1候选尚非最终包；原生桌面等待已发出的本人解锁答复，未操作锁屏/安全输入。部署工具静态25+Windows准备11分开36项通过，未安装服务。Anaconda3.12缺ensurepip内置wheel的venv失败保留；固定uv Python3.13.5在新工具venv离线安装35锁定wheel、pip check和14运行库导入通过，未改全局环境。
> - 完整边界：P4回款历史/完整UI/严格来源/Reference/typed、周期分期及七储蓄计划尚未闭合；P6/P7完整业务/保护/更新/文件旅程继续。安卓设备暂停、Linux缺环境延后；独立Chrome，不用用户Edge/个人Chrome。Git main无提交基线，未提交/推送/生产部署。
> - 运行：PG55432保留原测试集群；18080无旧监听，迁移18090/Web18190与恢复18087/18088自有短程宿主验证后均关闭；保留QA库、vault、备份及所有失败现场。

## 分期状态

| 切片 | 状态 | 验收依据 |
|---|---|---|
| 本轮计划制定 | 已完成 | [本轮任务记录](../../logs/2026-10-21_plan-flowtrace.md) |
| P0 证据补齐与契约，4 项 | 实施基线已验收，原应用动态补验保留 | [证据矩阵](evidence-matrix.md)、[平台检查](platform-validation.md)、[开发记录](../../logs/2026-10-21_develop-flowtrace.md) |
| P1 基础工程与 Linux 隔离演练，4 项 | P1-01/02/03 已验收；P1-04 环境待补 | 客户端95项+Android真机1项、Web真实持久化/分区；Python独立wheel/HTTP，领域各86项；Linux按用户要求延后 |
| P2 身份同步与后台最小管理，4 项 | 本地基线已验 | 客户端178通过/3项默认跳过且各有live专项结果；Android身份/冲突/附件各1项、专库真实回滚1项；普通main启动与客户端诊断页真实浏览器已验，Linux边界未验 |
| P3 Android 日常完整主路径，4 项 | 原记账真机与查询/统计/移动本地/Web分项已验；真实系统picker/OS恢复专项新通过，完整旅程待最终 | 合成图片77bytes/取消/10MiB+1拒绝，第二attempt同APK无重装COLD/query_only恢复、余额9875和原IDs/body/完整草稿/原件一致；不是完整P3/P4旅程 |
| P4 高级账务与完整功能，5 项 | P4-01本地/Web接收；P4-02 B授权/因果/纯预览/单笔确认接收，历史/UI/复合待后续 | server445+后补2/socket1、合同21、client764/5默认skip与分析通过；Android本地fixture专项、c974/504 Web保持。cap/严格来源/Reference/typed未闭合，整包/全平台未验 |
| P5 自动记账迁移个性化与后台全量，4 项 | 非安卓部分实施中；安卓专属延后 | 数据服务/真实PG恢复分项通过；客户端迁移、设置保护、全量后台未闭合 |
| P6 Web，3 项 | 实施中 | 离线壳真实Chrome专项通过；普通Flutter完整旅程、更新屏障及完整业务仍待验 |
| P7 Windows，3 项 | 实施中 | 原生QA两版本升级/数据保持与快照专项通过；普通main桌面/完整旅程仍待验 |
| P8 Linux 最终交付与全量验收，3 项 | 未开始 | 待干净 Linux 部署、恢复与完整验收 |

工作包定义与详细依赖以 [任务分册](tasks.md) 为准。表中的未来产物是验收要求，不是已获得的结果。

P4-02的[实施细化](p4-02-implementation.md)包含开工差异、A–F依赖及T01–T15；最新接收表已区分追踪/summary部分、纯模型和未实现B/C/D。字段/无标识聚合已实现验证，但整套方案A严格规则未闭合，`receipt-tracking-v1`仍不advertise，未来`receipt-restructure-v1`独立未实现。

## 验证与遗留

本轮文档结构、覆盖和本地链接检查通过，实际验证回执保存在任务记录；当前能力和已知环境缺口以 [工作区说明](../../modules/workspace.md) 为准，原应用证据边界以 [产品范围](product-scope.md) 为准。

当前已有P0基线、P1本地工程与P2身份同步等专项结果；P3分项测试不等同于完整应用业务验收。Linux部署恢复未执行。用户确认暂无Linux测试环境，先完成本地开发；这只延后P1-04/P8对应验证，不缩减交付目标。

## 下一步

当前下一包为[Alpha M2](alpha-milestones.md)：候选已冻结，做必要的组合验证/阻断修复和最终封包；等待用户决定是否进入。以下原全功能顺序保留为后续待办，不再连续执行。

本轮以[P5–P7分册](p5-p7-implementation.md)和顶部状态恢复：先完成客户端大文件映射草稿/完整清单确认、正式preview/apply/undo与source-release，再完成真实HTTP/普通页面和main能力发布。后台保护服务、全部读者及真实任务hold已验证，继续候选/零删除预览的实际页面，见[清理分册](backup-retention-controlled-cleanup.md)。Windows原生等本人解锁，部署工具保持Prepare阶段；最终新包和常驻服务按交付分册推进。以下P4完整高级前置仍保留。

当前约定开发与验收闭合后，按[交付分册](delivery-local-test.md)生成普通Windows/Web/APK并部署独立本机持久测试服务；三产物、固定Web/API/后台入口、启动维护与持久化/恢复证据都是最终交付条件，不能只给旧QA包或仍依赖当前终端的临时服务。

1. 继续B授权实际回款历史与追踪列表查询；来源read/纯预览/单笔确认已纳入764完整回归，四处审阅缺口红绿证据保留。随后接C完整草稿和同币单源页面，再多源/FX。pure preview不是写凭证，确认仍fresh read/事务复核；旧raw/hash/冻结字节保持。
2. B读取通过后接C退款报销主路径；D严格来源规则及typed修订/原子重构按正式契约推进，旧增额测试精确期望迁到实际typed验证，补回款换来源/类型双源修订，cap未闭合不advertise。P3/P4固定产物及18080旧基线保留，升级仍需可恢复备份与验证。
3. 全团队Flutter pub/build/test串行，测试/构建时短冻结共享生产源。新0006只验专用assets库，不迁移/重置开发库或历史测试库；P4候选独立wheel验收前不替换18080的377包。
4. 手机已完成合成数据的系统picker/取消/超限与同APK OS恢复专项，普通main已恢复并冷启；完整资金/统计预算/回款等跨功能旅程仍待最终。后续Flutter继续串行。浏览器单独启动隔离Chrome，不使用用户Edge或个人浏览器会话。
5. 原应用V01–V10在各领域接收时保留证据边界；Linux部署恢复待有环境后实测。c974即时退出专项已修并通过，完整P6无障碍/离线/更新旅程仍待其阶段；提交、推送与生产部署尚未执行。

2026-10-21 用户已授权按计划开发。接续实施以本文件顶部状态和开发记录为准，规划阶段的“不创建工程”限制已结束；生产发布仍按具体授权执行。

## 计划变更

| 日期 | 变更 | 依据 |
|---|---|---|
| 2026-10-21 | 确认多用户、Android → Web → Windows、Linux 原生部署并加入后台面板 | 用户本次与前轮确认 |
| 2026-10-21 | 由三个子代理实际撰写分册，规划 9 阶段、34 个工作包 | 用户要求计划本身委派子代理并详细说明任务 |
| 2026-10-21 | 开始 P0，实际委派三位子代理并按依赖推进开发 | 用户明确要求开始开发、委派执行、及时更新进度与日志 |
| 2026-10-21 | 剩余手机验收统一放最后，浏览器改为单独启动Chrome测试实例 | 用户暂时断开手机并要求不再使用其Edge |
