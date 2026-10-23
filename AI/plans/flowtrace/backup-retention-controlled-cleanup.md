# 备份保留、保护与受控清理实施设计

> - 职责：让备份保留设置形成可审候选，并在独立保护/租约下分阶段隔离与销毁，当前不删既有资料。
> - 入口：当前恢复先读[progress.md](progress.md)；现有`backups/retention.py`、`leases.py`、`job_references.py`及`admin/retention_pages.py`。
> - 不变量：preview零rename/unlink；显式选择旧UUID；pin/hold/原恢复意图/partial保护；文件效果不冒充与DB同事务；不碰旧QA/三恢复target。
> - 必跑测试：新隔离PG与UUID临时包的保护/租约/竞争/失权/失lease/断点回执；后台另用短UUID独立Chrome，不使用旧fixture执行清理。
> - 相关：[后台](../../modules/admin.md)、[诊断](../../modules/diagnostics.md)、[配置](../../modules/configuration.md)、[作业](../../modules/jobs.md)、[P5–P7](p5-p7-implementation.md)。

## 用户目标、状态与恢复位置

2026-10-23当前增量：稳定head0016，旧库不迁。执行21、root确认页-Worker11及完整jobs68/1图片默认skip、另图片1分次已验。641c Chrome入队5后，Worker因Windows274字符目标读取失败留无receipt partial；文件字节完整、reserved v2保持。扩展路径修复先红后17文件、另27 PG/HTTP与24路径别名验证通过；同深度新2890 Chrome入队5/完成3与真实CLI Worker、目标全hash、回执、controls v3/唯一审计及余三包保持均验，host/Chrome精确关闭。两fixture合成dump非真实恢复。专用“从未领取取消”新9add25/25通过，root独立GET/POST确认页与本人任务入口已接，HTTP/Chrome继续：只pending/attempt0/gen0/manual0/无JobAttempt，在EX下全核原包且整个intent目录不存在，同事务取消并精确解除本intent预留。无需新DDL，running/partial reconcile、专用retry和purge未实施，641c不自动修复。

用户原话：“那就按计划开始开发，委派子代理执行，从P0开始按依赖推进，并及时更新计划进度和任务日志。”本轮非安卓范围沿用用户确认“是，安卓先不动，执行其余 P5–P7”。此分册把已授权完整后台中的受控保留/清理分解为可审实现，不授权对旧QA、恢复目标或私人资料执行销毁。

2026-10-23（Asia/Shanghai）：当前稳定head0016，0013四表及生命周期触发器保持。保护服务139、读者76及后补14、真实任务引用整合124、实际pg_dump/Worker新登记2是分次已验事实。固定verify/restore入队和人工重试已接真实job hold，released不复活、restore永久保护，旧无证明包按原规则校验且不自动登记。后台七条候选/显式登记/pin/零删除路由及四模板已接，helper24、生产main真实HTTP14、root独立Chrome7与fixture守卫11分次通过。四包字节/目录不变，浏览器会话和监听均已关闭。后续隔离pure16、submission文件10、真实入队PG13及独立execution PG/IO21分次通过。0016固定kind、root运行时/后台确认提交已接，真实main/worker专项由root另记；**无生产包移动或销毁、purge及其按钮**，保留天数不触发自动清理。详见[读者](../../../server/tests/backup_retention/READERS.md)、[任务引用](../../../server/tests/backup_retention/JOB-REFERENCES.md)、[页面](../../../server/tests/backup_retention/PAGES.md)及[隔离](../../../server/tests/backup_retention/QUARANTINE.md)。

主代理唯一持registry/迁移/job kind/worker集成。代理可在下一明确切片实施新backups模块/DTO/内部服务及相应tests/admin页面，原`backups/service.py`仍与数据代理协调。Git main无提交基线，以实际工作区为准；所有旧失败/回执保留。

## 语义与范围

`backup_retention_days`仅决定哪些完整旧包可进入候选，不是到期自动删除。首次实现建议分为“隔离到私有quarantine”与另一次“永久销毁”，两者分别预览、当前recovery/密码/CSRF/固定UUID确认及审计。关闭或取消任务不会把非空目标重新视为空，也不会自动恢复或销毁partial。

沿用固定UUID目录与安全文件工具，不接受目录、DSN、URL、shell命令、通配符、任意时间表达式或生产替换选项。界面显示固定包UUID、UTC建立时间、文件/字节数、候选原因及保护原因；不显示服务私有根或凭据。

## 有界只读预览

目录扫描最多10000项，20项分页。每次明确选择最多20个backup UUID；所有选定包累计字节不得超过当前单个导出归档上限，累计文件最多100002个。超过界限拒绝，用户拆小批操作，不截断后默默执行。每包完整验证manifest、真实包成员集合及逐文件hash，拒绝非法日期或声明。

预览不rename、不unlink、不创建目标包。生成300秒受控preview，绑定操作者/当前会话、配置版本、源instance/epoch、固定cutoff、选定UUID闭集与manifest/成员摘要。控制记录只写源私有控制目录，不夹带原包。提交必须重新验证全部绑定、当前保护状态与实际hash，当前权限或候选改变即拒绝。

cutoff为服务端UTC当前时间减当前保留天数；候选依据合法manifest的建立时间，不能使用客户端时间或目录mtime替代。每个当前instance/epoch至少保留最近一个实际验证成功的完整恢复点。部署可以进一步保护最新N个，但初版若无该配置不能悄悄制造另一个保留策略。

## 保护与竞争

以下对象始终保留，并在预览列出固定原因码：

- 持久pin及尚未显式释放的hold；读取保护元数据失败时拒清理。
- pending/running/retry_wait的backup_create、backup_verify或restore_rehearsal引用。
- 所有已确认restore intent引用，即使原任务成功或失败，初版均不自动释放，保证receipt复核仍有来源包。
- 未完成创建、没有闭合manifest、hash失败、partial、未知成员、link/junction/hardlink或异常目录。
- 当前instance/epoch最后一个完整恢复点。

需要所有备份读者共享per-backup文件lease：下载从全hash到独立ZIP完成持shared；恢复从来源验证到目标最终fresh验证持shared；创建只在UUID目录闭合后可被正常读者引用。清理取exclusive，忙则固定拒绝/稍后重试，不能等待期间持admin/User/config写锁。多UUID按规范UUID排序取锁，目标恢复锁在来源backup lease之后，避免顺序环。

还需短事务的持久控制行/reservation，阻止“保护检查结束→新任务/hold入队→文件被移走”的竞争。新任务和hold创建须核包不在reserved/quarantined状态；清理在取reservation后结束源事务，才做长期I/O。没有这条所有入队/读者接线前，不advertise清理handler。私有lease与DB控制二者各管跨进程I/O和新引用，不能用TTL推测活跃读者已经结束。

## 文件效果与审计

1. 当前recovery、当前密码、CAS及目标确认后，短事务保存不可变清理intent并审计入队，caller commit。payload仅intent UUID和固定摘要，不含路径。
2. worker核当前owner/角色、source instance/epoch、配置版本与lease后，取选定对象的exclusive lease，纯I/O重新全核。过程中不持源DB业务行锁。
3. 每个包只能从登记UUID根原子rename到源私有quarantine的固定`intent UUID/backup UUID`。写不可变效果receipt，记录原摘要/目标摘要/状态；没有receipt的非空结果视partial并保留。
4. 返回源DB短事务时再次复核owner/lease/版本并提交正式结果/审计。文件与DB没有跨资源原子事务；若源完成丢失，新generation只能fresh核quarantine和receipt后复用既有效果，不重复移动或猜测成功。
5. 移动中撤权/失lease停止后续效果，已移动包保留quarantine/partial及固定失败回执，不自动移回或销毁。后台区分入队、已隔离、partial、完成，不能用“任务成功”混称“永久删除”。

永久销毁是独立后续操作：只可选择已有完整quarantine receipt UUID，再次当前recovery/密码/明确范围确认、审计intent后执行。严格descriptor/no-follow检查预先批准的成员，逐文件执行并记录固定结果；不对未知树递归rmtree。任一缺失/变更/失败留partial且不继续扩大范围，重试按不可变receipt核对已经发生的效果。是否提供恢复quarantine的独立受控入口由root另定，初版不自动移回。

## 测试与实施依赖

root需登记持久pin/hold/reservation/intent schema及迁移、closed job kind与worker facade；来源读者和入队服务必须共同遵守lease/reservation。后台仅持表单、CSRF、固定目标展示与真实状态，不伪造清理或worker结果。

测试必须新UUID临时备份及新隔离库：预览目录字节完全不变、保护原因、旧包精确选择、新引用/持读lease竞争、撤权/失lease、rename后source完成丢失、partial与link保留、quarantine精确成员、永久销毁再次认证。真实浏览器用新短UUID Chrome profile，验证选定对象与确认范围一致；测试不能对当前QA或恢复证据运行清理。


## Closed接口与所有权提案

拟定模块不是当前可调用API；root审模型后再注册迁移，不在import时偷偷改变metadata。

| 模块 | 最小职责与闭合输入 |
|---|---|
| `retention_models.py` | `BackupControl`按backup UUID记录available/reserved/quarantined/partial/destroyed、version及固定摘要；`BackupHold`绑定明确holder kind/UUID与active/released；`BackupRetentionIntent`绑定actor/preview/选择摘要/配置/epoch/job及不可变状态。pin是否独立表由root审DDL，不能用mtime/TTL代替 |
| `retention_schemas.py` | `RetentionSelection(backup_ids<=20, request_id, expected_config_version)`、固定保护reason枚举、private preview/intent/effect receipt及public metadata。所有extra forbid、规范UUID、有限计数/字节/UTC；没有path/DSN/URL |
| `leases.py` | `backup_read_lease(settings, backup_id)`共享文件lease，`backup_exclusive_lease(settings, sorted_ids)`排他lease；实际文件位于源private control根，读者租约不写包成员。租约等待有界、忙固定拒绝 |
| `retention.py` | 零删除candidate/preview、当前授权/保护CAS、明确pin动作、quarantine纯I/O效果/receipt。永久purge暂不实现、不advertise |

建议显式阶段函数：

```python
list_retention_candidates(session, principal, settings, *, before: UUID | None)
# -> items<=20/has_more/next_cursor，每项candidate/protected原因，不把历史校验当当前完整

precheck_retention_request(session, principal, *, selection, password)
# -> trusted RetentionAuthority；只读当前身份/配置/来源/控制版本，caller明确commit

build_retention_preview(settings, *, authority, selection)
# -> PreparedRetentionPreview；无源Session，shared lease+完整hash，有界private preview

authorize_retention_preview(session, principal, settings, *, prepared, password)
# -> public RetentionPreview；短事务重认证/当前控制与holds/CAS+audit，caller commit

set_backup_pin(session, principal, settings, *, command, password)
# command仅backup UUID/expected_control_version/pinned bool/request UUID；不释放其他持有者hold

replay_retention_intent(session, principal, settings, *, preview_id, password)
# -> 同owner/同preview/完整选择与摘要的原job metadata或None；只找回，不重新隔离

prepare_quarantine_submission(settings, *, actor_id, session_id, preview_id)
# -> PreparedQuarantineIntent；纯I/O fresh hash+按序exclusive leases，close由caller负责

enqueue_backup_quarantine(session, principal, settings, *, prepared, password)
# -> job metadata；短current reauth/config/source/controls/holds核验，设reservation并唯一入队
# caller commit前一直持private leases，之后close；不接受HTML已准备对象或秘密引用

run_backup_quarantine(settings, *, owner_user_id, job_id, payload,
                      check_budget=None, check_authority=None)
# -> 固定quarantined receipt；仅trusted worker调用，payload仅intent UUID/选择摘要
```

`build`不调用业务Session。preview/confirm/worker对配置/epoch/保护向量逐阶段复核；任何未读到的保护状态按拒绝处理。private preview也受已登记控制集合约束，不能借UUID找到其他目录。`check_authority`仅受信worker可注入，在每个包的独立效果前短读当前lease/owner/角色后结束事务；I/O仍不持源行锁。不能宣称授权检查与后续文件rename不存在竞争，失权后终态必须拒成功并保留已经发生的部分效果。

## 锁序、读者与取消

短DB事务以现有User→job顺序为准：管理授权先admin_control→当前User/session；涉及既有job时先锁job，再ConfigurationHead与按UUID排序BackupControl，不在control之后回头锁既有job。新intent/job同事务创建，最终服务接线由root统一核对。长I/O只持private backup lease，恢复读取来源时先来源backup lease后target lock；source DB短事务结束后才能等待private lease。

新backup_verify/restore/download/hold创建均须先核control没有reservation，活动引用与hold同事务登记；旧未登记包默认protected/unregistered，不能被首轮清理扫描自动认领后删除。可另设当前恢复角色+全hash的受控登记入口，登记本身不授权删除。创建worker在完整验证闭合包后登记control。

原始下载持shared至独立ZIP完成后即可释放，流出只读独立私有归档；进程崩溃遗留hold不按时间猜测释放，需重核无活跃private lease及该操作效果/私有临时资料后受控回收。restore intent引用初版永久保护；普通job status变化不释放这些引用。清理cancel若仍pending且从未领取，root可同事务取消并释放本intent的reservation；running/partial不允许通过通用cancel抹除文件效果，需单独reconcile。未实现这些状态分支前，不给页面该kind的取消/重试按钮。

每包effect重试矩阵：原址在/隔离址无且原hash匹配→允许本intent移动；原址无/隔离址在且匹配完整receipt→fresh核验后复用；两边均在、两边均无或只有非空无receipt→固定冲突/partial并保留。receipt不得被另preview/owner/job挪用；源完成丢失后同intent的新generation重新全核，不再rename既有效果。

## 依赖推进与验收门槛

1. root审closed DTO/三类持久控制与锁序，串行建立迁移；仅新隔离库升降升和metadata核对。
2. 先pin/hold与所有当前读者lease/reservation接线，真实第二连接竞争证明新引用不会跨reservation创建；此时无清理效果。
3. 有界候选/零删除preview和后台只读/确认展示；当前配置天数实际影响候选，但界面明确不自动清理。
4. 受控quarantine job/worker、私有receipt/失source completion恢复；只新UUID临时包，真实Chrome明确选择→当前密码→一次隔离→后验字节/DBaudit。
5. 永久purge、quarantine恢复与遗留hold/reconcile另立显式动作和验收，再决定是否开放；没有实现时不显示假按钮。

下一项具体动作：第1–3步已有保护/读者/真实任务引用、页面HTTP/Chrome后验证据；第4步先审最小closed quarantine接口/CAS/取消重试与DDL差异，纯I/O效果仅允许pytest新UUID临时包验证。尚无生产执行kind或接线；第5步purge不实施，所有旧包/四个Chrome包/既有恢复target严禁操作。


## 2026-10-23 第一包当前事实

新增`retention_models.py`四表候选、closed DTO与`leases.py`已写，**尚未registry/0013/PG迁移，也没有pin/hold/CAS应用服务或清理handler**；不存在文件移动/删除或按钮。版本/生命周期约束是后续精确CAS的结构前置，不能以DTO/DDL编译宣称实际并发CAS已经通过。冻结候选DDL含immutable intent的DB触发器提案，root审核后才建迁移。

初轮`retention-structures-leases-85cb6d6e-74d1-4df9-9186-86b946351ded.xml`为5通过4失败：本机portalocker没有pywin32 extra，msvcrt明确不支持真实共享锁；另一个测试FK注册导入因无效noqa被Ruff移除导致NullType编译失败。未把共享降成排他，也未跳过目标。root同意Windows采用ctypes系统API，无新依赖；POSIX仍用portalocker。参考微软[LockFileEx](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex)及[UnlockFileEx](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-unlockfileex)：同步handle、FAIL_IMMEDIATELY、共享省略EXCLUSIVE位，OVERLAPPED offset0/hEvent0，锁及解锁精确同一1-byte范围。锁文件不存包内容，所有本模块参与者使用同协议。

修复后第一轮9项通过，再加同进程不同thread句柄SH/EX及短等待目标，最终**11/11，1.01秒**（`outputs/validation/P5/admin/retention-structures-leases-d60e4846-62cb-431d-83d8-1e025f60d540.xml`）：Windows真实跨进程shared读可并存/排他拒绝、排他期间reader拒、批量锁按UUID排序且失败释放先前锁、budget异常finally释放、hardlink拒且外部/包sentinel字节不变、同进程跨线程共享/排他及50ms有界等待均通过。此结果只涵盖DTO/DDL编译与本机lease，不替代Linux或后续PG保护服务。

root独审明确：CHECK只能限制当前行形状，不能单独阻止SQL把已释放version2改回version1，或者改写原pin/hold主体。新增冻结候选位于`server/tests/backup_retention/fixtures/0013_retention_lifecycle_candidate.sql`及对应`_down.sql`，未导入registry、未改变head。intent拒UPDATE/DELETE/TRUNCATE；pin/hold仅可初始version1插入、一次version1→2完整释放，其余更新（含no-op）、删除及TRUNCATE均拒绝。JSONB整体减去唯一允许的释放字段后作`IS DISTINCT FROM`比较，当前与将来新增主体字段均不可改。函数使用SECURITY INVOKER、pg_catalog search_path和固定55000错误码/固定消息，不含行数据；control的实际状态CAS仍留应用服务。

新增5项SQL结构检查与既有11项合并**16/16，1.19秒**，Ruff通过（`outputs/validation/P5/admin/retention-trigger-structures-a0c624b8-4f41-4d76-bffd-407445d5fece.xml`）。这些检查核对候选生命周期、可变字段白名单、逐行/逐语句挂载与完整逆序卸载，不执行PG触发器，不能写成真实SQL不可复活已经验证。下一项由root在新隔离库冻结0013并验证原始SQL复活/主体改写/no-op/删除/TRUNCATE拒绝、唯一合法释放及升降升；其他代理当前PG窗口保持原head不变。

## 2026-10-23 保护服务与零删除预览当前事实

上节为第一包历史事实。root随后稳定注册0013并在专用a938新库验证生命周期，合并**102/102（真实PG86、纯目标16）**；这组结果由root执行，模型/触发器冻结，本代理没有迁移旧a938库。root再在新c76库验证0014并稳定发布，本轮两份新admin库由标准conftest各自升至0014，旧QA和三个恢复target未升级、重置或删除。

`prepare_registration(settings, backup_id)`只做纯I/O，持源SH到调用者完成`register_verified_backup`短事务并commit；上下文关闭、settings绑定不同或包source与当前登记源不同均拒绝。完整成员集合、每文件hash、manifest二次读取及tree摘要共同绑定PackageStamp；只允许已知空`objects/`目录。登记不会自动发生，旧未登记UUID始终显示protected。当前验证证明完整字节/hash及格式，不把PGDMP测试头称为真实pg_restore成功。

pin创建/唯一释放和hold创建/合法job终态释放已接当前真实admin会话、动态recovery角色与当前密码、source及version CAS。请求重放先重新认证，pin原请求hash不同拒绝；Control、pin/hold及job重新查询当前值，避免长Session的旧identity map复活记录。hold的精确重放辅以对应audit的base_version整数与原主体，**AdminAudit目前没有DB防改触发器**，仅由本服务追加、从不改旧audit，不能把它当作绕过当前角色/控制状态的DB授权证明。download的`archive_built`与`explicit_reconcile`仍拒绝，等待真实可信reader完成上下文；restore_intent初版保持永久保护。

只读catalog最多10000项、每页20，metadata eligibility仅代表可准备预览，不宣称附件当前完整。显式selection最多20且绑定实际配置revision与保留天数、当前source、control版本和保护状态。read-only precheck由caller明确结束事务后，纯I/O对所选包及一个未选最新已登记恢复点做fresh全hash，按UUID顺序持SH；零删除private preview最多32KiB/300秒。最终短事务重新认证、锁配置读版本、重核control/pin/hold/活动job与恢复意图，再追加一次审计；没有移动、删除、自动登记或入队。

`require_backup_readable(session, backup_id)`为可信reader提供短FOR SHARE gate，返回冻结的registered/stamp元数据。调用序列为源SH→短DB gate与commit→I/O持续SH；没有control的旧包仍可按原授权读取且始终不可清理，已登记非available拒绝。**包的历史source epoch不是当前服务围栏**，旧epoch已登记包仍可授权verify/download/restore，当前owner/session/source前后核验仍属原HTTP/worker/CLI调用者。此gate不伪造admin身份，也不等同于持久hold已接入所有enqueue。

首轮私有文件/租约9项通过0.48秒，首轮新f86库服务PG13项通过5.29秒；补齐空objects目录、settings/source错绑、长Session hold和配置/最后恢复点后，另建空b7ae库完整目录**139/139，13.32秒，无skip**，XML为`outputs/validation/P5/admin/retention-combined-d2838162-cbc7-4ba6-abf6-936db0103166.xml`。其中本代理新增IO10与PG18、root生命周期86、原纯目标16，以及并行读者代理当次快照的reader7/download-gate2；后两项不代替其后续最终整合。Ruff与py_compile通过，仅有既有Starlette/httpx弃用warning。最初Ruff的长行/import排序提示已修，未追溯把失败写成绿。

PG实际覆盖当前角色/密码/过期会话、pin/hold精确重放不重复审计、真实job绑定及终态、长Session观察另一连接释放后不复活、旧epoch可读、晚新增pin使preview CAS拒绝；reservation先锁control时另一连接的hold真实等待，reservation提交后hold与read gate均拒绝，包字节保持。reservation仅是新UUID的显式SQL元数据竞争fixture，**不存在可执行quarantine handler**。f86与b7ae均保留，已有账号/控制/审计fixture，不再当空库bootstrap。

下一项：root独审服务及reader适配，完成实际worker/CLI/download/rehearsal的SH/EX与短gate闭环，再把持久job/restore hold绑定纳入真实入队事务。只有这些关门边界齐备后才讨论候选后台与quarantine job；本轮仍不操作旧包或恢复目标。

## 2026-10-23 第3步页面与第4步纯I/O当前事实

上节为保护服务分包历史。随后读者和真实任务引用已闭合，后台七条候选/显式登记/pin/零删除路由挂入普通main：helper24、HTTP首12/最终14、root独立Chrome7分次通过。20个备份选择是HTTP专项，Chrome的20+1是pin分页；四包字节和目录全同、会话/18092监听0，宿主精确关闭。详情见[页面](../../../server/tests/backup_retention/PAGES.md)。未实施销毁或移动这些包。

下一切片已新增隔离pure I/O/closed DTO，固定同卷不覆盖目标、完整effect receipt后才允许重放，缺receipt保留partial。只在pytest新UUID临时包上实测Windows移动；首14绿，root发现prepared替换绑定缺口后2目标先红，修后16全绿，Linux仍未运行。细节和不可混同的权限/PG边界见[隔离验证](../../../server/tests/backup_retention/QUARANTINE.md)。root准备0016 job kind候选，但当前head未变，纯文件层不授予生产任务能力。

后续root已发布0016，仅新库升级。本代理独立submission authority/prepared/入队facade完成：提交前不含jobID，真实enqueue后同事务绑定intent/control reservation；prepared不可替换身份或锁目标，跨最终commit并finally关闭。新5f4库真实PG最终13/13（10.53秒），加上分次纯提交10及隔离pure16，见[隔离分包](../../../server/tests/backup_retention/QUARANTINE.md)。新建preview audit有完整canonical digest，旧无digest拒用于隔离且保留；等待控制锁期间TTL到期另先红再修。

后续独立execution facade完成prepare→handle/run→complete：真实State→User→原origin Session→job→config/control围栏、当前held witness、无长SQL等锁/hash、一次冻结completion、store.complete精确保留CAS及无文件最终事务。新ede库21/21、26.84秒；origin在control锁等待期间到期先真PG红，再末DBclock复核/最短预算修绿。实际失租OS窗口和缺receipt保留不冒称跨资源原子；详见隔离分包。

root已接运行时及后台确认提交，源码只读复核生命周期无阻断；其新库HTTP/worker专项与这里21分项各自留证。下一项：实际公开隔离旅程、受控无effect取消/重试及其reservation处理，仅新临时UUID包和新专库。新5f4与ede留下全部intent/job/reservation证据，fixture收尾取消不代表生产受控取消已实现；旧QA和四个Chrome包继续保持。purge不实施。

随后新增无DDL的三阶段未领取取消facade，真实新9add库**25/25、32.29秒**，首轮24/1仅新配置fixture字段错误保留；精确证据/锁序/回执见[隔离验证](../../../server/tests/backup_retention/QUARANTINE.md#从未领取任务的专用取消)。本人新的当前管理会话可以取消旧origin，原plan旧epoch/config不能因此执行；取消只恢复尚未动过的包可读。原immutable intent/pin/hold保留，源包或任何intent目录变化、已领取、晚失权/到期、CAS冲突均保留reservation。元数据重放只认专用code及per-job完整命令SHA，旧generic cancelled不得冒认。尚未公开该取消入口，不把内部25项当浏览器/整个清理旅程完成；运行中reconcile、retry和purge另立后续切片。
