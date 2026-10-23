# 备份保留页面独立浏览器夹具

> - 职责：在全新隔离库和固定端口给真实Chrome提供可重复候选/登记/pin/零删除旅程。
> - 入口：`prepare_retention_fixture.py`与`serve_retention.py`；普通main应用，无fake路由或cap。
> - 不变量：不复用旧库/包/恢复target；凭据只在ignored私有JSON；固定Loopback18092；源包字节/目录前后相同。
> - 必跑：准备前空库/空data检查、seed后`--verify`；浏览器退出全部角色后再次`--verify`并记录owned宿主精确关闭。
> - 相关：[后台模块](../../../AI/modules/admin.md)、[保留分册](../../../AI/plans/flowtrace/backup-retention-controlled-cleanup.md)、[页面测试](../../../server/tests/backup_retention/PAGES.md)。

2026-10-23（Asia/Shanghai），此夹具只测hash、显式登记、pin及零删除页面。`database.dump`是合成PGDMP测试头，`restorable_dump=false`，不是实际pg_dump/pg_restore证据。不会自动登记未知包，也没有文件清理动作。

准备脚本只接受`work/flowtrace-dev/postgresql/server-p5-restore-<新UUID>.env`中的Loopback测试DB，名称`flowtrace_test_p5_admin_<16hex>`，data必须在该任务`p5-restores/<32hex>`且尚不存在。确认public schema没有任何表后，显式升级已冻结`0015_import_requirements`；非空旧库拒绝，不替旧库迁移。需先通过现有受控工具创建新UUID空库。

```powershell
server/.venv/Scripts/python.exe tests/e2e/admin/prepare_retention_fixture.py --env-file <新环境绝对路径>
server/.venv/Scripts/python.exe tests/e2e/admin/serve_retention.py --fixture <输出fixture.json绝对路径>
server/.venv/Scripts/python.exe tests/e2e/admin/prepare_retention_fixture.py --verify <输出fixture.json绝对路径>
```

宿主只接受`--fixture`，严格校验purpose、输出目录、DB/data/source/head绑定。固定`http://127.0.0.1:18092`，`access_log=false/reload=false/workers=1`，没有任务worker。root先查端口，再以Hidden启动自有宿主，记录PID/启动时间/命令和日志，最后精确关闭；它不是持久测试服务安装。只用独立短profile Chrome，不用用户Edge或个人会话。

fixture purpose固定`flowtrace-retention-browser-synthetic`，输出`outputs/validation/P5/admin/retention-<UUID>/fixture.json`；`credential_file`指向ignored私有JSON。该JSON有`owner/recovery_only/service_only`的`username/password/user_id`和一个`wrong_password`，标准输出不含凭据。owner三角色，另外两个各只有单一角色。seed使用真实短期管理会话完成服务登记/pin后撤销，浏览器登录不会复用seed token。

`packages`有四个固定键：40天`old_eligible`已登记、40天`old_unregistered`未登记、40天`pinned`已登记且21个活动pin、当天`newest_witness`已登记。每包记录规范UUID、manifest SHA、完整文件摘要/字节数和目录清单。`--verify`只读校验head/source、精确四个包目录、所有原字节/目录不变，并输出当前活动会话/已登记数/fixture活动pin数；登记或pin改变只改变受控元数据，不允许改变原包。

本轮新库`flowtrace_test_p5_admin_f38b21e210114b19`与fixture`retention-36ed99e2a9b94f79aaed420e790a24d0/fixture.json`已seed，四包/21pins。先验`outputs/validation/P5-retention-browser-preconditions1.json`确认head0015、4包不变、3个登记、21pins、0活动会话。`P5-retention-browser-prepare1.log`保存准备回执。

root实际独立Chrome **7/7**，`retention-36ed99e2a9b94f79aaed420e790a24d0/browser-ca82ea4d-5f91-41e4-ae95-547c71b2fe05/receipt.json`保存结果/ARIA/截图路径：普通入口/保护原因、错误密码与显式固定目标登记、精确pin创建和释放、所选UUID零删除报告、20+1 pin分页、390窄屏/键盘/reduced-motion、recovery-only允许/service-only拒绝。桌面1280×900；root查看四张截图。20个备份同时选择是独立HTTP目标，不能以20pin分页代替。

浏览器全部角色退出后`--verify`四包/目录全相同、登记4/pin21/active sessions0；`host-closed.json`记录parent48516/child22516经实际命令/fixture核对后关闭、18092监听0、数据保留，Chrome context也已关闭。这是短程测试宿主，不代表持久部署完成。夹具安全守卫另11/11、0.30秒，在连接前拒绝hostaddr/service/options/错误DB/端口/UUID绑定，回执`outputs/validation/P5-retention-fixture-guards1.*`。
