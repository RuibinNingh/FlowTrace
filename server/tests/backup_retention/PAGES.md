# 备份保留后台页面验证

> - 职责：说明有界候选、显式可信登记、pin和零删除报告的真实页面入口与验证边界。
> - 入口：`admin/retention_pages.py`、`admin/router.py`与四份`backup_retention*.html`。
> - 不变量：当前recovery/会话/密码/CSRF/CAS；长hash不持业务行锁；完整SH到最终commit/finally；不自动登记、不改包、不释放job hold。
> - 必跑：`test_pages_forms.py`、`test_pages_pg.py`、`test_pages_http.py`；另用新UUID夹具的独立Chrome验主路径。
> - 相关：[保留分册](../../../AI/plans/flowtrace/backup-retention-controlled-cleanup.md)、[读者锁](READERS.md)、[任务引用](JOB-REFERENCES.md)、[浏览器夹具](../../../tests/e2e/admin/RETENTION.md)。

2026-10-23（Asia/Shanghai），Git main无提交基线。页面已挂普通生产`create_app`，没有quarantine/purge、文件移动、销毁按钮或清理job。项目整体部署与交付状态由主计划维护。

## 当前行为

`GET /admin/backups/retention`最多扫描10000个目录、每页20项，显式选择最多20个当前候选。metadata只代表可以准备预览；忙包用timeout=0共享锁立即显示受保护，不逐包等2秒。未登记、pin/hold、真实活动任务、恢复意图、最新恢复点或不满足天数的包不可选。设置保留天数不触发自动清理。

`GET/POST /admin/backups/{UUID}/register`将GET所见manifest SHA、当前instance/epoch绑定到表单。POST先当前认证/密码预检并commit，再持SH做完整成员/hash；最终重新认证并核SHA/source、写control和commit，`finally`关闭上下文。旧包只有本人明确登记才获得control，不因列表扫描或校验而认领。

`GET /admin/backups/{UUID}/protection`分页20个活动pin，新增或释放单个pin均绑定URL父UUID、当前control/pin版本、明确目标确认、请求UUID及当前密码。重放原pin请求不重复审计或复活已释放记录；本页不提供普通job/download/永久restore hold释放。

`POST /admin/backups/retention/preview`仅该表单允许最多26个字段、0文件；20个选择加5个固定字段能通过实际multipart解析。重复单值字段、额外URL/字段、非规范UUID/版本、重复或21项选择都拒绝。预检结束事务后，纯I/O完整验证所选包和未选最新witness，按UUID顺序持SH；最后重新认证、核配置/保护/CAS并追加审计。报告只显示批准的固定UUID/UTC/hash/count，省略服务私有根、会话和密码；没有执行动作。

四个POST的初始DB认证与最终helper都在线程池，GET是同步路由。CSRF/origin与闭集表单解析不调用DB。密码不回填到任何失败页。

## 实际证据

纯表单/模板18项与真实PG helper6项在新`flowtrace_test_p5_jobs_0fac1e5ea1d345d9`，标准pytest共**24/24，0skip，7.25秒**，`outputs/validation/P5-retention-pages-helper1.log`和`.xml`。涵盖20/21界限、重复/额外字段、真实21pin分页和旧CAS拒绝、EX忙包立即保护、GET后manifest改变、迟到pin使预览失败、完整源字节不变。

生产main真实cookie HTTP首包在新`flowtrace_test_p5_admin_a0e6109ca87740cb`，**12/12，0skip，12.53秒**，`outputs/validation/P5-retention-pages-http1.*`。用户、角色和会话真实commit，不用外层savepoint伪装锁已释放；hash回调内第二独立连接用NOWAIT锁User/AdminControl/config成功，同时同包EX被SH拒绝。另核实际20项multipart、CSRF/origin/PW/重复/额外字段、source/SHA拒绝、撤recovery、pin幂等/释放及认证off-eventloop。收尾active session/admin role/active job均0，24个control和1个pin保留，`P5-retention-pages-http-postconditions.json`。

随后补真实GET后合法重写manifest和hash完成后另一连接撤recovery，最终同HTTP文件**14/14，0skip，15.16秒**，`P5-retention-pages-http2.*`；两种迟到变化均拒登记、不改原包，异常finally释放SH。两轮分别保留，不与helper24相加当作一次完整快照。

包内容是明确的合成PGDMP头，用来测试完整成员/hash和页面；这些证据不声称实际pg_restore成功。真实pg_dump/恢复证据见任务引用、数据工具及全局任务记录。两新库head均为`0015_import_requirements`，没有升级旧测试库。

root另在新f38b库独立Chrome执行**7/7**，回执`outputs/validation/P5/admin/retention-36ed99e2a9b94f79aaed420e790a24d0/browser-ca82ea4d-5f91-41e4-ae95-547c71b2fe05/receipt.json`。1280×900及390×844、reduced-motion、键盘确认、三角色、显式登记、精确pin创建/释放、pin分页20+1和实际选定UUID的零删除报告均通过，root已查看截图。这里的20+1是pin分页；20个备份同时选择由上面的HTTP专项证明。后验四包字节/目录不变、control4/pin21、active sessions0；root核对命令/fixture后精确关闭宿主父48516/child22516，18092监听0，Chrome context已关闭。

夹具连接/路径保护另**11/11，0.30秒**，`P5-retention-fixture-guards1.*`，覆盖hostaddr/service/options、生产DB/错误端口/其他测试DB、dataUUID/runUUID错绑和重复包，均在连接前拒绝。准备入口及完整边界见[RETENTION.md](../../../tests/e2e/admin/RETENTION.md)。本代理未操作浏览器，Chrome结果来自root实际执行。未提交、推送或启动持久服务。

后续隔离submission前置给**新建**preview audit加完整record canonical SHA，旧audit不回填。新digest/legacy拒绝及当前授权由另一个head0016新库13个PG目标验证，见[隔离分包](QUARANTINE.md)。上述HTTP14/Chrome7保持当时源码快照事实，不能宣称覆盖后来新增digest或任何实际隔离执行。
