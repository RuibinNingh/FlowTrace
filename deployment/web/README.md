# Web完整资源发布

职责：封装完整离线资源与静态站配置；入口：`apps/flowtrace/tool/web_release/seal_release.py`；不变量：资源完整后才激活、API/后台/账号数据不缓存；必跑测试：封装单测和真实Chrome壳专项；相关材料：[Web专项](../../tests/e2e/web/README.md)、[客户端模块](../../AI/modules/client.md)。

使用独立的新构建目录，保留旧固定验收产物。SDK调用必须与团队其他Flutter命令串行。

```powershell
flutter --no-version-check build web --no-pub --pwa-strategy=none --no-web-resources-cdn --output build/web-release-unique
python tool/web_release/seal_release.py build/web-release-unique
```

第二条命令从`apps/flowtrace`执行；它拒绝重封已封装目录，生成资源SHA256/字节长度清单`flowtrace-release.json`和同路径升级默认Flutter worker的`flutter_service_worker.js`。先验证完整目录，再上传至新的不可变服务目录，通过服务器目录指针原子切换。不能逐个覆盖正在服务的目录。Nginx示例提供COOP/COEP及不缓存HTTP头，实际Linux配置语法与切换尚须Linux环境验证。

首次联网逐项下载全部资源并核对SHA256，最后写完整marker；新资源失败、断流、缺少、hash错误或配额错误均不激活、不删除旧完整包。当前worker每次从同一版本cache读取并核对资源，缺失/损坏返回503，不从新部署版本拼接。激活后保留当前及上一完整壳，清理更老的本协议cache及旧Flutter缓存；不删除其他cache命名空间、Drift数据库或用户原件。

安装下载为资源URL添加`flowtrace_release=<releaseId>`query，隔开不同候选的在途/失败请求；静态服务器需对带query的同一路径返回相同文件。cache仍使用canonical资源路径，资源hash和业务存储不变。任何204空响应、404、错误长度或hash不符均拒绝完整marker，不能因重试而跳过校验。

SHA256验证传输完整性，**不是发布者签名**。服务端TLS、发布目录权限和worker代码来源仍是信任边界。worker和清单自身不进入循环资源hash；所有可执行Flutter/runtime资源、WASM、字体、图标和应用入口均进入清单。

无SW/非安全上下文或首次准备失败，显示“离线准备未完成”并启动联网UI，`offlineReady=false`；这不承诺断网可启动。已受控但资源被浏览器清理的页面可能无法启动，需重新联网准备；未同步数据没有虚假恢复承诺。

已有controller的页面必须确认资源完整和升级锁状态后才启动Flutter；检查失败显示重试提示，不降级绕过写入屏障。active资源损坏仍拒绝拼接网络资源；原版本资源重新可用或完整新版安装后，按核验状态重新打开。清站点数据将失去未同步的浏览器数据，不能将其作为无损修复承诺。

热更新需要每个已开窗口通过`FlowTraceShell.registerUpdateBarrier({prepare,resume})`。`prepare`必须暂停新写入、等待在途事务及outbox提交，并返回true；`resume`必须幂等，在更新取消时恢复写入。无桥接、任一窗口拒绝、超时或新窗口加入均保留旧版。正在准备时active worker锁住新窗口启动；全部确认后claim并整页重载。没有桥接时可关闭所有窗口使完整新版自然激活。壳专项使用合成IndexedDB证明协议，真实账务写闸由平台模块另验。

启动锁以非敏感token/到期时间保存在active版本壳cache中，最长25秒；状态读取、获取与对应token释放串行执行，worker被停止重启后有效锁仍生效。候选worker准备超时为15秒，取消或激活失败会解锁并通知所有窗口恢复，锁的到期处理防止异常退出留下永久停用。最后client扫描之后只允许当前轮次激活，重复确认或迟到取消不会激活旧轮次。

active与waiting的注册URL即使仅相差旧Flutter的`?v=`query也必须协商同一启动锁；不能将scriptURL相同视为worker身份。旧Flutter worker没有协议响应时热更新安全拒绝，关闭全部窗口后完整新版自然激活。相同资源release仅迁移注册URL时，激活入口清除已完成prepare lease，避免新页面被上一轮锁短暂阻止。
