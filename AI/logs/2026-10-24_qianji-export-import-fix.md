# 2026-10-24 钱迹实际导出、退款与脱敏诊断修复

> **任务**
> - 标识：qianji-export-import-fix
> - 状态：已交付

## 背景

用户先提供钱迹实际XLSX和导入失败截图，随后明确要求：

> 那就修复，兼容钱迹实际导出的文件，105条和退款关联都处理好，补齐并开启脱敏日志，显示具体错误原因，测试通过后更新到生产环境。

开工为`main`、`db77b7e895ce13fb90cdd4a6c0a01d06d698cdf0`且工作区干净，已有本地恢复基线。沿用[Alpha单包/额度约束](../plans/flowtrace/alpha-milestones.md)，本包并发至多2位子代理，分别负责实际文件适配/精确关联、客户端错误与完整入口；主代理负责集成、真实浏览器、诊断及生产更新。没有增加其他功能包；安卓/ADB测试按既有用户要求取消，不使用用户Edge或个人Chrome。

原普通适配器仅接受公开V10模板；真实导出有ID/币种/关联等19列，且XLSX声明A1而物理有106行。原泛化提示不能定位错误，105条也超过普通50行上限。原生产私有诊断硬开关关闭；首次开启后发现Linux Python3.13标准日志分派与既有无全局锁handler不兼容，stderr正常但私有采集为空，随后窄修并实际验证。

当前授权包括本地恢复提交与`root@192.168.0.145`生产更新；Git推送未授权。Linux原生部署既有事实见[首次记录](2026-10-24_production-deployment.md)，本包范围与下一动作见[进度](../plans/flowtrace/progress.md)。

## 行为变化

- 按[钱迹原始导出v1](../../contracts/qianji-export-v1.md)识别实际列/秒级时间/币种和真实行数；原文本ID经稳定命名空间重写，与文件hash/顺序无关。旧V10与普通50行/5MiB上限保持，105条走既有stage整批原子流程。
- 退款保留原支出来源和精确分配，检查缺失/错误/循环/跨账本/跨币种/累计超额；不把退款当普通收入。收支同名分类分别映射，样本实际需10个分类资源；账户空就保空，不凭空创建资产账户或分录。
- 页面提供“钱迹原始导出 / 超过50条完整导入”，先持久保存已选文件再交接stage；显示固定中文原因、行/字段、错误码、请求ID及异步任务ID。新parse/rows显式选择诊断字段，旧客户端省略时响应键集合保持。
- 新增`import_parse_checked`固定元数据事件，包含HTTP200内的解析失败；合法路由模板从惰性router递归注册。Python3.13路由handler显式分派过滤/emit，保持每policy/store独立锁。诊断不保存文件名、原ID、单元格、备注、图片、口令或token，不作为正式金融提交证明。
- 正式服务已更新：后端`/opt/flowtrace/releases/20261024-qianji-1447709`，Web`/www/wwwroot/flowtrace/releases/20261024-qianji-fcdcda0`，各自current原子切换；OS与数据库诊断双开。head0016无DDL变化，未改路由器/Nginx/证书和其他服务。用户原105条只在隔离库验证，未替用户导入生产账本。
- 代码本地恢复提交为`fcdcda0`、`fa91d84`、`1447709`，没有推送；最终文档提交可从本任务交付回复和git log核对。服务器项目快照/wiki只承载文档和安全回执，不复制账单、凭据或长运维教程。

## 影响文件

- `server/src/flowtrace_server/imports/`：新增`qianji_export.py`，调整`qianji_template.py`、`staging_parsers.py`、`staging_references.py`、parse/rows DTO及router、stage解析事件。
- `server/src/flowtrace_server/diagnostics/`：固定导入码/字段/事件投影、合法路由登记和Python3.13分派；`server/tests/data_tools/test_qianji_export*.py`、`test_import_diagnostics_http.py`及`server/tests/test_import_diagnostics.py`覆盖回归。
- `apps/flowtrace/lib/core/network/`、`data/data_tools/`、`data/diagnostics/`、`features/data_tools/`及相应测试：安全错误关联、文件交接和现有stage流程消费。
- `contracts/qianji-export-v1.md`、`contracts/openapi.json`；模块`contracts/server/client/web/data-tools/diagnostics/reimbursements/production-deployment/workspace`、README/文档入口、Linux手册及现行计划同步。契约的72路径/176schema/79操作不变，导出SHA为`35c882b686e73a70228755d4aea8c590343d719bc5ffc04f12e2f01963964bc7`。
- 映射核对：账务领域/同步/job/configuration闭集/附件授权/正式审计规则未改，原子发布/撤销/权限仍走原实现，对应现状无需空改；配置仅开启既有诊断字段。旧已交付任务记录未重写，缺口集中登记workspace，没有新增自动文档门禁。
- 私有执行文件/真实XLSX/凭据仅在忽略的`work/qianji-import-fix-20261024/`及服务器root-only控制目录；产物/安全回执在`outputs/`，不加入版本库。

## 已执行验证

定向优先、阶段集成一次；后续两项窄修只重跑相关目标。以下是不同范围/快照的实测，不累加成新的“完整总数”。

| 执行与范围 | 结果与回执 |
|---|---|
| `git status --short --branch`、分步差异与Ruff/格式检查 | 开工干净，保留原资料；三次代码提交可恢复，无推送 |
| 服务端解析目标：新实际导出与旧CSV/Excel/V10测试 | 首次77通过/1.86秒，其中新增24例；含A1、105条、文本ID/重排、关联、公式等。随后收支分型修复相关84通过/6.14秒，Ruff通过 |
| `server/.venv/Scripts/python.exe work/qianji-import-fix-20261024/run_pytest.py`，传入目标`tests/data_tools/test_qianji_export_integration.py` | 真PG/HTTP合成105条、3退款先于原支出、精确余额/分录、相同请求/重排文件不重复、撤销恢复期初，最终1通过/12.39秒，`pg-105-final.xml/log` |
| 同launcher的阶段服务端集成 | parsers、excel、http、import_transactions、qianji_export/integration、staging_parse/preview/publish/http/requirements、import_diagnostics_http及三类诊断，共175通过/205.28秒，`server-integration.xml/log` |
| 最终诊断窄修：`tests/test_import_diagnostics.py tests/test_diagnostics.py tests/test_diagnostic_policy.py tests/data_tools/test_import_diagnostics_http.py` | 30通过/6.52秒，含真实PG、隐私/开关/多app/慢探针及过滤，`diagnostics-python-compat.xml/log`；原首次29项另留 |
| 根目录契约目标 | 21通过/113 subtests/0.31秒，`contracts.log`；旧响应键集合及可选request_id兼容已验 |
| Flutter数据工具/网络/诊断目标及9项范围analyze | 首次61通过/1旧泛化提示断言失败，更新具体原因/错误码/UUID期望后单项通过；范围分析No issues/5.6秒，`client-target.log`、`client-narrow-rerun.log`、`client-scoped-analyze.log` |
| Flutter已接收测试集合：`flutter test --no-pub`传入排除未接收历史单文件后的文件清单 | 1015通过/8专用live默认跳过/74秒，`client-integration.log`；整体analyze失败限制见下节 |
| 普通Flutter Web release构建及既有seal工具 | 87.3秒，39资源+manifest/worker共41文件，`web-build.log`；已验Web不因后端窄修重建 |
| Linux Python3.13独立venv离线hash锁定安装、`uv pip check`、真实CLI及Uvicorn QA探针 | wheel/35项依赖可用，实际错误落私有文件并从后台导出4073B，`qa-smoke-r3.json`；不是仅依赖Windows3.12测试推断 |

主要本地回执目录为`outputs/validation/qianji-import-fix-20261024/`，首次纯解析回执另在`outputs/validation/production/qianji-export-adapter.json`。本机server venv实际Python3.12；原生目标实际3.13.5，上述跨运行时证据分开保留。

**真实原文件**：全新隔离库`flowtrace_test_qianji_linux_cf4db2c041`、独立资料/用户/账本，真实TCP共34请求（33×200、退出204）。解析105、预览105新行且无账务效果；原子导入105，逐条金额、3退款来源/金额及正式收入/支出/退款净额报表对照原文件通过，10个收支分型分类、0凭空账户/资产分录。同冻结apply重放回同任务不重复；一次undo后payload指纹、报表、分录恢复基线。原文件SHA前后相同，不把原金额/ID/备注写入Git。回执`linux-filecheck.json`。

**真实页面**：独立Codex IAB经本包SSH转发访问同版隔离服务。使用合成19列/A1/105条文件，经系统filechooser选择；普通入口显示第52行上限原因、错误码/请求ID，一键保留文件进入完整stage；解析105/0错、整批预览/确认，显示服务端已导入且本机已同步。重开仍105条/0待传，净支出10800分（仅合成数据），含3退款冲减；截图`error-detail.png`、`browser-import-success.png`、`browser-reopen.png`及`browser-proof.json`。不把这组截图称为生产私人账本导入。

**失败与修正保留**：

- 105条HTTP及真实文件checker最初断言漏掉正式模型的`rate:null`，产品已成功原子导入；修正fixture，真实文件只读接续原stage、重放原冻结请求并一次撤销，未另造金融intent。一次Ruff自动移除pytest重导出fixture导致setup错误，以显式重导出修复后通过。原失败文件未改写。
- 实际原文件发现收入/支出有同名分类，单一名称映射不合法；新增导出profile分型键，相关84项及真实文件验证通过，旧V10不改。
- 首次全目录Flutter analyze还有已有历史测试undefined_method和风格info；只修本包测试的null-aware风格提示，未展开后续历史功能，集成明确排除一文件。
- ZIP封包助手最初误写worker名，保留partial；改用实际`flutter_service_worker.js`后生成校验完整ZIP。
- 第一次生产私有日志smoke未找到关联记录，stderr可见；定位到Python3.13的`Handler.handle`采用`with self.lock`与原`lock=None`冲突。显式无全局锁分派修复，30目标及Linux真实HTTP/导出通过后再最终切换。QA脚本一次Windows默认编码读取中文断言失败，改UTF-8/Unicode常量，属于测试脚本编码而非页面故障；两轮证据保留。

**生产更新与备份**：本包最初受控切换前备份目录`/root/workspace/backups/flowtrace-qianji-20261024T125008Z`，一致备份`9d7f476b-65e7-4aa9-b174-f5819476de1d`、5文件/186438B。最终1447709切换前再备份`ff301d6b-6b9c-4d9e-8d54-c2f8d0fa3b69`、5文件/186993B，manifest SHA`89d2e840a75bf50795a83cd0923bce94c0c6cd82dc7f02094b5064836f27aeeb`；原程序/Web软链、env及旧manifest另存`flowtrace-qianji-20261024T130322Z`。仅停止/启动FlowTrace API/worker，原子切换匹配发行，check head0016，无DDL。最终HTTPS ready200、API/worker active，旧版本/数据库/失败资料未删。

**生产安全smoke**：只使用合成错误CSV解析，不apply金融数据；普通登录/退出、后台真实CSRF表单登录/服务概况/脱敏导出/退出通过。`unsupported_qianji_columns`第1行的请求ID与HTTP头及私有JSONL一致，导出2179B；源文件名/敏感哨兵/密码/token均不在日志，目录0700/文件0600。回执`production-update-r3.json`、`production-smoke.json`。

**实际产物**：`outputs/releases/production/20261024-qianji-1447709/`含：

- `flowtrace_server-0.1.0-py3-none-any.whl`，431617B，SHA`f8e69b8ac3300b1ca9f973d2b985cfd54ec0824c1b7651bddc306405ad5b8e77`，后端来源1447709。
- `FlowTrace-qianji-fix-web.zip`，25835422B，SHA`66225934f6cb756928b274693d40fe94f31265a758e9103c700ce3b12d8908f6`，Web来源fcdcda0，release `5ba6ba58d80d6c79419d1439101752bbcd0d801ad6a63bdb9cc0fd7eb61f6770`。
- `requirements.lock`，63443B，SHA`0d1ce7a333c7d8803f2d1ec80f077fd0a38762f4706d0860b7f3e480a28515a6`，以及README、release-manifest和SHA256SUMS。Windows/APK继续使用原M1/初始生产目录，未宣称包含新UI。

QA临时API/worker-r3已精确停止，systemd读回inactive/not-found；只在CIM核对pid/ssh及本包端口/目标主机后停止本包SSH转发，QA库/数据/原件保留。生产API/worker读回active。执行`server/.venv/Scripts/python.exe work/qianji-import-fix-20261024/check_delivery.py`：18份受影响Markdown的本地链接/五行模块速查/任务五节/占位符、旧任务日志保持、真实私有值不进入跟踪源码及Web、3个产物hash及ZIP41文件均通过（`documentation-check.json`）；`git diff --check`及`git check-ignore -v`通过，未把本任务脚本称为持久化门禁。服务器文档快照、项目manifest与wiki交接由项目目录的`documentation-update.json`提供回执；只改本项目入口和wiki实体/维护日志，保留原Wiki脏状态与旧日志字节，无远端Git提交。

本包收尾额度接口：7天窗口已用14%，普通使用允许、额外积分0；这是账号共享窗口，不是本包token/费用计量，不据此自动扩展任务。

## 未执行验证

没有自动将真实105条导入生产，也没有替用户决定目标分类/账户；需用户在正式Web完成资源映射、核对整批预览并确认。生产smoke只有解析和会话/审计元数据，原文件完整财务验证在隔离库。

没有全仓库静态分析通过结论：未接收历史单文件的`_PauseCommit.intercept`编译错误和既有实现风格info仍在workspace集中登记。没有再跑全服务端套件或已验阶段重复完整回归；后端分类/诊断后续只做相关目标与真实运行验证，8个专用live未配置时跳过。

未重建Windows/APK、未做ADB/安卓验收，遵循用户取消指令；Windows完整原生UI、独立外网/IPv6、整机重启/断电、异机备份/Guard接入、20万行/性能极限及全量P0–P8验收未在本包执行。并发group40001原场景未修，不把本次105条同步成功扩大为全部并发场景已修。未执行生产数据库恢复/降级、Git推送或额外发布。
