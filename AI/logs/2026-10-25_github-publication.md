# 2026-10-25 GitHub 公开仓库与 Alpha 构建发布

> **任务**
> - 标识：github-publication
> - 状态：已交付（公开源码与既有构建）

## 背景

用户原话：

> 帮我建GitHub仓库
> 公开
> 然后上传构建

本次明确授权创建公开仓库、推送当前源码及发布构建，覆盖10月24日工作包“不推送”的旧限制。默认使用当前已登录的`RuibinNingh`账号和项目名称`FlowTrace`；不扩展新业务、客户端重建或生产更新。

环境为Windows PowerShell，日期采用Asia/Shanghai。开工`main`基线为`3098a5f`，没有remote；已有17项受跟踪修改及7个未跟踪文件，均为上一包图标资源、导出器、文档与任务记录，原样保留并保存为`5a735e8`。相关来源见[图标接入记录](2026-10-25_app-icon-integration.md)、[原生构建记录](2026-10-24_native-client-rebuild.md)和[生产部署记录](2026-10-24_client-production-deployment.md)。已阅读AI入口、当前进度/计划、workspace/client/web/windows/production模块及日志约定；未派发子代理。

## 行为变化

- 公开仓库：[RuibinNingh/FlowTrace](https://github.com/RuibinNingh/FlowTrace)，默认分支`main`；本地`origin`为该仓库HTTPS地址，`main`已建立上游跟踪。原有历史及“流线 F”图标源码均已上传，没有改写提交历史。
- 公开预发布：[v0.1.1-alpha.2](https://github.com/RuibinNingh/FlowTrace/releases/tag/v0.1.1-alpha.2)，标题`FlowTrace 0.1.1+2 Alpha`，Release ID为`423293747`，上海时间2026-10-25 17:40:40公开；`draft=false`、`prerelease=true`。标签精确指向Web构建来源`5f3e813625778623ca313e3eea4203c304be18ad`。
- 发布7项附件，共159,004,263字节：Windows x64 ZIP、Android ARM64 Debug APK、Web ZIP、Python服务端wheel、`requirements.lock`、公开`release-manifest.json`及`SHA256SUMS.txt`。五个既有交付文件按原字节复制，公开manifest只保留版本、来源、构建/签名边界及摘要，没有沿用生产备份路径等运维字段。
- 构建为2026-10-24已验字节：Windows/APK来源`158ebc2`，Web来源`5f3e813`，服务端来源`1447709`；客户端版本0.1.1+2、后端包版本0.1.0。Release说明和仓库首页明确：最新源码包含10月25日新图标，现有构建尚未包含；本次没有重新构建或更新生产。
- 真实凭据、业务数据/数据库、备份、本机环境及调研原件仍留在忽略目录；构建作为Release附件发布，没有强制加入Git源码树。

## 影响文件

- `AGENTS.md`：增加本次明确GitHub授权，说明覆盖旧包不推送限制。
- `README.md`：增加公开源码与Alpha下载入口，纠正仍停留在初始开发阶段的介绍，说明当前源码/构建版本差异。
- `AI/README.md`、`AI/modules/workspace.md`：登记发布恢复入口、源码跟踪与产物边界。
- `AI/plans/flowtrace/plan.md`、`progress.md`：登记R18、实际发布状态与下一动作，保留旧包接收快照。
- 本任务记录。
- 上包24个既有图标相关文件仅保存为`5a735e8`，没有在本任务重新修改或重做图标。
- `outputs/releases/github/20261025-alpha-0.1.1-2/`：7个上传附件的本地原字节副本；`outputs/validation/github-publication-20261025/`：审查、整理、远端摘要核验脚本及API/匿名下载回执。两目录继续被忽略。

人工核对映射：workspace、AI入口和计划恢复位置已同步；日志与计划约定本身未变。client/web/windows模块已准确描述图标只进入源码、当前构建仍是旧字节，production模块及Linux手册的线上事实未变，均不制造空改动。既有已交付日志没有改写。

## 已执行验证

1. `git status --short --branch`、`git log`、`git remote -v`、`gh auth status`及`gh api user`：核对基线、账号及授权；最初一次GitHub API请求出现TLS握手超时，随后同会话鉴权/只读重试成功。创建前查询该仓库不存在。`git count-objects -v`提示一个既有临时对象垃圾，保留原文件，未执行清理；后续完整源码推送成功。
2. `python outputs/validation/github-publication-20261025/audit_publication.py`：首轮扫描可达Git历史blob、当前跟踪/未跟踪文件及4个压缩包成员，共2536项；高置信密钥/令牌规则与已知生产私有口令匹配均无发现。10处字面量候选经上下文核对，实际为字段拒绝/脱敏测试哨兵、测试数据库密码或随机测试用户名的前缀，不是真实凭据。发布文档完成后再扫描2537项，仍无高置信发现；回执`publication-audit.json`，不输出真实口令值。
3. 四个压缩包CRC及安全成员检查通过：Windows26项、APK161项、Web41项、wheel226项；摘要逐一匹配此前交付manifest。`git check-ignore -v`确认真实凭据、outputs产物及venv均在忽略边界。
4. `prepare_release.py`：从已验目录复制五个交付文件并逐项比对原有大小/摘要，生成公开manifest和校验清单；7项附件合计159,004,263字节。上传前再次逐项读取`SHA256SUMS.txt`核验通过，旧产物没有变更。
5. `git diff --cached --check`、`git commit`保存图标源码为`5a735e8`；`gh repo create RuibinNingh/FlowTrace --public --source . --remote origin ...`成功，`git push --set-upstream origin main`成功。GitHub返回`visibility=PUBLIC`、`isEmpty=false`、默认分支`main`。公开树读取986个文件且未截断，没有work/outputs、私有环境文件、数据库或密钥文件。
6. `gh release create ... --draft --prerelease --target 5f3e813... --notes-file ...`上传7项附件；`verify_remote_assets.py`逐项核对远端`state=uploaded`、字节数和GitHub存储SHA-256，与本地完全一致后，才执行`gh release edit v0.1.1-alpha.2 --draft=false`。公开后再核对全部7项摘要仍一致；回执`remote-release.json`、`remote-assets-verification.json`。
7. `git fetch origin tag v0.1.1-alpha.2`及GitHub tag ref API均确认标签指向完整`5f3e813...`提交。首次普通curl读取仓库主页30秒超时；显式沿用会话代理后，匿名仓库主页、匿名Release API和匿名校验清单下载均为HTTP200，下载的校验清单与本地逐字节相同。没有借此更改系统代理设置。
8. `verify_documents.py`检查7份文档的173个本地链接全部可解析、任务日志五节完整，`git diff --check`通过；发布文档提交后推送`main`，最终以本地/远端SHA与工作区状态复核同步。命令及摘要回执保留在本包outputs验证目录。
9. 额度接口可用，当前7天窗口已用8%、剩余92%，额外积分0；这是本次账户接口快照，不沿用旧包数值。

## 未执行验证

未重新运行Flutter构建、完整analyze/test、服务端完整回归或设备测试，因为本任务发布已验构建，持久化修改为仓库入口/授权/发布记录及保存既有图标改动。原生/业务原有验证范围仍以相应历史记录为准，不把本次hash/CRC核验当成新的运行验收。

未配置GitHub Actions自动构建或发布、GitHub Pages、代码签名、生产更新及旧库原地升级测试。Windows应用未签名，APK继续使用既有Debug签名和`.dev`包名，安卓设备测试继续取消；现有完整高级功能及平台验收缺口集中在[workspace](../modules/workspace.md#当前缺口)。本包公开上传已获授权，不自动开启含新图标的重新构建或其他工作包。
