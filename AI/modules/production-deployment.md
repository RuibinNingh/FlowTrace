# Linux 生产部署

> - 职责：FlowTrace Alpha 的 Linux 原生安装、独立运行、HTTPS 入口、备份与恢复边界。
> - 入口：`deployment/linux/README.md`、该目录的 systemd/Nginx 配置；目标机 `/root/workspace/apps/flowtrace/README.md`。
> - 不变量：业务进程使用专用非 root 身份；数据库/附件不在静态目录；密钥不入库；恢复只进入全新隔离目标；不改动其他服务。
> - 必跑测试：独立锁定安装、真实迁移/check、TLS/身份/精确账务与重放、含附件备份/隔离恢复、仅本服务重启保持；浏览器与外网证据分别报告。
> - 相关：[服务端](server.md)、[后台](admin.md)、[数据工具](data-tools.md)、[Web](web.md)、[任务记录](../logs/2026-10-24_production-deployment.md)、[当前缺口](workspace.md#当前缺口)。

## 当前部署

2026-10-24 按用户明确授权部署到 `192.168.0.145`，项目运维文档放在 `/root/workspace/apps/flowtrace/`。服务器 wiki 实际为 `/root/workspace/wiki/`；只提供背景、稳定约束和项目入口，运行配置及本手册是操作依据。

访问入口为 [FlowTrace](https://home.ruibin-ningh.top:18473/) 和[后台登录](https://home.ruibin-ningh.top:18473/admin/login)。家庭网络 80/443 不适合该入口，使用独立 TCP 18473；BT/UFW 主机规则及 OpenWrt 精确 DNAT/回流已保存。Windows 使用域名、不跳过证书验证得到 200；这是局域网经公网地址回流，未取得独立外网验收。

| 项目 | 已落地配置 |
|---|---|
| 系统与数据库 | Debian 13.5、原生 PostgreSQL 17.11；`flowtrace_prod`，专用非超级角色 `flowtrace_app`，仅本机连接 |
| Python | 3.13.5，发行目录独立 venv，35项锁定依赖按 hash 安装；36个包依赖检查通过 |
| 服务 | `flowtrace-api.service` / `flowtrace-worker.service`，用户 `flowtrace`，均已启用；API 仅 `127.0.0.1:18210` |
| 程序 | `/opt/flowtrace/releases/20261024-alpha-0926681`，`/opt/flowtrace/current` 指向本次发行 |
| 静态 Web | `/www/wwwroot/flowtrace/releases/20261024-alpha-0926681`，`/www/wwwroot/flowtrace/current` 指向本次发行 |
| 资料 | `/var/lib/flowtrace`，`flowtrace` 所有、0700；独立于 Web、宝塔递归权限目录和旧测试资料 |
| 私有配置 | `/etc/flowtrace/server.env`、`/root/workspace/apps/flowtrace/bootstrap-credentials.json`，均 root 所有、0600 |
| 反向代理 | `/www/server/panel/vhost/nginx/flowtrace-home-18473.conf`，公共域名 TLS → 回环 API；未知静态路径404 |
| 备份调度 | `flowtrace-backup.timer`，每天上海时间03:35起、随机延迟不超过5分钟，持久 timer；不自动删除备份 |
| 证书调度 | `flowtrace-certificate.timer`，每天03:10起检查；只续已有 home DNS 订单，成功后验证并 reload Nginx |

原生 PG 集群 `start.conf=auto`，`postgresql.service` enabled；实例通过 Debian generator 启动，`postgresql@17-main` 显示 enabled-runtime。本次没有重启整台主机。

## 已取得的证据

- 全新本库真实迁移0001–0016/check成功，未迁移旧QA库；发行 wheel、35项锁定依赖独立安装成功。
- 通过真实 HTTPS 检查拒绝未登录/错误 Origin、正常登录、Secure Cookie、78B PNG上传下载、精确 account/bill push及原正文重放；只一条-125分录、余额9875。pull脚本修正多余字段后通过，恢复检查未重复金融写入；合成账号最后禁用，正式owner私人账本未写测试账。
- 真实后台HTML表单完成CSRF登录、服务概况和退出；这不是浏览器布局验收。
- 首份一致备份 `010b2d24-66aa-41aa-be1f-aaa4d3d02536` 已校验，5文件、178872B。全新独立库 `flowtrace_test_production_restore_d0aff831ef13` 实际 `pg_restore` 通过，含原图/缩略图两文件；52表内容摘要校验、余额重算、epoch改变、旧会话撤销通过，源库身份与账务未变。
- API和worker受控重启后PID均改变，源实例/epoch、余额/唯一分录和图片hash保持；脱离SSH仍由systemd运行。不是整机掉电测试。
- home证书已精确续期，实际TLS证书有效期至2027-01-22 09:47:34 UTC；新定时器“尚余30天以上”分支实际执行成功，自动到期续签的未来调度未等待实测。

回执在目标机项目目录的 `acceptance.json`、`backup-create.json`、`restore-rehearsal.json`、`persistence.json`，以及本地忽略目录 `outputs/validation/production/`。不在版本库保存私有运行资料。

## 发行与验收范围

后端 wheel 源自本地提交 `0926681058789da10ae75074bb236c43743dc853`，含 head0016；SHA256 `47bad6e745f87c2fb90e5f6428484436ab94e89de5eb6b0166f1eadcbfdd3ba8`。Web复用 a3d9 release，Windows/APK复用[M1候选](../plans/flowtrace/alpha-candidates.md)，客户端不是当前schema5完整功能切面。

Web静态ZIP为 `outputs/releases/production/20261024-alpha-0926681/FlowTrace-0.1.0+1-web.zip`，25760050B，SHA256 `3246b8c72107161ae1c35f58a9b41c629b89450c1ccdb39f613649a65f331502`。客户端首次使用须在设置保存生产服务器地址，具体见运行手册；没有修改既有冻结包。

生产浏览器自动化连续两次取页超时，按额度约束停止扩大调查；页面登录/同步仍待用户试用，未冒称通过。本轮Android测试按用户要求取消；Windows完整原生UI、独立外网与整机重启未验。完整钱迹功能和其他已知待办统一见[工作区](workspace.md#当前缺口)，不将本包标为全量P8验收。
