# 跨轮计划约定

需要跨阶段或跨轮恢复的任务，建立 `AI/plans/主题/plan.md` 和 `progress.md`。简单且可当轮交付的任务直接使用任务日志，不额外制造计划文件。

- [计划模板](../../.agents/skills/repo-collaboration-logging/assets/templates/plan.md)：保留用户原话，写明完成状态、现状证据、范围、默认决策、执行顺序、验收与停止条件。
- [进度模板](../../.agents/skills/repo-collaboration-logging/assets/templates/progress.md)：记录当前阶段、基线、执行能力、已完成位置、未验证事项和下一项具体动作。

恢复工作时先读 `progress.md` 的状态块和下一步，再读对应的 `plan.md` 章节。更新进度时链接到实际任务记录，不复制完整命令回执；目标或范围发生变化时明确登记依据。

当前维护 [流迹完整开发计划](flowtrace/plan.md)，恢复入口为 [流迹计划进度](flowtrace/progress.md)。2026-10-21 已获开发授权，按依赖实施中；规划与开发的实际证据分别保存在 [任务日志目录](../logs/)。
