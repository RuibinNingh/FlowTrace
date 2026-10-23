# Web壳专项验收

职责：真实Chrome验证独立版本壳与失败边界；入口：`shell_acceptance.cjs`；不变量：新UUID测试profile、无账号/ADB/个人浏览器、测试数据隔离；必跑测试：Python封装单测与Node浏览器脚本；相关材料：[发布说明](../../../deployment/web/README.md)、[P6任务](../../../AI/plans/flowtrace/tasks.md#p6web3-个工作包)。

从仓库根目录执行，Node需可解析Playwright，Chrome需安装。工具自己在loopback随机独立端口启动静态fixture，结束关闭所属浏览器和服务器；所有产物位于忽略的`outputs/validation/P6/<UUID>`，profile位于忽略的`work/flowtrace-dev/browser-profiles/chrome-p6-shell-<UUID>`，不覆盖以前回执。

```powershell
server/.venv/Scripts/python.exe apps/flowtrace/tool/web_release/test_seal_release.py
$env:NODE_PATH = 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules'
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' --test tests/e2e/web/worker_protocol_test.cjs
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/web/shell_acceptance.cjs
```

这里的应用是明确标记的合成JavaScript壳fixture，用真实Chrome执行生产worker与shell代码；不把它当作Flutter页面、账务/outbox原子性、跨端或完整P6验收。测试覆盖完整首装、离线刷新与新标签、关闭浏览器进程后的离线冷启、hash错误/资源404/下载中断保旧包、多标签拒绝与保存协调、迟到prepare取消恢复、新tab准备期间阻止启动、版本切换、旧Flutter缓存清理、损坏active资源拒绝network拼接、真实浏览器配额拒绝的联网降级、清站点数据后未同步fixture不恢复。另将首装deadline加速至50ms并真实延迟资源750ms，验证联网降级UI中的未flush内存输入在晚到claim后保留，没有未经写入屏障的重载。实际SQLite多标签写闸、真实Flutter build/offline草稿、完整业务与跨端旅程须另有回执。

2026-10-22：Python封装8项通过；Chrome155.0.8059.85的13项壳专项通过，最终独立回执`outputs/validation/P6/8cff9b98-1d06-4213-abac-e4f5b49abbe4/receipt.json`。首批与中间失败/中止回执均保留。故意中断后自动worker检查可能晚结束，合法候选只在核对旧版仍完整后最多重试3次，并记录每次releaseId/结果；每次成功仍须完整hash/marker，未绕过校验。独立fixture服务器清理显式关闭自身keepalive连接，避免等待后台worker连接而挂起。配额通过CDP仅限制fixture来源为1字节，worker真实报告`QuotaExceededError`；`navigator.storage.estimate()`仍有浏览器隐私填充，不将其10GiB显示值当作实际失败阈值。

同日接续复核修复最后确认的异步竞态：`matchAll()`等待期间取消或重复确认不能激活已取消的轮次；`skipWaiting()`拒绝时解锁并恢复各窗口。新增Node生命周期3项通过，封装8项再次通过；Chrome13项新回执`outputs/validation/P6/aacb9d15-da30-43e0-b853-9d949822d6a6/receipt.json`通过并关闭所属进程。之前`19b8522a-578a-454d-b2bd-5f90d074721a`失败保留：故障fixture在安装reject尚未完成就切换部署，裸socket断开还触发Chrome内部GET重试；已改为实际发送部分body后断流，并等待对应installer终止，避免两个故意故障轮次混合。

随后将active worker的启动锁写入该版本壳CacheStorage的独立metadata（非敏感token和25秒到期时间），序列化状态读取/获取/释放；任一worker重启仍检查有效锁，错误token不能释放，过期锁在读取时回收。Node生命周期现为5项通过，封装8项再次通过，最新Chrome13项回执`outputs/validation/P6/d596be6c-2582-4154-98b9-48ab1fb10ad0/receipt.json`通过：CDP实际停止active版本并观察`stopped`，新标签触发worker重启后仍停在“另一个窗口正在更新”，未启动Flutter合成fixture，升级按新tab取消并恢复双方。该结果证明真实worker重启边界，不能代替操作系统整机断电验收。

后补`?v=旧Flutter版本`注册URL迁移握手和同releaseId激活清锁，Chrome专项现为14项。连续故障轮次仍偶发固定资源URL收到204空响应、fixture服务器未收到对应请求（`112830dc-3932-4eab-97e3-a8414c0642da`）；同一失败profile重新启动仍复现。新候选仅将安装下载URL加`flowtrace_release=<releaseId>`后收到真实200及完整资源，同一profile自然激活后完整读取通过；底层204来源未证实，不用“已修fixture”掩盖该现象。生产下载现按版本query分隔、canonical cache key不变、每个资源仍验证原hash。修改后两轮14项连续通过：`fecc7200-b0d2-443d-8906-ef985d515ddb`与`1aa40e9b-3dc1-4017-8030-d20295f21f44`，先前所有失败保留。

普通Flutter构建的inline loader自身声明支持`serviceWorkerSettings`，sealer曾将声明误判为启用默认worker；已改为检查实际global load/loadEntrypoint调用参数，封装测试现为10项通过，含支持参数声明允许、显式默认worker两种调用拒绝。普通`web-p6-shell-20261022-b8e5`已封装39个资源，main SHA256为`1067fb802777913681c66b0a87bbfd6072bb6d607aa0f698415b775c192c9786`、releaseId为`ad8100626e768192bc6c96cd33e40b5a3c5450be802f78073b1d8889f340d714`。首次误报后错误提前启动专项的`67ae778d-aaac-4e85-9429-5d983ffc69af`无manifest失败回执保留。

`flutter_shell_acceptance.cjs`为普通main专项，需提供已封装的新Flutter产物，命令如下。

```powershell
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/web/flutter_shell_acceptance.cjs --build 'C:/Ruibin_Ningh/program/FlowTrace/apps/flowtrace/build/web-release-unique'
```

该脚本创建新的UUID浏览器profile/随机静态端口，通过普通可见UI保存两个独立标签的provisional草稿、离线刷新、两个未保存编辑器下更新及整个浏览器进程离线冷启。它不会登录、调用内部Flutter测试钩子或改写数据库，并阻止非本轮静态来源的网络请求。候选B复制普通A包到新的忽略目录，只修改公开`manifest.description`后重新封装，两个`main.dart.js`哈希相同；因此只验证真实Flutter写入屏障与资源包更新，不代表两个业务版本、正式账务/outbox、附件、跨端或完整P6验收。

2026-10-22普通Flutter专项4/4通过，回执`outputs/validation/P6/e92c98ad-8f37-4b26-8f2b-595b38013a50/receipt.json`，Chrome155.0.8059.85，所属浏览器/随机54440端口关闭。两标签通过UI各保存不同草稿，刷新后各看到两笔；两个真实编辑器分别保留未点保存的新文字，点击壳更新时Dart participant自动保存到原ID并drain，双方重载到B；关闭整个浏览器后离线启动仍有四条且各唯一。B releaseId为`979015b97774c212b43271bc2fdaca6de8d7362da4a813ab3d2d1fcc49e9a338`，page_errors为空，没有其他origin请求。首轮`5cb1f13c-2561-4e53-87af-84261ea64312`因ARIA实际将hint接在“备注”之后、脚本错误匹配后缀而失败，按实际ARIA改选择器后重跑成功；未修Dart来迁就测试，旧回执/截图保留。
