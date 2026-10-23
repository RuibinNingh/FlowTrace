# P0-04 平台预研与验证基准

日期：2026-10-21（Asia/Shanghai）。状态：P0 环境探测与设计基准已完成；同日 P1 已建立工程、锁定依赖，并完成基础测试、Android 构建/真机持久化及 Web 基础浏览器验证。完整业务与三端最终验收仍按后续阶段执行。Git `main` 尚无提交，已有工作区文件是基线。

入口：[任务 P0-04](tasks.md)、[架构](architecture.md)、[UI 映射](../../../contracts/ui-map.md)、[合成场景](../../../contracts/fixtures/scenarios/README.md)、[测试入口](../../../tests/README.md)。本文件只保存本次环境证据与预研决定，长期现状由主代理同步到工作区/客户端模块文档。

## 1. P0 初次实际检查（保留历史观察）

未安装系统服务、未修改 Flutter/Android SDK 配置、未接受 Android 许可证、未创建/启动模拟器，未操作现有钱迹。Flutter 默认 doctor 曾长时间无输出，确认进程属于本任务后只停止该进程；随后用同一 Flutter snapshot 加 `--no-version-check`，设置进程级 `FLUTTER_SKIP_UPDATE_CHECK=true`，50 秒超时限制下约 8 秒完成。过程级变量未持久化到系统配置。

| 范围 | 实际命令或读取 | 实际结果与能力边界 |
|---|---|---|
| Flutter/Dart | `flutter --version --machine` | stable **3.38.3**，Dart **3.10.1**；SDK 为 `C:/Ruibin_Ningh/app/FlutterSDK/flutter`，revision `19074d12f7eaf6a8180cd4036a430c1d76de904e`。尚不证明任何应用能构建。 |
| 完整工具诊断 | 同 SDK `flutter_tools.snapshot --no-version-check doctor -v`，由 SDK Dart 执行 | Flutter、Windows、Chrome、Visual Studio、网络检查通过；Android 有未接受许可证警告；代理配置缺 `NO_PROXY=::1` 警告。退出 0 不代表所有检查无警告。未改代理配置，测试服务优先使用 127.0.0.1。 |
| Android SDK | SDK 目录/`source.properties`，`adb version` | SDK 为 `C:/Users/ruibi/AppData/Local/Android/Sdk`；platform android-34/36，build-tools 35.0.0/36.1.0，NDK 28.2.13676358，cmdline-tools/latest；ADB **36.0.0-13206524** 可实际运行。ADB 不在 PATH 不等于未安装。 |
| Java | doctor 指向的 `java.exe --version` | OpenJDK **21.0.7**，路径 `C:/Ruibin_Ningh/Minecraft/Java/microsoft-jdk-21.0.7-windows-x64/bin/java.exe`；后续 Gradle 使用何版本须构建时记录。 |
| Android 设备 | SDK `platform-tools/adb.exe devices -l`，用户接入ADB后立即重查及getprop | 首次列表为空；用户接入后设备在线：**PLT140，Android 16/API 36，arm64-v8a，boot_completed=1**。追踪标识 `android-plt140-dev1`，实际serial仅用于本地执行，不写进共享夹具。未操作现有钱迹。 |
| 模拟器/镜像 | `emulator.exe -version`、`-list-avds`、镜像 source.properties | Emulator **36.2.12.0**；AVD 列表为空；已有镜像 `system-images;android-36.1;google_apis_playstore;x86_64`，revision 3，不需为此镜像重新下载。尚未实测启动。 |
| 虚拟化 | `emulator.exe -accel-check`、Win32_ComputerSystem/Processor 只读查询 | 返回 0，**WHPX installed and usable**；HypervisorPresent=true。CPU 在已运行 hypervisor 环境下报告的部分虚拟化布尔为 false，不能据此推翻模拟器的加速可用结果。未修改 Windows 功能/BIOS。 |
| Windows 构建链 | `vswhere -all -products *` 及 C++ 组件过滤；`cl.exe /?`、CMake `--version`、MSBuild `-version` | Visual Studio Community **2026 18.3.1**，C++ 工具已装；实际 compiler **19.50.35724**、CMake **4.1.2-msvc8**、MSBuild **18.3.0.7010**，Windows SDK **10.0.26100.0**。本地 Flutter 源码含 VS18 2026 generator，doctor √；真正原生构建仍待验证。 |
| 浏览器 | doctor 设备发现及浏览器文件 ProductVersion | Chrome **155.0.8059.85**、Edge **155.0.4283.62** 可被 Flutter 发现；尚未运行应用、IndexedDB/OPFS 或页面主路径。Firefox/Safari 未验证，不据 Flutter 通用支持声明为本项目已验收。 |
| WSL/Linux | 实际 `wsl --status` / `wsl --list --verbose` | 分别退出 **50 / 1**，提示尚未安装 WSL。当前没有可用 Linux 实例；不安装 WSL、不用容器绕过用户要求。用户随后确认先本地开发，Linux 演练保留待补。 |
| PostgreSQL | Get-Service postgres 筛选、常见安装目录、应用目录 psql/postgres/initdb/pg_ctl 文件搜索、127.0.0.1:5432/15432 连通探测 | **初查时**未发现所查服务/二进制或可连监听，不证明全磁盘/远端均未安装。**后续主代理已配置 Windows 便携 PostgreSQL18.6 隔离实例，见第6节与工作区说明；本行不是当前缺口。** |

标准复查命令（命令本身已执行过，未来回执按当时状态重记）：

```powershell
flutter --version --machine
flutter --no-version-check doctor -v
& 'C:\Users\ruibi\AppData\Local\Android\Sdk\platform-tools\adb.exe' version
& 'C:\Users\ruibi\AppData\Local\Android\Sdk\platform-tools\adb.exe' devices -l
& 'C:\Users\ruibi\AppData\Local\Android\Sdk\emulator\emulator.exe' -list-avds
& 'C:\Users\ruibi\AppData\Local\Android\Sdk\emulator\emulator.exe' -accel-check
wsl --status
wsl --list --verbose
```

## 2. Android 后续可执行路径

2026-10-22用户确认手机重连，ADB隔离专项已通过：OEM系统picker本人同意首次协议后选中77bytes/3×2 PNG，取消与10MiB+1拒绝均保持快照；原只读helper BEGIN IMMEDIATE失败保留，修QA后第二attempt同APK无重装force-stop PID16642→17379/COLD3541ms、query_only重建原余额9875/ID/冻结正文/完整草稿/原件，SQLite SHA不变。完整结果见[Android专项](../../../tests/e2e/android/README.md)。这不是新回款UI、网络或整包验收；无QA普通main22.4秒构建成功，已安装并force-stop后COLD4814ms启动，实际未登录首页与定向应用错误tag0行已核；OEM错误保留不宣称全E日志为空。

用户补充“我提供了一个adb，你可以调试”后已发现上述在线 PLT140；当时仅安装/启动/调试 FlowTrace 测试包，无需为主路径创建 AVD。SDK命令使用明确设备serial，避免多个设备时误选。getprop只查询型号、API、系统版本、ABI与启动完成状态，未读应用数据。用户随后暂时断开手机；2026-10-22已确认重连并恢复隔离ADB，当前专项与完整旅程边界见第8节及文末。

P1-01 已获准并创建三端工程，构建与真机结果见第6节。未运行许可证同意命令。doctor 的部分许可证警告须以实际构建判断；本轮固定兼容依赖后已成功构建，无需接受新许可证。

已有镜像与 WHPX 提供创建**工作区隔离 AVD**的条件。后续执行时把 `ANDROID_AVD_HOME` 指向 `work/flowtrace-dev/avd`，用现有镜像建立专用 FlowTrace 测试设备，不覆盖默认 `.android/avd`，不安装钱迹或读取用户账本。新 AVD 与端口、快照/数据都只供合成样例。必须记录设备 serial、API/型号、启动完成状态和测试 APK 包名；失败则保留错误而非将可创建条件写成真机验收通过。

当前原生边界采用专用包名，与 `com.mutangtech.qianji` 不同。APK 安装、应用数据清理、进程终止等后续动作均限定 FlowTrace 测试包和专用设备，不能误用原应用包名。

## 3. 本地数据库的可实施默认

选择：**Drift + sqlite3**，Android/Windows 使用 `NativeDatabase` 后台 isolate；Web 使用 `WasmDatabase`，优先 OPFS，明确检测并展示回退模式。Repository 与 schema 统一，连接创建、文件目录和平台凭据隔离。官方平台文档分别说明 native/wasm 连接器，Web 仍需独立 WASM/worker 文件与浏览器能力检测。[Drift 平台](https://drift.simonbinder.eu/platforms/)、[Web](https://drift.simonbinder.eu/platforms/web/)。

P0 通过 pub.dev 维护者发布页及官方包 API 读取了以下版本约束；**该表是首次解算前的候选，不是当前锁定组合**。P1 解算已发现传递依赖不兼容并采用第6节的实际版本：

| 候选依赖 | 本次核对版本 | 本机适配结论 |
|---|---|---|
| drift | 2.35.2 | Dart >=3.10；本机满足。提供事务/迁移及跨平台接口。 |
| sqlite3 | 3.7.1 | Dart >=3.10；native assets/hook 自动随应用提供 SQLite，Web 另配对应 sqlite3.wasm。大于 2^53 绑定/读取仍须项目夹具实际验证。 |
| drift_dev | 2.35.1 | Dart >=3.10，允许 drift <2.36；生成器版本不要求与 runtime patch 号完全相同。 |
| build_runner | **2.15.0** | SDK ^3.7 可作为本机候选；2.16.1/2.17.1 均要求 Dart ^3.11，不能直接照当前文档示例升级。最终依赖图仍以 pub 解算/锁文件为准。 |
| path_provider | 2.1.6 | Dart ^3.10 / Flutter >=3.38，本机满足；数据库放 application support 目录，不放安装目录。 |

以上版本仅作为 P1 首次解算候选；当前实际精确版本、完整性摘要和传递依赖已写入 `apps/flowtrace/pubspec.lock`，未升级用户 SDK，也未使用依赖 override。项目手工连接 native/wasm，未引入辅助 drift_flutter。[Drift 安装](https://drift.simonbinder.eu/setup/)、[sqlite3](https://pub.dev/packages/sqlite3)、[Drift 版本](https://pub.dev/packages/drift/versions)、[build_runner 2.15.0](https://pub.dev/packages/build_runner/versions/2.15.0)、[path_provider](https://pub.dev/packages/path_provider)。

Web 预研通过条件：业务写入与 outbox 同事务；重开仍存在；两标签写不互盖；大整数无损；存储配额/隐私模式失败可见；支持模式不是内存。Drift 的 IndexedDB 回退也要检测共享 worker/多标签限制，不能无条件标为可靠。若实际环境无法满足，则评估**直接 IndexedDB 的多 store 原子事务适配层**，仍保留 Repository 契约；不得改用 localStorage 或 shared_preferences 存交易/outbox 充当事务库。

`amount_minor`/revision 传输和夹具为字符串，领域用 BigInt。Native SQLite 只在有符号 64 位范围校验后存 INTEGER；Web 如绑定不能可靠覆盖 64 位，采用十进制文本/精确桥接。账务汇总不对文本直接做非精确 SQL 数值强转。

Web 应用壳与数据库是两件事：后续需自管离线资源完整缓存、版本原子切换、outbox 先持久化再提示更新；`flutter build web` 不证明已经可靠离线。当前官方 FAQ 不再默认生成缓存 service worker；本机较旧 SDK的产物也必须检查，不能把不同版本文档当作本机实际行为。[Flutter Web FAQ](https://docs.flutter.dev/platform-integration/web/faq)。

## 4. 原生能力与三端适配矩阵

下表是实施边界，均非已完成应用能力。

| 能力 | Android | 用户 Web | Windows |
|---|---|---|---|
| 本地账单/outbox | Drift native SQLite事务，应用私有目录 | Drift WASM持久层，检测能力/配额/多标签，失败显式降级 | Drift native SQLite，application support目录、文件锁/多实例 |
| 图片/导入导出 | 系统文件/相册选择、受控附件目录 | file input/下载与Blob，不用dart:io | 文件选择与用户目录，处理占用/路径/磁盘满 |
| 截图识别 | 分享接收、可编辑候选、本地OCR适配 | 手工上传图片并编辑候选 | 选择/拖入图片并编辑候选 |
| 无障碍支付页面 | 原生服务、权限/后台限制、适配列表；用户确认才入账 | 无Android服务，显示适用范围 | 无Android服务，显示适用范围 |
| 小部件/快捷入口 | Android专用实现与应用锁联动 | 应用内快捷入口；PWA安装单独验证 | 应用内/桌面快捷入口按平台实现 |
| 凭据/保护 | 系统安全存储、应用锁/后台预览保护 | HttpOnly会话Cookie+CSRF，不能把长期令牌放localStorage | 受控系统凭据存储、本地保护与窗口行为 |
| 后台面板 | 浏览器访问独立/admin | Jinja2后台独立权限，不是用户Flutter Web | 浏览器访问独立/admin |

## 5. 验收视口、数据和证据

- Android 基准：按原截图信息层级还原，五列分类、行内二级分类和四列计算器；以逻辑像素适配 360/412 宽，原 720×1570 截图仅作该设备参照。深/浅主题、常规/放大字体分别核验，不能靠固定整屏位图复制实现。
- Web：在单独启动、隔离测试profile的 Chrome 上验证 390×844 与 1280×800，不再使用用户Edge；Windows 验证 900×700/1280×800 和 100%/150% 缩放。上述是合成验收视口，非原应用观察事实。
- S01–S56 逐项映射在 ui-map；通用 ST01–ST10 与 J01–J12、V01–V10 延续产品编号。页面只出现不算数据行为通过。
- 账户 alice/bob/carol/operator/recovery、合成账本和静态本地图片；以 `contracts/money-time.md`、`ledger-rules.md`、`permissions.md`、`sync-v1.md` 为期望权威。场景是声明式描述，不伪造实际API回执。
- 实际验收证据写入忽略目录 `outputs/validation/P阶段/`，任务日志写命令/结果；测试账号/附件/数据库均隔离。后端固定 127.0.0.1:18080，Flutter Web 与浏览器测试另用独立端口并记录，不连接生产服务。

## 6. P1 实际落地与验证更新

本节是同日后续实施事实，取代初查中“尚无工程/依赖/设备构建”和“PostgreSQL缺环境”的当前状态；初查记录保留以说明决策来源。

| 项目 | 当前实际结果 |
|---|---|
| Flutter 工程与依赖 | `apps/flowtrace/` 已建立 Android/Web/Windows 工程。锁定 drift2.34.4、sqlite3 3.5.2、drift_dev2.34.0、build_runner2.15.0、path_provider2.1.6、path_provider_android2.2.21、timezone0.11.2；完整图见 pubspec.lock。候选 sqlite3 3.7.1 传递包要求 meta^1.19，与 Flutter 固定1.17冲突；已回选兼容组合。 |
| 本地库生成 | `dart run build_runner build --force-jit` 已成功。默认 AOT 入口在本机 Dart3.10 上因 build hooks 报错，因此采用包支持的 JIT 选项。schema2 的事务、旧库迁移、文件重开、分区和冻结请求基础已实现。 |
| 静态/VM测试 | 修复真机发现的弹层生命周期问题后，再次执行 `flutter --no-version-check analyze --no-pub` 无问题；`flutter --no-version-check test --no-pub` **95/95通过**，包含基础9项与领域86项。 |
| Android工具链兼容 | 初次 path_provider_android2.3.1 引入 JNI 并要求未安装的 android35，构建失败；固定2.2.21后消除该要求。sqlite3 原生库首次下载超时，后续arm64构建成功，未绕过校验或改SDK。 |
| Android真机 | `flutter --no-version-check build apk --debug --no-pub --target-platform android-arm64` 成功；ADB安装 `com.flowtrace.flowtrace.dev`、`am start -W`冷启动成功（约3.8秒）；自身PID错误筛选无AndroidRuntime/Flutter错误。`flutter --no-version-check test integration_test/foundation_test.dart --no-pub`（实际通过`-d`指定授权设备）修复后 **1/1通过**：UI保存合成草稿、关库重开仍保留、outbox为空、删除该轮合成草稿。只证明P1基础，不是正式记账/完整Android验收。 |
| Web基础 | 关闭SDK默认PWA策略并使用本地Web资源的构建已成功。真实Edge通过本地18181服务验证新增草稿、刷新保留、切换服务器打开空空间、切回原地址保留草稿，未发现控制台error/warn；合成数据已清理。应用壳离线/升级、多标签/配额、跨端同步仍归P6。 |
| Windows边界 | Windows上原生SQLite VM文件重开测试已通过；VS工具链已实测。Windows桌面产物/窗口/安装尚未验收，不能从VM测试或工程目录推断通过。 |
| PostgreSQL/Linux | 主代理已配置来自EDB的便携 PostgreSQL18.6，工作区独立数据，loopback 127.0.0.1:55432，非系统服务；迁移、服务就绪与隔离PG测试已有真实回执，详见[服务端模块](../../modules/server.md)与[工作区说明](../../modules/workspace.md)。Linux仍无环境，用户确认先本地开发，P1-04/P8 Linux部署恢复待补。 |

当前完整业务和平台差异仍按[计划恢复入口](progress.md)继续推进；P1基础结果不替代J01–J12最终验收。截图等隔离证据位于 `outputs/validation/P1/`，不包含私人钱迹数据、真实用户凭据或设备serial。

## 7. P2 身份与同步平台实测

原生安全存储依赖已锁定flutter_secure_storage10.3.4（Windows实现4.2.2）；Android实际验证系统安全库保存/轮换/退出清除，不向普通SQLite保存refresh。Web使用HttpOnly刷新Cookie、CSRF与内存access，未将长期令牌存入浏览器localStorage。身份/传输和安全HTTP元数据单测34项通过；串行合并回归178项通过、3项需QA参数的live测试默认跳过，各自真实专项回执单列。真实Android身份集成1项通过，包括合成邀请注册、重开恢复与凭据轮换、同资料空间草稿保留及退出清除。

同一PLT140授权设备上的同步UI集成1项通过：新建合成账本与标签，用两套独立native缓存和真实HTTP会话制造两次并发冲突，在页面分别选择服务器/本机版本；服务端字段与修订核对一致。恢复段显式设置本地需重建状态，核对恢复备份列表和记录详情，验证未传输入与outbox仍保留；未执行服务端恢复或自动重放。该用例构建19.6秒、安装72.5秒、设备测试约15秒；Android附件存储另1项通过（构建19.7秒、安装35.2秒、约3秒测试），实际应用支持目录原件关重开和撤权清缓存已验证。

测试完成后已经替换不含QA编译参数的常规main ARM64 debug包：构建20.7秒，aapt确认包名/ABI，APK全部ZIP成员不含两组QA凭据字面量。ADB更新安装成功，冷启动Status ok/COLD（3910ms）、自身PID错误日志为空；截图`outputs/validation/P2/android-main.png`已实际查看，手机保留正常未登录首页。P2接收时完整静态分析无问题，诊断页换space目标回归1项通过。

真实Edge（18181独立来源）已完成合成邀请注册、刷新恢复、退出后刷新仍退出、再次登录和撤销当前会话；控制台无error/warn。切换会话时有旧Semantics节点残留待复查，视觉正确不代表无障碍语义通过。完整浏览器多标签身份/配额/离线壳恢复仍属P6；Windows原生凭据存储和桌面构建仍待验收。

为避免Windows原生依赖缓存争用，多代理协作时同一工程Flutter生成、测试和构建串行运行。原生双缓存测试保留Drift多实例提示，实际executor彼此独立；不通过关闭诊断掩盖共享文件风险。当前测试与截图证据位于 `outputs/validation/P2/`；Linux无环境的边界不变。

## 8. P3 原生主路径实测

管理模块8项 widget/SQLite回归与完整客户端静态分析通过。新增 file_selector1.1.0 的锁定 Android0.5.2+6 已随 P3 原生调试包实际构建安装，未升级 Flutter/Dart/Android SDK 或接受新许可证；系统选择图片本身仍待专项。

授权 android-plt140-dev1 上 ledger_test 1/1通过：创建真实本地账本/两级分类/标签/两个账户，支出实付30minor+优惠10minor、收入10000minor、转账5000minor+手续费100minor；受控HTTP阻断下保存，重开文件库和controller后保持实体/操作ID，重连并由第二HTTP会话核对最终现金94870minor/银行卡35000minor及独立统计预算标记。两会话退出、合成业务对象普通墓碑清理通过。此轮构建19.4秒、安装36.8秒、设备用例约64秒；日志/JSON回执位于outputs/validation/P3。

首轮构建61.9秒/安装5.7秒成功，但收入分类定位由测试helper横向滚动导致54秒失败；修正为仅不可点时ensureVisible并等待编辑器退出后通过。库/控制器重开不是OS杀进程，HTTP拦截不是切换系统网络。截图在设备私有目录生成后随Flutter工具卸载测试包被删除，尚未导出；当时dev包已卸载；用户2026-10-22确认重连后已安装独立合成fixture并恢复系统picker/OS终止专项，常规main恢复和完整旅程仍待最终步骤，不引用P2截图冒充新主路径。

同轮统计/日历/预算6项及首页1项widget合并7/7通过：31号账期、独立统计预算标记、精确大额预算新建/编辑/沿用、日历补记、独立全屏图切空间/数据库撤权隐藏、390宽与1.8倍字体柱线布局。此为本地组件/SQLite验收，不能替代真机或完整浏览器主路径。浏览器后续另起隔离Chrome实例，不再操作用户Edge；第6/7节保留历史Edge结果。

## 9. P3 独立 Chrome 准备

CUA创建Chrome会话返回不可用，库存也无浏览器；未回退Edge。按主代理授权改用本地代码E2E：工作区打包Playwright1.62.1实际启动已安装Chrome155.0.8059.85，headed、全新工作区UUID profile，初始恰有一个about:blank；按该profile路径实际核对主/子进程，随后正常关闭。没有连接已有个人标签页、下载浏览器或改变系统配置。脱敏启动回执位于`outputs/validation/P3/chrome-session.json`和`chrome-process.json`。

[独立Chrome验收入口](../../../tests/e2e/client-web/README.md)提供可复现启动和18080合成账本准备。11项专用对象与ready PNG已创建，HTTP核对收入10000/支出1350/预算占用2375minor，重跑去重及另一轮正常墓碑清理已验证。18181服务HEAD实际200并具备COOP/COEP。

首份正常main Web构建44.9秒成功，摘要`523a8cdea8693de8fa9f8133b73675d82f3c648d9cccd67b5cc0434cb04e9f02`；真实UI验证设置地址/登录/页面同步、重开后会话及账本保留、精确报告/全屏折线、图片关键词搜索及日历补记入口。旧预算保存与导出预览超过8秒等待的失败回执保留，后续[隔离事务诊断](../../../tests/e2e/client-web/TRANSACTIONS.md)确认并修复应用嵌套事务边界。

修复后普通main构建55.8秒成功，摘要`cabc652412d5d805591c947d12b53f6d0e76b11886fc01a5a01cff143bcfa8d2`；每阶段实际Chrome收到的main.js正文摘要均核对一致。原profile预算创建100.00、修改100.01、下期沿用100.01及各自剩余金额通过；日历补记10月16日1.25后重新打开保留，支出14.75/结余85.25、预算已用25.00/剩余75.01，页面同步后重开首页为0待传/5笔。中断后18181/API/PG曾无监听，首次新轮只在open-app被拒绝，无业务写入；原数据/instance/epoch和相同静态服务恢复后才继续。

图片导出预览恢复1笔/1图后，metadata/content实际200，下载仍因旧派生registrant遗漏FileSelectorWeb失败；仅点击阶段CDP捕获MethodChannel无实现，保留失败收据、旧main及生成文件。offline pub get未使已有entry重新生成，随后核对清理目录都在Flutter工作区后执行标准Flutter clean、再次offline pub get。依赖锁摘要前后保持`90c726415a608d613b10bee8d92b16a3538be73821befaaf54766a988e4fbed9`；SDK生成的新registrant含FileSelectorWeb，无手改SDK或生成源。

最终普通main55.9秒构建成功，摘要`a3a1c9eece0ffd8453592c219a1f4097958efda6afcbc42c9a98accb983b1c9a`。同profile真实点击下载ZIP217字节，唯一序号名原图77字节，SHA256与合成原件完全相同；新产物重开报告/预算亦通过。UI退出204、视觉已退出，关闭重开后仍退出且登录控件正确；同页退出时Semantics遗漏可见表单控件的严格断言仍失败并保留。最终合成账本普通墓碑清理、准备/核对会话退出、专用Chrome进程0。未操作ADB/Edge。整体浏览器因已知语义问题与P6范围仍为部分验收，不标P6完成；安全回执及PNG/语义树位于`outputs/validation/P3/`。

## 10. P3 跨账本移动和 Web 原图解码

377非editable wheel在18080提供book-move-v1，沿用原instance/epoch/data。新建两个owner合成账本、本人私有现金账户期初10000、expense125及77字节PNG、明确目标分类/标签；固定8条operation先持久化，再发送，seed重复核对通过。真实Chrome使用原独立profile，经设置入口填写表单登录和页面同步；从唯一来源记录打开移动页，预览/准备目标原图副本后本机确认。确认前后余额98.75，源列表为空；随后显式页面同步，真实marker及applied修订2回执已保留，目标书1笔及目标分类/标签/原微秒时刻正确。

首普通main41.6秒、摘要`dc484696b4f3242d05b0a1055c75cc9d66446805da6fa3d21d3eaaa489df2c9b`在图片预览失败。安全CDP只在该点击捕获异常class/栈，确证Flutter Web的ImageDescriptor.width不支持；PNG Pillow实际load、三块CRC与目标实际下载字节均正确。保留该失败与原fixture后，生产改公共跨平台codec尺寸回调，维持尺寸/像素/完整解码/动画限制；selector/panel14项通过。没有换图、重复移动或删除像素校验。

修复后普通main46.1秒、摘要`a55bfe7934a502b70a66b39fb8c1e83a729883a2811581bae80d2c0d00970ed0`，锁文件仍为`90c726415a608d613b10bee8d92b16a3538be73821befaaf54766a988e4fbed9`。原已移动账单只读verify通过：源0、目标1、原图实际渲染、目标分类标签与原时间正确、余额9875；辅助HTTP同UUID/修订2、clone新UUID/77字节同hash/源0目标125均通过。退出即时语义断言仍失败并保留，logout204及关闭重开退出通过。两个新账本和固定私有账户已普通墓碑清理、会话退出、Chrome0，未使用ADB/Edge。该专项不代替P6或剩余手机验收。

## 11. P4资产与Web语义、字体增量（2026-10-22）

本节按实际产物区分验证层；P3原`build/web`、e14b失败产物和旧专用profile均保留。[资产模块](../../modules/assets.md)、[客户端同步](../../modules/client-sync.md)与[浏览器专项](../../../tests/e2e/client-web/P4_ASSETS.md)分别说明账务、同步和UI证据，下一恢复位置以[进度](progress.md)为准。

P4真实资产客户端HTTP使用Windows上的生产Flutter VM、文件SQLite和专用18085候选wheel，最终1/1通过（约6秒）。首轮正常删单后余额不可用，主代理用独立canonical墓碑来源证明修复，删除两序先2失败再2通过、独立证明9项通过；保持原固定金额重跑后bank100000/EUR0/card-10000恢复准确，SQL确认有效分录/附件引用0、两测试会话0、专属线程停止。回执为`outputs/validation/P4/assets-client-http-receipt.json`；这是Native客户端HTTP联测，不是Android设备或Linux部署。

| 普通main产物 | 已执行构建与摘要 | 真实浏览器结果与边界 |
|---|---|---|
| `build/web-p4` | 45.2秒；`e14b234aad6a6deead2a8f2c21040cb41daab6b578a34b112fe045947b1eba81` | 初始化等待后可见用户名光标，但document/开放shadow编辑节点0，公开type/insertText两次真实输入均无字；没有输入凭据或业务写入。该最小失败保留，不能仅归因最初harness漏查textarea。 |
| `build/web-p4-semantics` | 40.4秒；`03a1c84dfb17657d87e0c14191f0634fac18cbe3e75596a9aa1e26a00f0036fe` | 全新受控Chrome不点placeholder即可实际输入；真实登录、同步和下述业务路径通过。首次沿旧profile仍由旧SW返回e14b，harness核对正文hash后拒绝，在进入UI前停止；未将旧产物计作新版本通过。 |
| `build/web-p4-fonts` | 41.9秒；`ae7964f21eddde4b5be7298cd5679ed43de2e317f3a364520f66b41e5bd3a7d1` | 同profile正常worker更新后，本地字体阻远程域、宽/窄中文和配置刷新liveRegion通过；即时退出表单仍缺ARIA，原失败保留。 |
| `build/web-p4-logout` | 41.5秒；`4897e5b9687515b057a5c6126f401bedfc6bcbaf875bf96bc044ac1e85c90f8e` | 等待确认modal完整移除只修生命周期顺序，实际同页表单仍失败；安全DOM对照FORM可见但5子节点变0，Tab无改善，重开退出通过。 |
| `build/web-p4-auth-card` | 41.9秒；`c974c847b3dceb1ef138ae2fcd536a9937c968dfe69e09efe3ed5859fbe26a61` | 登录Card稳定key后实际表单公开输入/Tab、真实登录、退出204后即时ARIA/Tab及公开输入清空、重开保持退出全通过；root亲看图并核回执。 |

根组件仅Web在initState持有公共`ensureSemantics`句柄，卸载时释放，原生不增加句柄。独立本地SDK审阅支持首帧一致语义/编辑模式，但旧placeholder激活也会持有平台句柄，故未把“路由释放临时句柄”写成确定根因。该改动后完整客户端500通过/5项需显式QA配置的live默认跳过（25秒），完整分析无问题（3.1秒）。Web常驻语义有DOM计算和accessibleNavigation影响，长列表、路由往返和含动作的SnackBar仍需按实际操作观察，不能用Native回归宣称无影响。

03a1候选的新UUID专用Chrome实际收据已通过：正常DOM登录auth POST200、初次同步、总览及窄屏、分组创建、新信用卡-80.00后的净资产720.00、分组/排序/隐藏设置、金额隐私，以及信用卡还款/借入/借出/收回/归还/跨币种转账六个资金动作和再次同步。跨币转账保留100CNY→12.50EUR、冻结0.125及独立0.25手续费。公开`focus_probe_01`的type/insertText截图已实际查看，但其收据是inspected；真实登录和业务passed分别有独立回执，不能用公开probe替代完整旅程。

偏好/报价保存后的状态文字在ARIA遗漏，原`currency-preferences`和`rate-create`失败收据保留。后续`web-assets-rate-create-valuation-readback-receipt.json`是实际页面只读估值核对，另有`rate-replace`通过回执；不能回写原失败为提示已通过。`web-assets-financial-audit-receipt.json`以RR+SQL READ ONLY确认配置revision5、偏好CNY/[CNY]/`latest_on_or_before`、报价8已删/9有效、六账单Money/冻结FX/fee及13分录，所有账单revision仍1；独立合计资产142225、负债69000、净73225minor。该审计未改库、未新建检查登录会话，不是HTTP或ARIA复验。恢复应沿用这些已完成事实，不再次写偏好、开户或重复六资金单。

03a1截图中净/负/借等中文曾呈缺字方框，ARIA金额正确不能作为中文视觉通过。当前资源已加入未修改的官方Noto Sans CJK SC Regular（16437364字节）以及官方Flutter SDK的Roboto400/500，pubspec、主题fallback和标准LicenseRegistry注册已接；固定来源、逐文件摘要、版权与完整许可见[字体来源](../../../apps/flowtrace/assets/fonts/README.md)。标准库66字符非0字形检查只证明所测字存在；不证明fallback实际选中、CanvasKit渲染、离线加载或三端显示。

同轮`client-full-fonts.log`记录完整客户端500通过/5默认live跳过（32秒），`client-fonts-target-final.log`记录补充目标73/73（约6秒），`client-analyze-fonts-final.log`记录No issues（5.9秒）。最终Card修复后新增/增强4个widget、identity38通过，最新完整504通过/5默认live跳过（25秒）、完整分析No issues（2.9秒）；该504尚未包含后续P4-02新源。实际ae字体/配置反馈已接收；390宽浏览器请求OS字号1.8但html computed仍16px，因此只计正常字号窄屏，另有真实widget1.8证据。c974退出后35语义节点/2editor，真实Tab由text到password INPUT，无需刷新即可再次输入；所有历史失败保留，不能据此标完整P6通过。

18080仍保留P3已验377包及原instance/epoch，P4新0006只用于专用资产库；不以候选源码、构建或18085结果声称已升级开发/生产服务。手机2026-10-22已重连，独立fixture的真实picker与OS终止正在执行，Android普通main恢复和完整旅程仍待最终步骤；Linux仍待实际环境。当前新浏览器只使用隔离Chrome，不使用用户Edge或个人标签页，不把本轮分项结果写成完整P4/P6完成。

P4-01该run最终16正常墓碑、8账户精确期初、有效分录/附件引用/活跃会话均0，18085/18185与专用Chrome已关闭，18080/18181/55432保留。随后P4-02追踪/summary及纯模型新源码完整客户端602通过/5默认live跳过、分析无问题；后端独立receipts专库425通过（含12 PG/ASGI），后续18086真实socket1通过并关闭。新schema表达窄修仅21合同/33组runtime等效比较，无需重复425；新wheel未安装。602尚未构建Web/Android新产物，无新回款UI/真实Flutter HTTP验收，不能把前一c974/504浏览器结果扩大到后续新模块。
