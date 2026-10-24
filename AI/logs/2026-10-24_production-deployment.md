# 2026-10-24 FlowTrace Linux生产Alpha交付

> **任务**
> - 标识：production-deployment
> - 状态：已交付（Alpha部署范围；浏览器、独立外网与整机重启未验）

## 背景

用户原话：“可以,接下来你可以进入192.168.0.145 ssh 阅读root/workplace的wiki了解 然后尝试进行生产部署 并且记录项目文档,那里就是生产环境 现在完工并开始 安卓测试废除 直接到开发计划最后环节”。后确认域名`home.ruibin-ningh.top`，并要求在服务器查找路由器认证。

这覆盖本包早先“不部署生产/等待M2”约束；仍按额度受控Alpha，不新增无关功能、不推送。开工`git status --short --branch`为干净`main`，已有本地提交`59e246f`，业务恢复基线`0926681`。目标机实际wiki为`/root/workspace/wiki`；读取SCHEMA/index、mini-rbn/备份与既有运维skill，区分文档约束、实况和用户授权。远端wiki原有大量脏文件，予以保留。

本包两个子代理分开使用、没有超过2并发：`production_package_review`只审冻结wheel/依赖与Linux安装风险；`production_docs`只同步6份授权/导航/计划文件。主代理独占SSH生产改动、资料/凭据、验收与集成。没有新Flutter构建、Android/ADB操作、全量回归或其他工作包。

## 行为变化

- Linux原生生产现提供`https://home.ruibin-ningh.top:18473/`及`/admin/login`；专用`flowtrace`系统用户、独立本库/角色、venv和版本目录，API/worker由systemd持续运行。
- 静态Web复用普通a3d9；Windows/APK复用M1。三端产物、后端wheel、35项生产依赖锁、SHA256SUMS及安装说明统一到本地`outputs/releases/production/20261024-alpha-0926681/`。客户端首次使用须在设置保存生产HTTPS服务器地址，未替换旧包内的默认本机地址。
- 正式`flowtrace_owner`由现有bootstrap CLI创建。口令只在服务器root:0600文件和本地忽略文件的受限ACL交接；临时`flowtrace_test`没有迁入生产。生产接口测试使用一个新私有合成账号，结束时禁用，资料保留；未向正式owner私人账本写测试账。
- BT/UFW持久入口和OpenWrt专用IPv4 DNAT/回流已配置。服务器已有`openwrt` SSH别名与专用身份文件可用；未复制/打印私钥，未替换全局防火墙或其他服务。
- 含附件一致备份、全新隔离恢复、受控重启保持已验证；每天03:35备份和03:10证书检查timer已启用，私有配置另做root-only归档。证书精确续期至2027-01-22。
- 项目运维文档及源码快照保存在服务器项目目录；wiki仅新增FlowTrace稳定入口、index和维护记录，不改历史logs/raw、不stage/commit远端wiki。

## 影响文件

新增`deployment/linux/`：实际API/worker/backup/certificate四份service与两个timer、Nginx vhost/proxy include、定向证书检查脚本、运行手册。新增`AI/modules/production-deployment.md`和本记录；同步AGENTS映射、AI导航、根README、workspace/server/web/admin/jobs/data-tools模块及flowtrace计划/进度/Alpha/交付分册。未改变业务Python/Dart代码、API或数据库DDL，OpenAPI无须重导出。

目标机新增`/opt/flowtrace`程序、`/var/lib/flowtrace`资料、`/www/wwwroot/flowtrace`静态、`/etc/flowtrace`私有配置、FlowTrace systemd/Nginx文件、原生PG17本库和精确18473入口。控制/证据在`/root/workspace/apps/flowtrace`；写前主机备份`/root/workspace/backups/flowtrace-deploy-20261024T102650Z`，路由器备份`/root/flowtrace-deploy-20261024T103700Z`。

当前配置私有归档`production-config.tar.gz`为26140B，SHA256 `13f3f4aede4194d6c13239f9afe81fda18df2f87d58628241845c9683b552810`，root:0600；不复制到公共产物。旧本机临时Web18200、PG55432、旧QA库、恢复点与所有失败现场保留。

文档映射逐项核对：新增Linux部署已登记唯一映射；现状变更同步上述模块，客户端、Windows、附件和同步契约的代码/规则未变，保留原模块验证边界，不制造业务文档空改动；任务日志/计划格式约定本身未变，不改历史记录。无自动文档门禁，本任务做人工及实际链接/差异检查。

## 已执行验证

1. SSH预检：确认Debian13.5/Python3.13.5、端口/进程/磁盘与内存、BT/Nginx/防火墙实况，写前备份Nginx、UFW、live rules及一致的宝塔firewall.db。既有服务未重启；只允许新增本包目标。
2. `apt-get install --no-install-recommends postgresql-17 postgresql-client-17`：安装原生PG17.11。新建`flowtrace_app`（无superuser/createdb/createrole）和`flowtrace_prod`，仅loopback；旧容器DB未改。已有`/etc` etckeeper bad-object警告保留，包实际安装与服务通过，未修无关Git。
3. 上传Web ZIP/wheel/requirements.lock并逐SHA核对；wheel425738B，SHA47bad6e7…d3ba8，来源0926681。`uv pip install --require-hashes -r requirements.lock`安装35锁定依赖，再装wheel；`uv pip check`36包兼容。真实非root执行`python -m flowtrace_server.tools.migrate upgrade`和`check`，0001–0016通过。
4. 首次非root执行遇权限：新顶层目录受umask0077影响为0700；修正后基本import通过，但真实迁移发现hardlink依赖anyio0600。第二轮只在新venv内将共享hardlink先复制为私有inode再规范只读/执行权限，真实迁移/check/bootstrap通过，未改root共享缓存。runuser绝对路径修正也留证。
5. `systemd-analyze verify`通过；`systemctl enable --now flowtrace-api flowtrace-worker`后User=flowtrace、active，API回环18210。`nginx -t`通过后reload新增独立vhost；共享vhost原有listen警告保留，未扩大修复。
6. 通过宝塔`firewallModel.comModel.main.set_port_rule`登记18473，复核UFW/live规则；服务器`ssh openwrt`创建`firewall.flowtrace_https_18473`并commit/reload，核对WAN DNAT与LAN回流。Windows `curl.exe --noproxy "*" https://home.ruibin-ningh.top:18473/health/ready`返回200/status=ok，无`-k`；静态index与WASM200、WASM MIME和隔离头正确。独立web工具不支持该非标准端口，不能据其错误判定外网可用或故障。
7. 精确home既有DNS订单`2b958eb6749b0f84b14bc1a597512c40`在证书/元数据私有备份后执行宝塔`acme_v2.py --renew=1 --index=... --cycle=30`，真实续期成功；`nginx -t`后reload，Windows标准CA/hostname验证TLS1.3，证书实际至2027-01-22 09:47:34 UTC。新`flowtrace-certificate.service`执行返回valid_more_than_30_days；timer enabled，未批量续其他域名。
8. 真实HTTPS合成用户：401未登录、403错误Origin、正确web登录/Secure cookie、本人资料、3×2 PNG实际78B上传完成与原图下载、account期初10000和expense125两项push、原正文重放均通过。pull首轮脚本多带client_id触发422（closed契约正确拒绝），未修改服务端。保留原金融回执，只复用唯一合成用户重置测试密码并做读取；恢复脚本曾误用旧样本77B，查DB证实本次78B后修正，最终12项后续HTTP检查通过。最终pull含原bill，唯一分录[-125]/余额9875；新脚本未push，没有重复金融写入。
9. 同一验收通过正式owner的实际后台HTML form CSRF登录、服务概况与退出；合成用户disabled。回执`acceptance.json`及前失败json/log均保留，未将表单HTTP当浏览器布局证明。
10. 新`flowtrace-backup.service`实际运行`python -m flowtrace_server.backups.cli create --pg-dump /usr/lib/postgresql/17/bin/pg_dump`，返回verified；首个脚本错误期待created而断言失败，按真实CLI契约保存现有verified回执，没有重复创建。包`010b2d24-66aa-41aa-be1f-aaa4d3d02536`，5文件/178872B，manifest SHA `e3151a8938717378f15cba58dfcc6fd4eb466124174a680df880306e8731a353`。
11. 新独立恢复库`flowtrace_test_production_restore_d0aff831ef13`/目录在恢复前保存身份。首次脚本未能读取新operations目录；修目录0755后进入解释器，又因继承/root cwd而无法检查.env。第二轮启动修复明确cwd=/opt/flowtrace/current，原空目标才实际进入`restore_isolated`并成功，无重建/覆盖目标。真实pg_restore17/52表摘要、2用户/2账本/4实体/1分录/1附件、原图及缩略图两文件、余额9875、epoch更换/旧会话撤销与源身份保持均通过。两个启动失败日志与新恢复目标保留。
12. `systemctl restart flowtrace-api flowtrace-worker`后两PID从1404587/1404588变1445037/1445041；HTTPS ready200。只读前后快照完全相同：instance/epoch、账户ID、9875余额、唯一-125分录、78B图片hash与合成用户disabled。`postgresql.service` enabled、start.conf=auto，实例enabled-runtime来自Debian generator；两个timer enabled/active，实际进程脱离SSH。
13. 新Web ZIP及复制复用的Windows/APK/wheel/锁五项SHA全部核对。源码未扩展，旧schema3/Debug/未签名限制保留。新部署配置/脚本逐字节比对远端，文档相对链接、模块速查、五节日志、占位符、Git差异与私有文件忽略检查完成；回执保存在`outputs/validation/production/`。
14. 额度接口本包收尾查询：7天窗口已用7%，额外积分0，ordinaryUsageAllowed=true。比例为账户窗口，不是本包token/费用；后续以接口实时值为准。保存本地恢复提交，不推送；实际标识见git log及交付manifest。

## 未执行验证

- 生产浏览器控制两次取页均30秒超时并重置，停止扩大调查；新域名普通Flutter页面登录/同步尚待用户试用。未用用户Edge/个人Chrome，未启动额外验收框架；没有页面截图，不借用临时Web图片。
- 独立外网/IPv6、主机重启/断电、未来每日timer临期签发与失败告警未验；配置事实和实际服务重启分开报告。FlowTrace尚无异机备份或Guard监控接入，同机归档不能承诺整盘损坏可恢复。
- 本轮安卓测试被用户取消，未ADB/重装/重编；Windows完整原生UI保留此前锁屏未验边界。完整钱迹功能、group新路径、P4高级回款/自动任务等延期见[workspace](../modules/workspace.md#当前缺口)。本包未完整回归，不把旧分项相加为新的全量通过。
- 没有Git推送、其他生产项目改动、全局防火墙回滚、旧资料删除、生产库恢复覆盖或数据schema降级。
