# 流迹 Flutter 客户端

当前已接入 Android/Web/Windows 共用工程、本地 SQLite 草稿与迁移、资料空间隔离、邀请码注册和登录、设备会话、主题及手动同步入口。同步页面提供冲突选择和恢复备份核对；算法与真实验收见模块文档。正式记账和完整三平台体验继续按计划开发，本地草稿不会被算为账单。

在本目录运行：

```powershell
flutter --no-version-check pub get
dart run build_runner build --force-jit
flutter --no-version-check analyze --no-pub
flutter --no-version-check test --no-pub
flutter --no-version-check devices
flutter --no-version-check build apk --debug --no-pub --target-platform android-arm64
flutter --no-version-check build web --no-pub --pwa-strategy=none --no-web-resources-cdn
```

SDK 本轮验证为 Flutter 3.38.3 / Dart 3.10.1，精确依赖见 pubspec.lock。Debug Android 包为 com.flowtrace.flowtrace.dev；不得对现有钱迹包或真实账本执行清理/写入。Android 许可不自动接受，构建也不自动下载系统 SDK。Web WASM/worker 已按固定版本放在 web/，普通构建不需连接 Python 服务端。

P1 全套95项和授权Android真机基础集成1项通过；P2身份/传输与安全HTTP元数据34项、真实Android身份1项和同步UI1项通过。本轮串行完整回归178项通过、3项需QA参数的live测试默认跳过；各项真实联测另有专项回执。后续完整回归计数以模块文档与任务日志为准。设备集成入口位于 `integration_test/`，使用 `flutter --no-version-check test integration_test/foundation_test.dart --no-pub -d <授权设备>`；身份与同步测试还要求隔离18080服务及未提交的合成QA参数文件，通过 `--dart-define-from-file` 提供。不得将真实账号凭据编入测试包。

测试只操作本轮合成数据与独立debug包；不运行钱迹的数据清理或写入。Flutter工具的测试安装生命周期不保证保留debug应用数据。设备集成完成后重新构建并安装常规 `lib/main.dart`，不携带QA参数。arm64构建只代表当前真机调试产物，其他ABI及正式签名包仍需各自验收。多人协作时串行运行本工程Flutter命令，避免Windows原生依赖构建缓存竞争。

Web基础浏览器检查使用独立18181端口，并提供COOP `same-origin`/COEP `require-corp`响应头；需要正确提供sqlite3.wasm和drift_worker.js。应用拒绝纯内存/unsafeIndexedDb存储模式；关闭默认PWA生成，完整离线缓存与升级按P6实现。

数据库、当前验收与平台限制见 [客户端模块](../../AI/modules/client.md)，完整目标及恢复入口见 [计划进度](../../AI/plans/flowtrace/progress.md)。
