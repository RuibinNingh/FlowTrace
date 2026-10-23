# 正式本地账务读写

职责：在一个 DataSpace 内一致读取本机实体、确认投影、冻结队列和权限缓存，为业务页面提供精确余额与事务写入。
入口：`apps/flowtrace/lib/data/ledger/ledger_repository.dart`；查询/确认批改在同目录 `ledger_query.dart`、`ledger_batch.dart`，移动在 `ledger_book_move.dart`，报告适配在 `ledger_reporting.dart`，图片ZIP导出在 `ledger_image_export.dart`，精确分录在 `lib/domain/ledger/postings.dart`。
不变量：金额使用 BigInt；本地实体、outbox 和分录提示同事务；公开账单与私人财务链接分离；恢复只读期间仍可保存完整草稿。
必跑测试：`flutter --no-version-check test --no-pub test/ledger test/receipts/receipt_tracking_data_test.dart`、`flutter --no-version-check analyze --no-pub lib/data/ledger lib/domain/ledger/postings.dart test/ledger test/receipts/receipt_tracking_data_test.dart`；变更共用分录后补领域测试。
相关材料：[客户端同步](client-sync.md)、[领域金额](ledger.md)、[报表](reporting.md)、[管理补充](../../contracts/management-v1.md)、[查询批量](../../contracts/query-batch-v1.md)、[账务契约](../../contracts/ledger-rules.md)、[同步契约](../../contracts/sync-v1.md)。

## 读取与角色

`LedgerRepository(LocalRepository)` 不创建另一个数据库，不进行网络请求。`read` 通过 `AppDatabase.readSnapshot` 在同一 SQLite 快照读取当前空间的 localEntities、serverShadows、pendingOperations、syncStates 和相关 appSettings；调用者已有事务时复用该快照，不另开读 savepoint。`watch` 观察这五类表，事务提交后重新获取一致视图。`LedgerQuery` 当前支持 bookId、includeArchived、includeDeleted，日期和搜索由页面或后续查询层完成。

`LedgerView` 提供账本、分类、标签、账户、账单、余额映射、epoch、同步状态及待处理数量。`budgets` 返回空间内未删除预算，由调用者按 scopeId 和完整周期筛选。`find` 使用完整空间内实体集合，避免页面过滤后误认为引用不存在。配置按 `(sort_order, entity_id)` 稳定排序；归档父分类和分组使子项有效归档，但不改写子项自身标志。

角色缓存使用 `sync.scope-details.<space.id>`，只有缓存 epoch 等于当前 syncStates.epoch 时采用；revokedScopes 优先拒绝并排除已撤权域。本人 user scope 和由本人 user scope 队列证明的新账本可先创建本机意图。`roleFor`、`canCreate` 与实体 canEdit 仅表示当前离线最后已知权限，服务端在提交时重新鉴权。editor 可管理分类和标签，账本设置限 owner；未知角色不推断为 editor。

公开显示模型与编辑模型分别暴露为 `LedgerEntity.payload`、`editablePayload`。后者只在本机拥有全部必要资金和来源引用权限时提供。服务端 bill_public 与本人 user scope 的 bill_private_finance 始终分开保存；只在构造授权编辑内容时合并链接。待发送的完整本机账单也会在显示 payload 中裁剪私人账户 ID 和跨账本分配来源。共享账本失权后，仅留下私人财务投影不足以还原该账本的备注、标签或附件。

资金链接不完整时 editMode 为 metadata 或 readonly，不允许普通完整表单误把隐藏字段清空。调用者可提交显式 `preserve_hidden_financial_links:true` 的 metadata 更新；验证器要求资金字段与当前可见原值一致，只允许备注、分类、标签、附件、统计/预算标志及expense可选报销追踪意图变化。追踪字段的本地合法性不代表当前部署已声明该能力，现有页面是否暴露入口由其页面验收另记。

## 写入与批量配置

`save` 接受 entityType、scopeId、payload，以及可选 entityId、baseRevision、dependsOn，返回 operation ID。固定 entityId 不存在时创建，存在时修改；已删除 ID 不复活。相同本机正文重试复用该实体最后操作，首次已经冻结的请求不改写。页面先持久化草稿内的 `ui.entry_entity_id`，正式保存成功后即使清草稿失败，重试仍指向原实体，不会产生第二笔。

账务保存、模板复制、草稿和批量确认使用 `AppDatabase.atomicWrite` 持有一个完整外层事务。内部保存队列复用同一受控事务；任一内部写失败会标记整次写入必须回滚，即使上层捕获该异常也不能提交先前部分。原始 Drift transaction 语义保留；写帮助函数拒绝隐式加入未知原始事务，调用方需明确使用 atomicWrite。报告、批量预览、图片导出捕获及账务读取复用 readSnapshot。这修正了锁定 Web 组合中嵌套事务完成后外层提交不返回的问题，不通过关闭事务规避。

账本 create 使用本人 user scope，后续更新规范到其自身 scope。`saveBatch` 按给定次序，在一个外层 SQLite 事务调用既有 saveEntityAndQueue；任何一项本地验证或写入失败，整批实体、队列和分录提示回滚。引用新账本、父分类、分组时自动建立已入队操作依赖；同实体前序依赖由 LocalRepository 维护。建议顺序为新账本、根分类/组、子分类/普通标签。服务端仍逐项提交与返回结果，不能把本地原子性误写成远端整批原子性。

写入前验证闭合字段、币种精度、严格金额/日期/时区、11 种账单字段与账户种类、汇率折算、退款报销分配守恒、折扣、手续费以及分类/标签层级与引用。离线知识不能证明服务端最新剩余可分配额度、附件 ready 或其他设备的新修改，仍由服务端事务裁决。

### P4-02本地追踪兼容

2026-10-22本地写入已接受expense可选严格boolean `reimbursement_tracking`；显式null、数字、字符串、数组/对象，以及非expense的任何显式presence均拒绝。旧记录没有该字段时，读取和写入都不补false/null。同expense的旧完整表单省略它时保留原有缺失、true或false；显式false只取消追踪意图，合法expense转income且不带该字段时不自动继承。

追踪属于metadata，并从`financialFingerprint`排除；不改变金额、分配、原分录或统计/预算标记。缺少私人资金证据的共享editor可用既有preserve模式改追踪，其他隐藏金融事实仍须逐项相同；viewer继续拒绝。`source_summary`仍是公开投影外层的只读证据，不接受为可写payload，不从私人finance补退款/报销分量。旧shadow、原有冻结请求和正文哈希不因该字段加入而回填或重写。

本切片只有通用Repository的离线意图校验，没有新增页面、网络请求或能力声明。当前能力未advertise、UI没有此入口；Repository不进行能力协商，后续页面/发送入口仍须核对当前部署的`receipt-tracking-v1`，不能把本地接受意图当作旧服务已支持。关联源单的严格金额限制及typed原子修订仍由后续切片对齐，原有允许增额的生产回归暂时保留，不在这里改写Reference或删除测试。正式边界见[退款报销契约](../../contracts/refund-reimbursement-v1.md)。

实际执行新[数据测试](../../apps/flowtrace/test/receipts/receipt_tracking_data_test.dart)及旧`test/ledger`合并143/143通过（新29、旧114），4个受影响源/测试文件窄analyze无问题。新测试消费共享16条严格输入与6条presence向量，并覆盖冻结字节/哈希、取消追踪后余额与完整报表/日历/预算不变、隐藏资金metadata、只读summary、viewer和末项非法整批回滚。首轮28通过/1失败仅为测试误期待metadata待传后仍显示confirmed；数值及报表不变，测试改为核对pending后通过，没有为此修改生产。没有执行本切片真实HTTP、PG、浏览器或Android验收，也不将目标结果当作完整客户端结果。

`copyBookConfiguration` 只复制账本设置、分类、分组和标签；生成新 UUID，重映射 parent_id/group_id。账户、流水、预算、余额、分录、成员、回执和附件都不在复制白名单。模板预置类别如采用 FlowTrace 默认，必须在页面明确，不能冒称已还原原应用的私有模板数据。

## 精确余额和不可用状态

账户确认基线来自 `account` 服务端投影中的 balance。未使用账户的本机期初修改加上相对确认期初值的差额；账单变化加上“当前本机分录减该单确认分录”的差额。多个未同步修改只反映最终本机结果，pull 先于 ACK 到达也不再把确认部分重复相加。

`FinancialPosting` 支持 income、expense、transfer、credit_repayment、loan_borrow、loan_lend、loan_collect、loan_repay、refund、reimbursement、balance_adjustment，手续费使用独立 component。金额和累计值始终检查有符号 64 位边界，计算不经过 double。

余额调整的有符号 delta 在正式本机保存时冻结，保存在 `ledger.postings.v1.<space.id>.<operation_id>`。同一事务记录旧/新分录及资金正文摘要，后续修改更早的支出不会重新猜测该调整的方向。该前缀已由同步恢复完整备份保留，不属于 HTTP payload。恢复时旧操作仍不自动重放。

历史余额调整只改备注、日期/时间或 flags 时，Repository 和 Batch preview 均保留原有符号分录；目标余额仍是创建该调整时的历史定义。例如期初10000、支出1000、调账+500、之后收入1000，修改旧调整的上述字段后仍为10500，删除该调整回到10000。只有明确改变金额、目标余额、账户或类型，才以撤回原分录后的正确基线重算；旧 signed 证据缺失时明确拒绝，不能根据正金额猜方向。

缺少确认投影、ACK 后尚未取得规范分录、冲突/阻塞或无法证明历史调整方向时，余额显式 unavailable/awaiting_server_projection/conflicted，value 为 null，并保留可用的 confirmed 值。旧共享账户余额调整仅有目标余额和绝对金额，若没有匹配本地提示或私人确认分录，不能推断历史正负方向；在拿不到证据时拒绝其资金编辑。服务器完整历史分录读取是后续可补能力，不能用猜测把该项当作已支持。

删除回执和真实删除墓碑的原始shadow正文均可能是空对象，因此不能仅凭deleted标志判定余额已确认。完整pull commit或校验后的snapshot安装时另写 `sync.tombstones.v1.<space.id>.<scope>.<bill>` 来源证明，绑定空间、epoch、scope、UUID、revision及原正文hash；只有全部相符，已应用操作才可采用账户canonical余额。ACK单独到达仍为不可用，实际删除commit到达后恢复准确余额；证明不改变shadow原字节或协议hash。现有旧库缺少证明时保持保守，后续重新拉取或快照才补足。跨账本移动仍按上节来源/目标版本与权限规则判断，不因旧来源墓碑被误认为目标确认。

2026-10-22两序余额回归先失败后通过，独立来源证明9项通过并纳入完整客户端500通过/5默认live跳过；完整分析无问题。真实资产HTTP1/1在正常删除后确认bank100000/EUR0/card-10000准确恢复，服务器有效资金分录与附件引用均0；并非仅本机合成shadow测试。首轮真实失败、编译/夹具错误与最终回执见[开发记录](../logs/2026-10-21_develop-flowtrace.md)。

已入队跨账本移动会先将本机公开记录放到目标账本。目标最新canonical尚未到达时，余额仅可复用这次move绑定的来源确认基线：操作仍为queued/sending/retry、双方仍可读、来源revision和projection hash完全相符、本人private finance的revision/book/全部signed entries一致、old/new分录相同、当前资金正文仍等于冻结move正文；较新的目标canonical优先。往返移动可能留下更旧目标live或与来源live同revision的旧目标墓碑，二者不能覆盖此精确来源证明；较新目标墓碑保持不可用，不能将before当零。该证明只补账户确认差额，不伪造目标shadow。raw ACK、来源失权/证据变化、拒绝操作或资金正文随后变化时继续明确不可用，不将缺证据当作零。

`LedgerBookMoveService(ledger, attachments, {required refreshPermissions, transfer})` 提供 preview→prepare→confirm。必需的refreshPermissions通过共享SyncEngine通道落库角色、撤权、附件受控缓存清理和恢复状态；生产页面使用AppController.refreshAttachmentPermissions，不能用仅GET后throw的替代实现。选中账单和引用定义须已canonical确认，双方可编辑、账本币种相同、仅本人私人资金账户，无退款报销关联；每笔分类/标签/手续费分类需显式映射或清空。prepare上传并校验目标图片副本但不移动账单；confirm在一个atomicWrite内入队同UUID的完整move命令与signed分录证明。服务器逐笔提交，不宣称远端整批原子性。相同prepared重复确认复用原operation IDs；身份切换后的迟到查询不能返回成功。

## 完整草稿

`saveDraft`、`readDraft`、`watchDrafts`、`deleteDraft` 直接使用 LocalDrafts。结构为 `{kind:ledger_draft, version:1, book_id, payload, ui}`；保留部分无效表单、计算器原始表达式、手续费/汇率/目标输入、稳定账单 ID 和 attachment_ids。单份 UTF-8 JSON 上限 1 MiB，超限明确拒绝，不截断正文。旧纯文本草稿仍由旧页面处理，结构化草稿不会当普通备注展示。

草稿在恢复只读期间仍可本机保存；正式实体写入明确拒绝。现有 SyncStore 完整备份已包含 LocalDrafts，附件原件和暂存元数据仍由附件模块持有，不因从草稿移除引用而自动删除原件。

## 本地净收支、日历与预算

`LedgerReportingService(LocalRepository).read(space, ReportQuery, {budgetId})` 返回 `Future<ReportResult>`，`watch` 同参返回观察流。入口导出纯报告域的 ReportQuery、ReportResult、ReportTotals，使用既有本机库，不发请求、不读取当前汇率。空间实体、确认shadow、完整队列、同步状态及权限缓存在同一次SQLite事务读取；观察这五类表的已提交变化后重读。

必须为已验证空间，syncState存在且active，当前账本权限缓存与epoch匹配；owner/editor/viewer均可读。恢复、缺权限、无有效账本、相关冲突、数据或金额证据不足时通过 `ReportResult.unavailable` 返回有限原因码，金额/分类/日历/预算均为空。已拒绝删除也不能被当作成功删除后返回较小数字。整个账本内未解决的分类/账单/预算冲突采用保守不可用策略，不把某个期间的部分结果宣称为完整。

适配器读取本账本全部可见公开历史，保留归档分类父子关系，再按查询business_date区间统计。源费用的确认已分配额为确认原金额减canonical remaining；当前已分配额在此基础上加每笔回款“当前本机分配减canonical分配”的差额。多次本机编辑只计最终状态，删除撤销该回款原分配；pull先于ACK时canonical已反映的部分不再重计。源费用本机改金额时仍保留原确认累计分配，而不是把旧remaining直接当成新净额。

外账本新建回款如有当前可读的完整本机创建意图，可以证明原分配为0，其增量只用于查询源单净额；外账本ID、回款正文和私人链接不会进入报告输入或输出。已有外账本隐藏旧分配的金融修改无法证明差额时返回不可用，显式preserve_hidden_financial_links的metadata修改不改变分配。raw ACK只有提交正文而没有派生来源证据，保持不可用直到canonical到达。新revision0源费用由本机冻结create意图证明；旧共享源费用不能类推。私人finance从不用于填补统计缺口。

报告仅使用公开账单payload；canonical remaining可以证明总净额，但看不见全部回款时退款/报销拆分为空。金额由纯报告域使用BigInt和冻结reporting计算，不按当前估值汇率补全。查询层的名义合计与这里的净统计是独立口径。预算默认自动选择同账本、完全相同区间的唯一有效预算，无预算时budget为空，多份时明确ambiguous；显式ID仍核对权限、周期和Money币种精度。总额、分类、混合组合与父类后代占用沿用纯报告域，不重复计算。

## 批量图片ZIP导出

`LedgerImageExportService(ledger, attachments, {transfer, saver})` 要求账务与附件使用同一本机SQLite库；`preview(space, billIds)` 提供可导出状态、按账单定位的有限issue、去重后的账单/图片数量与已知原件大小。`export(AttachmentLease, preview)` 返回saved、downloadStarted或cancelled，以及图片数、ZIP字节数和文件名。预览绑定服务实例、资料空间、epoch/client、完整选中正文/修订和角色缓存；后续同修订的本机修改也会使预览失效。

当前导出使用活动在线lease，先核对当前服务端scope权限，再按既有AttachmentRepository读取本机原件或AttachmentTransfer下载已授权原件。viewer可导出可见图片，不要求完整私人资金编辑权。新建本机账本可由本人的revision0创建意图证明本机所有权；已有账本不能借此绕过当前权限。每次读取前后、系统保存对话框返回后、最终发布前后均重验lease和本机证据；线上角色/权限版本改变或撤权也拒绝。服务不写同步队列，不把导出当作正式服务器备份。

每次最多1000个输入账单、100个去重图片，原件合计20MiB、单图沿附件10MiB上限、ZIP最多21MiB。输入超过上限明确拒绝，不能先截断后声称全部导出。未知远端大小逐张有界读取，超过总额立即失败；完整ZIP生成后才打开保存位置，任一缺件、摘要错误、失权或超限均不产生部分成功回执。已经取得的受控附件缓存继续受附件模块管理，不删除用户原件。

ZIP采用archive4.0.7的store方式，图片引用按ID去重，内部只使用`images/image_0001.ext`等合成名字与固定文件时间，不写入账单ID、备注、原文件名或业务清单。图片原件字节保持不变，包含原图自身可能携带的EXIF；“无私有标识”是归档命名和应用附加元数据的约束，不声称原图片内容已被脱敏。archive固定版本与新增posix锁由客户端依赖维护任务统一加入，未升级SDK或既有锁版。

保存器分开选择目标与写入。Android新增`ImageExportBridge.kt`及MainActivity注册，ACTION_CREATE_DOCUMENT只返回本次选择的opaque token；桥不接受任意路径/URI，不新增Manifest存储/照片权限。目标先标partial，完整写入且Dart再次重验后才发布随机合成短后缀的ZIP名；失败仅尝试清理该次document，无法清理时仍保留partial标记。依赖provider支持rename，不能将桥编译等同于所有provider已验。使用机制依据[Android文档保存说明](https://developer.android.com/training/data-storage/shared/documents-files)与[DocumentsContract](https://developer.android.com/reference/android/provider/DocumentsContract)。

Windows复用锁定file_selector选择路径，在该目录写独占临时文件、flush并重新核对后rename到用户选择的位置；失败清理本次临时文件，重验失败不覆盖旧文件。Web复用file_selector/XFile触发下载，只报告downloadStarted，不能确认用户最终保存到磁盘。已经完成发布的独立文件无法通过后续撤权收回。

## 验证边界

跨账本服务18项与页面widget4项合并22/22目标通过，owned分析无问题：显式映射/能力门槛、只读与未确认配置拒绝、同UUID与冻结字段、旧applied历史、同修订本机变化和服务端变化、真实本机PNG克隆、末项失败整批回滚、来源hash/权限缺证、raw ACK、来源/目标pull双序、历史signed+500、带手续费转账三分录、fresh撤权/降级/恢复落库与受控缓存清理，以及阻塞已排队查询时切身份拒绝迟到成功。独立审阅发现往返移动历史目标shadow会误作零基线，修复后新增旧目标墓碑/旧live两例回归均保持9875，并核对较新目标墓碑为不可用；未执行未修版往返失败，不把审阅推断写成失败回执。

首次服务目标2通过9失败暴露fingerprint误纳入Drift序列化时间戳超出控制数边界，改为明确scope/revision/deleted/payload字段；中间1项预览异常类型未统一，修正后服务目标通过。首次22合并目标21过1失败暴露标签弹层复用已发送初始事件的broadcast观察流而持续加载，改为弹层独立watch后22项全部通过。widget涵盖显式清空选择/离线不写、数据库来源撤权隐藏账单、打开标签弹层后目标撤权立即隐藏名称、390宽/1.8字布局。页面三步区分核对方案、准备图片副本和确认本机待同步，说明取消不移动、完整统计同步后更新。Search已接移动入口并补选择快照/取消保留；随后完整客户端411项通过、4项默认live跳过，full analyze无问题，含页面最后的当前映射完整守卫。

独立18084/专库真实HTTP移动1/1通过：生产Service、两份磁盘SQLite与原件目录、2张不同hash PNG准备、同plan复按与成功后丢回复冻结重试、同UUID目标revision2、账户9875保持、来源报表0/目标125、来源-only viewer拒绝目标；第二笔准备后来源撤权拒绝确认，受控缓存实删而本机原件及草稿保留，账户最终9850。Python SQL另核对唯一正式回执、分录/refs/摘要和四测试会话退出；自有线程停止、不改18080。详见[真实联测记录](../../tests/e2e/sync/README.md)。后续Chrome移动页面已接收；手机2026-10-22重连后恢复隔离验收，不以411项或该HTTP专项代替。

2026-10-21 独立 Chrome155 / Drift2.34.4 / SQLite WASM3.5.2 的真实 OPFS probe，修复前最小 outer transaction→inner transaction 已记录内层写入和内层完成，但外层提交30秒未返回；不含账务模型或观察流也能复现。预算保存与4个并发watch保存同样停住。修复后的生产 Repository / AppDatabase / SyncStore 路径4/4通过：预算写入、并发watch写入、捕获内部异常仍回滚及账单后续非法tag的整批回滚、冲突替换新操作并保留冻结历史；四组数据库关闭后重新打开4/4仍为准确预算10000最小单位与一个待发送操作。回滚实测实体2、outbox0、分录提示0、账户余额20000保持。没有改依赖缓存、worker或SDK；原始最小失败回执保留。命令、隔离和证据路径见[Web事务诊断](../../tests/e2e/client-web/TRANSACTIONS.md)。这些是存储路径证据，正常应用预算与下载页面仍由独立Chrome主路径另验。

P3-02 新增纯公开投影查询和确认批量服务，书面语义见[查询批量契约](../../contracts/query-batch-v1.md)。全部筛选条件组合后返回稳定 ID 集合；原币名义合计分别按币种、类型返回，净收支交由 reporting。批量默认字段不变，确认前复核修订、正文及权限摘要；分类/备注/标签/时间/独立 flags 和图片引用移除走同一本地原子事务，不提供金额或账户批改。

新增 22 项查询/批量测试与原账务 22 项合并，最新 44/44 通过，相关目录 analyze 无问题。包含选择过期与本机同修订继续编辑、权限版本变化、末项失败整批回滚、有关联单据的显式删除顺序、DST/微秒、图片引用与其他记录隔离，以及 metadata raw ACK 不解除隐藏资金限制。复制关联回款/余额调整、跨账本移动、批量文件下载仍有明确边界，不等同 P3-02 全量验收。

补历史调账回归后，`test/ledger` 与 `test/domain` 合并158/158通过，目标 analyze 无问题。新增8项真实SQLite覆盖 Repository 与 Batch preview 的备注/时间/flags、删除、显式资金编辑和非法金额回滚；双端参考领域另有原始分录保持回归。独立PostgreSQL同例5/5通过，Python整个domain目录106/106通过；该轮158项不包含随后新增的本地报告适配或完整Android验收。

加入本地报告适配后，新增21项真实SQLite与纯报告/factory18项合并39/39通过，整个 `test/ledger test/domain` 最新180/180通过，对应数据/领域/测试目录analyze无问题。覆盖跨期退款和报销、本机改删差额、新源单、确认来源改金额、pull先于ACK、raw ACK空窗、隐藏累计金额与外账本分配边界、归档分类、预算组合/歧义/币种、角色epoch与恢复、拒绝删除及观察流。原始首轮编译曾因测试文件Drift扩展导入不全失败，补齐并隐藏同名isNull后重跑通过；不把失败轮次当成功。

图片导出新增21/21目标通过，其中服务目标使用真实SQLite与临时目录原件，网络授权/下载用合成lease；保存器目标验证Android channel两阶段顺序和Windows真实文件的临时发布/旧文件保全，未打开真实OS保存对话框。范围analyze无问题；`android/gradlew.bat -p android :app:compileDebugKotlin -x :app:compileFlutterBuildDebug --console=plain` 实际BUILD SUCCESSFUL，82任务中5项执行，耗时3分52秒，没有重建完整Dart应用或调用ADB。首轮恢复fixture未接住configure的预期StateError导致1项失败，修fixture后重跑全部通过。

Android SAF实际保存、不同provider能力、Windows原生对话框和Web真实下载仍未验；用户2026-10-22确认手机重连，已恢复隔离ADB，普通main恢复及完整平台旅程仍按最终步骤执行。真实浏览器仅使用独立Chrome测试实例，不操作用户Edge。

本轮隔离 SQLite 22 项与既有领域 86 项合并执行，108/108 通过；本地读写/分录/测试目录的 analyze 无问题。覆盖稳定 ID/冻结重试、离线改删和确认差额、ACK 空窗、超过 JavaScript 安全整数的金额、最终值合法而临时差额超过 64 位的计算、固定调整分录、角色/撤权、模板原子依赖与失败回滚、私人链接隔离、metadata 更新、归档与分组、观察流，以及磁盘重开后的长草稿恢复。

本机读写层直接消费共享 L01–L04 中 36 条账单命令，逐步对照原始 expected.account_balances_minor，覆盖全部 11 种账单类型。适配器仅把合成名字映射成 UUID、区分输入中复用名称的收支分类，并补成同步 API 要求的完整 fee/reporting 属性，不修改原始期望。L04 的市价设置步骤只核对余额不变，没有实现或调用估值设置接口；这些用例不声称统计、资产估值或 P4 调度已完成。

账本 display_mode 的本地默认与服务端闭合字段一致，为 month/year/all。服务端同轮在专用 PostgreSQL 数据库执行 management/schema/input 89 项通过，包括旧客户端省略后保留设置、非法值拒绝和旧物化页哈希不变；无数据库迁移。实际 OpenAPI 导出与运行中 QA 服务更新由服务端集成任务顺序完成。

本包属于 P3-01 数据层。界面主路径、真实 HTTP 保存同步和 Android 交互需由对应页面/集成任务另验；分期、周期、存钱计划调度仍在后续 P4，不把底层支持相关账单种类等同于完整高级流程完成。

## P4账户定义与冻结金融事实

账户元数据新增私人组、排序、归档、图标备注、银行/服务商、尾号、期初业务日及信用卡配置，prepaid/investment沿用Money余额。旧表单省略新字段保留既有值，不改已确认shadow原始JSON/哈希。组需同空间活动epoch/client的REST完整列表确认且未排队删除；它不作为同步depends_on。共享账户禁止引用私人组。

已有有效分录的账户禁止改期初金额/币种/精度/kind/opening_date（含给旧null补日期），余额修正通过可追踪balance_adjustment。archived禁止新资金引用但原单已有引用可维护；已知期初日之前不能记分录。transfer_fx仅六种双账户异币转账，精确换算须与target_money相同；旧更新省略保留，已冻结率不能显式清空，移动/隐藏元数据金融指纹包含它。私人组不是本地sync实体，不能因缺少sync组定义误把账户继承归档。

首新账户11+原账务22最终33/33通过，新资金UI4+旧UI4合并8/8。恢复备份已包含资产配置/冻结REST队列全部旧epoch行；授权读缓存使用独立prefix及撤权递增nonce，任何scope失权全清本空间受控资产读缓存，保留配置意图与原件，迟到读取按nonce拒收。新nonce及读缓存备份已在账户/资金合并21项目标通过；专用读层与页面的实际撤权/迟到响应专项仍由读取模块另验。
