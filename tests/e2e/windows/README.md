# Windows 原生验收

本目录使用新 UUID 与显式用户数据根，保留所有原始回执。普通 `lib/main.dart` 不包含 QA 入口；目标 `lib/platform/windows/windows_acceptance_main.dart` 仅显式编译时使用，无网络或 Android 操作。

串行构建第一个候选，先由协调者确认 Flutter SDK 无其他任务：

```powershell
$run = [Guid]::NewGuid().ToString()
flutter build windows --release --target lib/platform/windows/windows_acceptance_main.dart "--dart-define=QA_WINDOWS_RUN=$run" --dart-define=QA_WINDOWS_BUILD=one --build-name=0.1.0 --build-number=101
```

将候选按 [Windows 打包说明](../../../deployment/windows/README.md) 包装并解压到独立目录，QA 包需加 `-Qa`。随后调用 `run_acceptance.py`，`--exe`传入新解压包的绝对路径，`--output`传入本轮UUID证据目录，`--run`沿用构建时的`$run`，`--build one`。脚本只操作自己的子进程；观察原生可见窗口、Flutter 原生帧、真实第二进程退出73，再终止第一进程并重启同一候选，比较原有快照。不是宿主机系统重启证明。

候选使用生产 NativeDatabase/附件路径入口、LedgerRepository、AttachmentRepository、SyncStore 和系统受控凭据插件；真实写入图片账单，检验 `9007199254740993 − 125 = 9007199254740868`、3条 outbox/1份冻结字节、完整草稿 `12+`、附件 SHA256 与设置。故障探针使用另一个独立SQLite文件，以真实 EXCLUSIVE 锁验证 SQLITE_BUSY/LOCKED，以 `max_page_count` 精确限制验证 SQLITE_FULL和失败回滚，不填满宿主机磁盘、不修改主业务库。

第二个候选使用相同UUID、`QA_WINDOWS_BUILD=two`、`--build-number=102`，重新打包解压到另一个全新目录。运行相同host并加 `--build two --reopen-only`，不能播种、必须读取第一版本留下的账单/附件/outbox/设置/系统凭据；成功后只删除本轮UUID的合成凭据key。其余测试数据和产物保留，不触碰真实用户目录。

最终另构建普通 `lib/main.dart` release，包不标QA，独立干净数据根启动并保留普通界面证明。只有构建不能算原生运行通过。全量桌面键鼠旅程、Windows系统重启和真实两端同步必须分别登记，不能用此小集代替 P7-01–03 完整验收。当前实际执行结果由计划进度和任务日志维护。

## 2026-10-22 已执行的第一候选

新UUID `4c6ec455-9e78-4c67-84b1-b69928c2fc0c`，`0.1.0+101` release原生构建成功（67.8秒），定向分析无问题、WindowsRuntime 6项通过。ZIP SHA256为 `a1a5b920848dc9d6d380f97d438fd51e3264c53178cce59db99eb74b01d38ce1`，Authenticode为NotSigned；新解压目录逐文件校验通过。该QA包不作为普通应用发布。

实际Windows进程取得可见原生窗口，生产SQLite/附件/完整草稿/outbox和大整数均通过；同数据根第二进程退出73。首次进程终止后的新PID重开，业务快照SHA256仍为 `5ec117bedbe4b0efe34b56e258513aed26df9f787a75c0aed0112275cb3ffb05`。独立SQLite故障探针真正返回BUSY=5、FULL=13，失败写不存在且基线保留；系统受控存储合成key重开成功。回执在忽略的 `outputs/validation/P7/4c6ec455-9e78-4c67-84b1-b69928c2fc0c/`。

实际MSVC `/W4 /WX`编译runner目录逻辑，4项OS边界通过（第二writer、异常退出释放、relative/UNC/install拒绝、junction指向install在创建前拒绝）。安装器的6组合成ZIP检查通过：正常包接受，遍历、大小写重复路径、清单外文件、单文件摘要错与ZIP摘要错均拒绝。脚本早期编译器环境/PowerShell模块路径和编码失败目录保留，修正后使用全新UUID重跑。

Computer Use官方`@oai/sky`已观察第一QA候选重开窗口；首次非前景像素归属不正确，未作输入、未将内容用于验收，显式激活返回的唯一FlowTrace窗口后原生标题栏/恢复状态像素与ARIA均正确。当前这些第一候选证据未覆盖普通main、全部桌面旅程、Windows系统重启或真实联网同步；第二候选另列如下。

## 第二候选升级与离线快照

同一 UUID 的 `0.1.0+102` release 原生构建成功（38.1秒），在新目录解压并逐文件复核后运行，读取第一版本原资料而没有重新播种。ZIP SHA256 为 `87f239fa2a5f25b96ff1647cc58afbb3c06ce576fc9cf8d3e484a6aed2c07f0b`，NotSigned；host 回执 `host-two-0676d905-e55f-4564-ab42-51060e614927.json` 证明大整数余额、3条 outbox/1份冻结正文、完整草稿、原件与设置的快照 SHA256 仍为 `5ec117bedbe4b0efe34b56e258513aed26df9f787a75c0aed0112275cb3ffb05`。跨版本读取本轮合成凭据成功后只删除其 UUID key，第二 writer 仍退出73。owned进程已关闭。

官方 Computer Use 对唯一第二候选窗口返回 `WINDOWS_REOPENED · two` 和正确 ARIA；但三次截图在激活/重新选择/Raise 后仍含其他窗口遮挡像素，未将这些像素当作外观通过。应用自己生成的 `qa-frame-two-31236.png` 渲染帧文字正确；此帧不代替真实屏幕归属验证。

`test_data_snapshot.py` 用上述真实 SQLite 和原件验证快照/新目录恢复，9组检查通过：live OS writer拒绝、离线复制、恢复后 `integrity_check=ok` 且3实体/3outbox、已有目标拒绝、摘要损坏/路径穿越/空库/junction拒绝。原 SQLite SHA256 未变，系统凭据不复制，QA文件不进入快照。成功回执在 `outputs/validation/P7/data-snapshot-60035937-c411-4e77-bfbf-0565e7d1b0ca/receipt.json`；第一轮仅验证器表名写成 `outbox_operations` 的断言失败场景 `data-snapshot-c2372ca2-af8d-4b43-9c1e-ee40c524db4d` 保留，改为实际 Drift `pending_operations` 后新 UUID 重跑通过。

这些结果不覆盖普通 main、完整桌面旅程、Windows 系统重启、真实磁盘耗尽或联网同步。

复核分发依赖后，另打包含已安装 VS 官方 x64 CRT `14.50.35719.0` 三DLL及 NOTICE 的 `qa-two-crt-4c6ec455-v2` 包，SHA256 `94bf86f83103efa6491d87ac5fa7c87289b21eae7d6dbb7f550986239c7f2fbd`。新目录解压和逐文件摘要已通过，原101/102包保持。首个重包 `6a6b82c0f2b282bfa1bed16eaef1fb6164e056103b140b59348b5115831fde53` 因将原包旧清单纳入新清单造成自哈希不一致，实际安装校验拒绝；改为忽略输入旧清单后新目录复验通过，失败包与目录保留。CRT包尚未在干净无VS机器运行，普通main新包的实际运行另验。

快照安全复审另加“附件清单经过中间junction”检查，首次 `data-snapshot-64651593-721d-494e-bf3a-d5b400ffbbd4` 和只修改错误循环的 `data-snapshot-0196eb8e-438a-489d-9a4d-7791dbe3d8a4` 均因测试发现错误接受而失败，场景仅涉及合成文件/新目录且已保留。实际文件祖先检查改为先取 `FileInfo.Directory`，再沿 `DirectoryInfo.Parent` 检查重解析点，新UUID `data-snapshot-f6a4433e-4067-405b-a206-b2704e6c5780` 的10组检查全部通过，原数据摘要仍不变。前述9组保留为先前证据，当前检查集为10组。

随后把附件junction用例再扩为“junction与文件之间隔一层普通目录”，用 `[IO.DirectoryInfo]` 类型区分文件/目录，避免依赖 provider 的 `PSIsContainer` 扩展属性。最终 `data-snapshot-1e4a2a73-5bbc-4044-b18f-83468df83227` 仍10组通过，原SQLite不变。打包脚本追加拒绝嵌套输出/junction路径、只取已装官方 Redist、微软有效签名验证和 EXE FileVersion 一致检查后，新CRT包v3的SHA256为 `d4b8bb567a3ec498156656fb713deec6a0e279463ba7258d72209b323194a602`，新目录解压逐hash通过，Microsoft三DLL均14.50.35719.0。实际拒绝嵌套输出和System32运行库来源且未创建目标；普通main实际运行仍待后续独立候选。

## 2026-10-23 普通内部候选与profile验证

在协调者授予的串行SDK窗口，实际执行`flutter build windows --release --target lib/main.dart --dart-define=FLOWTRACE_LOCAL_TEST=true`，构建成功75.3秒；保持pubspec原版本`0.1.0+1`，不混用QA入口。立即复制整个Release到`outputs/validation/P7/ordinary-local-test-fda06dae-ad2f-4160-ae92-377cd637c34f/candidate/`，与`candidate-receipt.json`、`build.log`和父源码快照一同保全。来源为167个源文件（含144个`lib/`文件及资源/Web/pub文件）快照`bfb4a863801955200c117841ce20f854c6808169ff7ac322b07ad5196664bc1d`，构建后逐源文件复核仍一致；bundle文件列表SHA256为`b8473c80a1d24dd4b91bd6f3bb8ab1443c649f25997b4731a449fe9bb4c5ff4d`。这是内部运行候选，尚非统一版本的最终分发产物。

`test_package_profiles.py`以实际保全的旧QA102和新普通候选验证3项：省略`-BuildProfile`得到`production`且QA标记保留；显式`local-test`得到普通非QA包；非法profile拒绝且不创建输出。两包均含3个微软CRT/NOTICE、受hash覆盖的`BUILD-PROFILE.txt`，分别在新目录解压并由现有解压器逐文件验证，原EXE摘要保持。脚本只验证包装声明；编译常量以对应构建命令和保全回执证明。

```powershell
$windowsProfileRun=[Guid]::NewGuid().ToString()
./server/.venv/Scripts/python.exe tests/e2e/windows/test_package_profiles.py --production-build outputs/releases/windows/qa-two-crt-4c6ec455-v3/FlowTrace --production-version '0.1.0+102' --production-qa --local-test-build outputs/validation/P7/ordinary-local-test-fda06dae-ad2f-4160-ae92-377cd637c34f/candidate --local-test-version '0.1.0+1' --output "outputs/validation/P7/package-profiles-$windowsProfileRun"
```

实际成功回执为`outputs/validation/P7/package-profiles-9ae1e7ce-a393-414d-a2ca-38418687baff/receipt.json`。新production QA102内部包装SHA256为`5dba3d0205f88b31b7f4ba213feebc1b203bc94ff8861f43a6075faee71feae4`；新普通local-test内部包装SHA256为`17a7f6d95dd8b8bad1c3d6e0f4134f5fa29650cafe07e7bfd5e7c86e19988a63`。均NotSigned；原101/102和CRT v3等旧ZIP未改，也未在干净无VS主机验收。

从该轮`installed-local-test/FlowTrace/flowtrace.exe`以全新`ordinary-native-data`根真实启动所属进程33120，取得窗口792788和正常“流迹/未登录/本地草稿/新建草稿”ARIA；实际SQLite已创建。首次activate失败后，仅按技能恢复规则重新选择唯一返回窗口观察一次，截图明确显示Windows锁屏。未进行原生UI输入，不能把底层ARIA当成应用像素或完整输入验收。`native-launch.json`、`native-observation.json`及stdout/stderr保留在上述profile验证目录；所属进程保留，待用户本人解锁后再继续。

暂停依据是Computer Use [SKILL.md](C:/Users/ruibi/.codex/plugins/cache/openai-bundled/computer-use/26.1016.51333/skills/computer-use/SKILL.md)所指定的[guidance.md](C:/Users/ruibi/.codex/plugins/cache/openai-bundled/computer-use/26.1016.51333/docs/guidance.md)，其Recovery原文为：“If the Windows desktop is locked, stop immediately and ask the user to unlock the desktop. Do not try to interact through LockApp.exe.” 该指南还明确禁止“any in-app security or privacy settings”更改及“Do not automate user authentication dialogs.”，未给自建应用或合成口令例外；本轮不通过其他原生自动化绕开它。共享保护/隐私已有KDF、草稿与widget证据，原生真实保护口令输入仍未验；后续获准主题、普通功能、草稿及键鼠旅程与此分别记录。
