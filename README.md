# 流迹 FlowTrace

流迹面向个人与朋友提供多用户记账，目标采用 Flutter 客户端和独立 Python 服务端，优先 Android，随后支持 Web 与 Windows，服务端主要在 Linux 原生部署，并提供后台面板。

项目已进入开发：P0 证据基线与契约落盘，Flutter 客户端和独立 Python 工程正在实现。每阶段的实际验证与未完成事项见当前进度；现有钱迹调研资料保存在本地 `work/` 目录。

2026-10-24 Alpha 已按用户授权原生部署至 Linux：[访问流迹](https://home.ruibin-ningh.top:18473/)、[后台](https://home.ruibin-ningh.top:18473/admin/login)。钱迹实际导出兼容修复已上线：原文件105条/3退款已隔离验证，页面显示具体错误及请求ID，生产脱敏日志已开启；真实账本仍由用户预览后确认导入。首次服务器设置、账号、完整导入、启停及备份见[Linux运行手册](deployment/linux/README.md)。

最新Web/后端包在`outputs/releases/production/20261024-qianji-1447709/`；Windows/APK继续使用`20261024-alpha-0926681/`中的冻结产物，本轮未重建且安卓测试取消。验证、未验项和更新证据见[生产部署模块](AI/modules/production-deployment.md)及[本次记录](AI/logs/2026-10-24_qianji-export-import-fix.md)。

- [完整开发计划](AI/plans/flowtrace/plan.md)：需求、范围、阶段、验收与委派要求。
- [当前进度](AI/plans/flowtrace/progress.md)：实施状态与下一项任务。
- [协作规则](AGENTS.md)：任务开始、文档同步和交付要求。
- [文档入口](AI/README.md)：按任务查找模块说明、日志与计划。
- [工作区说明](AI/modules/workspace.md)：目录职责、实际能力和当前缺口。
- [项目内 skill](.agents/skills/repo-collaboration-logging/SKILL.md)：本次采用的方法、参考资料和模板。

本地 Git 已初始化。查看当前文件状态：

```powershell
git status --short --branch
```

`work/` 和 `outputs/` 用于本地资料、工具和生成结果，已通过 `.gitignore` 排除。需要长期维护的项目代码、设计说明和测试应放在受版本跟踪的目录。
