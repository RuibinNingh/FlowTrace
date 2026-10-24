# 持久任务与独立 worker

> - 职责：固定任务类型的持久队列、租约与尝试记录、脱敏管理投影及独立 worker。
> - 入口：`server/src/flowtrace_server/jobs/`、`server/src/flowtrace_server/worker/`，运行 `python -m flowtrace_server.worker`。
> - 不变量：API不启动worker；generation/当前租约约束提交；数据库效果和成功状态同事务；任务列表无payload或路径；没有handler的类型不领取。
> - 必跑测试：隔离PostgreSQL下 `python -m pytest tests/jobs`；改管理页面须补真实浏览器验证。
> - 相关：[服务端](server.md)、[后台](admin.md)、[数据工具](data-tools.md)、[作业契约](../../contracts/jobs.md)、[权限](../../contracts/permissions.md)。

2026-10-24生产已有专用`flowtrace-worker.service`，非root、自动重启且已启用，受控重启后再次active；API不内嵌worker。每日备份由独立systemd oneshot/timer调用现有一致备份CLI，不冒称后台新周期业务任务或完整handler均已验证；见[生产部署](production-deployment.md)。

2026-10-23新增`0009_background_jobs`，建立任务、尝试、worker心跳三表。仅在本轮独立测试库升级，不自动修改旧开发/验收库。`(kind, occurrence_key)`全局唯一，幂等重送要求owner、scope、rule_revision、epoch与冻结payload摘要全部一致；规则修订不构成新的业务期次。

领取使用真实`FOR UPDATE SKIP LOCKED`，普通任务60秒租约；固定import_preview/backup_create为300秒、import_apply/restore_rehearsal/backup_quarantine为900秒，调用方不可任意选择。长DB回调持有job行锁时不能从另一连接续租，最终仍按真实DB时钟核租约；超限效果回滚，不由此承诺20万行性能或已有对应handler。当前backup_verify每20秒续租。旧代不能完成/失败/续租新代；退避5/30/120/600秒、默认5次，人工重试保留ID/occurrence/payload，取消不撤销已成功效果。

0016备份隔离kind现已接runtime/executable_kinds和固定900秒不续租分支；后台需新预览、明确选择和当前密码，真实job/intent/reservation同事务。执行从真实intent重建计划，每代固定选中EX与未选恢复点SH，先结束DB事务再做全hash/同卷不覆盖移动。逐包短事务核State→User→原Session→job→Config→controls，原管理会话须持续有效且不续idle；预算取其三期限和job租约最小值减5秒。最后store.complete只做DB复核/CAS/审计及安全结果，不做文件I/O，文件lease跨最终commit/失败事务后关闭。

root接线后完整jobs在新005e库68通过/1专用图片默认skip（17.02秒），新2a1库图片专项另1/1（1.94秒）。首3073包60/6失败/1skip的六项都因旧restore substitute漏新增before_read参数，实际业务未进入；只修替身显式回调+真实SH与已登记永久hold/gate两个新case，未放宽production，新旧失败/库均保留。不是同次69全绿或新的真实pg_restore执行。

执行facade在新ede库21/21通过（26.84秒），包括origin等control锁时到期的实际先红后修、完整receipt丢完成后的新代只读复用与无receipt partial保留、旧代迟到OS效果但不能成功。短DB检查到OS rename存在窗口，EX防并发同包操作，不宣称文件和PG同事务。全部失败保留reserved原版本，缺收据不猜修；通用retry/cancel在列表与服务均关闭。root新9c9c库真实后台提交→Worker→完成/同POST精确metadata重放及拒绝共11/11通过（11.23秒）；随后2890独立Chrome入队5与完成3分次通过。641c深路径失败及无receipt partial保持；Windows文件层修复实际红绿17、另27 PG/HTTP和24路径验证分次通过。此前25f固定租约/控制25是先前快照。

专用未领取取消服务在新9add库25/25通过（32.29秒），仅本人当前恢复身份与密码、pending/attempt0/gen0/manual0/无attempt/无lease/result/error，EX下全核原包且整个intent目录必须不存在。元数据精确重放先于文件I/O；取消结果的sha256是包含完整取消命令/操作者/动作的摘要，不能当作包hash。job cancelled、原controls v2→available v3和唯一审计同调用方事务，immutable intent/原包/pin/其他hold不删。root专用确认页面已接、HTTP/Chrome继续；已领取或partial reconcile、专用retry与purge仍未实现。

`store.complete`供受信内部handler使用，不接受外部Python代码。handler不得提交/回滚Session或在数据库回调中发布文件；回调和结果模型校验位于savepoint，失败不保留部分效果。完成按部署状态→owner用户→任务→handler业务scope顺序持锁，用户锁持续到外层提交；handler还须同事务复核业务计划及权限。未来账务任务必须接原账单/分录/同步写入入口与唯一实例回执，队列基础通过不代表它们已实现。

隔离接线前runtime默认backup_verify、import_preview（固定parse/preview）和import_apply（固定apply/undo）。当时新主库完整jobs62通过/1图片case明确deselected、0skip（12.54秒），图片在另一新库1通过/3非图deselected、0skip（1.37秒）；不合成同次63。当前另含上述backup_quarantine；trusted pg_dump存在时启backup_create，OS登记target且pg_restore存在时启restore_rehearsal。private import不借管理员身份，四类stage callback和job完成共用事务及当前origin/lease预算。recurring/installment/export仍无handler。

恢复worker使用固定900秒租约，不用另一连接续租；外部目标工作受claim剩余减5秒及模块840秒协作预算共同约束。I/O前结束源事务，最终短事务核配置版本并持head共享锁、源instance/epoch、当前角色及lease generation；失去完成权不写成功。已核验目标的私有receipt绑定owner/job/preview/target，重试必须重新核目标，不能仅凭旧文件报成功；没有receipt的非空/半成品目标保留，绝不清空重做。真实恢复结果与源job成功是两个边界。

backup_create在维护窗口取得共享写者收敛后生成同恢复点dump/设置/原件/缩略图/完整表摘要。300秒固定租约，维护期间不启动会被自己维护闸门拒绝的续租线程，按chunk/summary批次检查协作预算，最后fence仍核真实DB时钟；不声称可硬中止所有OS I/O。稳定backup ID来自受信意图，已完整验证的同源instance/epoch包可在回执丢失后重用，不能再dump或覆盖；半成品保留并安全失败，须用新受控请求/目标处置，不自动删私有目录。

创建worker12个真实PG/pg_dump目标、运行策略9目标均通过；root后补工具缺失/配置感知管理投影后，jobs完整42/42（6.42秒）。创建入队当前密码/recovery/缺工具/同请求幂等单次审计及caller回滚已验，最初一项fixture错误预期全角色撤销后的错误码，按实际portal与独立recovery两层分别断言后通过。创建按钮与实际CLI浏览器旅程接续验证，尚非最终常驻服务。

创建页面实际Chrome4及无工具专项1、相关235回归已接收；包计数/字节包括manifest文件，42再次通过（6.24秒）。恢复源DB围栏11新增与既有42合并53/53（6.69秒），外部恢复操作在此组明确使用替身；真实第二连接证明I/O不持源User/job/head锁、版本/角色前后变化及instance/epoch变化均无成功、失租新代重验。首合并51过2失败为测试缺导入，修复后绿，原失败保留。真实pg_restore、恢复后全表/文件与receipt复用由独立目标专项另验。

A04页面后续正式接收：额外get_job当前角色/可控动作边界纳入jobs23目标，和admin/identity/模板共70/70通过；真实独立Chrome5/5，包括实际独立CLI worker对备份校验、同job手工重试generation2、取消不领取、未实现export保持pending、61行分页和心跳失鲜。控制页二次确认+当前密码/CSRF，service无recovery不操控恢复kind。原两次浏览器UUID pattern错误修复及失败回执保留，详情见[后台验收](../../tests/e2e/admin/README.md)。当前18087仍是临时QA，尚未部署最终常驻worker。

`jobs.administration`提供50行分页、worker心跳、固定元数据详情、当前密码重认证的校验入队/重试/取消，调用方负责CSRF和事务提交。recovery-only只查看恢复类任务；service/owner可查看任务元数据，原始备份能力仍要求独立recovery角色。心跳超过60秒显示失鲜，UUID不包含主机名或PID。后台页面正在集成，尚未取得这一新任务页面的浏览器验收。

本轮独立PG测试22项通过，包含两个真实连接竞争、旧代迟交、回调失效savepoint回滚、完整五次退避、手工重试、取消、epoch/owner禁用，以及真实pg_dump包校验成功/同长损坏/校验前后撤权。额外第二连接在effect中及complete返回后外层commit前禁用owner均遇受控锁超时，证明用户锁未提前释放。首轮13项中2项失败来自终态与lease字段短暂不一致被autoflush写入，修复后原失败与新增目标合并通过，失败回执保留。详情管理新分支与后续页面测试另记，不将分项当作全量作业系统交付。

2026-10-23全新jobs库解析/预览整合59/59（9.84秒），含真实61行/领域预览、同意图回放、source期限/退出阻断、末lease回滚后新代复验；无正式ImportBatch。此59包含旧恢复围栏53，不能相加。恢复实际pg_restore/失完成复用backend6及Chrome4+1、262相关回归另证；不是53中的替身证明。API/worker/cleanup CLI已绑定独立诊断策略并close；真实持久服务尚未部署。
