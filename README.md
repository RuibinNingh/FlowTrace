# 流迹 FlowTrace

[GitHub 仓库](https://github.com/RuibinNingh/FlowTrace) · [Alpha 构建下载](https://github.com/RuibinNingh/FlowTrace/releases/tag/v0.1.1-alpha.2)

流迹面向个人与朋友提供自托管、多用户记账，采用 Flutter 客户端和独立 Python 服务端，支持 Android、Web 与 Windows；服务端在 Linux 原生部署，并提供后台面板。

当前为 Alpha，完整功能与各平台验收仍有未完成项，详见[当前进度](AI/plans/flowtrace/progress.md)和[工作区缺口](AI/modules/workspace.md#当前缺口)。现有调研原件保存在本地忽略目录 `work/`。

GitHub Release `v0.1.1-alpha.2` 提供 Windows x64 ZIP、Android ARM64 Debug APK、Web ZIP、Python 服务端 wheel、锁定依赖及 SHA-256 清单；客户端版本为 `0.1.1+2`。本次复用 2026-10-24 已验证的构建，具体来源提交见附件 `release-manifest.json`。`main` 源码已包含 2026-10-25 选定的“流线 F”图标，现有 Release 构建尚未包含新图标。发布与核验见[本次记录](AI/logs/2026-10-25_github-publication.md)。

2026-10-24 Alpha 已按用户授权原生部署至 Linux：[访问流迹](https://home.ruibin-ningh.top:18473/)、[后台](https://home.ruibin-ningh.top:18473/admin/login)。钱迹实际导出兼容修复已上线：原文件105条/3退款已隔离验证，页面显示具体错误及请求ID，生产脱敏日志已开启；真实账本仍由用户预览后确认导入。首次服务器设置、账号、完整导入、启停及备份见[Linux运行手册](deployment/linux/README.md)。

Web/Windows/APK `0.1.1+2`已部署到生产，新安装默认服务器为`https://home.ruibin-ningh.top:18473`，既有手动地址与资料保持。[Windows下载](https://home.ruibin-ningh.top:18473/downloads/0.1.1-2/FlowTrace-0.1.1-2-windows-x64.zip)、[Android ARM64 APK下载](https://home.ruibin-ningh.top:18473/downloads/0.1.1-2/FlowTrace-0.1.1-2-android-arm64-debug.apk)已实取核对hash；Windows未签名、APK为原Debug证书且未做设备测试。部署与回退证据见[本次记录](AI/logs/2026-10-24_client-production-deployment.md)，原生构建见[前包](AI/logs/2026-10-24_native-client-rebuild.md)。后端继续已验1447709，schema不变。

- [完整开发计划](AI/plans/flowtrace/plan.md)：需求、范围、阶段、验收与委派要求。
- [当前进度](AI/plans/flowtrace/progress.md)：实施状态与下一项任务。
- [协作规则](AGENTS.md)：任务开始、文档同步和交付要求。
- [文档入口](AI/README.md)：按任务查找模块说明、日志与计划。
- [工作区说明](AI/modules/workspace.md)：目录职责、实际能力和当前缺口。
- [项目内 skill](.agents/skills/repo-collaboration-logging/SKILL.md)：本次采用的方法、参考资料和模板。

本地 `main` 跟踪公开仓库的 `origin/main`。查看当前文件状态：

```powershell
git status --short --branch
```

`work/` 和 `outputs/` 用于本地资料、工具和生成结果，已通过 `.gitignore` 排除。需要长期维护的项目代码、设计说明和测试应放在受版本跟踪的目录。
