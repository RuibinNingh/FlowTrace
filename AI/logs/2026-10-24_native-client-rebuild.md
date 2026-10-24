# 2026-10-24 内置正式服务器并重建 Windows / APK

> **任务**
> - 标识：native-client-rebuild
> - 状态：已交付

## 背景

用户要求：

> 以后应用内置服务器就是home.ruibin-ningh.top的
> 重建windows和apk

开工`main`、`57b6386a23f2e279472fee0e231c765c97090aad`干净，已有恢复提交。生产完整HTTPS入口为`https://home.ruibin-ningh.top:18473`；不能省略实际部署端口。此前Windows/APK为旧M1包，当前代码已经包含上包钱迹105条/3退款、完整导入与安全错误提示。本包只改默认地址/客户端版本并重建两端，不扩展业务或重部署Web/后端，安卓设备测试继续取消。

沿用[额度受控里程碑](../plans/flowtrace/alpha-milestones.md)：本包0个子代理，Flutter命令串行，使用针对性验证，不重复上包1015项完整回归。用户Desktop中的旧FlowTrace进程仍在运行，未覆盖其安装或操作其资料。

## 行为变化

`AppController.initialize`在没有持久`active_server`时使用正式HTTPS地址；已有手动地址优先，旧草稿/账本按原服务器资料空间保留，不隐式搬迁或清除。共同源码的未来构建均继承该默认值，本包实际重建Windows/APK；已部署Web仍为上包版本。

客户端版本从`0.1.0+1`升至`0.1.1+2`。Windows使用普通main的Release、production profile，不传local-test/QA参数；Android使用普通main的ARM64 Debug，沿用`com.flowtrace.flowtrace.dev`及原Debug证书，versionCode2，静态身份满足覆盖旧code1的条件。Android不改成新的release包名，未创建新的发布签名或内置账号口令。

实际产物在`outputs/releases/production/20261024-clients-0.1.1+2/`，旧M1和生产包保留：

| 文件 | 字节 | SHA256 |
|---|---|---|
| `windows/FlowTrace-0.1.1+2-windows-x64.zip` | 29479922 | `c2be922a3055f1e039b5bc5be3331f7700d28352b72656306fc3388ccff8f78e` |
| `FlowTrace-0.1.1+2-android-arm64-debug.apk` | 103190871 | `f976b0b10b67b6c65e01c4c749da84d4a7c9005d53a374a722db4c13c1156b32` |

交付含README、`release-manifest.json`和`SHA256SUMS`；Windows包内另有25个运行文件的逐项hash/CRT许可/构建profile清单。新包源码来源`158ebc27eec7dd570b70dc184d3d51ef0f0cf49e`，随后文档提交由交付回复和git log核对；仅本地提交，无推送/生产替换。

## 影响文件

- `apps/flowtrace/lib/app/app_controller.dart`：唯一未保存地址的默认值；`test/widget_test.dart`调整已有非法地址拒绝后仍保持默认空间的断言，没有新增镜像常量的测试。
- `apps/flowtrace/pubspec.yaml`：持久版本`0.1.1+2`，依赖锁不改。
- README、客户端README、文档入口及client/windows/workspace/production-deployment模块、Windows/Linux使用说明：当前产物、默认值、升级/签名/验收边界；当前计划/里程碑/交付分册按本包更新。生产配置及契约/服务端没有变化，无需制造空改。
- 新任务记录只记本包；旧已交付日志、候选和失败证据未重写。私有包装/观察/验证脚本在`work/client-rebuild-20261024/`，回执在`outputs/validation/client-rebuild-20261024/`，均忽略；本任务未增加持久化文档门禁。

## 已执行验证

1. `git status --short --branch`确认开工干净；代码三文件通过`git diff --check`后保存`158ebc2`。本包构建前记录214项源码/资源/原生平台/依赖锁输入hash，构建后全部相同，普通main无QA/local-test define。
2. 在`apps/flowtrace`执行`flutter --no-version-check test --no-pub test/widget_test.dart test/core/server_address_test.dart test/core/build_profile_test.dart test/identity/account_page_test.dart test/identity/identity_controller_test.dart`：**41通过，约5秒**。覆盖默认初始化、错误URL不切换空间、HTTPS传输策略、账号页/身份行为；`client-target.log`。
3. `flutter --no-version-check analyze --no-pub lib/app/app_controller.dart test/widget_test.dart`：**No issues，4.3秒**；`client-analyze.log`。没有将范围分析表述为全仓库分析。
4. `flutter --no-version-check build windows --release --no-pub --target lib/main.dart`：**成功64.8秒**；`windows-build.log`。再执行`deployment/windows/Package-FlowTrace.ps1`，BuildDirectory为该Release目录、OutputDirectory为新版本目录的`windows`、Version `0.1.1+2`、BuildProfile `production`；应用NotSigned、CRT微软签名Valid、qa=false。
5. `deployment/windows/Expand-FlowTrace.ps1 -Package outputs/releases/production/20261024-clients-0.1.1+2/windows/FlowTrace-0.1.1+2-windows-x64.zip -Sha256 c2be922a3055f1e039b5bc5be3331f7700d28352b72656306fc3388ccff8f78e -InstallDirectory outputs/validation/client-rebuild-20261024/windows-unpacked`：全新目录解压、25运行文件hash/集合通过；FileVersion/ProductVersion均`0.1.1+2`，回执`windows-package.log`、`windows-expand.log`。
6. 对新解压exe以`Start-Process -WindowStyle Hidden`和唯一`--flowtrace-data-dir=.../windows-runtime/data`启动。观察脚本只读该合成SQLite：schema5、注册默认地址为生产HTTPS、AOT app.so有内置完整地址；未登录或写入金融数据。在CIM核对本包PID/exe/数据根后仅停止自有进程，用户Desktop进程47444仍运行。`windows-startup.json/log`；这不是完整UI或旧库升级验收。
7. Windows SDK命令结束后才执行`flutter --no-version-check build apk --debug --no-pub --target lib/main.dart --target-platform android-arm64`：**成功58.5秒**；`android-build.log`。复制到新交付路径，未覆盖旧交付包。
8. 对本表APK具体路径运行已安装Android build-tools36.1.0的`aapt dump badging`、`aapt dump xmltree`（指定AndroidManifest.xml）及`apksigner verify --verbose --print-certs`：包名`.dev`、versionName0.1.1/code2、min24/target36、ABI arm64-v8a；APK v2签名通过，证书SHA`2f185c936ad71ad0908b1e885ac02543e7d0ff2451abbd6e4bf564034af7b74f`与旧M1一致。仅静态构建工具，没有ADB/设备操作；三个`android-*.log`保留。
9. `server/.venv/Scripts/python.exe work/client-rebuild-20261024/verify_release.py`：APK161成员CRC、kernel普通main/完整内置地址、无Android QA入口标识；Windows ZIP CRC/不含运行资料；实际私有凭据值未出现在两包；214输入未变，摘要/大小及合并manifest/hash清单生成通过。`release-verification.json`；无明文口令进入交付包。

首次测试启动器的相对工作目录令日志目标不存在，Flutter没有执行；改成绝对证据目录后第一次实际测试即41通过。一次附带空目录清理的命令被自动策略拒绝、没有执行；后续只创建所需目录继续，未删除资料。没有产品测试失败后反复扩大调查。

交付前核对本次Markdown链接、模块速查、任务五节/占位符、旧日志保持、差异和忽略边界；实际检查回执`documentation-check.json`。阶段只更新本包计划/日志一次，不把此前生产验收重新声明为本次执行。文档收尾额度接口7天窗口已用15%、普通使用允许、额外积分0；这是账号窗口，非本包token/费用。

## 未执行验证

未安装APK、未连接ADB或真机测试，按用户既有取消要求执行；只证明构建、静态身份/签名/内置地址，不声称Android运行旅程通过。未生成新Release/商店签名APK或其他ABI，未做Windows完整UI/旧schema3真实资料原地升级、干净无开发工具机器验证。

本包未重建或部署Web、未更新后端/生产数据库、未使用正式凭据登录或导入账本。当前生产Web仍来自fcdcda0，后端1447709；共同源码新默认地址在下一次Web构建才进入它的产物。用户既有自定义地址不强制改写，临时库不自动迁入生产。

未重复完整服务端/Flutter回归；既有未接收回款历史测试编译错误和其他长期缺口继续集中见[workspace](../modules/workspace.md#当前缺口)。没有Git推送、外部分发或替换用户Desktop安装；后续工作包待用户决定。
