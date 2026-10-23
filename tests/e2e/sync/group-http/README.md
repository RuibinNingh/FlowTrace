# 真实分组同步联测

> - 职责：独立PostgreSQL、真实stage worker和Flutter VM文件SQLite的组同步联测。
> - 入口：[Python harness](../group_harness.py)、[Flutter live目标](../../../../apps/flowtrace/test/live/group_http_test.dart)。
> - 不变量：只管本轮18093宿主/子进程/合成账号；不迁旧库、不伪造主能力、不发送客户端outbox。
> - 必跑：主代理授予串行SDK窗口后运行harness；须独立新库、明确head、真实main能力与宿主关闭后验。
> - 相关：[组同步分册](../../../../AI/plans/flowtrace/group-sync-implementation.md)、[原联测入口](../README.md)。

2026-10-23（Asia/Shanghai），主代理仅将新专库`flowtrace_test_p5_jobs_164327289e8e48a6`升到`0013_backup_retention`，50表/初始0users，旧库不迁。随后串行格式化/分析live目标并运行真实harness，**1/1通过，7秒**，日志`outputs/validation/P5/group-real-http-main1.log`。本轮UUID为`e7b80efcd11748268ef8839b0468bd48`；忽略目录的[脱敏回执](../../../../work/flowtrace-group/live/e7b80efcd11748268ef8839b0468bd48/public-receipt.json)已核对。准备阶段的源码摘要与拒绝回执保留，不能把旧“未运行”快照重写成成功证据。

owner/viewer各收到201笔账单与3个unit receipt，其中publication receipt各1；支出均25125，owner私有现金余额`9007199254715868`，viewer无私人账户。两个客户端均真实成功page丢包1次、同token续传、离线磁盘SQLite重开、冻结行与原草稿不变、额外push为0；private PNG owner下载/hash成功、viewer403。SQL独立核3个正式publication chunks、201笔/201分录、仅1个seed sync receipt和private原图scope保持。最后活跃测试会话0、强制撤销0、末尾额外清理handle0，自持HTTP线程已停止。此结果是Windows Flutter VM协议/文件SQLite证明，不等于普通桌面/浏览器/Android界面验收。

正式main另6项HTTP在新`flowtrace_test_p5_jobs_6a2ebebc0cb94572`/head0013通过，最终3.85秒；日志`outputs/validation/P5-group-http-mounted-cleanup-final.log`，关闭后验`outputs/validation/P5-group-http-mounted-postconditions.json`。该PG测试fixture的SQL会话撤销与真实live客户端正常退出明确分开；12个合成用户及领域数据保留，活跃会话/未collected handle均0，instance/epoch保持。

## 固定输入与运行边界

隔离环境文件位于忽略目录`work/flowtrace-dev/postgresql/server-p5-restore-164327289e8e48a683ce87355f80a950.env`，不把DSN/密码写入版本或终端。脚本严格要求本机PG55432、flowtrace_dev角色、无连接query、两URL一致及新UUID jobs库名，连接后再核真实数据库/主机/端口/用户与明确head。18093若已有监听则中止，不按端口杀进程。

只读准备命令（已验证该专库head；不重建已有夹具）：

```powershell
server/.venv/Scripts/python.exe tests/e2e/sync/group_harness.py --env-file work/flowtrace-dev/postgresql/server-p5-restore-164327289e8e48a683ce87355f80a950.env --expected-head 0013_backup_retention
```

此命令只检查现有新库并保存准备回执，不创建用户、不启动HTTP/Flutter。加`--seed`才临时启动自持API线程、创建合成账号和生产stage；没有`--run-flutter`绝不运行SDK。`--run-flutter`必须与`--seed`或已有`--fixture`并用，且提前获得主代理SDK窗口。源文件来自当前`server/src`，当前未固定wheel，不能称为最终分发包验证。

服务由生产`main.create_app`创建。stage若尚未挂main，仅在该受信harness显式include，fixture明确`stage_test_only`。可选`--test-group-router`只供组件准备，不改server-info；Flutter live强制group路由真实在main且server-info包含`group-sync-v1`，不把lease能力强设为true。正式集成后可用原始main的组路由，无需额外include。

## 已验证的真实路径

1. 新库创建owner/viewer并共享真实账本。owner经HTTP登录与普通sync writer建立私人现金账户，期初`9007199254740993`；真实上传私人用户域PNG。图片保持私人孤儿，不转入共享账本；转入账本本应按账本权限共享，不能谎称该图片仍只本人可见。
2. 原始JSON 201条支出各125分经stage create/upload/seal及生产Worker的parse/preview/apply，形成真实多commit ImportPublication。账本支出合计25125，私人余额精确为`9007199254715868`。原件、预览、正式job与publication留在本轮新库/数据目录。
3. 每个Flutter客户端使用生产IdentityController、SyncEngine.pullLatest、ApiClient默认1MiB/8秒和独立文件SQLite。先保存并冻结一个合法本机分类命令；只拉取，全程push计数必须0。
4. TCP已返回publication第一data页成功响应后，测试transport排空真实响应再丢包。检查组内账单仍0、正式cursor恰为该unit前一个安全prefix；关闭SQLite但不退出该测试会话，真实离线重开后检查原request/page token、完整冻结行与草稿不变。
5. 恢复同一真实session/client后继续同page token，完整201笔一次组安装；核cursor完整checkpoint、同组receipt恰一份、owner/viewer支出一致且私人账户仅owner可见。owner可下载原PNG并核hash，viewer被403拒绝。
6. 两个客户端正常退出。Python独立SQL核201笔/201分录、原余额、唯一seed sync receipt（客户端没有额外push）、正式stage和private图片scope保持；显式清理本轮用户handle，最后关闭自持Flutter进程Job与API线程。失败时保留资料，仅撤销这两个新建合成用户的会话，并单独记录强制撤销，不能算正常退出成功。

执行前静态审阅修复了初登录先建立SyncStore active绑定再刷新scope，并改用OpenAPI路径识别FastAPI延迟IncludedRouter，避免误判并重复include。主代理完成这些修复与SDK校验后才实际运行本次成功旅程。凭据与MemoryVault均为合成夹具；系统安全库、Android、普通浏览器/Windows界面、Linux部署与完整业务仍未验。
