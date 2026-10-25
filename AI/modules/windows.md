# Windows 原生运行与升级

> - 职责：用户数据目录租约、平台channel、独立目录解压包、升级和离线快照恢复。
> - 入口：`apps/flowtrace/windows/`、`lib/platform/windows/`、`deployment/windows/`、`tests/e2e/windows/`。
> - 不变量：同一规范数据根只有一个OS写者；业务资料不写安装目录；坏包不覆盖旧版/旧资料；受控凭据不复制到普通快照。
> - 必跑测试：WindowsRuntime Dart测试、MSVC目录/租约宿主、原生两候选重启升级、打包解压与快照恢复检查；普通main需另验完整桌面旅程。
> - 相关：[客户端](client.md)、[原生验收](../../tests/e2e/windows/README.md)、[分发说明](../../deployment/windows/README.md)、[计划](../plans/flowtrace/p5-p7-implementation.md)。

## 当前行为

2026-10-25工程`runner/resources/app_icon.ico`已改为“流线 F”，包含16/24/32/48/64/128/256七帧，源图和导出器见[图标说明](../../apps/flowtrace/assets/branding/README.md)。实际Runner.rc经Windows SDK rc.exe资源编译通过，独立解码核对全部帧；没有重建Windows EXE/ZIP或替换用户安装，当前已分发版本仍按下文记录。

原生runner在Flutter打开库前取得`flowtrace.instance.lock`的Windows独占文件句柄；第二进程退出73并尝试激活原窗口，异常终止由OS释放句柄。默认保留既有`%APPDATA%/com.flowtrace/flowtrace/flowtrace`资料根，公司/产品名不改；显式`--flowtrace-data-dir`只接受有效绝对隔离路径，拒绝UNC/相对/安装目录及junction绕入安装目录。

正式SQLite和附件适配器在Windows通过`com.flowtrace/windows-runtime`读取已持租约根，没有channel/lease不回退打开无锁数据库。其他平台原路径保持。系统安全存储使用原锁定Windows实现，独立QA已验证合成UUID key重启/跨版读取后仅清本轮key；不把它描述成整个数据库加密。

打包生成完整逐文件清单/hash和签名状态，解压到全新目录再逐文件核对；不删旧版、不自动联网升级。离线快照脚本先取得同一OS租约，拒绝运行中写者，复制SQLite/WAL/SHM和附件至新目录并校验；恢复同样只进新目录，拒绝穿越/损坏/junction，不复制实例锁、QA文件或系统凭据。

打包参数`-BuildProfile production/local-test`默认`production`，写入清单及受hash覆盖的`BUILD-PROFILE.txt`；它声明已有二进制的编译profile，不会检测或更改编译常量。普通Windows Release只有显式以`FLOWTRACE_LOCAL_TEST=true`编译时才可连接本机/局域网HTTP测试服务，公网HTTP仍拒绝；QA入口标记与profile独立。输入旧清单和旧profile说明均重新生成，最终普通应用不标QA。

## 当前证据

2026-10-24上述0.1.1+2原生包已按后续生产授权发布为[Windows HTTPS下载](https://home.ruibin-ningh.top:18473/downloads/0.1.1-2/FlowTrace-0.1.1-2-windows-x64.zip)，复用同字节，不再次构建。服务器完整HTTP取包hash及Windows端HEAD/长度/MIME核验通过；没有替换用户Desktop安装，签名/完整UI和旧库升级边界保持，见[部署记录](../logs/2026-10-24_client-production-deployment.md)。

2026-10-24普通`0.1.1+2` production Release已重建，来源`158ebc2`，内置`https://home.ruibin-ningh.top:18473`，不传local-test或QA define。ZIP29,479,922B/SHA`c2be922a3055f1e039b5bc5be3331f7700d28352b72656306fc3388ccff8f78e`，25个清单运行文件及manifest经全新解压校验；CRT官方签名保持Valid、应用NotSigned。独立合成数据根实际启动，SQLite schema5及注册的默认正式地址正确；仅关闭本包进程，用户桌面应用保持运行。没有登录/金融写入，不声称完整UI或旧schema3原地升级旅程通过。现行包在`outputs/releases/production/20261024-clients-0.1.1+2/windows/`，命令与回执见[本包记录](../logs/2026-10-24_native-client-rebuild.md)，下文保留此前候选边界。

2026-10-24 M1复用下面普通fda06dae/local-test候选：ZIP 29,202,962B/SHA17a7f6d9…88a63，26个文件CRC/安全集合/逐hash及既有bundle全部一致，CRT三DLL当前签名Valid，应用NotSigned。冻结副本在outputs/releases/alpha/m1-20261024，详见[候选清单](../plans/flowtrace/alpha-candidates.md)。167输入与Web a3d9的144个lib/资源/pub完全一致，仅Web壳不同；旧原生DB header schema3。本包未重建/原生UI操作，不借用当前schema5/group验证；实际组合联机与持久保持留M2。

WindowsRuntime6项、MSVC `/W4 /WX`宿主4项、打包恶意ZIP6组、离线快照恢复最新10组通过；中间junction漏查实际失败后已修，原SQLite SHA保持。QA release101→102真实原生升级保留9007199254740868精确余额、3条outbox/1份冻结正文、完整草稿、原件/设置与合成凭据，第二writer73，所属测试进程已关闭。SQLite探针实际BUSY/FULL不等于填满宿主磁盘；进程关闭重开不等于整机重启。

后补独立CRT v3包包含已安装VS官方x64三DLL及NOTICE，Microsoft签名Valid/14.50.35719.0与逐文件hash/解压通过，包SHA d4b8bb567a3ec498156656fb713deec6a0e279463ba7258d72209b323194a602；旧101/102包未改。该新包未再运行已清理凭据的QA入口，不宣称干净无VS机器或普通main通过。

第二候选Computer Use窗口/ARIA正确，截图有其他窗口遮挡且归属不能证明，未记外观通过；Flutter自己渲染帧另保留。上述101/102候选均为测试入口，未签名、未外部分发，普通main完整桌面/联网旅程仍待实现与验证。

2026-10-23另以普通`lib/main.dart`、`FLOWTRACE_LOCAL_TEST=true`构建`0.1.0+1`内部候选成功75.3秒，立即保全bundle及逐文件摘要，来源为167个源文件（含144个`lib/`文件及资源/Web/pub文件）的快照`bfb4a863801955200c117841ce20f854c6808169ff7ac322b07ad5196664bc1d`，构建后逐源文件重新核对仍一致。这不是最终统一版本交付包；候选回执位于忽略目录`outputs/validation/P7/ordinary-local-test-fda06dae-ad2f-4160-ae92-377cd637c34f/`。

实际profile包装验证3项通过：旧QA102省略profile得到`production/qa=true`；新普通候选显式`local-test/qa=false`；非法profile在创建输出前拒绝。两包均新目录解压且逐hash通过，原二进制摘要不变；普通内部包SHA256为`17a7f6d95dd8b8bad1c3d6e0f4134f5fa29650cafe07e7bfd5e7c86e19988a63`，NotSigned，CRT/NOTICE与profile说明均入清单。测试脚本不独立证明编译define，须与同轮构建回执结合。

新普通包真实进程33120取得原生窗口，ARIA为正常未登录本地草稿页，独立数据根创建SQLite。首次激活失败，按Computer Use指南仅重新绑定观察一次，截图明确为Windows锁屏；已停止全部原生UI输入，保留所属进程等待用户解锁。该证据只证明原生窗口和ARIA启动，不能算应用像素、主题/草稿键鼠、保护输入或完整桌面旅程通过。精确暂停依据与回执见[Windows验收](../../tests/e2e/windows/README.md)。
