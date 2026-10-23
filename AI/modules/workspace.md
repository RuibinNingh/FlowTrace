# 工作区与资料边界

> **速查**
> - 职责：说明 FlowTrace 当前目录、版本跟踪边界和可核验的执行能力。
> - 入口：根目录 `README.md`、`AGENTS.md`、`.gitignore`、`work/`、`outputs/`。
> - 不变量：保留已有调研资料；本地资料与可维护项目文件分别存放；未实现能力不写成现状。
> - 必跑测试：核对受影响文件和本地 Markdown 链接，运行 `git status --short --branch` 与 `git check-ignore` 检查跟踪边界。
> - 相关：[文档入口](../README.md)、[协作规则](../../AGENTS.md)、[任务日志约定](../logs/README.md)。

## 当前行为

2026-10-24起按用户新要求执行[额度受控Alpha](../plans/flowtrace/alpha-milestones.md)：先保存本地Git恢复点，当前0个活跃子代理；暂停非交付必需的新功能。Windows/Web/APK与独立本地测试服务优先，每包返回结果/额度后等待用户决定。M0只保存与交接，不重新构建、回归或安装服务。

2026-10-23最新：普通Windows/Web/APK及本机持久测试部署已纳入[交付分册](../plans/flowtrace/delivery-local-test.md)，尚未最终打包/部署。[本机部署工具](local-test-deployment.md)只做实现与合成/短程验证，未Install/真实Start/任务注册。18087/18088后台临时QA已关闭并保库，后续恢复页面另显式启动自有宿主；root地址/离线专项的18190静态宿主验证后精确关闭。PG55432为原工作区测试集群；最终服务独立数据、端口并脱离Codex/PTY持续运行。

2026-10-22 23时续作复核：用户已明确暂停安卓/ADB，执行其余P5–P7；数据工具/Web壳/Windows原生候选已实施，分项证据见各模块和计划。原PG进程已终止，经原目录pg_ctl启动/WAL恢复后55432 ready，没有重置原库；18080当前无监听（非本轮主动关闭），以下早期“运行/保留端口”描述仅为历史快照，不代表当前在线。开发源码、所有旧包/数据库仍保留。

当前工作区位于 `C:\Ruibin_Ningh\program\FlowTrace`。初始化前只有 `work/` 和 `outputs/`；现在包含协作文件、项目内skill、开发计划、共享契约和Flutter/Python独立工程。2026-10-24 M0从无提交的main建立首次本地恢复提交，具体标识以git log和本包交付回复为准；没有推送。

| 路径 | 当前职责 | 版本跟踪 |
|---|---|---|
| `README.md`、`AGENTS.md` | 项目入口与协作规则 | 纳入 |
| `AI/` | 模块说明、维护任务记录、计划约定与流迹开发计划 | 纳入 |
| `.agents/skills/repo-collaboration-logging/` | 原样保留的 skill、参考资料和模板 | 纳入 |
| `contracts/`、`tests/` | 共享规则、脱敏黄金样本、接口候选与实际导出、契约检查 | 纳入 |
| `apps/flowtrace/` | Flutter跨平台工程；P3主路径已分项验证，P4资产实施中 | 源码与锁文件纳入；缓存/构建忽略 |
| `server/` | 独立Python包、锁文件、迁移、身份/同步/后台及资产候选与测试 | 源码与锁文件纳入；虚拟环境/构建忽略 |
| `deployment/` | Linux原生部署说明、Web/Windows打包及Windows独立本机测试部署工具 | 脚本/说明纳入，真实资料与产物忽略 |
| `work/qianji-research/` | 已有 APK、反编译材料、界面截图、结构与调查结果 | 忽略 |
| `work/tools/` | 本地调研工具及下载包 | 忽略 |
| `outputs/` | 本地生成交付物 | 忽略 |

“纳入”表示不被忽略，供后续按用户授权提交；不代表已经提交。

当前 Windows PowerShell 环境可调用 Git 2.51.0 和 Python 3.12.13。上述版本是本次检查结果，不是应用依赖要求。具体业务结论应重新核对对应材料，现有调研回执不能代替本次验证。

开发实测 Flutter 3.38.3/Dart3.10.1、Android SDK/JDK21、VS2026 C++、Chrome/Edge 可用，细节见[平台检查](../plans/flowtrace/platform-validation.md)。用户2026-10-22确认手机重连，ADB只读核对唯一PLT140/Android16/API36/arm64设备、dev包未安装，已恢复隔离真机验收；部分 SDK 许可证未接受，构建是否受影响以实际命令为准。WSL 未安装，用户确认暂无 Linux 测试环境、先本地开发。

服务端使用 `server/.venv` 的 Python3.12.13 和独立哈希锁；已验P3独立377包仍运行18080；P4资产候选全服务411及RR竞态2、独立wheel36HTTP通过，尚未替换该开发服务。工作区 `work/flowtrace-dev/postgresql/` 有来自 EDB 的便携 PostgreSQL18.6，绑定 127.0.0.1:55432，独立 `flowtrace_dev_local`/`flowtrace_test_local`，非系统服务。凭据只在忽略的本地环境文件，模块文档不记录密码。Linux运行不能由Windows PostgreSQL结果替代。

用户已确认的技术方向和推荐默认方案保存在 [完整开发计划](../plans/flowtrace/plan.md)，实现状态以 [计划进度](../plans/flowtrace/progress.md) 为准。计划中的路径与命令不代表相应工程已经存在。

## 接口与数据边界

当前集中缺口：group/stage17均已挂普通main，完整映射/金融确认UI及schema5全量1009/6默认live skip/分析通过，生产图片两端反核4，c462/d1ba真实TCP native各1通过；两followup失败分别为测试peek和PG40001 group创建，原现场保持，正在修预算内重试与普通8bb7 Chrome。新Web c5e8封装39资源，尚非最终包。quarantine完整jobs68/1默认图片skip及另图片1通过；641c深路径无receipt partial保留，扩展路径红绿17/PG27/别名24后，同深度2890 Chrome入队5/完成3与真实CLI Worker通过。未领取取消PG25及独立页面已接，HTTP/Chrome继续；已领取/partial的retry/reconcile、purge、OCR/AI仍待。head0016，旧QA不迁。原生ZIP短profile204与HTTP归档证明分开；P4历史/完整高级业务/保护/更新、原ARIA未复现、Windows本人解锁及最终产物/常驻服务均继续。部署只Prepare，固定Python3.13离线依赖闭环已验，3.12ensurepip缺wheel失败保留。安卓专属/ADB暂停，Linux缺环境延后。

已建立 P0 契约；服务端身份、最小后台、同步和附件路由已落地并在隔离环境验证，P2客户端本地基线已验，P3本地与Web主路径已分项验证，P4资产/币种当前开发联调。真实API导出以`contracts/openapi.json`为准，P0候选单独保留。研究原件保留；`work/flowtrace-dev/` 新增隔离开发数据，`.gitignore` 排除本机配置/虚拟环境/构建及`server/var/`、`var/`私有运行数据，允许示例配置和依赖锁。

维护任务日志记录变更证据，存放在 `AI/logs/`。应用运行日志需要结合实际代码的持久性、并发与容量需求设计；skill 中的运行日志参考材料并不构成已经实现的运行设施。

## 验证方式

在根目录运行：

```powershell
git status --short --branch
git ls-files --others --exclude-standard
git check-ignore -v -- work/qianji-research/session-completion.json work/tools/jadx-release.json outputs/probe.txt .env
```

检查文件清单与本任务预期一致，资料目录和本机配置被忽略；另外核对 Markdown 链接可解析、实际文档无未替换占位符、任务记录具备有效日期和完整五节。模板内的占位符应保留。

## 当前缺口

2026-10-24 Alpha交接：以下仅登记状态，本包不扩展修复。group创建在并发UPDATE sync_clients时曾发生PG40001/503；d1ba金融undo成功但客户端刷新未完成，原失败和只读后验保留，有界重试生产修复尚未落地。M1应判断选定候选是否受此同步/启动问题阻断，若必须修复再按两轮上限单包处理，不能再发原undo。新增receipt_history源码/测试未跑、未接普通入口，冻结为后续功能；专用隔离取消HTTP最后35通过，但新确认页Chrome尚未执行。周期/分期/储蓄、完整回款UI/typed复合、OCR/AI、清理retry/reconcile/purge及全平台边缘旅程均延后，已知严重账务/安全问题不因Alpha放行。

现有普通Web c5e8 seal候选、Windows普通本机测试候选与Android debug产物可供M1筛选复用，未核成同一版本/能力组合，不能直接宣称三端Alpha交付。APK新构建/签名与普通入口需核验；本机部署工具仍Prepare，尚未真实持久安装/启动/自启。原生桌面此前锁屏未验，未获新解锁答复；不再重复申请或操作安全界面。安卓ADB仍暂停，Linux实际环境仍缺。

当前完整Flutter871通过/5专用live默认跳过、analyze clean；新普通Web6f72及Windows普通local-test候选已构建，实际旅程接续。数据服务89、A05相关108及真实权限/布局分项通过，独立HTTP归档核验不替代原生Chrome ZIP下载。当前缺口集中于本节上方与[计划恢复](../plans/flowtrace/progress.md)，不将旧分项扩大为P5–P7完成。

2026-10-22续作最新结果：B完整ACK/授权watch/精确预览/offline lease与单笔确认适配已落地，客户端最终完整764通过/5需QA配置live默认跳过、分析无问题；服务端lookup完整445及后补撤权2/增强socket1分别通过，实际OpenAPI42/114/48。四个审阅边界均先复现后修。授权回款历史/追踪列表、新UI/严格来源锁/typed仍未接收；c974浏览器与18080运行基线保持。Android真实系统picker/取消/超限及第二attempt同APK无重装force-stop/COLD只读恢复通过，原SQLite SHA不变；普通main已无QA参数恢复并实际冷启，完整旅程仍未完成。

- Flutter P1真机构建与基础持久化已通过，两端领域规则各86项测试已通过；P2真实身份及HTTP双客户端同步已验，Android冲突/附件真机、真实恢复及本机诊断已验，P3主路径已有Android旧记账与独立Chrome分项结果，P4-01资产本地/Web分项已接收。完整22类功能尚未全部实现，P4-02追踪/聚合仍实施中，逐包状态以进度为准。
- 钱迹原调研中的提交、报销升级、同步冲突、共享权限等流程仍需隔离样本核验；具体证据边界登记在计划的产品范围分册。
- 尚无自动文档门禁、历史保护检查器或派生索引生成器；当前约定由人工核对和任务内检查执行。
- 服务端已有固定字段诊断、正式管理审计、同步回执与有界脱敏导出；后台完整任务/配置/恢复管理仍待P5/P8。当前后台最小能力不代表全量后台完成。
- Linux部署恢复、完整Web/Windows业务验收待对应平台与阶段；当前Windows原生PG、工具发现或Web预研不能替代这些证明。
- 用户2026-10-22确认手机重连，已取得合成数据fixture的系统选图/取消/超限和同APK OS终止恢复专项通过回执；普通main已安装冷启，完整旅程仍待后续。仅操作原授权PLT140，忽略新增设备；隔离Chrome验收约束保持，不使用用户Edge或个人会话。
- Web即时退出缺表单问题已在c974专项修复：根Web语义句柄、确认modal完整结束和登录Card稳定key共同保持编辑/语义生命周期；原ae/4897失败仍保留，4897等待modal本身未修实际DOM。Native确证无key Card替换/GlobalKey Form迁移，c974真实Chrome即时ARIA/Tab输入与重开退出已通过。完整P6无障碍、离线壳/跨版本原子更新与长列表体验仍待阶段验收，专项通过不能替代它们。

P4隔离安装新增忽略目录server/.wheel-assets-venv，候选位于server/dist/assets；18080仍为已验377包，assets新0006仅在专用测试库。P4-01候选411+RR2、wheel36HTTP及Flutter资产live1通过；固定c974/504客户端及实际Web业务/字体反馈/即时退出已专项接收，旧产物和失败profile保留，浏览器1.8倍未证生效。该Web run已16正常墓碑、8账户精确期初、分录/附件引用/活跃会话0，18085/18185及ownedChrome均关闭，18080/18181/55432保留。

P4-02追踪/聚合部分已验：新receipts专库完整服务端425通过（含12个PG/ASGI），后续独立18086 socket1通过并关闭，合同21/21；客户端数据143/143、纯模型69/69，最终完整源码602通过/5默认live跳过、分析无问题。该602为前次快照，未生成新Web/Android产物；B授权/因果读取后续已通过上方722回归，回款UI、严格来源锁与typed复合仍未实施，cap不advertise。summary optional但nonnull的schema窄修已通过，33组runtime/序列化等效、21合同通过；未重复跑425，原等效runtime回归和新schema检查分列。最新receipts-schema wheel未安装，运行18080未更新。无Git提交基线，提交/推送/生产部署未执行。
