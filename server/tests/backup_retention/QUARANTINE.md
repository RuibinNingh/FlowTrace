# 备份隔离底层验证

> - 职责：记录固定UUID包的不覆盖移动、完整效果回执及中断保留；不代表生产隔离功能已开放。
> - 入口：`backups/quarantine.py`、`quarantine_schemas.py`、`quarantine_submission.py`与`quarantine_execution.py`；独立facade不自行挂路由/worker能力。
> - 不变量：仅完整登记摘要/闭集20UUID；selected EX及未选witness SH全序；不覆盖、不复制、不删除；缺完整receipt即保留partial。
> - 必跑：`test_quarantine_io.py`；真实任务/权限/租约/配置/CAS接线后必须另用全新PG库及临时包验证。
> - 相关：[清理分册](../../../AI/plans/flowtrace/backup-retention-controlled-cleanup.md)、[页面](PAGES.md)、[任务引用](JOB-REFERENCES.md)。

2026-10-23（Asia/Shanghai），首包只用pytest新UUID临时树。所有旧包、四个Chrome包、旧QA和恢复target未执行任何移动。没有purge、自动清理、生产job执行或持久部署。

`QuarantinePlan`闭合绑定实际intent/job/actor、source、配置版本、精确选择摘要及完整PackageStamp。选定UUID规范排序且不重复，总量沿现有单包bytes/files界限；DTO本身不授予任何权限。内部`prepare_quarantine`用于已经存在真实job/intent的worker I/O，不是提交前prepared：实际`store.enqueue`自己生成job UUID，提交不能预造它。

目标固定`data/backup-quarantine/<intentUUID>/backups/<backupUUID>`，回执固定同intent的`receipts/<backupUUID>.json`，额外`intent.json`绑定完整plan。源和目标都用现有严格成员/summary/hash校验；包内不加秘密、nonce或新文件。receipt不可覆盖、最大32KiB，绑定plan完整SHA及同job/actor/source/config/package；只有source不存在、target存在且完整同绑定receipt再全hash成功才可复用。双存在、双缺失、未知目录/成员、坏hash、坏receipt/不同job均保留并拒绝。

移动使用同卷不覆盖原语。Windows调用[MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)，只WRITE_THROUGH，不设REPLACE/COPY/DELAY。Linux实现[renameat2(RENAME_NOREPLACE)](https://man7.org/linux/man-pages/man2/rename.2.html)，父目录dirfd/no-follow；内核/文件系统不支持即拒绝，没有可覆盖`rename`或copy fallback。Windows本机已实际验证，Linux没有环境，不能声称已运行。

每个效果前及最终返回都调用required trusted authority callback及budget；数据库权限/租约/owner/source/config/reservation必须由后续真实worker当前读取，纯I/O不假装持有它们。rename后、完整receipt写入前中断，目标保留partial且重试不猜成功；已完整receipt的前缀可全核后续同intent余包。最终数据库成功/控制状态更新不在此模块内发生。

首轮**14/14，2.07秒**，`outputs/validation/P5-quarantine-io1.*`。root独审发现普通mutable prepared可换plan/witness，实际新增2目标先红：两项均DID NOT RAISE，`P5-quarantine-prepared-binding-red.*`，0.71秒；这些移动也仅发生在该轮新pytest临时树。修后factory保存冻结的canonical plan/witness摘要、精确锁UUID/settings/guard identity和真实guard关闭信号，execute在创建任何新目标之前重核。全文件**16/16，3.02秒**，`P5-quarantine-prepared-binding-green.*`，Ruff通过。

内部binding只防实现误替换，不能当作不可伪造授权cap；真实DB回调始终必要。首包时head仍0015，未因pure目标改变数据库；下面单列后续submission范围，仍没有worker文件执行/取消/重试或Chrome隔离旅程证据。

## 提交与真实入队阶段

root随后原子发布`0016_backup_quarantine`，只扩固定kind CHECK并同步store的900秒lease；没有执行handler或后台advertise。本代理另建新`flowtrace_test_p5_jobs_5f4dd771543646b8`，只有该空库按标准pytest升到0016。所有旧库和旧HTTP/Chrome包保持原head/字节。

新增`quarantine_submission.py`：纯读取私有preview最多32KiB，closed验证并重算selection摘要；当前readonly precheck核真实recovery/PW、当前origin、配置版本/天数、source、所有control/保护及当前未选最新witness，caller commit后才取全序selected EX/witness SH并全hash。提交prepared不含jobID、不写execution plan，冻结record/witness/command/settings/guard绑定，关闭或被替换均拒。

新建preview audit增加canonical完整record的`preview_sha256`，提交须核同actor/preview/config/digest与显式command selectionSHA。旧无digest audit保留不补写，要求新做预览。AdminAudit没有DB不可改触发器，该digest只是服务追加的辅助证据；当前身份/密码/source/config/control/hold仍逐项重新核验，不把audit当授权cap。

入队先当前reauth、精确既有request查找；新请求通过prepared绑定后，调用真实`store.enqueue`生成job UUID，再同事务创建immutable intent及selected available(v)→reserved(v+1)，witness保持可用。锁序为admin/User→实际job→config/control。等待控制锁期间时钟仍会前进，写intent/reservation前再次核当前会话/PW和preview有效期；caller最终commit/rollback后finally.close。

丢入队响应的重放先fresh认证，只返回同owner/同command原job metadata，允许本人新管理会话及旧preview已过期；不读取过期preview来执行、不新建job/intent/reservation、不改原origin绑定。错request/selection固定冲突。

纯提交文件**10/10，0.79秒**，`P5-quarantine-submission-io1.*`。真实PG先9/9（7.22秒），补迟到密码、生产配置服务保存/恢复和closed guard后12/12（8.26秒）。再发现“最后控制检查等待期间preview到期”漏洞，实际新PG目标先红DID NOT RAISE（`P5-quarantine-submission-expiry-red.*`，1.15秒），修后最终**13/13，10.53秒**，`P5-quarantine-submission-pg3.*`；Ruff通过。这些分次执行不加总成一次完整套件。

真实PG还验证新preview canonical SHA和legacy拒绝、改私有record拒绝、hash阶段第二连接NOWAIT无User/Admin/config锁、真实jobID与reservation原子可见及外层rollback、迟到pin/角色/PW/config拒绝、旧TTL/旧origin撤销后新session精确重放。包字节不变，未产生execution-plan或目标目录。配置值经生产保存恢复30天，保留4个真实revision。

后验`outputs/validation/P5-quarantine-submission-postconditions.json`：70 control（12 reserved）、12 immutable intent/12 jobs保留；fixture仅精确取消自身未执行任务，reservation继续保守保留，不冒充生产受控取消/释放已实现。active session/admin role/active job/Worker心跳/其他活跃连接均0，source SHA同回执。尚需实际worker当前lease/取消重试/final completion、受控取消reservation和独立新包Chrome隔离旅程；purge不做。

## 独立执行facade与真实队列联测

新增`quarantine_execution.py`，只在另一个新库`flowtrace_test_p5_jobs_ede47f415f1847f7`升0016验证，没有把本模块挂入运行时或后台。三接口为`prepare_quarantine_execution(engine,settings,lease)`、`run_quarantine_execution(handle)`、`complete_quarantine_execution(session,settings,lease,handle)`。prepare成功后caller始终持有handle；run失败也由caller在当前generation的失败事务提交后finally.close，不提前丢失EX/SH。prepare失败尚无rename，内部直接释放。

短检查先无锁定位owner/immutable intent，然后按State→User→原origin Session→实际leased job→config→UUID controls锁序重新读取。worker不获取AdminControl、不伪造Principal、不用密码提升，也不续原session idle；本切片明确新增“原管理session仍活跃”的窄策略，撤销或任一到期均停止。selected仅接受同intent的reserved、原PackageStamp.version+1及完全相同包摘要；不猜测接受DB partial。真实pin/hold、活动reader和所有restore保护仍独立于CAS检查。

每代初选当前source、未选、available最新witness，结束DB事务后与selected EX一起按UUID总序持SH并全hash。之后只认可实际持SH的该witness；新增更晚完整点不静默切锁，也不使仍完整available的原witness失效。run每个required callback都开独立短事务重核当前generation、owner/role/origin/source/config/reservations，结束事务后才做文件工作。

900秒固定租约不启续租线程；合作式预算取实际剩余job期限与origin三期限最小值再减5秒，不是OS硬截止。root独审发现读取origin后等待control锁会让时钟前进：真实独立连接锁住全部control，线程已核origin后等过3秒idle期限，旧代码仍返回，目标先红DID NOT RAISE，`P5-quarantine-execution-origin-clock-red.*`（4.36秒）。修后末尾fresh DBclock重核origin，并用最短期限限制准备预算；complete effect flush control/audit后再次fresh origin/DBclock。修后13/13、17.56秒，`P5-quarantine-execution-origin-clock-green.*`。

成功run只在内部一次封存冻结completion，绑定authority/lease/plan/witness、实际I/O/guard及完整receipt结果SHA；complete不接受外部QuarantineResult。最终在store.complete当前owner/epoch/lease围栏内再次核DB，精确reserved(v+1)→quarantined(v+2)，审计及safe JobResult共享事务；完成回调不打开/读取/移动文件。外层rollback不改已发生文件效果，但回滚全部job/control/audit状态，新generation仅复核原完整receipt后复用，绝不重复移动。

最终**21/21，0skip，26.84秒**，`outputs/validation/P5-quarantine-execution-pg-final.log`和`.xml`。包括真实Windows原子移动两包、第二连接NOWAIT证明hash时State/User/origin/job/config锁均已释放、屏蔽文件函数后final CAS仍成功、完整效果后source completion回滚→gen2原字节/hash复用且只两次rename、缺receipt crash reclaim拒绝、未封存/替换结果拒绝、六类before-effect围栏、held witness遇新latest、origin最短预算及不续idle、独立CAS的legacy pin/download hold/reader、实际配置变更和source epoch推进。

另有实际race：A完成最后SQL callback后失租，B真实领取generation2并等待A的EX；A仍可落入不可消除的callback→rename窗口，只移动一个包便在下一check被拒，旧store.fail也不能覆盖B。A释放EX后B才继续，并因该目标无完整receipt固定partial拒绝，没有并发移动或补猜成功。这个边界不能描述成权限检查与OS rename跨资源原子化。

首轮12个fixture因误用不存在的`store.now`在业务前失败，`P5-quarantine-execution-pg1.*`保留；修为auth.now后12/12、13.49秒。后续13及最终21是分次快照，不与pure16/submission13相加为同次全量。

后验`P5-quarantine-execution-postconditions.json`：47 immutable intent、48 jobs、54 attempts及142 control保留；其中available48/reserved77/quarantined14/partial3。partial3和错误CAS是测试显式构造的拒绝fixture，facade失败不写DB partial、不释放reservation。active session/admin role/active job/Worker心跳/其他活跃连接均0；配置值恢复30天，revision2保留。最后一个source围栏目标仅对这个新库将epoch前进一次且不回退，旧库/四个Chrome包/恢复targets未变。文件移动仅pytest新UUID临时包，Linux未执行。

root随后接入运行时三接口、固定900秒且不续租、typed失败处理与handle跨完成/失败commit后finally关闭，并接两条后台确认/提交路由。root新库的真实main HTTP/worker结果另记，不由本文件21项自动证明。此代理只读复核该runtime分支未见阻断，未改运行时。下一项为实际公开旅程与受控取消/重试；purge和无effect reservation释放仍未实现。

## 从未领取任务的专用取消

后续新增`quarantine_cancel.py`与closed `UnclaimedQuarantineCancellation`，本切片尚未挂路由。命令绑定job/intent/selection SHA、per-job request UUID及严格整数generation=0；不宣称request全局唯一。当前本人新的管理session、recovery与当前密码可以取消旧origin任务，不要求原origin仍活跃。只接受pending、attempt/generation/manual_retries全0、无lease/result/error且真实JobAttempt不存在，不能把人工retry后的attempt0误判成未执行。

只读precheck保存完整原plan与本次当前instance/epoch/config，caller commit后才获取selected UUID全序EX。纯prepare全核所有原包摘要，并确认整个固定`backup-quarantine/<intent_id>`路径完全不存在；空目录、只有plan/receipt/target、链接或hash异常都拒绝保留。这里不调用会写plan的执行prepare，不创建/移动/删除intent或包，只有共享lease设施创建私有控制锁文件。

prepared冻结绑定authority/command/settings与真实guard生命周期。最终按AdminControl→State→当前User/Session→job→config→UUID controls核验，本次阶段间当前配置/source变化即要求重做precheck；旧plan自身config/epoch仍精确绑定原job/intent/control，取消不授予该旧plan任何执行权限。control锁等待后再次fresh校验当前会话/角色/密码，末尾再核活跃会话，不能因字段未变忽略到期。

成功在同一事务内调用原`store.cancel`，设置经`JobResult`验证的专用code与取消命令SHA，所有本intent reserved(v+1)→available(v+2)、intent_id清空、审计共享commit。原immutable intent/pin/hold/包均保留；整个选择任一CAS失败或caller rollback都不半解。EX跨最终commit后finally关闭。同命令重放fresh认证后只返回原metadata，不再取EX/hash/解除任何新预留；变更命令拒绝。该result.sha256是**取消命令绑定摘要**，不是备份完整性摘要。旧generic cancelled/result为空不算该证明；原提交请求重放仍返回cancelled旧job，不复活旧预留。

当前0013六个生命周期trigger仅保护intent/pin/hold，没有BackupControl状态迁移trigger；CHECK允许available且intent=NULL和版本递增，故首版没有新增DDL/head。running、曾领取、partial、失败已撤权任务的reconcile、专用retry及purge仍未实现，通用quarantine控制继续拒绝。

唯一新库`flowtrace_test_p5_jobs_9add79933fe84d88`按标准pytest升0016。首轮24通过/1失败、30.39秒（`P5-quarantine-cancel-pg1.*`），唯一失败是新测试误用配置命令字段，未进入生产配置修改；改为实际base_version/public_patch及必需validator，最终**25/25、0skip、32.29秒**（`P5-quarantine-cancel-pg2.*`）。没有声称首轮fixture错误是生产业务红证据。

目标含真实claim先赢→worker等待取消EX→取消拒绝保留，取消先持job锁→claim skip，源包全hash时第二连接NOWAIT无业务锁，最终禁文件函数仍能完成，外层rollback，目录四型/hash损坏/替换prepared/版本CAS/晚角色密码会话撤销，control真锁等待跨access期限，旧origin的新session、旧config与旧epoch释放和精确元数据重放。claim赢的目标只让新临时worker prepare写plan后关闭，没有执行移动。

后验`outputs/validation/P5-quarantine-cancel-postconditions.json`：head0016，active session/admin role/active job/Worker心跳/其他活跃连接均0；50 intent/50 jobs/4 attempts、150 controls（available64/reserved86）及7专用取消回执保留。生产配置真实revision2恢复30天；每次完整运行最后一个目标只推进本专库epoch一次且不回退。Ruff/compile通过。旧库/四个Chrome包/恢复targets保持，未运行新取消页面或Linux，不把25项与前面的21/13分项合成同次全量。

execution原21项对应行为源码SHA `c62e60f2…cdb2cf3`；root挂运行时后仅同步首docstring为可信worker生命周期，新SHA `9f955f82…523c289`，没有行为变更，静态回执`outputs/validation/P5/restore-worker-fixture-static.json`。恢复Worker旧替身补真实SH内before_read和永久hold两项的完整jobs重跑由root单列，不算本文件25项。
