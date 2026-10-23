# 数据导入导出与隔离恢复验证

当前记录服务端实测与普通客户端的独立Chrome迁移验收分项。本目录不保存真实账单、数据库口令或原始备份；正常浏览器的实际路径、失败与恢复边界见[浏览器记录](BROWSER.md)。

## 新stage真实联测恢复入口

`stage_harness.py`只使用普通生产main及真实Worker，拒绝缺少stage/group路由或能力；不注入测试router、不调用SDK、不升级已有库。`prepare --migrate-fresh`仅对专用新UUID且实际无表的本机库显式迁移到固定`0016_backup_quarantine`，默认prepare不迁移、不启动HTTP。端口固定API18094/Web18194，使用前拒绝已有监听。所有凭据、原件与SQLite只在忽略的`work/flowtrace-stage/live/<run>/`；工具stdout只给路径或固定安全码。

2026-10-23已实际准备下列互不混用的夹具：

| 用途 | run | 数据库与状态 |
|---|---|---|
| 普通Chrome | `8bb7c19397ba48cca93b167cb25fc296` | 新`flowtrace_test_p5_jobs_a9c14beaf8b14e66`至0016；0用户，尚未seed、启动或导入 |
| Flutter首轮真实TCP | `c4624915cf5c4d3ea0b729498cb6ccfe` | 新`flowtrace_test_p5_jobs_153c8df6ef114d54`至0016；首native已applied，后续已清源/撤销/本机释放，后续整条测试末断言失败保留，不可重新导入或重跑金融操作 |
| 修后两阶段TCP | `d1ba8376278c40149c88d3acf5357327` | 另新`flowtrace_test_p5_jobs_b77a9e2c6f354715`至0016，新namespace/source/actor；seed已完成，0stage/0batch/0ledger/0活跃会话，等独占SDK运行 |

每套`fixture-plan.json`包含无凭据的路径/名称/预期量；`seed`产生私有`client-config.json`，仅该文件供客户端与服务运行读取。原生源204行包含101分类、101支出及一个book/私人账户，前向引用交真实拓扑校验；原JSON后接合法空白至614400bytes，实际两片，未放宽金融字段长度。每笔125minor，总支出12625，期初9007199254740993，预期余额9007199254728368；77-byte PNG具有原生manifest/hash。独立V10 CSV61行使用真实中文资源原名与手动选图名称，图片URL只作为原名，不被下载。浏览器与TCP不得共享actor/client或消耗彼此首次来源。

TCP初始化首轮失败`seed1.log`保留：harness把正式成功`applied`误判为`accepted`。只读`seed-diagnosis1.json`确认两条本人正式回执均applied，cash/category完整原名、revision1和cash10000，0stage/0batch/0活跃会话。`resume-seed`再严格复核唯一owner/身份/已撤销seed会话、两正式回执、完整规范化payload/scope/revision/余额及未消费的业务状态，仅补缺失配置/receipt，没有HTTP或数据库写入。首次未预存原请求正文的事实在receipt明确为false，不伪造冻结请求；后续新seed先将真实body落盘再发HTTP。失败、诊断、原账户与全部回执保留。

仅在协调到独占端口/SDK窗口后运行，现有已seed夹具不得重新seed：

```powershell
# 仅在本轮TCP未运行时使用其既有配置；禁止同时再开另一个宿主。
server/.venv/Scripts/python.exe tests/e2e/import_restore/stage_harness.py serve --fixture work/flowtrace-stage/live/d1ba8376278c40149c88d3acf5357327/client-config.json --worker
```

新夹具的`prepare --env-file`只接受私有目录中严格匹配的新UUID环境，`seed --fixture`只接受该次尚未消费的`fixture-plan.json`。Chrome分阶段处理时使用`job --job-id`指定其实际本人stage任务；不猜任务、不把命令示例中的ID当运行事实。

`apps/flowtrace/test/live/stage_http_test.dart`是显式`FLOWTRACE_STAGE_QA_FILE`环境选择的专用TCP目标，默认跳过。2026-10-23由主代理独占SDK与18094、真实Host/Worker实跑**1/1、19秒**，日志`outputs/validation/P5/stage-http/c4624915cf5c4d3ea0b729498cb6ccfe/stage-client-http1.log`；实际client receipt在同run私有`client-receipt.json`。真实AppController、磁盘SQLite、生产StageCommands/附件上传/group pull已核：614400B两片原件，chunk0与apply各实际成功回包丢弃一次，两次离线SQLite重开及同apply冻结body，preview没有正式Batch/Items/现金账户；正式204Items、101支出/101分类分两个publication chunk，一次group安装，支出12625、余额9007199254728368、77-byte图当前scope/hash正确，原冻结outbox/草稿保持且客户端0push。独立`postgresql-after-client.json`确认最终applied和0活跃本人会话，`owned-host-closed.json`确认owned宿主/Worker退出，18094/18194无监听。

首轮新live静态12项错误（同名import的级联类型错误及flow block）保留，修夹具后analyze clean；未为此修改生产逻辑。此VM目标只注入沙箱目录桥和内存vault，不代表Windows runner租约或系统安全存储/普通UI已验。undo、源释放、CSV及50MiB/20万性能各自单独验收，不能由此预先宣布通过。

首c462的独立`stage_undo_release_http_test.dart`实际**14秒失败**，原`stage-followup-http1.log`不改：末尾为窥读调用`SyncStore.nextPush`，这个生产方法会原子写入sending并增加attemptCount，使完整pending行的期望3/实际4；并无客户端push。到该断言前，新会话显式reauth、服务端源释放/rows410、正式undo/freshgroup、图回私域和本机BLOB显式释放均已执行。新纯只读`followup-readonly-postconditions1.json`是独立后验，明确`whole_scenario_passed=false`：PG stage/Batch undone v3、原204Items/apply2chunk完整metadata SHA不变，另undo2chunk；真实清除614400B/2源片/204预览行/2需求，释放audit SHA与received历史保持；分录0、原账户deleted/余额回9007199254740993，图ready私域/无refs或hold、本人会话0。SQLite以mode=ro/query_only重核完整pending与失败Actual相等，唯一Expected差为attemptCount，已清本机BLOB但draft/create/input保留；受保护文件前后SHA不变、端口无监听。此后验不能把14秒原run改绿，也未再次金融操作。

修正仅限两live测试中的窥读：改从实际StoredOperation.frozenRequestJson读取，首native真正建立冻结仍只调用一次nextPush，完整pending行含attemptCount的相等断言保留。首native的19秒快照也曾在最后为读取body调用nextPush，虽未改变冻结正文/业务意图或发push，但计数不能据此声称全程无变化；原1/1结果与该边界同时保留。另新d1ba夹具已实际prepare/seed并持久真正seed body、收到两applied回执；普通服务已关。后续必须在此全新来源串行重跑native→undo_release，使用原配置及新增followup receipt，不覆盖c462或消费Chrome8bb7；尚未据准备结果声称修后两阶段通过。

2026-10-23，`server/tests/data_tools/`此前完整为**169/169、0skip、107.63秒**（稳定0012快照），含四个全新UUID库的真实dump/verify/恢复与跨库迁移；当时备份源stage表为空，不代表非空BYTEA/Publication已验。该次回执`outputs/validation/P5/12cce6b76eea4d2f844d83deb0bf66e6/data-tools-full-stage-receipt.json`，JUnit `data-tools-full-stage2.xml`；首轮0012施工中错误及四空库DDL回滚证明保留。

随后0014源释放必要回归120/120（73.79秒）和独立非空8表恢复1/1（3.39秒）；最新0015资源需求/映射hash/源释放必要回归为**168/168、0skip、79.71秒**，独立非空9表恢复另**1/1、0skip、4.17秒**。最新两次分别见`outputs/validation/P5/requirements-regression2.xml/log`与`requirements-backup1.xml/log`，不合成完整169。新source/restore中retained 967-byte源/4rows/1 requirement与released audit实际删除1派生并存，9表所有值精确相等；77-byte图、9875余额、epoch轮换/会话撤销及源会话继续有效均核。回执与实际包/原件保留在`outputs/validation/P5/requirements-roundtrip-6cb4a1fc9f2f4f8c/`，0014旧包/旧库未迁或覆盖。

更早完整89项（73.05秒）使用独立本机PostgreSQL18.6及四新库，回执`outputs/validation/P5/e637e97b0df94ddbb5fcc7989a5eb2f1/data-tools-server-receipt.json`、JUnit `data-tools-full9.xml`、原件`work/p5/full9/`仍保留。此前84/67及更早结果同样不追溯计入新增行为。

新增stage只读probe/jobs、本人显式discard、源book分页、图片生产黄金与相关upload/parse/hold/HTTP/DTO必要回归另同次**129/129、0skip、55.14秒**（`stage-metadata-regression1.xml/log`），使用新2efbbd专库/0015；与168及恢复1范围不同，不相加。零DML/全部52表fingerprint验证只针对两个metadata读入口；discard实际删除与配额、预算取消全回滚、旧origin/TTL和其他图片hold保护均实测。此快照test-only边界保持；随后普通main已挂[17操作契约](../../../contracts/import-stages-v1.md)并声明import-stages-v1，实际OpenAPI72路径/176schema/79操作，SHA 7e9287a91ffae00d05a81262c5ecd995c4d580d5fea3d9aa2d92d05f9799dd0b。主代理main相关87首86通过/1空body422测试假设错误、改单项后1/1（1.98秒），合同另21/21（0.465秒），不合成同次87或普通UI通过。容量实算与脱敏receipt分别在`outputs/validation/P5/stage-mapping-capacity.json`、`stage-metadata-receipt.json`。

本机复跑使用受控入口，每轮首先创建新 source/restore/迁移目标测试库，旧库与失败证据保留；短的 UUID 临时路径避免 Windows MAX_PATH，父目录需先存在：

```powershell
server/.venv/Scripts/python.exe work/flowtrace-dev/prepare_data_tools_backup_tests.py
New-Item -ItemType Directory -Path work/p5 -Force | Out-Null
$testPath = 'work/p5/' + [guid]::NewGuid().ToString('N').Substring(0, 8)
server/.venv/Scripts/python.exe work/flowtrace-dev/run_data_tools_backup_tests.py server/tests/data_tools -q --tb=short --basetemp=$testPath
```

这些 `work` 脚本是本机含受限环境配置的测试编排，不是发行包中的安装入口。可移植测试需提供下列环境变量，再运行 `python -m pytest server/tests/data_tools`：

- `FLOWTRACE_ENVIRONMENT=test`，`FLOWTRACE_TEST_DATABASE_URL` 指向常规独立测试库。
- `FLOWTRACE_BACKUP_TEST_DATABASE_URL` 指向全新空 source 库，测试只迁移它。
- `FLOWTRACE_RESTORE_TEST_DATABASE_URL` 指向另一全新空 restore 库，测试不预建 schema。
- `FLOWTRACE_MIGRATION_TEST_DATABASE_URL` 指向全新空 `flowtrace_test_p5_migration_*` 目标库，JSON/XLSX测试仅迁移该独立目标。
- 非空stage恢复专项另需`FLOWTRACE_STAGE_BACKUP_EVIDENCE_DIRECTORY`指向尚不存在的新目录，并使用另两个全新source/restore库单跑`python -m pytest server/tests/data_tools/test_backup_stage_source_release.py`；不复用前一恢复目标。不设置此明确路径会skip该专项，不能据此声称全项0skip。
- 当前实际恢复夹具限定本机 `127.0.0.1:55432`、`flowtrace_test_*` 库名，拒绝 `flowtrace_test_p5_local` 作为备份源/恢复目标；运行前需独立创建，不能重复覆盖已有恢复实例。
- 依赖 `openpyxl 3.1.5`、`defusedxml 0.7.1`、`et-xmlfile 2.0.0`；已加入正式服务端 hash lock 并安装至正式开发 venv，最新结果不依赖 ignored target 或 PYTHONPATH。真实 `pg_dump.exe`/`pg_restore.exe` 来自本地受控 PostgreSQL 目录。

测试证明下列当前行为：

- 原生 JSON/CSV/XLSX 使用闭合六实体结构，精确金额和原字段 presence 保留；公开钱迹 V10 CSV/XLSX 模板进行显式账本/账户/分类/标签/时区映射，未知私有格式不猜兼容。官方格式依据为[公开模板说明](https://docs.qianjiapp.com/other/import_templete.html)，官方[导出说明](https://docs.qianjiapp.com/export_guide.html)本身也提示导出再导入存在不兼容。
- 根据公开模板与[官方报销流程](https://docs.qianjiapp.com/ji-zhang-jie-mian/baoxiao.html)对照，模板类型“报销”映射为待报销垫付支出（expense + reimbursement_tracking），不凭空创建回款。旧实现错误地要求回款来源的纯目标先红，修后纯目标与真实PG均通过：含优惠券10.25−1.25=9.00元使余额10000−900=9100。模板未定义的“报销入账”仍明确拒绝；分类的二级列覆盖一级列，未知账单标记按官方格式忽略。
- 预览在当前授权的一致事务中，用无条件回滚的 savepoint 执行实际领域校验；不创建正式 batch、receipt 或设备 lease，不持久化实体、分录或附件引用。未知账户错误定位原第 2 行，前后持久状态保持。
- 同一稳定 source ID 原文重试去重；不同 source ID 的同额两笔均保留，指纹只警告。十一种账单在同一批事务及同一同步 commit 中入账，源单 revision、回款聚合和账户投影一致；失败全部回滚。
- 撤销在完整预检后逆序执行，仅作用于该 batch；后续合法编辑导致整批拒绝，未清库、覆盖或改写历史请求。回款及全部五账户的撤销后余额恢复到期初。
- JSON 导出只包含当前授权范围，完整私人 payer 引用无权时安全拒绝；XLSX 保留字符串整数、公式样式备注不执行，图片嵌入和授权相对链接清单有 SHA 校验。客户端 URL 不被后台主动抓取。
- 当前应用实际挂载的 `/api/v1/data-tools` parse/preview/apply/history/undo-preview/undo 及 JSON/XLSX 授权下载已纳入16个真实ASGI/PG目标。文件parse限制5MiB，options64KiB、禁止重复key/NaN/任意多余multipart路径，实际解析响应超过1MiB明确413；中文映射key可用。公开模板返回去重的资源名称/原行号，重新选择资源后可重解析；备注、金额不进入mapping_requirements。
- 本人操作历史按不可变batch元数据授权，即使原账本删除或当前撤权仍可查看状态和计数；不返回实体或scope ID，不因此取得当前资源写权。active批次撤销仍复核当前完整write权限，外人batch不返回。稳定keyset分页不漏项、不重复，undone批次重放仅返回状态元数据。
- 原生JSON信封与XLSX图片清单提供闭合的 `attachment_sources`（原source ID、SHA256、字节数、媒体类型），供客户端本人选图校验。外部URL、重复/缺少图片条目、bool大小或任意本地路径字段明确拒绝；不抓链接，也不自动提取嵌入图。没有manifest的原生文档保留显式手工映射要求。
- 导出 envelope 可直接解析为导入文档。JSON与XLSX均保留独立的 `posting_hints` 历史正负变动；仅允许余额调整，非零、绝对值与原金额一致。真实账单后编辑使余额变为10075的样本，重新按日期排序导入后仍为10075，原历史target10000与signed posting+100保持；普通同步不接收该导入参数。
- 含原图的新账本跨库迁移已分别走JSON、XLSX：原图通过既有上传服务先放本人私有scope，显式 `resource_mapping` 与 `attachment_transfers` 将它在同一导入事务中采纳到新book。预览与失败回滚保留原私有孤儿/票据；成功使旧票据410，撤销无后续引用时退回私有scope，后续合法引用或权限版本改变整批拒绝撤销。两格式均复核125支出、25退款的来源关系、净余额9900、month_start_day15/display_mode year/travel设置及原图校验和，原始网络URL未被抓取。
- 备份在数据库排他维护窗口内制作 custom dump、非密钥 settings、数据库声明原件/缩略图及版本/hash 清单；还为所有public表计算count与分帧JSONB SHA。恢复在轮换epoch/撤会话前先核对源instance/epoch和全表内容，避免仅报告没有源值可比的counts。独立空库恢复、旧会话撤销、源库会话仍有效、密码和 owner 权限、原始图片、余额10000−125=9875、NULL余额/缺期初/错币种拒绝及损坏副本拒绝均实际验证。早期没有全表摘要的包可校验文件，但隔离恢复明确拒绝缺少摘要，不伪报全库内容核对。

以下不能由当前测试代替：实际钱迹私人导出文件兼容、跨文件不稳定ID的自动确定去重、未含源单关系的历史报销入账猜测恢复、未实施分期领域关系、普通大批文件完整旅程、Windows原生迁移旅程、Linux服务级恢复。后台高权限备份下载与重认证由独立A05任务保留证据，本目录不作其验收结论。旧快捷导入最多50行、导出最多1000实体不因新stage链而放大；容量与完整旅程待闭合，不是缩减后的验收目标。

早期内部服务端大批发布5项纳入89完整回归，另外与原事务8项合跑曾13/13、80.15秒（`publication-internal2.xml/log`）。202行由同一PG事务产生3个≤200事件commit，校验跨chunk退款来源、余额979901/来源剩余99、别连接不可见部分数据、固定ID重放、末条领域/末sync chunk/撤销末chunk失败全回滚，以及完整pull和成功撤销恢复1000000。该历史快照当时尚无stage/job链路、客户端仍每页可见，其证明边界不变；随后持久stage/Worker/group生产链已接并有独立目标，不能将旧内部结果追溯成当前完整旅程通过。当前设计和依赖见[大批实施分册](../../../AI/plans/flowtrace/large-import-implementation.md)。

客户端当前实现位于 `apps/flowtrace/lib/data/data_tools/` 与 `lib/features/data_tools/data_tools_page.dart`，正式根入口和附件采纳适配由主代理接线。2026-10-23 owned **14项目标通过**（`outputs/validation/P5/data-client-test4.log`），scoped analyze无问题（`data-client-analyze5.log`，4.4秒）。验证范围包括精确字符串/历史posting、闭合原图清单、完整请求持久化与超时后原批次原字节重试、旧epoch/迟到结果拒绝、预览与二次确认、320宽错误定位、身份变更清除私有选择、原图hash不符时不上传，以及POST授权导出与浏览器“下载已发起”提示。

服务端确认成功后页面必须调用应用提供的同步回调；同步失败时明确显示“服务端已确认导入，本机同步尚未完成”，不伪写本地entities。撤销保留原applied回执供本机附件队列按当前权限反采纳。上述widget/DTO目标不代表实际系统文件选取、真实HTTP客户端、完整浏览器或Windows原生旅程已验收；仍需在根入口完成后使用独立Chrome和隔离服务验证。首轮选图相关widget失败源于Windows `XFile.fromData` 的 `name` 参数被忽略，合成夹具补充 `path` 后通过，原失败日志保留。

后补真实跨设备撤销与同库双tab迟到修复：本人历史可用`batch_id` UUID精确过滤，保持默认分页及已撤权/删book的本人元数据例外，foreign返回空。对应HTTP目标先红后修，现17项全过9.29秒（`data-history-filter-red.log`、`data-history-filter-green.xml/log`）。客户端`remoteBatchStatus`/`refreshRemoteUndo`只读正式元数据，校单项ID和当前epoch/client，SQL value CAS将applied推进undone且保原请求/回执；已确认undone不被迟到applied覆盖。页面fresh read本地阶段决定反向刷新，仍保一致wire DTO。同库race先红（`data-undo-race-red.log`），修后`test/data_tools`24项通过，含主代理的5项local_refresh目标（`data-undo-cas-green1.log`）；owned scoped analyze无问题3秒（`data-undo-cas-analyze2.log`）。这批新增结果不追溯计入前述完整89。
