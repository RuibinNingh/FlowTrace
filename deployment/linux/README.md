# FlowTrace Linux 生产运行手册

2026-10-24 生产 Alpha（钱迹兼容修复已更新）：`root@192.168.0.145`，入口 **https://home.ruibin-ningh.top:18473/**，后台 **https://home.ruibin-ningh.top:18473/admin/login**。本目录保存实际部署的配置与续期脚本；没有容器依赖。当前事实、验证和限制见[生产模块](../../AI/modules/production-deployment.md)、[本次更新](../../AI/logs/2026-10-24_qianji-export-import-fix.md)及[首次部署记录](../../AI/logs/2026-10-24_production-deployment.md)。

## 开始试用

正式账号为 `flowtrace_owner`。初始密码在目标机 `/root/workspace/apps/flowtrace/bootstrap-credentials.json`（root:0600）；本地交接副本在忽略目录 `work/flowtrace-production/bootstrap-credentials.json`，ACL仅授予当前Windows用户。不要把该文件复制进网站、版本库或wiki。

复用的普通客户端默认指向以前的本机地址，首次使用执行：

1. 打开 Web，进入设置的服务器地址，保存 `https://home.ruibin-ningh.top:18473`。
2. 在账号页登录 `flowtrace_owner`，使用上述私有文件里的密码。
3. 进入同步页进行同步，再开始自己的记账。不要把临时试用账号 `flowtrace_test` 当作生产账号。

Windows 解压ZIP后运行 `flowtrace.exe`，同样设置该HTTPS地址；它是未签名 Alpha。APK为已冻结ARM64 Android Debug包；本轮按用户要求取消安卓测试，未新构建/安装。已有Web站点数据属于各自origin，改地址不把临时库直接迁入生产。

## 导入钱迹实际导出

当前Web已更新，旧页面若出现更新提示，先保存编辑内容，再按应用内提示完成更新；关掉其他流迹标签后重新打开。不要删除站点存储或清空本地数据库来“更新”，其中可能有离线账单。新页面文件格式为“钱迹 Excel（原始导出 / 公开模板）”。

1. 在“数据迁移与导出”选择原始XLSX和目标账本，进入“钱迹原始导出 / 超过50条完整导入”；普通入口的50条限制保持。
2. 保留原ID和关联账单列，不拆文件。按需映射账户、分类、标签或原图；收入/支出同名分类分别匹配对应类型。
3. 等待上传/解析，完成资源映射后生成整批预览；核对105条及错误数，再主动确认正式导入，最后确认已同步。
4. 出错时提供页面的行/字段、错误码、请求ID或任务ID即可；不必发送完整账单或口令。

本次原文件105条及3条退款在Linux隔离库验证了逐条金额、关联、报表、幂等和撤销；独立浏览器以合成105条验证完整操作和重开。生产没有自动导入用户原文件，仍由用户选择目标资源并确认。

## 目录与身份

| 内容 | 目标机路径 |
|---|---|
| 运维文档与安全回执 | `/root/workspace/apps/flowtrace/` |
| 后端版本与current软链 | `/opt/flowtrace/releases/20261024-qianji-1447709`、`/opt/flowtrace/current` |
| 运维脚本 | `/opt/flowtrace/operations/`，root所有；目录0755、脚本0644，无内嵌密钥 |
| 公共静态Web | `/www/wwwroot/flowtrace/releases/20261024-qianji-fcdcda0`、`/www/wwwroot/flowtrace/current` |
| 数据与附件 | `/var/lib/flowtrace`，专用用户 `flowtrace` 所有、0700 |
| 数据库 | 原生PG17 `flowtrace_prod`，本机5432；角色`flowtrace_app`无superuser/createdb/createrole |
| systemd | `/etc/systemd/system/flowtrace-api.service`、`flowtrace-worker.service`、`flowtrace-backup.*`、`flowtrace-certificate.*` |
| 密钥配置 | `/etc/flowtrace/server.env`，root:0600，由systemd读取再降权运行 |
| Nginx | `/www/server/panel/vhost/nginx/flowtrace-home-18473.conf`、`/etc/flowtrace/nginx-proxy.inc` |

不要把程序放在root私有目录再放宽`/root`供www读取。私有资料不放宝塔`panel/data`，不运行递归权限“修复”。当前部署使用专用DB owner完成显式迁移与运行，未宣称另有独立迁移角色。

## 查询、启停与日志

以下命令在目标机root SSH执行；只操作FlowTrace自己的服务：

```bash
systemctl status flowtrace-api flowtrace-worker --no-pager
systemctl list-timers flowtrace-backup.timer flowtrace-certificate.timer --all
curl --noproxy '*' --fail https://home.ruibin-ningh.top:18473/health/ready
journalctl -u flowtrace-api -u flowtrace-worker -n 80 --no-pager
systemctl restart flowtrace-api.service flowtrace-worker.service
```

API的绑定是`127.0.0.1:18210`。Nginx只代理精确的`/api/`、`/admin/`、`/health/`，其他请求是固定静态文件，未知404。静态文件不含环境文件、密码和数据库。没有新增API访问日志；journal输出有服务限速，Nginx只写`/www/wwwlogs/flowtrace.error.log` warn级错误。

脱敏诊断现已开启：`FLOWTRACE_DIAGNOSTICS_ENABLED=true`且数据库运行开关为true；两者均允许才收集。私有目录`/var/lib/flowtrace/diagnostics`为0700、JSONL为0600。每条仅固定事件/路由模板/错误码、状态/耗时、行字段/数量及合法UUID；不记录原文件名、备注、正文、图片、密码或token。1MiB×3轮换、含当天7个UTC日期/合计8MiB的既有上限保持，容量可能更早淘汰记录。

后台审计页“导出脱敏诊断”走`/admin/diagnostics/export`，须当前管理员会话；导出再次白名单投影、最多1MiB且不缓存。可用页面请求ID定位`import_parse_checked`；解析成功与HTTP200均不是正式入账证明。Python3.13兼容修复已验证真实HTTP落盘/导出，诊断故障仍不改判业务提交。关闭诊断不会删除旧文件；正式DB审计不受该开关控制。

API/worker enabled；PG的`start.conf=auto`且`postgresql.service` enabled，实例由Debian generator拉起。定时器enabled、Persistent=true。进程重启与脱离终端已验证，整机重启未执行；不可把enabled当作已完成断电验收。

## 备份与隔离恢复

每天上海时间03:35起的备份走已有维护排他屏障，生成数据库custom dump、非密钥设置、附件原图/缩略图及hash清单。短暂维护窗口可能令并发请求返回忙碌；不要复制运行中的PG数据目录代替备份。

```bash
systemctl start flowtrace-backup.service
journalctl -u flowtrace-backup.service -n 12 --no-pager -o cat
```

新包位于`/var/lib/flowtrace/backups/UUID`，只有完整校验才返回`status=verified`；partial没有成功标记，应保留诊断。定时备份不自动清理旧包，需留意磁盘。首包`010b2d24-66aa-41aa-be1f-aaa4d3d02536`、5文件/178872B，已真实恢复到全新独立库`flowtrace_test_production_restore_d0aff831ef13`和`/var/lib/flowtrace-rehearsal/d0aff831ef13`；这些验收资料保留。

后续恢复必须提供全新、无表的隔离测试DB和全新附件目标，使用独立`Settings(environment="test")`及PG17的`pg_restore`，调用现有`flowtrace_server.backups.cli restore-isolated`或`restore_isolated`。不要将生产DSN传给隔离恢复，不向已有目录合并，不自动重新生成/重发旧金融请求。恢复库会更换sync epoch、撤销旧会话并冻结旧设备，源生产身份不变。生产切换需另按目标状态审阅。

密钥、PG角色、systemd、Nginx不包含在逻辑包中，须独立保管。初始root-only配置归档位于`/root/workspace/backups/flowtrace-deploy-20261024T102650Z/production-config.tar.gz`，含本次环境/账号文件及原生PG配置；证书备份同目录的`home-certificate/`。这些仍与生产同机，尚无FlowTrace异机备份/告警接入，不能把其他服务Guard绿色当作已覆盖FlowTrace。

## HTTPS、路由与续期

家庭网络使用非标准HTTPS端口18473：OpenWrt命名节`firewall.flowtrace_https_18473`只把TCP18473转发到`192.168.0.145:18473`，启用IPv4回流；主机端通过宝塔防火墙原生接口登记，UFW和live规则已核对。不要flush规则或替换全局防火墙。

路由器认证沿用服务器`/root/.ssh/config`里的`openwrt`别名和既有身份文件；只使用认证，不复制/展示私钥。规则变更前的路由器备份在`/root/flowtrace-deploy-20261024T103700Z`，主机写前备份在上述部署备份目录。IPv6公网链路没有验收。

证书位于宝塔`vhost/letsencrypt/home.ruibin-ningh.top/`，本次沿用已有DNS验证订单，精确续期至2027-01-22。原通用定时续期未覆盖此手动订单，所以新增FlowTrace专用每日检查；有效期大于30天时不触发签发，临期时只匹配该域名/保存目录的唯一DNS订单，先保存私有备份，再续期、验证域名与有效期、`nginx -t`后reload。它依赖现有宝塔DNS认证与ACME网络，不是离线承诺。

```bash
systemctl start flowtrace-certificate.service
journalctl -u flowtrace-certificate.service -n 12 --no-pager -o cat
openssl x509 -in /www/server/panel/vhost/letsencrypt/home.ruibin-ningh.top/fullchain.pem -noout -dates
```

不要改其他域名证书、重置DNS凭据或批量续期。未来自动临期调度尚未等待实测；本次真实签发及新服务“无需续期”分支分开验证。

## 升级与退出本次部署

本次修复未加DDL，仍`0016_backup_quarantine`。最终更新前一致备份`ff301d6b-6b9c-4d9e-8d54-c2f8d0fa3b69`已校验，5文件/186993B；旧指针/env/manifest在`/root/workspace/backups/flowtrace-qianji-20261024T130322Z`，最初Alpha材料另在`flowtrace-qianji-20261024T125008Z`。仅切换本项目程序/Web软链、开启诊断并重启API/worker，未改其他站点、路由和证书；旧版本保留，没有实际执行回退。若需程序回退，先停这两项服务、核对备份记录的原指针及schema，再原子恢复匹配指针/env并启动检查，不恢复旧数据库覆盖新增账目。

升级在开发仓库完成明确改动及针对性验证，构建新的独立wheel/客户端，记录源码、锁及hash；上传新版本目录，不覆盖现有版本。先建立一致备份与私有配置备份，在隔离目标验证需要的迁移/恢复，再受控停止FlowTrace服务、显式迁移、原子切换current、启动并验证ready与原身份/账务。没有自动降级数据库；新schema不兼容时不能只换回旧wheel。

回退本次全新服务可停止FlowTrace API/worker及两个timer，保留本库/资料/备份/版本，撤回本次独立Nginx文件并`nginx -t`后reload，再通过宝塔及OpenWrt仅撤回本次18473规则。不要回滚整个主机防火墙快照、停止其他PG/容器或恢复其他项目。以上是预案，本次没有执行删除或回退。

完整限制以[工作区待办](../../AI/modules/workspace.md#当前缺口)为准。同版隔离服务真实IAB旅程与正式域名TLS/API/日志已分开验证，未执行真实私人账本生产导入；独立外网、完整Windows原生旅程与整机重启仍待验，本轮Android测试取消。当前交付Alpha，不代表钱迹全部功能完成。
