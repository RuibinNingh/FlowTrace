# 2026-10-24 客户端 0.1.1+2 生产部署与下载

> **任务**
> - 标识：client-production-deployment
> - 状态：已交付

## 背景

用户在上包默认正式服务器、Windows/APK重建的本地交付后追加：

> 生产部署啊

本包明确执行生产上线，覆盖前包“仅本地交付”的范围。开始`main`、`5f3e813625778623ca313e3eea4203c304be18ad`干净，已有本地恢复基线。目标仍为`root@192.168.0.145`、`https://home.ruibin-ningh.top:18473`；读现有项目手册、实际Nginx/指针/manifest及Wiki SCHEMA，保留其他站点和原有Wiki脏状态。

后端已是钱迹/日志修复1447709，未再改服务端源码；原生包已在[上包](2026-10-24_native-client-rebuild.md)完成构建/41定向/范围分析/Windows隔离启动及APK签名验证，本包复用原字节。只新建Web、发布原生HTTPS下载与维护资料；0个子代理，安卓设备测试继续取消，无Git推送。

## 行为变化

- 生产Web更新为`0.1.1+2`，与Windows/APK共同内置`https://home.ruibin-ningh.top:18473`；已有手动地址/本地资料空间保持，旧标签通过原有更新屏障切换，不清空站点数据。
- 新Web来源`5f3e813`，release `271e839535a9f2c94f689cd45a3b54f8d156481e6dbb968d127569a64c29f8dd`；`/www/wwwroot/flowtrace/current`原子指向`releases/20261024-client-production-5f3e813`，旧Web保留。
- 专用Nginx增加`/downloads/`静态alias，固定版本根`/www/wwwroot/flowtrace/downloads/0.1.1-2/`仅放两个原生包、manifest/hash和说明，无目录列表；不公开root控制目录、凭据、账目或备份。API/worker/后端指针/env/身份保持，无DDL或金融迁移。
- 发布[Windows ZIP](https://home.ruibin-ningh.top:18473/downloads/0.1.1-2/FlowTrace-0.1.1-2-windows-x64.zip)、[Android ARM64 Debug APK](https://home.ruibin-ningh.top:18473/downloads/0.1.1-2/FlowTrace-0.1.1-2-android-arm64-debug.apk)及[SHA256清单](https://home.ruibin-ningh.top:18473/downloads/0.1.1-2/SHA256SUMS.txt)。公开文件名用`-2`代替`+2`，字节与上包完全一致。Windows未签名，APK原.dev/Debug证书及code2保持，没有设备操作。

## 影响文件

`deployment/linux/flowtrace-home-18473.conf`只新增下载alias及MIME类型，其余站点指令保持；README、客户端README、文档入口及client/web/windows/production-deployment/workspace模块、Linux手册、当前计划/交付分册/里程碑同步实际部署。服务端/共享API/账务/任务实现、Dart业务代码、依赖锁和Windows/Android工程未改，相应模块无需空改。

新任务记录独立保存，旧已交付日志未回写。私有执行脚本在`work/client-production-20261024/`，构建/安全回执在`outputs/validation/client-production-20261024/`；本地新Web与发布manifest在`outputs/releases/production/20261024-client-production-5f3e813/`，原生包沿用前包目录。服务器项目文档快照、manifest与Wiki仅更新本项目入口/实体及维护记录，安全回执为项目`updates/20261024-client-production-5f3e813/`和`documentation-update.json`；没有远端Git提交。

## 已执行验证

1. `git status --short --branch`开工干净；SSH读回后端1447709、旧Web fcdcda0、API/worker active和专用Nginx实际配置。没有因为重编客户端而重新安装无变化的后端或依赖。
2. `flutter --no-version-check build web --release --no-pub --target lib/main.dart --pwa-strategy=none --no-web-resources-cdn --output C:/Ruibin_Ningh/program/FlowTrace/outputs/releases/production/20261024-client-production-5f3e813/Web`成功，**45.6秒**。既有CupertinoIcons字体提示保留，不阻断构建；没有构建新的wasm变体。首次启动器因相对日志目录不在预期位置而未执行SDK，改绝对目录后上述实际构建一次成功。
3. `server/.venv/Scripts/python.exe apps/flowtrace/tool/web_release/seal_release.py outputs/releases/production/20261024-client-production-5f3e813/Web`：39资源，加manifest/worker共41文件，生成上述release。`prepare_update.py`逐资源hash/长度、内置完整地址、实际私有值排除及原生前包hash核对通过，形成ZIP/上传清单；不重跑41/1015等此前测试冒充本包新结果。
4. 上传新root-only控制目录后校验全部输入SHA。执行既有`flowtrace-backup.service`生成一致备份`4ed86241-44d3-4c7f-b075-a56aebc7e318`，**verified、5文件/227775B**，manifest SHA`4a10a8747d35c59b1598f7b9c9ff462306e4d0e0bd233c78b4926f9e4ca5b95b`。原Web指针/Nginx/manifest和PID/env摘要存于`/root/workspace/backups/flowtrace-clients-20261024T140019Z`；业务服务没有停止。
5. 首次切换后HTTP校验失败并自动恢复旧Nginx/Web指针。现场`stat`为新Web根、downloads根和版本根0700，站点日志明确`Permission denied`；是部署助手的私有umask覆盖了mkdir请求模式。保留首次`deployment-failed.json`/日志/目录/备份，没有清理失败证据。
6. 窄修仅将这三处新公开目录显式0755、文件0644，私有root/配置/数据权限保持。以`runuser -u www -- test -r`确认主页/manifest/两个包可读，再执行第二次切换；`nginx -t`通过、reload成功。已有其他站点protocol options警告不改。两轮内成功，后续不再扩大调查。
7. 正式HTTPS逐项取回39个Web资源，hash/长度匹配；COOP/COEP保持。两个原生包完整HTTP200下载、长度/SHA/MIME匹配；公开目录的`.env`/`server.env`404。ready200、server-info身份前后完全相同、API/worker PID及后端指针/env摘要保持，回执`production-update.json`。随后只读SQL核head0016与诊断OS/运行双开，`runtime-state.json`。
8. Windows宿主使用无代理、正常证书校验读取生产manifest并HEAD两个下载，200/长度/MIME正确，`network-browser-check.json`。这是当前LAN链路，不声称独立外网验收。
9. 独立Codex IAB在实际生产域名打开主页，未登录且无草稿；实际看到“新版已完整准备”。点击更新的工具回执超时/会话重连，后续截图为正常主页且提示消失。保存`production-web.png`，只证明页面渲染和观察到的状态，不据此声称新默认地址字段已通过UI检查或全量PWA/多标签/离线旅程完成；未使用用户Edge或个人Chrome、未登录/写金融数据。
10. 文档/链接、五行模块速查、任务五节/占位符、旧日志保护与Git差异/忽略边界任务内检查，回执`documentation-check.json`；不是新增持久化门禁。服务器快照/Wiki由`documentation-update.json`记录，保留旧Wiki日志字节、其他Markdown及暂存区；不把项目教程复制进Wiki。

实际文件：

| 文件 | 字节 | SHA256 |
|---|---|---|
| `FlowTrace-0.1.1+2-web.zip` | 25835302 | `a677510547fecd5ff2ddd1df4139c5a502ed97ef11ed43baf2efbe26bbfce1fe` |
| 生产Windows ZIP | 29479922 | `c2be922a3055f1e039b5bc5be3331f7700d28352b72656306fc3388ccff8f78e` |
| 生产ARM64 Debug APK | 103190871 | `f976b0b10b67b6c65e01c4c749da84d4a7c9005d53a374a722db4c13c1156b32` |

后端复用144770926da48b8049fd05cee7c81c7e11c3356a，原生来源158ebc27eec7dd570b70dc184d3d51ef0f0cf49e，Web来源5f3e813625778623ca313e3eea4203c304be18ad；新控制/文档提交由交付回复及git log核对。收尾额度接口7天窗口已用15%、普通使用允许、额外积分0，非本包token/费用。

## 未执行验证

没有再次构建原生或重跑上包41定向/两文件分析/1015集成；本包只改部署配置/文档并为已有Dart改动补新Web构建、完整HTTP及实际页面验证。没有Android/ADB、Windows完整UI/旧库升级、独立外网/IPv6、主机重启/断电、完整PWA多标签/离线或额外性能测试。

没有新的登录、导入预览/apply、账务迁移、DB恢复/降级、后端重启、路由器/防火墙/证书变更，亦未覆盖用户Desktop安装。备份仍同机，未新增异机/Guard保护；其余既有缺口集中见[workspace](../modules/workspace.md#当前缺口)。不推送Git、不自动开启新工作包。
