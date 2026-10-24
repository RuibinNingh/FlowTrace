# Linux 生产部署

> - 职责：FlowTrace Alpha 的 Linux 原生安装、独立运行、HTTPS 入口、备份与恢复边界。
> - 入口：`deployment/linux/README.md`、该目录的 systemd/Nginx 配置；目标机 `/root/workspace/apps/flowtrace/README.md`。
> - 不变量：业务进程使用专用非 root 身份；数据库/附件不在静态目录；密钥不入库；恢复只进入全新隔离目标；不改动其他服务。
> - 必跑测试：独立锁定安装、真实迁移/check、TLS/身份/精确账务与重放、含附件备份/隔离恢复、仅本服务重启保持；浏览器与外网证据分别报告。
> - 相关：[服务端](server.md)、[后台](admin.md)、[数据工具](data-tools.md)、[Web](web.md)、[最新更新记录](../logs/2026-10-24_qianji-export-import-fix.md)、[首次部署记录](../logs/2026-10-24_production-deployment.md)、[当前缺口](workspace.md#当前缺口)。

## 当前部署

2026-10-24原生客户端另已本地交付`0.1.1+2`，Windows/APK内置正式HTTPS地址，来源`158ebc2`；替代用户后续安装使用的旧M1候选，详见[重建记录](../logs/2026-10-24_native-client-rebuild.md)。本包没有替换下表生产程序/Web，也未上传原生包或操作生产数据库；当前服务器版本仍以下表为准。

2026-10-24 按用户明确授权部署到 `192.168.0.145`，项目运维文档放在 `/root/workspace/apps/flowtrace/`。服务器 wiki 实际为 `/root/workspace/wiki/`；只提供背景、稳定约束和项目入口，运行配置及本手册是操作依据。

访问入口为 [FlowTrace](https://home.ruibin-ningh.top:18473/) 和[后台登录](https://home.ruibin-ningh.top:18473/admin/login)。家庭网络 80/443 不适合该入口，使用独立 TCP 18473；BT/UFW 主机规则及 OpenWrt 精确 DNAT/回流已保存。Windows 使用域名、不跳过证书验证得到 200；这是局域网经公网地址回流，未取得独立外网验收。

| 项目 | 已落地配置 |
|---|---|
| 系统与数据库 | Debian 13.5、原生 PostgreSQL 17.11；`flowtrace_prod`，专用非超级角色 `flowtrace_app`，仅本机连接 |
| Python | 3.13.5，发行目录独立 venv，35项锁定依赖按 hash 安装；36个包依赖检查通过 |
| 服务 | `flowtrace-api.service` / `flowtrace-worker.service`，用户 `flowtrace`，均已启用；API 仅 `127.0.0.1:18210` |
| 程序 | `/opt/flowtrace/releases/20261024-qianji-1447709`，`/opt/flowtrace/current` 指向本次发行 |
| 静态 Web | `/www/wwwroot/flowtrace/releases/20261024-qianji-fcdcda0`，`/www/wwwroot/flowtrace/current` 指向本次发行 |
| 资料 | `/var/lib/flowtrace`，`flowtrace` 所有、0700；独立于 Web、宝塔递归权限目录和旧测试资料 |
| 私有配置 | `/etc/flowtrace/server.env`、`/root/workspace/apps/flowtrace/bootstrap-credentials.json`，均 root 所有、0600 |
| 私有诊断 | OS与数据库运行开关均开启；`/var/lib/flowtrace/diagnostics` 0700、JSONL 0600，后台受权脱敏导出 |
| 反向代理 | `/www/server/panel/vhost/nginx/flowtrace-home-18473.conf`，公共域名 TLS → 回环 API；未知静态路径404 |
| 备份调度 | `flowtrace-backup.timer`，每天上海时间03:35起、随机延迟不超过5分钟，持久 timer；不自动删除备份 |
| 证书调度 | `flowtrace-certificate.timer`，每天03:10起检查；只续已有 home DNS 订单，成功后验证并 reload Nginx |

原生 PG 集群 `start.conf=auto`，`postgresql.service` enabled；实例通过 Debian generator 启动，`postgresql@17-main` 显示 enabled-runtime。本次没有重启整台主机。

## 已取得的证据

最新钱迹修复：原文件105条/3退款在独立Linux库完成逐条金额/报表/重放/撤销核对，同版Web以合成105条在独立IAB完成选择文件、完整预览/确认、同步与重开；生产仅执行合成错误解析、正常/后台登录退出和脱敏导出，没有替用户导入真实账本。最终HTTPS ready200，错误请求ID与私有导出一致，敏感哨兵/文件名/凭据不在日志；API/worker active。Python3.13私有日志分派故障已窄修并在真实TCP通过后切换最终版本。

两次受控更新均先一致备份，未加DDL，仅check既有0016。最终切换前备份`ff301d6b-6b9c-4d9e-8d54-c2f8d0fa3b69`，已校验5文件/186993B；程序/Web指针、私有env和旧manifest保存在`/root/workspace/backups/flowtrace-qianji-20261024T130322Z`。最初Alpha回退材料另在`flowtrace-qianji-20261024T125008Z`，旧发行/DB/原件保留；本次没有执行恢复或回退，也没有修改Nginx/防火墙/证书。当前安全回执在项目`updates/20261024-qianji-fcdcda0/`，本地`outputs/validation/qianji-import-fix-20261024/`。

### 首次 Alpha 部署证据（保留范围）

- 全新本库真实迁移0001–0016/check成功，未迁移旧QA库；发行 wheel、35项锁定依赖独立安装成功。
- 通过真实 HTTPS 检查拒绝未登录/错误 Origin、正常登录、Secure Cookie、78B PNG上传下载、精确 account/bill push及原正文重放；只一条-125分录、余额9875。pull脚本修正多余字段后通过，恢复检查未重复金融写入；合成账号最后禁用，正式owner私人账本未写测试账。
- 真实后台HTML表单完成CSRF登录、服务概况和退出；这不是浏览器布局验收。
- 首份一致备份 `010b2d24-66aa-41aa-be1f-aaa4d3d02536` 已校验，5文件、178872B。全新独立库 `flowtrace_test_production_restore_d0aff831ef13` 实际 `pg_restore` 通过，含原图/缩略图两文件；52表内容摘要校验、余额重算、epoch改变、旧会话撤销通过，源库身份与账务未变。
- API和worker受控重启后PID均改变，源实例/epoch、余额/唯一分录和图片hash保持；脱离SSH仍由systemd运行。不是整机掉电测试。
- home证书已精确续期，实际TLS证书有效期至2027-01-22 09:47:34 UTC；新定时器“尚余30天以上”分支实际执行成功，自动到期续签的未来调度未等待实测。

回执在目标机项目目录的 `acceptance.json`、`backup-create.json`、`restore-rehearsal.json`、`persistence.json`，以及本地忽略目录 `outputs/validation/production/`。不在版本库保存私有运行资料。

## 发行与验收范围

当前后端来源`144770926da48b8049fd05cee7c81c7e11c3356a`，wheel431617B，SHA256 `f8e69b8ac3300b1ca9f973d2b985cfd54ec0824c1b7651bddc306405ad5b8e77`；Web来源`fcdcda06d3009945f6b9955ccb09ce6a25eccf52`，release `5ba6ba58d80d6c79419d1439101752bbcd0d801ad6a63bdb9cc0fd7eb61f6770`。Web使用schema5；新本地Windows/APK已重建0.1.1+2，旧[M1候选](../plans/flowtrace/alpha-candidates.md)继续保留。opt-in诊断字段保持旧客户端响应兼容，新包不是本轮服务器/Web重新部署。

新包位于`outputs/releases/production/20261024-qianji-1447709/`，含wheel、锁、Web ZIP、manifest及hash；Web ZIP25835422B，SHA256 `66225934f6cb756928b274693d40fe94f31265a758e9103c700ce3b12d8908f6`。初始Alpha三端包和旧Web仍在`20261024-alpha-0926681/`，没有覆盖。首次服务器地址设置及安全更新见运行手册。

初始生产浏览器取页超时的旧证据保留；本次相同新候选已在隔离同版服务完成真实IAB业务旅程，正式域名另验TLS/API/日志，不把它当作真实生产账本导入证据。用户可在正式Web选择原文件、映射资源并确认105条导入。本轮Android测试取消；Windows完整原生UI、独立外网与整机重启未验。其他已知待办集中见[工作区](workspace.md#当前缺口)，不将本包标为全量P8验收。
