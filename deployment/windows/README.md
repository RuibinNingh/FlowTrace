# Windows 本地解压分发

Windows x64 采用每版本独立目录的 ZIP 分发，不写注册表或系统服务。`Package-FlowTrace.ps1`只包装已构建 bundle，生成逐文件清单、签名状态和 ZIP SHA256；`Expand-FlowTrace.ps1`先校验 SHA256 和目录边界，再解压到全新目录并逐文件复核。脚本不删除旧版本或用户数据，不执行联网自动更新。

打包还从已安装 Visual Studio 的官方 `VC/Redist/MSVC/<version>/x64/Microsoft.VC*.CRT` 复制未修改的 `msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll`。脚本核对 x64 PE 架构，清单记录版本和摘要，并带 `Microsoft-VC-Runtime-NOTICE.txt`；不搜索系统目录或网络下载 DLL。默认使用该 Visual Studio 的 `Microsoft.VCRedistVersion.default.txt`，可用 `-RuntimeDirectory` 指定同一官方 Redist 树中的已装 x64 CRT 版本。构建输入中的旧 `release-manifest.json`、`BUILD-PROFILE.txt` 被忽略，重新生成本次清单及构建说明。

依据：[Flutter ZIP分发要求](https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows)、[Visual Studio 2026可再分发清单](https://learn.microsoft.com/en-us/visualstudio/releases/2026/redistribution)。这些组件沿用适用 Microsoft 许可，不能据本地运行声称已在无开发工具的干净机器验收。

```powershell
./deployment/windows/Package-FlowTrace.ps1 -BuildDirectory ./apps/flowtrace/build/windows/x64/runner/Release -OutputDirectory ./outputs/releases/windows/0.1.0-local -Version '0.1.0+1'
./deployment/windows/Expand-FlowTrace.ps1 -Package ./outputs/releases/windows/0.1.0-local/FlowTrace-0.1.0+1-windows-x64.zip -Sha256 (Get-FileHash ./outputs/releases/windows/0.1.0-local/FlowTrace-0.1.0+1-windows-x64.zip).Hash -InstallDirectory ./outputs/releases/windows/installed-0.1.0
```

`-BuildProfile` 只接受 `production` 或 `local-test`，默认 `production`。该参数声明已编译二进制的 profile，打包器不检测或更改 Dart 编译期常量，调用者必须保留与声明一致的构建命令和回执。普通 Windows Release 的 `production` 使用 HTTPS；本机测试服务需要 HTTP 时，先在获准的 SDK 窗口以普通 `lib/main.dart` 加 `--dart-define=FLOWTRACE_LOCAL_TEST=true` 构建，再包装为 `local-test`。测试 profile 只允许本机/局域网 HTTP，公网地址仍须 HTTPS。服务地址在应用设置中填写，包内不附凭据或私有配置。

```powershell
# Version 和产物需对应同一次实际普通 main 构建；此处版本仅为调用示例。
./deployment/windows/Package-FlowTrace.ps1 -BuildDirectory ./apps/flowtrace/build/windows/x64/runner/Release -OutputDirectory ./outputs/releases/windows/0.1.0-local-test -Version '0.1.0+1' -BuildProfile local-test
```

清单包含 `build_profile`、`build_profile_file`，包内 `BUILD-PROFILE.txt` 同样列入逐文件 SHA256。`-Qa` 独立表示专用 QA 入口；最终普通应用不传此开关。已有 QA101/102 构建没有本机测试 define，不能仅改包装参数就称为支持本机 HTTP 的最终应用。

默认业务数据保留在 `%APPDATA%\com.flowtrace\flowtrace\flowtrace`：`flowtrace.sqlite`、`attachments/` 与实例锁。此位置与已锁定 path_provider 原有路径一致；CompanyName/ProductName 是存储兼容标识。refresh 凭据仍由 flutter_secure_storage 的 Windows 受控存储管理，不写普通 SQLite 或 ZIP。

原生 runner 在启动 Flutter 前取得数据目录的 OS 文件写锁；同根第二个进程退出73，尝试激活现有窗口。进程异常结束由 OS 释放 HANDLE，锁文件残留不表示仍运行。启动失败显示目录/权限/磁盘错误，不换空库。显式 `--flowtrace-data-dir=C:\absolute\isolated-data` 可指定本地数据根，安装目录及其 junction 别名、网络路径、相对路径会被拒绝；该参数不移动已有数据，也不改变安全凭据插件的产品命名空间。

升级前正常关闭旧版本，使用 `Snapshot-FlowTraceData.ps1` 将 SQLite、尚存 WAL/SHM 和附件复制到全新快照目录。脚本先取得 runner 使用的同一 OS 文件写租约，正在运行的应用会使快照拒绝；逐文件 SHA256 通过后才写完整清单。路径中的 junction/符号链接被拒绝，不复制实例锁、QA 记录或系统凭据。若复制中断，失败目录保留，不会覆盖原资料。

```powershell
./deployment/windows/Snapshot-FlowTraceData.ps1 -DataDirectory "$env:APPDATA/com.flowtrace/flowtrace/flowtrace" -SnapshotDirectory 'D:/FlowTrace-backups/before-0.1.0'
./deployment/windows/Restore-FlowTraceData.ps1 -SnapshotDirectory 'D:/FlowTrace-backups/before-0.1.0' -DataDirectory 'D:/FlowTrace-recovered/flowtrace'
```

快照/恢复目标的父目录需先存在，目标目录必须全新；恢复先核对清单、路径和所有摘要，损坏快照不会创建目标。恢复不覆盖原数据，使用兼容版本加 `--flowtrace-data-dir` 指向新目录。Windows 受控凭据保持在原插件目录及 Credential Manager 中，跨机器恢复需重新登录。文件快照含本地账单与草稿，应由使用者保存在受控位置。

新 ZIP 解压到另一个新目录后启动，共用同一用户数据根。应用包回退保留旧目录；若新版本发生不兼容数据库迁移，先从升级前的数据快照恢复，不能假设旧二进制可读新 schema。删除解压目录相当于卸载程序，默认保留用户数据；清除数据是单独的用户操作，本脚本不执行。

本地包未签名时 Windows 可能显示系统来源确认；签名状态以清单和实际 Authenticode 结果为准。本文不代表已发布、已签名或全部 P7 验收通过。实际运行证据见 [Windows 验证](../../tests/e2e/windows/README.md)。
