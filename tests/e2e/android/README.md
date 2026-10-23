# Android 平台专项

既有账务真机用例 `apps/flowtrace/integration_test/ledger_test.dart` 已1/1通过，证明真实页面、受控HTTP阻断、本地文件库重开和两会话账务一致。2026-10-22 本轮OEM系统picker的合成选图、取消和超限拒绝已通过；OS首次只读QA事务失败保留，修复后同一APK无重装的第二次force-stop/COLD/只读精确恢复通过，普通main已恢复并实际冷启。以下同时区分专项约定与本轮回执，不把已有组件或脚本视作完整跨功能验收。

2026-10-22 用户确认“已接入手机，继续执行剩余计划”，恢复授权设备专项。只读盘点确认唯一既有 `android-plt140-dev1` 为 PLT140、Android16/API36、arm64-v8a、启动完成；本轮开始时 dev 包未安装。普通main已在本轮专项后恢复；完整跨功能旅程仍待后续，不使用用户Edge或个人Chrome。

## 隔离数据与入口

- 每轮生成UUID，在应用支持目录下创建该轮独立SQLite/元数据目录；不打开正常用户库，不清应用数据。
- 图片只使用脚本生成的静态小PNG、一个超过10MiB的合成文件；仅写入 `Download/FlowTrace-UUID.png` 等明确命名的新文件。记录大小、SHA256和尺寸，不访问用户照片或钱迹。
- 图片选择复用 `ImageAttachmentSelector().pick()/read(XFile)` 和现有 `AttachmentPanel`，使用系统picker默认实现，不注入fake picker、不新增第二套生产选择器。面板引用变化必须等待完整草稿持久化。
- 当前Flutter测试器会在结束时卸载集成包。本专项采用单独的debug fixture entry构建和手动安装，宿主ADB分阶段控制；fixture使用独立数据目录，最终恢复无QA参数的正常main。入口为 `apps/flowtrace/lib/qa/android_acceptance_main.dart`，宿主为本目录 `acceptance_host.py`。

## 当前 fixture 与分阶段宿主

入口必须显式传入新v4 UUID `QA_ANDROID_RUN`。首次创建 `applicationSupport/flowtrace-qa/android-UUID/` 的SQLite及原件目录；使用生产LedgerRepository保存合成账本、期初10000minor现金与expense125minor，预期余额9875minor。生产SyncStore冻结一条book请求，但从不联网、登录或打开普通资料库。它保存未完成`12+`的完整草稿，附件面板调用默认真实ImageAttachmentSelector，不注入picker。

宿主以 `--serial` 明确绑定已授权的唯一设备，输出仅用追踪名；每一步通过 `--run` 绑定本轮清单。`prepare`只读getprop并生成宿主文件，`push`拒绝覆盖已有同名Downloads，推送后核对SHA256。`picker-state`仅输出系统导航及本轮两个唯一文件名，不导出其他文件名；`select`要求真实DocumentsUI并按完整名称定位。`screenshot`限定前台自身应用，禁止系统picker截图。所有JSON/PNG必须导出到忽略的`outputs/validation/P4/android/UUID/`。

`核验选图`读取原件、尺寸、SHA、草稿和冻结意图；取消/超限核验比较完全相同的持久化快照。宿主另须保存真实系统picker取消、超限错误可见性的回执，应用的快照不变化本身不证明实际执行过这些操作。READY只在三个应用核验收据均存在后写入；宿主只在其PID与当前进程一致时force-stop本包。重启入口见到READY后，以SQLite `query_only`、禁迁移方式只读重建并比较快照摘要，不重新播种或重发命令；原件读取仍使用生产NativeAttachmentBytes。缺库、缺草稿或不完整首次播种都失败并保留目录。

构建与全团队Flutter调用串行；不要运行integration_test以免工具结束卸载应用。以下是分阶段命令结构，必须使用本轮生成的实际UUID和显式已核验设备serial，不将示例当回执：

```powershell
python tests/e2e/android/acceptance_host.py prepare --run $runId --serial $deviceSerial
flutter --no-version-check build apk --debug --no-pub --target-platform android-arm64 -t lib/qa/android_acceptance_main.dart --dart-define=QA_ANDROID_RUN=$runId
python tests/e2e/android/acceptance_host.py install --run $runId --serial $deviceSerial --apk $retainedApk
python tests/e2e/android/acceptance_host.py push --run $runId --serial $deviceSerial
python tests/e2e/android/acceptance_host.py start --run $runId --serial $deviceSerial
```

按真实UI顺序执行`tap`/`picker-state`/`select`/`cancel`/`assert-error`，然后`export`、`restart`、`screenshot`、`validate`。宿主不自动浏览未知系统页面或猜测首张图；安装只接受本轮证据目录保留且kernel包含本UUID的APK，避免构建失败后误装旧产物。`validate`不访问设备，独立解析导出JSON核对三实体/三意图/单冻结正文、精确金额、草稿原件引用及真实picker/进程回执，不能仅靠应用自报passed。安装和运行的实际结果按本节后续回执补充；脚本存在不代表系统picker/终止测试已通过。此本地专项不证明服务端上传/下载、网络恢复、随机掉电或最终完整旅程。

2026-10-22 首轮实际run `52acb86b-a02b-41ca-a082-50fd04977043`：宿主prepare通过，合成PNG为77字节、3×2，SHA256 `1f9f02b6b40dcfd3a8db1d36e64a04e9568f3a389fe721ee5de9f76dca615aa9`，超限文件10485761字节。新fixture定向Dart分析无问题，宿主语法检查通过。获分配的首次APK构建48.2秒失败：共享`sync_engine.dart:681`的Drift布尔表达式`&`无可用operator，已向责任代理报告，未改他人文件；完整失败保留本轮`flutter-build.log`。本轮尚未安装、推送文件或执行picker/force-stop，不能据准备结果标通过。

随后共享源码修复并重新冻结，第二次APK构建61.9秒通过，保留`fixture-debug.apk`为99358667字节、SHA256 `33664c0c0bfc499a4c1012d8514535243e1473520d400c362ead35c9b05bbb86`。宿主确认kernel中run UUID后更新安装成功，两份本轮合成Downloads文件push并设备SHA核对通过；初次冷启动和独立本地播种成功，`picker-ready.png`已导出并查看，显示98.75及草稿12+。未运行integration runner，应用和证据未被卸载。

真实点击生产附件面板打开的默认handler由`cmd package resolve-activity`确认为`com.coloros.filemanager/com.oplus.filemanager.picker.PickerActivity`，对应OEM的`ACTION_OPEN_DOCUMENT`。首次停在文件管理的“欢迎使用”协议页，按钮为“同意并使用/不同意”，声明需要所有文件、应用列表、设备标识及网络等；代理未替用户接受、授予权限或改系统默认。只读取固定notice控件并导出`host-oem-picker-notice.json`，没有截系统picker或导出私人文件名。此时系统选图、READY和OS终止仍未执行，待用户在手机自行选择后续接，不把应用播种算作picker通过。

用户本人随后确认“我已同意，可以继续选图测试”。OEM网格及列表的TextView均手工省略完整长UUID文件名；只读精确MediaStore查询确认原文件77字节/3×2并已索引，未凭截短名选图。经主代理批准，仅新增同字节短名`FT-52acb86b-a02b.png`与`FT-52acb86b-a02b-big.png`，源完整名、同SHA、大小、尺寸及全部4个精确清理名记录在`host-alias-files.json`，原两文件和旧回执不改。

通过真实OEM“文件→下载”列表按完整短名选择，生产面板暂存77字节3×2 PNG，原件/完整草稿/冻结意图核验通过；再次真实打开并显式取消，返回自身应用后快照不变。10485761字节合成文件同样真实选择后显示“请选择10 MiB以内的图片。”且快照不变。首次宿主以整节点相等匹配错误句失败，失败PNG保留；实际截图已查看，Android合并Semantics中包含完整句，宿主改为核对该同包节点内完整句后只读复核通过，没有重复选择或改数据。

三个应用收据通过后原`ready.json`已落盘、导出。宿主确认PID8333后只终止本包，旧进程退出并COLD启动，应用的只读重建因Drift原生默认`BEGIN IMMEDIATE`被SQLite `query_only`拒绝（code8）失败。`os-reopen-failed.png`及`host-restart-failed.json`保留，不当作数据丢失或应用重开通过。安装修复包之前，宿主已只读导出本run数据库/原件；mode=ro/integrity_check与逐行比较证实原READY的实体、操作/冻结正文、完整草稿、同步身份及附件记录/原件仍完全一致，见`host-persisted-before-qa-repair.json`。

QA helper仅在真实query_only连接上使用显式`BEGIN DEFERRED`读取完整一致快照，未改生产AppDatabase/SDK/领域规则。修复APK构建19.7秒通过，保留`fixture-readonly-fix-debug.apk`，SHA256 `300c877a4a6e39b326bea05e768893c6e36e22246bcd93863fd0844f0181d928`；kernel实查含新deferred/recheck常量，原APK不含。安装前因第二台设备上线，最初“唯一在线设备”guard拒绝，未执行安装；主代理批准只按原授权serial及属性绑定，另外设备仅忽略、不操作，绑定持久为serial摘要而不导出完整serial。

为区分QA修复安装与OS验收，修复包首次只读恢复另存`reopened.json`；随后只读按钮仅写`ready-recheck.json`证据。第二次同一APK、期间无重装，宿主force-stop PID16642→17379，Status ok/COLD3541ms，`reopened-recheck.json`、`host-restart-recheck.json`及独立`host-final-receipt.json`全部通过。三实体/三意图/单冻结正文、12+完整草稿、77字节3×2原件/引用及9875minor余额与最初READY完全一致，snapshot SHA256 `1b125692b8a3b0b16618ec35ccf829eca03c38198d0c64d5924f59163864bf8c`。修复前与最终独立只读SQLite逐字SHA均为`c5c8ef4e7dc302831c0cf9c192eeb7aec502f8b2a31838c563d6d7ca4703e60c`，原件SHA不变。最终ownapp截图已导出查看，原首次失败保持原样。

QA元数据命名缺口：`device-reopened-recheck.json`中的`qa_read_adapter_repaired_before_this_attempt:false`代码实际按`!recheck`标记“本阶段是否为修复安装后的首次启动”，字段名却表达了更宽的“此前历史是否曾修复”，因此字面不准确。真实历史是在最终OS复验**之前**已修复并安装，最终READY→force-stop→reopen期间**没有**修复或重装；以明确的安装/开始/READY/最终host回执为证。该false不能用来声称此前从未修复，原历史JSON不追改，澄清另存`qa-metadata-clarification.json`。

独立host validate通过后，仅对登记4个Downloads文件逐一先核同SHA再删除，`host-downloads-cleanup.json`通过；未访问或删除其他文件，private UUID数据库/草稿/原件目录及本地审计证据保留。本地专项不证明真实HTTP上传/下载、随机掉电或完整跨功能旅程。

## 本轮普通 main 恢复

全团队最终源码测试764通过/5项需QA live配置默认跳过及完整分析通过后，分配串行窗口，以`lib/main.dart`且无任何QA define构建普通ARM64 debug APK，22.4秒通过。保留`normal-main-debug.apk`为123295330字节，SHA256 `8ebc81d5b5e13acd1a145691f6d7c114647ae4890d7dea08ae74769a943d2795`。161个ZIP成员实际扫描均不包含本run UUID、QA fixture标题、`QA_ANDROID_RUN`或4个已知本地QA凭据值；回执仅记录计数，不导出secret。aapt确认包名`com.flowtrace.flowtrace.dev`及仅`arm64-v8a`。

ADB仅按原授权设备更新安装，无清应用数据。实际普通main强制停止后冷启Status ok/COLD4814ms，PID19776；正常未登录、空草稿首页已在720×1570截图查看，保持普通应用。该PID全部E日志2097字节保留，包含OEM运行时、调度、ashmem、Oplus及gralloc记录，因此不能称全E为空；定向AndroidRuntime/Flutter/DartVM错误tag为0行，进程继续运行，见`normal-main-error-review.json`。不清logcat，不访问其他包日志。普通main安装后再次独立只读核对private UUID库和blob，仍与最初READY完全一致，见`host-persisted-after-normal-main.json`。

源码、APK、JSON/PNG和失败均保留在对应分层目录；本专项没有提交、推送、生产部署，未使用用户Edge或个人Chrome。P4资金/资产真机、后续退款报销UI及最后完整跨功能旅程仍由主计划按其各自范围推进，此处普通main冷启不替代它们。

## 系统选择器主路径

1. 宿主只把本轮合成PNG推送到明确的Downloads路径，点击真实附件面板“添加图片”。确认前台是系统文件选择器，再通过该文件的完整唯一名称选择；不根据任意首张图片或屏幕坐标猜测目标。
2. 返回后核对PNG签名/尺寸/大小/SHA256、原件持久键、attachment UUID及完整草稿引用均一致，忙状态解除后才能继续保存。导出应用自身页面证据，避开系统相册内的私人缩略图。
3. 再次打开并取消，断言草稿及附件数量不变；选超限合成文件时明确拒绝且原件/引用不增加。若系统本身不展示非法文件，记录平台过滤边界，不冒称应用已在真实UI拒绝。
4. 若当轮继续HTTP路径，使用合成账号/新账本提交：附件ready先于账单引用，第二会话下载核对同一SHA256；去引用不删除原件，撤权后的预览消失。既有P2 HTTP附件用例通过不替代此系统选择器路径。

## OS终止与冷启动

1. fixture第一阶段写入真实本机意图、完整未完成草稿及合成图片，持久化完成后输出只含UUID/哈希/预期minor的READY回执。保存原进程PID及实体/operation ID、冻结正文摘要、附件引用和原件摘要。
2. 宿主确认包名为 `com.flowtrace.flowtrace.dev` 且READY后，执行该包的 `am force-stop`，确认旧PID退出，再 `am start -W`。不使用 `pm clear`、不重新安装APK、不触碰其他包。
3. fixture第二阶段只读重建并对照第一阶段回执；不得重新播种丢失实体或自动重放旧操作来使结果通过。验证新PID、COLD启动、同一空间、ID/正文/草稿/原件仍一致和余额精确；错误输出failed并保留本轮目录。
4. 强制终止证明已落盘数据在进程终止后保留，不等于随机掉电或事务提交瞬间崩溃。网络恢复与鉴权若未纳入本轮，单独记录，不把本地只读检查算同步通过。

## 证据和收尾

宿主必须在替换fixture之前导出JSON回执和应用页面PNG，验证PNG可解码；不只在设备私有目录写文件。清理只限已登记UUID目录、明确新增的Downloads文件及正常API产生的本轮对象，禁止整库/整相册清理。所有专项完成后一次重建安装普通 `lib/main.dart`，扫描包中无QA凭据，核对冷启动和自身错误日志。未运行的系统picker、OS终止或普通main恢复保持not_run，不因脚本已设计而标通过。
