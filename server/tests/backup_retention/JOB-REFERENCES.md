# 固定备份任务的真实保护引用

> - 职责：记录新创建包登记、固定任务hold和终态重试保护的实际接线与证据。
> - 入口：`backups/job_references.py`、`jobs/administration.py`、`backups/rehearsal.py`、`worker/runtime.py`。
> - 不变量：不伪造管理员或密码；文件验证不持数据库行锁；注册与完成共享同一租约围栏事务；未知旧包不自动认领；released hold不复活。
> - 必跑：`test_job_creation_proof.py`、`test_job_references_pg.py`、`jobs/test_backup_create_references.py`及关联Worker、入队和恢复HTTP目标。
> - 相关：[文件读者](READERS.md)、[保留清理分册](../../../AI/plans/flowtrace/backup-retention-controlled-cleanup.md)、[数据工具](../../../AI/modules/data-tools.md)。

2026-10-23（Asia/Shanghai），本分包使用全新`flowtrace_test_p5_jobs_b3a1c67d8e3d4fd4`，稳定head`0015_import_requirements`。原5ce5/head0014与6a2e/head0013未迁移。未执行隔离、删除、文件改名或持久服务部署。

## 当前接口与生命周期

`retain_job_backup(session, job_id, for_retry=False)`从实际任务重读闭合payload、当前owner/角色/epoch和control。已登记包必须`available`，按真实job/owner创建唯一v1 hold并递增control版本；同绑定活跃hold幂等，released一律`backup_reference_released`。普通校验与创建用`job`，恢复用永久`restore_intent`。未登记包返回legacy保护结果，不插入control或hold。

该接口接在校验/创建入队以及人工重试的原事务里。恢复enqueue先认证actor、锁实际job，再核config/control并建立永久hold；过期或旧epoch的原恢复意图重放只返回已提交元数据，不建新引用、不改原绑定。Worker读者短控制门另调用`require_job_reference`，避免绕过管理重试入口复活已释放引用。历史无hold任务仍由实际active job及所有恢复意图的保守候选检查保护。

创建Worker在EX下、首次目标不存在时，以私有不覆盖的`creation-start.json`绑定job、owner、backup、source及随机nonce；完整新包校验后写`creation-complete.json`绑定manifest SHA。两份记录在`backup-controls/<UUID>/`，不进入包正文、公开任务结果或日志。相同job重试可从start重新全包验证后补complete，覆盖真实创建完成与journal完成之间的崩溃窗口；partial/坏包保留且不覆盖、不重dump。缺少start的既有包保持legacy，不补造来源。

`prepare_created_backup`持源SH核journal与完整包。新来源证明必须通过登记所需的严格成员集、数据库摘要及`PackageStamp`校验；无journal的旧包沿原`verify_backup`规则读取，允许原先合法的无summary或额外未列文件，仍保留SH但不给新登记资格。journal只有一份、字段/nonce/owner/source/hash冲突、超界或链接均拒绝，不回退为legacy。

`register_created_job_backup`仅在`store.complete`的当前owner/epoch/实际job/lease围栏内消费可信prepared对象，核同settings/source/manifest，登记同包control并建立创建job hold。完整验证位于数据库行锁之外，prepared SH跨过最终提交后才关闭；任何后续租约/权限/owner/epoch/取消失败都回滚control/hold，原文件和私有来源记录保留。Worker从不构造管理员principal或密码。

锁顺序遵循原部署/管理控制→actor或owner→实际job→config/control；文件锁先于这些短事务。常规任务结束或取消不自动释放hold。显式终态证明释放后，原job重试受控拒绝，管理页给出“到备份页新建校验任务”的提示；新请求可以形成新的job/hold。恢复hold即使任务取消仍永久保留。

## 实际验证

文件/journal/closed首包13项通过后，补旧格式兼容，共**14/14、0.79秒**；`outputs/validation/P5-backup-job-provenance-legacy.log`。首轮测试错误地读取了正持EX的锁文件，在Windows出现预期文件锁拒绝；已改为只快照两份journal，旧失败回执保留，不改生产锁行为。

独立PG adapter先**12/12、4.61秒**；随后生产恢复enqueue/永久hold/历史重放专项**1/1、1.05秒**。实际source checksum及DB引用均执行，恢复目标探测为合成callback，不声称pg_restore。这两个回执分别为`P5-backup-job-references-pg1.*`、`P5-backup-job-references-restore.*`。

最终关联整合**124/124、0skip、39.43秒**，`outputs/validation/P5-backup-job-references-integrated3.log`及`.xml`。范围含Worker真实dump、创建重试、归档/恢复HTTP、读者锁、14个provenance、14个引用PG及原retention service。特意先跑retention service再跑Worker，核对模块收尾不会让其他fixture角色/待领取任务污染后续测试。

前两轮保留：首轮119通过/4失败，原因是旧测试对整个共享库断言0/1；现按本fixture owner UUID精确计数，仍严格核单任务、单audit及事务回滚。第二轮122通过/1失败，原retention fixture撤权后保留自身pending任务导致后续Worker正确领取其他任务；现精确取消本fixture active工作，仍保留不可删除的job/actor/hold。仅该新专库前轮2个自有已撤权fixture任务被取消，保护四表摘要前后相同，`P5-backup-reference-fixture-job-closure.json`；无包删除或保护记录删除。

另跑实际pg_dump→生产Worker登记专项**2/2、1.36秒**，`outputs/validation/P5-backup-created-registration-real.log`及`.xml`：正常首代和真实过期lease后二代均只dump一次、只产生一control及一hold；过期首代无SQL登记，二代重用原manifest/数据库/complete proof字节，登记时SH占有，完成后context关闭、EX可重新取得。该2项与124是分次执行，不合称同次126。

测试fixture按真实保护FK保留不可变证据和actor/job，只撤本fixture会话/管理角色、取消本fixture active工作并移除自有Worker心跳；无引用的queue case沿原清理。未把审计摘要当授权凭证，未删除hold来迁就测试。源码及相关测试Ruff通过。

## 尚未验收

本包没有公开保留清理路由、quarantine/purge handler或删除文件。控制表/hold通过不等同于整个清理产品旅程完成；实际候选每次仍须检查当前control、pin、hold、active job和所有restore intent。Linux、干净Windows恢复、原生桌面安全输入及最终服务部署另按主计划验收。Git无提交基线，未提交或推送。

上段是本任务引用分包的范围边界。随后新增候选/显式登记/pin/零删除报告七条后台路由，沿用当前hold/intent保护，不提供它们的释放按钮；[页面验证](PAGES.md)单列helper、HTTP及浏览器边界。quarantine/purge handler及文件效果仍未实现。
