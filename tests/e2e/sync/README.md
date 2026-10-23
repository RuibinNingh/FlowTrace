# 同步真实联测

2026-10-21 主代理使用隔离 `127.0.0.1:18080`、本机 PostgreSQL 开发库和合成账号运行 Flutter VM 真实 HTTP 联测，`apps/flowtrace/test/live/sync_http_test.dart` **1/1通过**。两个客户端各有独立 SQLite executor、身份服务和client_id；此结果不是Android界面验收。

实际流程：创建专用账本/标签→服务端成功提交后丢弃回包→同operation及冻结正文重试，仅产生revision1→两个客户端各自离线修改同记录→首个提交revision2、第二个显示revision_conflict→选择以新operation保留第二端内容→双方一致revision3→删除墓碑传播→正常删除本轮专用账本并退出两测试会话。没有操作真实个人账目。

运行时设置 `FLOWTRACE_SYNC_QA_FILE` 指向忽略目录的合成凭据JSON，包含server/username/password；用 `flutter --no-version-check test --no-pub test/live/sync_http_test.dart` 执行。脚本拒绝18080回环地址之外的服务；默认不设置该环境变量时跳过，不把跳过算为成功。

Android `integration_test/sync_test.dart` 已真实通过1/1：同账号独立会话产生两次冲突，分别从界面选择服务器版本与本机修改，HTTP核对最终revision4；恢复备份列表与详情可查看未传输入。该测试的恢复状态由本机requireRebuild构造，真实数据库恢复由下一项单独证明。

2026-10-21 `server/.venv/Scripts/python.exe tests/e2e/sync/recovery_harness.py --reset-isolated` **通过**，启动独占的18083与`flowtrace_test_recovery_local`；Flutter `test/live/recovery_http_test.dart` 1/1通过。实际pg_dump保留合成用户/会话/基线账本与账户，随后ACK支出12500使余额100000→87500，并保留未发标签与草稿；停止本轮进程子树后pg_restore，事务锁下更换epoch且保持instance；客户端完整备份、新client登录和快照恢复后，缺失支出、未发标签、账户余额和私人资金影子4项差异可见，磁盘重开仍保留备份/草稿，旧操作重放0。

辅助脚本使用精确数据库/回环端口与工作目录保护，Windows私有Job持有本轮服务子树；没有按端口搜索终止其他服务。首次dump后停止检查失败时安全中止，改进关闭与有界等待后完整重跑通过。18080演练前后instance/epoch不变且ready200，18083完成后关闭。凭据、SQL备份和原始运行日志在忽略的work目录，脱敏回执在`outputs/validation/P2/recovery-http-receipt.json`。

这一结果范围是Windows Flutter VM、磁盘SQLite、合成MemoryVault和专用PostgreSQL的真实协议恢复；生产/Linux部署、附件字节备份、系统安全库恢复仍未验证。本地与模拟传输测试在`test/data/`，服务端PG测试在`server/tests/sync/`；附件断网重试另行验收。

## 同 UUID 跨账本移动

2026-10-21 独立 `book_move_harness.py` 与 `apps/flowtrace/test/live/book_move_http_test.dart` 在377基线非editable wheel、本机PostgreSQL18.6专库 `flowtrace_test_book_move_local`、自持 `127.0.0.1:18084` 完成真实HTTP **1/1通过**。不同账号共用账本并不共用私人账户权限。夹具包含一个账本owner、一个双方editor账号的两个客户端、一个来源-only viewer；四客户端分别使用真实磁盘SQLite与独立附件文件目录，凭据使用合成MemoryVault。

实际调用正式 `LedgerBookMoveService`、`AttachmentTransfer` 和 `SyncEngine.refreshScopes`：声明上传2张不同hash的合成PNG→创建私人账户及带图支出125分→明确目标分类/标签→准备目标ready克隆→同一计划重复确认只保留一个operation→真实服务端成功后人为丢弃一次回复→同operation、冻结正文重试→两端一致revision2。本人账户在移动入队及重放前后始终9875，来源/目标报表分别0/125；目标尚无canonical时本机报告显式不可用，不创建假影子。来源-only viewer收到原scope最小墓碑，正文和附件为空，目标GET为403；精确时间微秒及原业务时区保持。

再对另一个25分账单准备目标克隆，owner在确认前撤销移动者的来源权限。确认经共享权限通道拒绝入队，来源公开记录及受控下载文件立即清理，本机原件与未提交草稿仍保留；账单没有移动，私人账户最终9850。Python随后独立SQL核对唯一bill/revision、唯一正式receipt、-125分录及book_id、refs/图片hash、被拒账单的原来源revision1，并确认本轮四会话均退出。

从仓库根运行：

```powershell
server/.wheel-move-venv/Scripts/python.exe -I -S tests/e2e/sync/book_move_harness.py --prepare-only
server/.wheel-move-venv/Scripts/python.exe -I -S tests/e2e/sync/book_move_harness.py
```

预先建立专库及忽略的 `work/flowtrace-dev/postgresql/server-book-move.env`；脚本严格检查双数据库URL、回环地址/端口/库名、非editable安装和wheel全部包/资源字节，显式迁移head，不提供reset/drop。`--prepare-only` 不启动HTTP或Flutter。正式执行需要独占Flutter工具窗口；harness只持有本轮Flutter进程子树及18084线程，finally关闭。`FLOWTRACE_BOOK_MOVE_QA_FILE` 只由harness指向本次忽略目录的合成配置，未设置时该live测试默认skip，不能计为通过。

首轮使用不受当前规则允许的expense+fee输入，在入账前被 `bill.transfer_fields_not_allowed` 拒绝；改为合法无fee支出125，手续费三腿由既有独立领域/PG测试覆盖。第二轮误把包含删除项的 `LedgerView.find` 期待为null，改为严格检查可见bills不含该项且原scope墓碑deleted/无正文；第三轮误读报表API包装层，改按闭合 `BookReportResponse.report` 核对available与精确总额。三轮失败均只修夹具，未改生产规则或降低金额/授权断言，原日志保留；第四轮完整流程通过。Drift在同进程创建多个独立数据库实例时输出已有debug提示，实际executor和文件路径分别独立。

最终18084无监听、本轮合成会话活跃数0，专库夹具保留供核验；没有重置其他库。原图、SQLite、凭据和原始日志在忽略的 `work/flowtrace-book-move/`，脱敏回执在 `outputs/validation/P3/book-move-http-receipt.json`。18080由主代理独立升级至377且instance/epoch保持，这个harness没有调用或修改18080。结果范围为Windows Flutter VM的生产服务/存储/HTTP协议，不包含移动页面点击、系统文件选择器、真实Android/Web/Windows应用或Linux部署验收。
