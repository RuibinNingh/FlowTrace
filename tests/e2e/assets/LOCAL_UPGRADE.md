# 本机P4候选切换准备

截至2026-10-22，这是已核对代码和现有运行方式的待执行方案。没有停18080、备份/迁移其数据库或切换运行包。此处只针对现有本机开发服务，不能作为Linux或生产部署验收。

## 已确认的输入

| 项目 | 当前与候选 |
|---|---|
| 现有进程 | 主代理持有的18080非editable377包，`work/flowtrace-dev/run-backend-p3-move-wheel.py` |
| 现有数据库 | `127.0.0.1:55432/flowtrace_dev_local`，URL仅从忽略的`work/flowtrace-dev/postgresql/server-local.env`进程内读取 |
| 现有文件数据 | `work/flowtrace-dev/backend-data`，不新建空数据目录替换 |
| 现有迁移 | `0005_attachment_tickets`；旧包逐次ready检查会要求这一head |
| 候选包 | `server/dist/assets/flowtrace_server-0.1.0-py3-none-any.whl`，SHA256 `473a0a4289e6635f8e9047dba24910ea8131109fd87f21551a1ff2c5d2345e1c` |
| 独立安装 | `server/.wheel-assets-venv`，生产锁、非editable，96个包资源与wheel逐字节相同 |
| 新迁移 | `0006_assets_currencies`只新增五个私有配置表及索引/约束，不更新原JSON、账单、分录、instance或epoch |
| 新接口 | 41路径/112schema/47唯一操作；assets-v1/currencies-v1；旧377包为29/78/31 |
| 原包保留 | `server/dist/move/`及`server/.wheel-move-venv`，不覆盖/卸载 |

候选的服务端完整411、后补RR2、独立wheel HTTP36及生产Flutter VM HTTP1均已有回执；当前隔离浏览器使用18085/18185，不能把它当成18080已升级。浏览器全部结束及主代理只读核对后才能进入下列维护窗口。

## 放行后按序执行

1. 固定新维护UUID和忽略备份目录，记录旧进程归属、候选与原wheel SHA、API ready/server-info、实际DB名称/地址/owner、迁移head及原instance/epoch。连接只接受`flowtrace_dev_local`/loopback55432/`flowtrace_dev`，不复用资产测试库的env。记录只输出摘要，不输出URL密码、会话或账目。
2. 主代理通过自己持有的终端会话优雅关闭18080，确认监听已退出且没有其他写入/附件GC作业。PG进程保持运行。不能仅凭历史PID关闭进程，也不能使用泛化端口清理。SQL导出能保持数据库一致快照；数据库与原件文件共同备份还需这一步停止应用写入。
3. 使用同版便携PG18的`pg_dump --format=custom --no-owner --no-acl`备份完整单库；密码通过私有子进程环境或受控passfile传入，命令参数不用含密码的URL。备份路径、stderr与SHA均留忽略目录。保持写入暂停，复制整个原`backend-data`到同一备份批次，并记录相对文件名、大小、SHA。此备份不复制PG正在运行的物理data目录。
4. `pg_restore --list`只验证归档可读，不能声称已可恢复。由主代理明确批准后创建全新、空的`flowtrace_test_upgrade_restore_`专库，使用`--single-transaction --exit-on-error --no-owner --no-acl --dbname`恢复到此专库；不用`--create`或`--clean`，避免归档中的原库名导致写回源库。非空目标直接拒绝，不reset/drop。核对旧head、instance/epoch、全部旧表行数/受控摘要及附件refs与复制原件；身份和私人内容只作进程内比较。归档没有角色/tablespace全局对象，此演练使用已存在的相同角色。
5. 备份和恢复验证全部通过后，使用候选包内迁移入口对原开发库显式`upgrade`，不从editable源码取迁移。安装路径仍为已验独立venv；通过受控启动脚本在导入前加入该venv的site-packages。核对原URL/数据目录后运行包内`flowtrace_server.tools.migrate`，不让API自行迁移。迁移失败即停在维护状态，保留错误摘要与备份，不自动降级。
6. 独立连接确认head0006、原25表不变、新增五表初始为空、instance/epoch不变、原附件文件摘要不变，再以同一原`backend-data`和原开发配置启动候选18080。新CORS来源由主代理明确设置；保留既有18181/P3固定产物，不把P4构建覆盖到该目录。
7. 验证ready200、live、server-info原身份及新增能力、实际OpenAPI41/112/47和匿名读取安全拒绝。优先进行不写原数据的烟测；如需合成账号写入，单列新UUID并正常墓碑/退出。记录新进程归属、包SHA、迁移和备份回执后再开放本机普通P4入口。

`build/web-p4`是主代理已固定的普通`lib/main.dart`产物，当前SHA为`e14b234aad6a6deead2a8f2c21040cb41daab6b578a34b112fe045947b1eba81`。验收完可另设本机固定路径/端口；不改18181已有P3文件。API与Web服务分别安装、启动和验证。

## 回退边界

旧377包的ready检查要求0005，不能在0006原库上简单换回旧进程就称为恢复。新增账户kind和冻结FX也可能无法被旧包解析，保留原wheel仅提供恢复旧备份后的运行选项。迁移`downgrade()`明确拒绝，不能手动删表冒充无损回退。

切换尚未接收新写入时，可在受控维护窗口按已演练流程恢复旧批次到独立验证库，再由主代理决定原库恢复和旧包重启；文件原件必须与同批次数据库匹配。切换已发生新写入后，旧备份会丢失新状态；不得以“保留旧epoch”为由让客户端继续增量同步。需要先保全新状态，按恢复协议更换epoch并触发客户端完整备份/重建，另行制定数据恢复范围。

官方核对依据：[PG18 pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html)说明单库一致导出与自定义归档，[PG18 pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html)说明显式目标、归档恢复和错误处理。这里的可恢复结论只能在第4步真正完成后给出。
