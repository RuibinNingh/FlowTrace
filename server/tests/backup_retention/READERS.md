# 备份读者与创建锁验证

> - 职责：记录完整包读者的源共享锁、创建独占锁和恢复上下文生命周期证据。
> - 入口：`backups/administration.py`、`service.py`、`rehearsal.py`、`cli.py`和`worker/runtime.py`的固定备份分支。
> - 不变量：先源包锁后目标锁；长文件工作不保留数据库事务；未知旧包不自动登记；不删除、改名或覆盖既有包。
> - 必跑：`test_reader_leases.py`、`test_restore_reader_leases.py`及受影响的`backup_admin`、`backup_rehearsal`、`jobs/test_worker.py`和`jobs/test_backup_create_worker.py`。
> - 相关：[受控保留分册](../../../AI/plans/flowtrace/backup-retention-controlled-cleanup.md)、[数据工具](../../../AI/modules/data-tools.md)。

2026-10-23（Asia/Shanghai），本文件记录读者接线这一分包；主代理维护整体保护、预览、任务引用与交付状态。Git为main无提交基线，未提交、推送或部署。

## 当前锁覆盖

- 原始归档持源SH，从首次manifest、完整校验、逐文件ZIP复制到末次manifest复核和独立ZIP摘要完成。返回`PreparedDownload`时释放源锁；慢速HTTP流读取独立ZIP，仍按原生命周期关闭和清理这个临时ZIP。
- 目录及详情元数据用不等待的SH（timeout=0）；EX占用时返回`unavailable/backup_busy`。这些结果仍只是manifest声明及过去任务证据，不声称当前完整包已通过校验。
- Worker校验先SH，再用独立短事务调用`require_backup_readable`并提交，随后在SH内读文件。CLI固定包校验走`verify_backup_leased`。
- 创建及同UUID重试都用同一个EX覆盖存在检查、创建或重验、最终文件复核和源identity/epoch检查。内部token校验活动状态、绝对root和UUID，避免已持EX者再开句柄申请SH/EX；关闭、错root或错ID的token均拒绝。
- 恢复preview先源SH再目标锁；目标检查完成释放目标锁，prepared对象仍保留SH至调用方最终授权事务提交后的`finally.close()`。submission先SH后目标锁，两者一起保留到enqueue事务提交后关闭。prepared均有内部trust及closed检查。
- Worker恢复持源SH涵盖完整hash、隔离恢复、实际目标复验和私有receipt写入。低层公开`restore_isolated`也持源SH直至源文件复制、数据库摘要、epoch/会话/余额后验结束；外层SH可继续覆盖额外目标后验。异常均退出context释放锁。

`service.verify_backup`是明确的底层校验函数：调用者必须已经持有同包SH或EX，它不重复取锁。创建者在EX内调用它；归档和恢复在更宽的SH上下文内调用它。普通operator/worker校验需选带锁入口，不把直接底层校验当完整生产读者。

恢复的`before_read(identifier)`只接收已闭合record/payload解析出的UUID，在源锁内先完成短控制门并提交，再开始源文件I/O。当前HTTP和Worker保留原认证、角色、配置及任务终态fence；该hook不自行授予权限。已登记历史epoch包允许读取，其stamp保留原来源；包状态必须可读。源包的实际摘要仍需当前校验，控制元数据不是权限凭证。

可信CLI可以显式指定其他备份root。创建和恢复均从该root的父目录派生同一控制锁命名空间，固定服务root与`data_directory/backup-controls`一致。CLI隔离恢复配置的是目标数据库，不能用目标数据库的控制表冒充源数据库控制门；源只持文件SH，操作者仍须有受信源文件访问权。本分包没有新增CLI源数据库凭据参数。

## 实际回执

首次归档3个新增目标全部出现预期失败，回执`outputs/validation/P5-backup-reader-leases-red.log`。修后通过了共享读者/EX拒绝、实际复制阶段和失败释放；保留首次失败，不把它改成通过。

在唯一新库`flowtrace_test_p5_jobs_5ce5ee1b5e9f44af`（稳定head`0014_import_source_release`）运行：

```powershell
server/.venv/Scripts/python.exe -m pytest server/tests/jobs/test_worker.py server/tests/jobs/test_backup_create_worker.py server/tests/backup_rehearsal server/tests/backup_admin server/tests/backup_retention/test_reader_leases.py server/tests/backup_retention/test_restore_reader_leases.py -q
```

该次**76/76、0skip、26.21秒**，日志和JUnit为`outputs/validation/P5-backup-reader-integrated.log`及`.xml`。包括真实pg_dump、失completion后的同ID新generation复用原字节、权限前后撤销、原HTTP与归档并发、恢复授权/确认/精确重放。未使用三个历史隔离恢复目标。

随后只新增元数据非等待SH和创建短控制门hook：受影响create12与元数据2共**14/14、3.69秒**，`outputs/validation/P5-backup-reader-create-metadata-final.log`及`.xml`；owned reader12、恢复锁6及原纯boundary6共**24/24、4.00秒**，`outputs/validation/P5-backup-reader-create-gate.log`。各次范围不同，不相加为一次新的完整回归。相关生产与测试文件Ruff通过。

锁专项使用真实Windows文件锁；其中合成dump/恢复callback只证明源锁、顺序和异常生命周期，不冒充真实pg_dump/pg_restore。真实数据库备份的证据来自上述PG目标及主代理另行接收的非空stage恢复专项。

## 边界

本文件所记读者分包未进行真实备份隔离、删除、迁移旧库、包自动注册、旧保护记录释放或持久服务部署。随后委派的数据库任务hold/已验证新创建包登记已单独整合，见[任务引用](JOB-REFERENCES.md)及其新0015专库证据，不能由本文件的旧文件锁回执推算为已完成。测试只在新UUID专库和pytest受控临时目录操作；旧QA包、旧测试库和既有恢复目标保持。

随后后台候选与显式登记沿用同一源SH生命周期，实际hash阶段第二连接NOWAIT验证不持User/AdminControl/config行锁；列表metadata改为不等待SH，忙包立即protected。helper24、生产main HTTP14与root独立Chrome7分次证据见[页面验证](PAGES.md)，仍无quarantine/purge效果。
