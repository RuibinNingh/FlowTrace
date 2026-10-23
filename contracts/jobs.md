# 固定类型作业契约 v1

状态：P0 设计，P4/P5 分阶段实现。API 进程不内置周期调度，独立 Python worker 使用 PostgreSQL 队列；不依赖 Redis、Celery 或 Docker。

2026-10-23实施状态：默认verify/import_preview/import_apply及backup_quarantine，create/restore要求OS工具/目标，API不启动worker。stage17已挂普通main并协商能力，固定金融callback与job完成同事务；备份真实任务引用/可信登记已接。隔离facade21、root后台→Worker11及独立Chrome入队5/完成3为分次通过；完整jobs68/1图片默认skip，另图片1分开通过。未领取专用取消PG25已验、页面已接，当前不开放已领取/partial重试或reconcile。recurring/installment/export未实现。当前事实与历史独立证据见[模块说明](../AI/modules/jobs.md)。

作业状态 pending → running → succeeded / retry_wait / failed / cancelled。数据库保存 job_id、kind、owner/scope、occurrence_key、rule_revision、available_at、attempt、lease_owner、lease_until、lease_generation、固定 result/error code。普通用户只读本人业务作业；管理员看元数据，受控重试仍使用原 occurrence_key。

白名单 kind：recurring_occurrence、installment_occurrence、import_preview、import_apply、export、backup_create、backup_verify、restore_rehearsal、backup_quarantine。高权限数据切换由受控恢复执行身份处理，管理面板不接受 shell/SQL/任意目录作为任务输入。secret/账单正文不得进入诊断列表。

调度器按 (plan_id, occurrence_date/ordinal) 唯一键创建实例，规则版本同时留存但不能让编辑规则重复生成已存在期。领取用 `FOR UPDATE SKIP LOCKED`，递增 generation，普通任务默认60秒租约；服务器固定import_preview/backup_create为300秒、import_apply/restore_rehearsal为900秒，不接受调用方任意设置。当前backup_verify每20秒续租；长数据库effect已持job行锁时不从另一连接续租，必须在预算内完成，最后仍核真实数据库时钟，超时回滚。这不表示对应handler或20万行性能已实现。完成前在事务内锁作业行并核对owner、generation、租约及计划/权限有效性；旧worker失租不能提交。账单、分录、同步、实例回执和完成状态同事务，唯一键是最后去重保障。

暂时错误退避 5/30/120/600 秒，最多 5 次默认尝试（初始执行及 4 次重试）；永久权限/引用错误直接失败。取消在未提交前生效；已提交的账单不能通过改作业状态撤销。每天补跑最多 100 实例/轮，停机后按业务时区和固定月末规则补齐，客户端只显示预测，不自行生成服务器任务账单。

文件类任务在私有暂存目录产生内容、校验清单后原子发布；结果下载重新鉴权。备份默认维护窗口，暂停新写并等待在途事务/worker 收敛，数据库+附件+版本/hash 同恢复点；恢复演练始终隔离。真正旧备份切换必须改 sync_epoch、撤销会话，使客户端先保护完整本地快照。

隔离固定900秒不续租，实际预算取job租约与原管理会话三期限最小值减5秒。只允许当前recovery、源/config和本intent精确reserved CAS，选中EX及未选恢复点SH跨最终提交。文件移动与PG不属于同一事务；完整effect receipt才允许同job新generation复核复用，未知partial保文件与reservation。通用取消/重试不适用于隔离；专用未领取取消须当前本人恢复身份/密码，pending/attempt0/gen0/manual0/无attempt/lease/result/error，EX全核原包且整个intent目录不存在，再同事务取消与解除本intent预留。精确取消重放摘要绑定完整命令，不能当包hash；旧origin过期不阻止新的当前会话执行零效果释放，但不授权重新执行原隔离。当前没有永久purge、网页恢复或已领取/partial reconcile。

验收：两个 worker 抢同一期、租约到期旧 worker 迟交、成功提交后崩溃、人工重试、暂停/撤权、月末闰日补跑。实际替换数据的恢复另需受控目标核对，不以作业文本存在宣称已实现。
