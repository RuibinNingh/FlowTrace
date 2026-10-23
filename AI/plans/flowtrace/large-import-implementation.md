# 大批迁移、持久暂存与原子发布实施设计

> - 职责：闭合P5完整迁移的容量、重试和两端原子可见性；本分册不缩减原验收目标。
> - 入口：`server/src/flowtrace_server/imports/`中的`publication/publishing/service`及`staging*`；当前恢复先读[progress.md](progress.md)，再读本文件的下一步。
> - 不变量：当前HTTP50行和sync-v1每commit200事件保持；大批服务端全批提交、客户端全批单事务可见；私人投影不通过group元数据泄露。
> - 必跑测试：`server/tests/data_tools/test_publication.py`、`test_staging*.py`及完整`server/tests/data_tools/`、后续stage/job/group真实PG与客户端跨页故障目标；页面需独立Chrome/Windows实测。
> - 相关：[P5–P7实施](p5-p7-implementation.md)、[数据工具模块](../../modules/data-tools.md)、[stage契约](../../../contracts/import-stages-v1.md)、[共享同步](../../../contracts/sync-v1.md)、[验证入口](../../../tests/e2e/import_restore/README.md)。

## 用户原话与完成状态

用户要求：“那就按计划开始开发，委派子代理执行，从P0开始按依赖推进，并及时更新计划进度和任务日志。”当前范围以用户确认“是，安卓先不动，执行其余 P5–P7”为准。完整迁移验收仍沿用总计划；实际钱迹公开V10格式、关系与原件不能被自有小样本格式替代。

2026-10-23（Asia/Shanghai），本分册是已获继续开发授权下的具体实施设计。主代理确认采用“服务端全批原子 + 客户端全批原子可见”目标；**内部发布、持久stage、四阶段真实Worker及HTTP router已有分项验证；0014源释放核心及真实非空恢复分项通过，0015固定版本资源需求和mapping丢回执证明已有后端目标；普通main已挂17个stage操作及import-stages-v1、group协议已有真实TCP分项，完整大批映射旅程仍待闭合**。当前稳定head0016增加quarantine kind，专用handler由主代理另行集成与验证，不从迁移推断效果。主代理串行维护迁移、共享同步协议和worker，数据代理持有imports/exports后端与本分册；新大批客户端由Web代理协同接线。

## 现状与证据

| 事实 | 当前结果 |
|---|---|
| 公共导入 | 现`ImportDocument`最多50行、普通HTTP闭合DTO保持；独立stage17操作现挂普通main并声明import-stages-v1，完整UI/容量不由此视为已验 |
| 单同步commit | `common.write_changes`、`reader._ordered_commits`和Dart `_pull`均拒绝大于200事件；`sync_changes.event_index`有0–199数据库约束 |
| 拉取 | 完整commit不跨页拆分；旧v1增量命中当前授权多chunk publication返回resync_required并走完整snapshot原子安装；普通main已协商group-sync-v1，group完整后一次SQLite安装 |
| 内部发布 | `PublicationStageSnapshot`仅供可信持久stage读者构造；通过完整领域校验的内部Document/Request；无HTTP入口、无`model_construct`或正文替换绕过 |
| 内部事务 | `apply_import_in_transaction`、`undo_import_in_transaction`不提交/回滚外层；普通公共函数仍由原`run_transaction`包裹 |
| 多commit | `publishing.publish_changes`按稳定键切片，每片≤200，UUID5确定commit ID，全部仍在同一PG事务；独立结果有`publication_id`/`commit_ids`，`commit_id=null`，不假称单commit |
| 依赖排序 | 已换为保持原行优先级的拓扑优先队列，并只计算一次target映射；退款依赖先满足，历史余额调整presence和signed posting保持 |
| 当前worker | `jobs.complete`围栏effect不允许commit/rollback，最后再次检查租约；普通60秒、import_preview300秒/import_apply900秒固定预算；主代理四阶段handler已接，jobs主库62通过/图片专库1通过分开留证，均0skip |

持久stage模型/DTO位于`imports/staging_models.py`与`staging_schemas.py`：早期五表DDL编译和闭合输入7项目标通过（`staging-schemas2.xml/log`、`staging-schema-ddl2.sql`）保留。此后主代理串行注册0010五表，独立空库0010升降升、复合stage/batch FK及metadata无额外diff通过；主代理已推进0011服务配置与0012 group-pull三表并验证升降升/metadata无diff。纯schema证据不代替实际上传/worker/group证明。

`imports/staging.py`第一包现有真实PG **18/18，2.59秒**（`staging-upload-green4.xml/log`）：新UUID库`flowtrace_test_p5_jobs_2f055ce17df247ea`，未drop/reset。512KiB连续分片与新Session读取续传、同片同hash/bytes幂等、冲突/错序/错长度/逐片与整体SHA拒绝、seal同事务固定parse job intent均通过；job只含stage/version/hash。映射更新清除真实旧preview row/permission vector并取消未完成旧job，原source bytes/hash保留。显式重新授权绑定真实新会话/client、version递增；原access/full/idle过期、退出或用户禁用不能回退到worker权限。双并发配额只成功一个，过期源未实际删除时不假释放配额，cancel实际删除暂存字节后可重新预留；applying/applied/undoing/undone阶段拒绝换映射。

该包trusted `StagePolicy`初值7天、8个保留stage和200MiB预留字节，不接受客户端预算；尚未接配置页面/清理worker。原NotImplemented红目标、首次旧job错误码差异、旧preview夹具缺icon的失败均保留，18通过不追溯计入旧89完整结果。

随后创建超时恢复已闭合：`StageCreate.stage_id`接受可选UUID，原内部省略方式兼容，新客户端必须在POST前持久生成ID。同真实owner/origin/epoch、version1与完整规范化body相同时返回原stage/batch/expiry，且不会重复占配额；任何异body、foreign owner、新origin或已推进版本均409，客户端可按固定ID GET恢复当前版本，不把新映射冒充旧请求。真实同ID并发只留一份stage/reservation及同batch；不同owner抢同ID是一成一安全conflict。该包**27项PG + 7项DTO = 34/34，5.99秒**（`staging-upload-fixed-id2.xml/log`）。首次组合运行因保留的旧lease已过期抢先被通用claim选中，后仅调整本轮自有fixture job到队列最早之前，再跑通过；未取消或重置历史job。该回执形成时大文件parser/分页preview尚未实施，后续事实见下段；公开stage路由、金融发布handler、附件hold和group原子可见仍待闭合。

本次新增`staging_parsers.py`复用公共逐行V10转换、严格JSON/安全workbook及附件manifest校验，不将文件按50行重解析拼接。纯adapter现**17/17，0.41秒**（`staging-parsers-green3.xml/log`），覆盖75行原生三格式、61行V10两格式、精确大额、原SHA+实际物理行UUID、多行备注和空行、带符号历史posting及presence、manifest外链拒绝、错误后续行保留、重复source、公式/错误XML和伪造worksheet dimensions。最初模块缺失红结果、夹具分类缺必需parent/sort字段的首轮4失败均保留；没有放大公共50行/5MiB。

`parse_stage_in_transaction(session,actual_job_id,*,check_budget)`只写stage表：逐片重算原件SHA、逐行/每500行插入前预算检查，起终从真实origin会话复核。7项PG+10项初版adapter+7DTO的**24/24，2.14秒**（`staging-parse-pg2.xml/log`）包含601行另一连接仍看不到未提交暂存结果、预算中断后原lease重试、格式在已插入500行后失败清空本版本行而保原件、原件SHA变更抛错、最终complete失租连暂存结果一起回滚。文件格式失败可完成处理并返回安全code、stage.failed；权限/预算/围栏错误必须抛出。JSON受50MiB源上限约束但当前仍整体解码，不声称流式或20万行性能。

`staging_rows.py`只按当前owner/origin/epoch/版本读取，keyset最多100行、显式continuation，合法未领域预览行响应`parsed`且存储preview_status仍NULL。`staging_preview.py`的实际领域callback复用`preview_import_in_transaction` rollback-only savepoint；内部typed publication允许多commit容量，普通wrapper及200-event预览界限保持。首轮**6项真实PG/9.69秒**（`staging-preview-pg1.xml/log`）核对75行ready、202行退款依赖拓扑、CSV真实57行错误、临时领域写入后预算异常及最终失租全回滚、来源行篡改拒绝、当前撤权和真实新账户写入导致旧scope revision拒绝。其余公开导入/解析回归**54/54，2.37秒**（`preview-refactor-regression1.xml/log`）。这些分项不能累加为完整套件总数。

同次全部stage回归为**65/65，16.94秒**（`staging-full1.xml/log`），由27上传/7DTO/17adapter/8parse及分页/6preview构成；包含以上分项而非额外累加。新增实际>5MiB原生JSON、超过10个512KiB分片，275笔每笔100 allocation与2000汉字备注完成stage解析；旧公共parse仍拒绝file_too_large。实际分页受1MiB约束缩短并明确next_cursor，完整遍历275行不漏不重。该目标只证实解析和响应容量，不对这些未映射账单做领域预览/发布，不代表20万行性能。

LI04新增`staging_publish.py/staging_holds.py/staging_cleanup.py/staging_reauthorize.py`，现**14项真实PG/41.54秒**（`staging-publish-holds-pg1.xml/log`）：金融effect、ImportBatch/Items、所有同步commit、正反ImportPublication/Chunk、stage终态与job成功由同一jobs.complete外层提交。测试含202行第二真实chunk预算中断、metadata已经落入当前事务后最终失租的apply/undo全回滚；图片已临时迁到新book后失租恢复原user scope、自己hold与原字节；0新建全duplicate正反0chunk/0events是正式记录。作业结果仅固定code/created_count，未把大created/transfer数组塞进普通1MiB响应。原service/publication/publishing及附件移转的预算窄扩回归17/17（12.34秒）保留。

该14项回执形成时，已发布显式新会话reauth在受信budget服务中核当前本人/epoch、全部batch现write及原件/持久行一致；当前已改用下述PublishedStageContext去除源依赖。版本+1、取消精确旧未完成undo并绑定新origin，原ImportBatch/Items/正式apply正文/hash/metadata、原preview hash保持。新v2 undo已通过，旧lease由jobs.complete更早挡住、旧版本/失权拒绝。已undone的reauth仅找回metadata，不复活scope或允许再apply/undo。撤销沿用原逐item revision/payload hash、新引用及附件当前冲突保护：同book无关新增仍能撤销，不永久绑定apply时scope revision。applied/undoing/undone不受源暂存TTL阻断，真实会话期限/当前权限仍严格；成功金融stage不被expiry清理成可重做。

完整数据工具复验先得138通过/2跨库roundtrip未配置跳过、56.25秒（`data-tools-no-backup-stage1.xml/log`），明确排除两个backup文件，非完整全套。随后四个全新UUID normal/source/restore/migration库首轮恰遇0012生成中间态未限定Text，75纯目标通过/94 PG fixture错误（`data-tools-full-stage1.xml/log`）；主代理修为sa.Text并完成独立升降升后，数据代理只读核四库均public table_count=0、无alembic版本，证明此前DDL事务回滚（`data-tools-full-stage1-rollback-state.json`）。未drop/reset，同四个空库按稳定0012重跑完整**169/169、0skip、107.63秒**（`data-tools-full-stage2.xml/log`），包括全部79 stage目标、真实pg_dump/verify/全新隔离恢复、JSON/XLSX跨库金融设置/原件；仅一条既有Starlette/httpx弃用warning。脱敏回执：`outputs/validation/P5/12cce6b76eea4d2f844d83deb0bf66e6/data-tools-full-stage-receipt.json`。四库均46张public表；normal有57 stages/18 publications/16 chunks，备份source/restore与migration本次stage/publication为空，故未由该恢复目标声称非空stage BYTEA/Publication专属恢复已验。

四阶段金融Worker真实集成新增`server/tests/jobs/test_import_apply_worker.py`：独立主库`flowtrace_test_p5_jobs_3c792f85ad7443ba`运行完整jobs（明确排除专库图片case）为**62通过/1 deselected/0skip，12.54秒**（`jobs-import-apply-full1.xml/log`）；另新图片库`flowtrace_test_p5_jobs_c2ab648edfee4901`只跑图片case为**1通过/3 deselected/0skip，1.37秒**（`import-apply-worker-image2.xml/log`）。两次不相加冒充同次完整63。真实parse→preview→apply→undo、同请求job重放、applied过源TTL仍undo、撤权拒绝、最终失租金融/metadata回滚及新generation稳定重验、图片hold/原scope正反与原件SHA均有证据。fixture只取消本人未完成任务，Worker.close且未drop/reset；两个实际PNG原件与脱敏分次回执保留在`outputs/validation/P5/import-apply-worker-integration/receipt.json`同目录。

`staging_router.py`新增隔离测试专用的11个operation，现**17项真实PG/ASGI目标，0skip、13.23秒**（`staging-http-green3.xml/log`）：完整61行真实Worker HTTP旅程、固定ID重放、分页无漏重、闭合metadata、512KiB/错片/散列/连续性/已seal同片重放、无Content-Length超片、CSRF、owner/origin及新会话显式reauth、旧hash/撤权拒绝、published reauth预算中断原origin/version回滚与原apply hash不变。新库`flowtrace_test_p5_jobs_cffd26dfc552487d`保持0012；初始缺router红回执、13通过/2测试假设失败及后续15通过均保留。主app路径404、capabilities无stage，测试专用OpenAPI的所有业务响应闭合且旧50/1000不变；本项不表示外部能力或浏览器大stage旅程已开放。

随后同库stage全套与旧public HTTP组合为**113/113、0skip、63.97秒**（`staging-http-regression2.xml/log`）；首轮112通过/1测试假设失败保留：撤权后按scope UUID顺序，先遇本人control scope向量变化可409 `import_stage_preview_changed`，先遇已撤权book可403 `scope_forbidden`，两者均拒绝且无ImportBatch，最终目标核精确合法(code,status)而非放宽业务。主代理审阅发现async路由认证SQL仍在eventloop，本包将11处认证改为`await run_in_threadpool`，域调用原已offloop；后补HTTP专项**18/18、0skip、14.26秒**（`staging-http-offloop1.xml/log`）实际用create/GET/raw PUT证明认证线程无async eventloop。未重复执行169或将分项相加为新完整总数。

已发布操作现使用独立`published_context.py`的`PublishedStageContext`，替代此前重新构造原`ImportDocument`的依赖；apply仍严格校原件/预览行，undo及已发布reauth只核本人正式stage、ImportBatch/Items、原apply Publication及最多2000个连续chunk元数据。核对原epoch/version/hash、批次原回执commit数组、Items数量与created数量、chunk确定ID/count、flat权限/checkpoint形状；不读取原件/预览行、不读取历史BackgroundJob或SyncChange payload。历史event SHA由group reader验证，context不声称重算全批SHA；真正undo writer仍逐item当前revision/payload hash、引用/附件和现write权限完整校验。

新合成fixture仅移除该批源chunks/rows模拟缺失，证明正式undo、新origin显式reauth→undo与原apply hash不变，未重做apply；真实合法后续修改仍全批拒绝。该包新context目标先11/11（4.96秒），后补非法scope对象拒绝为12项；context/原publication/hold/HTTP组合先47/47（68.93秒）、最终**48/48、0skip、109.09秒**（`published-context-regression2.xml/log`）。真实Worker另复验普通**3通过/1 deselected/0skip、4.43秒**、图片独立库**1通过/3 deselected/0skip、1.59秒**（`published-context-worker-main1.xml/log`、`published-context-worker-image1.xml/log`），不合成完整4项。图片原件已按真实storage key及SHA复制保留，五个分次回执集中在`outputs/validation/P5/published-context/receipt.json`；无model/迁移/已发布source实际清理变动。

实际验证分开保留：内部5项 + 原事务8项 **13/13，80.15秒**（旧隔离库，`publication-internal2.xml/log`）；随后四个全新UUID库的完整 **89/89，73.05秒**（`data-tools-full9.xml/log`），包含此前84项，不能把13额外累加。四库包含新normal库及互异backup source/restore/migration，未drop/reset旧库或修改开发库。脱敏回执：`outputs/validation/P5/e637e97b0df94ddbb5fcc7989a5eb2f1/data-tools-server-receipt.json`。

新增目标实际使用202行、三个同步commit：201笔100 minor支出及1 minor退款，1,000,000→979,901，来源剩余99；退款位于文件首行，依赖排序和跨chunk来源关系都核对。另一连接在每片发布前仍只见旧状态；同批重放保持commit IDs及事件数；末条领域失败、末同步chunk失败及撤销末chunk失败均整批回滚；成功撤销恢复1,000,000；完整pull每commit≤200、无拆漏。没有由此声称普通HTTP或客户端已支持大批原子迁移。

## 范围与默认决策

1. 新建独立stage协议，旧parse/preview/apply继续兼容；禁止把公共50行直接改成大数字，也不将多HTTP部分成功称作整批原子。
2. 公共钱迹CSV/XLSX与原生导出仍是实际输入格式。源文件保持原字节/hash，映射不修改源；金额保持精确字符串，原始payload字段presence保留。
3. 上传分片、解析中间结果和预览可以分事务持久化到stage；业务实体、分录、来源索引、附件移转、发布清单和最终job成功必须同一最终事务提交。
4. 先使用数据库受控BYTEA暂存分片，禁客户端路径/URL读取。建议单片512KiB，维持现通用1MiB请求界限并留协议开销；若选择1MiB文件片，需精确路由额外开销限额，不能放大全局限制。
5. 建议原始文件总量50MiB、stage有效期7天及每用户暂存配额均为可配置技术初值，正式容量需真实文件/性能证据决定，不改写用户完整目标。内部模型200,000行仅是防护上限；金融领域/发布实际为202行，解析有601行及275行>5MiB目标，不能声称20万行已可用。
6. 当前pull最多50,000事件、snapshot最多200,000 items且有时间/页数界限。大文件不能绕过这些界限；超限时要设计受控group流/完整快照发布路径，而不是静默漏记录或触发循环重建。

## 0010五表：主代理已串行注册迁移

现`import_batches`/`import_items`继续作为已发布批次及稳定来源索引，不把未通过预览的暂存行写入这些业务表。

| 表 | 关键列与约束 | 职责 |
|---|---|---|
| `import_stages` | UUID `id`主键；`batch_id`唯一；owner user、origin client、epoch外键/绑定；`origin_session_id` FK→`sessions.id`、purpose仅api_native/api_web；format；expected/received bytes和原SHA；stage状态；stage/mapping版本递增；闭合mapping JSON；preview_hash、required_scopes及permission_versions；row/error counts；parse/preview/apply/undo job IDs；created/updated/expires | 绑定上传、映射版本、预览与固定最终请求；绝不允许客户端自报已就绪 |
| `import_stage_upload_chunks` | `(stage_id,chunk_index)`主键/FK；BYTEA、SHA256、size；非负连续index、单片/总量限制；同index同hash/bytes重试返回原结果，冲突409 | 原字节持久上传；seal必须校总长度和串联SHA，无缺片/重叠/替换 |
| `import_stage_rows` | `(stage_id,position)`主键/FK；source UUID在stage内唯一；闭合原row JSONB及原row hash；依赖/拓扑位置；parse/mapping版本；闭合定位错误、preview状态及去重元数据；分页复合索引 | 不暴露半版本解析结果；按原行分页定位错误，保存原金融字段presence |
| `import_publications` | UUID id；`(batch_id,action)`唯一，action为apply/undo；batch FK；`(stage_id,batch_id)`复合FK指向stage唯一对；stage_version；固定request/preview hash；epoch；内部全量chunk/事件计数及SHA；权限向量和最终checkpoint；时间 | 最终事务的内部完整发布证明；正反发布分别成组，不能把两个分别合法的stage/batch串错；全量计数/hash不得直接作为共享用户可见manifest |
| `import_publication_chunks` | `(publication_id,chunk_index)`主键/FK；commit_id唯一索引；内部事件count/SHA；chunk顺序固定 | reader定位同批所有commit、服务端核验与重放；每commit仍≤200 |
| `import_stage_requirements`（0015） | `(stage_id,position)`主键/FK；parsed_version；完整kind/source_kind/resource_type/source_key组合SHA的窄unique；源key≤2000字、first_line BIGINT；可选manifest hash/size/media配对CHECK | 同一次parse持久保存非金融引用，stage requirements_version/hash/count明确完整派生；不索引2000字UTF8长key，不把源UUID当授权 |

stage状态建议为uploading→uploaded→parsing→parsed→previewing→ready→applying→applied，另undoing/undone/failed/cancelled/expired。状态转换用版本CAS及job围栏；parsed可含明确错误，不能伪装ready。最终apply按stage、epoch、所有scope、附件稳定顺序锁定，整体原子完成。

## 当前DTO与客户端动作

当前已实现router前缀为`/api/v1/data-tools/import-stages`，替代本分册早期建议的`/api/v1/data-tools/imports/stages`；已挂普通main，声明import-stages-v1，历史test-only回执保持原边界。operation ID独立，不复用现`ImportApplied`将多个commit塞成一个。

| 动作 | 最小输入 | 输出与幂等 |
|---|---|---|
| POST创建 | 客户端先持久stage_id UUID（旧内部可省略）、format、client_id、epoch、expected bytes、原SHA、闭合mapping | stage_id、batch_id、version、分片上限/有效期；同v1规范化body精确重放；不接受路径/URL |
| PUT `/{id}/chunks/{index}` | 有界字节及片SHA；index由路径固定 | 原片回执；相同片重试幂等，不同正文409 |
| POST `/{id}/seal` | stage/version、总SHA/长度 | 服务端复算后冻结原件并排解析任务；重复seal不产生新job |
| GET `/{id}` | 当前身份 | 版本、状态、计数、任务ID、当前mapping_hash；任务错误另从jobs读，不回显原金融正文或磁盘路径 |
| PUT `/{id}/mapping` | stage_version；闭合资源/时区/图片映射 | version+1；旧预览及旧apply意图失效；原源文件不变 |
| POST `/{id}/preview` | 固定stage/version | 稳定preview job；完成后生成preview_hash，不授写权 |
| GET `/{id}/rows` | cursor、page_size≤100、当前版本 | 原行号、闭合预览/错误、必要资源选择；显式has_more/next_cursor，不静默截断 |
| GET `/{id}/requirements` | 当前stage_version、cursor、limit≤100 | 闭合原引用kind/source_kind/source_key/resource_type/first_line、可选原生manifest；页含完整requirements_hash、显式continuation且≤1MiB；不重读源 |
| GET `/{id}/source-books` | 当前stage_version、cursor、limit≤100 | 当前持久合法book原source_id/name/currency/timezone、稀疏原position；真实总count与continuation，帮助明确选同批图片目的book，不授写权 |
| GET `/{id}/jobs` | 当前stage_version；origin/owner/epoch | 至多4个已绑定任务的实际状态/版本/attempt/安全码和时限；不回payload/result、不接受任意job ID；源TTL/释放不阻metadata |
| POST `/{id}/apply` | stage/version/preview_hash/batch_id | 原`import_apply`任务回执；超时按原stage/hash找回，不新建批次 |
| POST `/{id}/undo` | 固定stage/batch、当前client/epoch | 独立撤销任务；同样全批反向发布，后续合法修改或引用时整批拒绝 |
| POST `/{id}/reauthorize` | 原stage_version、新真实client_id/epoch；session/purpose取当前凭据 | 未发布重绑定并作废旧预览；已发布只续undo，原apply不变；成功version+1，超时按固定ID GET确认版本 |
| GET `/{id}/reauthorization` | 当前真实本人API会话/同epoch；允许新client无SyncClient历史 | 仅stage/batch/version/format/expected_bytes/sourceSHA/mappingSHA/status/source_released/expired；零DML，不证明当前origin绑定，不授写权 |
| POST `/{id}/cancel` | 当前stage_version | 精确释放本版本hold/未完成任务并实际删除暂存字节；已发布拒绝 |
| POST `/{id}/discard` | 固定stage_version/batch_id/client_id/epoch/sourceSHA；本人显式动作 | 新当前会话可放弃旧origin/过期未发布源；真删后N→N+1 cancelled归还quota；N/N−1仅确认已空desired state，不重绑定或假重放ACK |
| POST `/{id}/source-release` | 固定request_id/stage_version/batch_id/client_id/epoch/source_sha256 | 当前本人显式释放已发布源；同body精确重放、异body拒绝；closedreceipt区分实际删除字节与归还reservation |

HTTP创建用独立`StageCreateRequest`强制stage_id必填，内部`StageCreate`可省略仍兼容。分片为`application/octet-stream`、路径index、query stage_version和`X-Chunk-SHA256`；handler边读边限512KiB，原generic middleware仍预缓存至1MiB上限，未放大全局或声称网络读取严格停在512KiB。映射支持中文资源名key，原import严格解码保重复key/NaN/浮点/深度/NUL拒绝；部分typed无效值会在FastAPI先422拒绝。元数据返回closed StageCreated/StageChunkReceipt/StageStatusResponse/StageJobResponse/StageRowsPage，不返回大created数组。

当前17个operation已挂main/cap，实际OpenAPI为72路径/176schema/79操作，SHA256 7e9287a91ffae00d05a81262c5ecd995c4d580d5fea3d9aa2d92d05f9799dd0b。主代理新1d246库相关87目标首86通过/1测试夹具错误（typed空body422误期望401），只改目标后单项1/1（1.98秒），不合成同次87；合同21/21（0.465秒）另跑。新`staging_metadata.py`纯读真实当前API会话、ServerState与已有SyncClient；无client历史的新真实client不创建记录，已有frozen/过期/旧epoch拒绝。probe允许本人在旧origin失效后核对源固定事实，不回原session/client、mapping内容/金融数据，不续client/改version/排job。普通GET和全部原写仍严格origin；显式reauth丢回复只能用普通GET证明绑定，不能把另一会话获胜的N+1/hash当作自己的ACK。此前53相关目标（23.16秒）已核零DML及52表前后hash一致、A/B赢家、源TTL和released/revoked元数据边界。

discard是明确用户动作，预算来自当前调用会话，不能让过期旧origin阻断放弃。金融及未知applying阶段、正式Batch或Publication一律拒绝；其余源真实chunks/rows/requirements/精确自己hold及未完成job同事务清理，之后quota才能归还。原source/mapping/created/binding保留，返回真实cancelled状态，不伪造不可变请求receipt。已cancelled仅当前N或N−1确认实际空源，远旧版本或残留拒绝；未知applying+failed job恢复需后续reconcile，不由discard猜测安全。18真实PG（8.39秒）与后续source-books/原HTTP同次40（26.85秒）分开留证；首两次各17/1测试错误保留。

source-books仅从当前版本合法book ImportStageRow提供非金融原定义，不扫源；102本书按稀疏原pos跨两页无漏重，页≤100/1MiB，cursor绑定stage/version/sourceSHA/mappingSHA/requirementsSHA，wrong origin/owner/version、未parse409和清源410均已验。`fixtures/stage_image_mapping_golden.json`两例有77-byte合成PNG/base64/manifest、native原book source→真实UUID5目标、V10图名→uploaded→既有book；实际生产adapter/operations_for/target_ids/plan_transfers的5纯目标（0.24秒）验证正确双映射及旧错误键/错目的地拒绝，不以期望dict镜像代替生产规则。

jobs endpoint只读stage存的4UUID，核真实owner/kind/epoch及闭合intent/action/版本/sourceSHA或batch、payload hash后给固定安全字段。实际job payload版本允许旧于stage（published reauth不改历史apply），不重写首ACK，不回payload/result/rawerror或任意job查找。队列请求当前只记录job UUID，stage ready不是任务成功；真实claim→fail后metadata显示failed/attempt1，重复apply仍同failed job而不重新入队。11新jobs与13原probe同次24/24、0skip、20.07秒，含零DML/52表相等、源释放/TTL和旧版本任务及8类错绑拒绝。

单次mapping正文容量与源行数独立。下表实算完整规范化StageMapping、`stage_version=1`、紧凑UTF8 PUT JSON，limit=1048576字节；只代表这些固定shape，混合字段、创建wrapper/更长version会改变边界，不能据此制定统一资源条数上限。

| 指定shape（仅一种映射） | 此shape最多项 | 该项数正文bytes | 下一项正文bytes |
|---|---:|---:|---:|
| native UUID→UUID resource_mapping | 13441 | 1048552 | 1048630 |
| V10六位ASCII账户名→UUID | 21838 | 1048558 | 1048606 |
| 1994个中文字+六位后缀（2000字符名） | 173 | 1043524 | 1049554 |
| 1994个emoji+六位后缀（2000标量名） | 130 | 1043454 | 1051478 |
| 1994个U+0001+六位后缀（JSON转义） | 87 | 1045378 | 1057390 |

此shape的20万native映射正文15600154字节、六位V10名9600334，均无法走当前1MiB接口；记录`outputs/validation/P5/stage-mapping-capacity.json`只核字节，不声称HTTP写或性能通过。50MiB源、20万记录/唯一需求与1MiB mapping/response、512KiB片分别是防护值。大量不同资源需独立设计可持久分段映射与最终固定hash确认，不能擅增正文、截原名或把20万模型上限说成完整容量已验；普通300/900秒worker与客户端8秒仍不变。

新增元数据/显式放弃/源book/jobs/图片生产golden与upload/parse/hold、旧HTTP/DTO/mapping必要回归同次**129/129、0skip、55.14秒**（`stage-metadata-regression1.xml/log`）；仅既有Starlette/httpx弃用warning。专用新2efbbd库在0015运行，不迁旧库。此129包含前述53/18/40/24/5的相关目标，不能相加作完整总数；此前168/独立restore1为各自快照。脱敏receipt在`outputs/validation/P5/stage-metadata-receipt.json`。129的历史快照17操作均test-only；随后普通main已挂载并声明能力，分次证据见上文及[stage契约](../../../contracts/import-stages-v1.md)。客户端真实旅程与性能另验。

已发布reauth显式核正式publication context而不重新解析原文件或做金融preview；retained预览行可采纳新显示版本，其数量/存在不再成为金融授权前提。trusted协作预算取5秒与当前真实origin access/full/idle剩余时间的最小值；单SQL原10秒/锁3秒保持，操作系统及SQL不受5秒硬中断。超预算503全事务回滚；transport超时按固定stage GET版本恢复，不自动隐式reauth或重发金融effect。不读取50MiB源，但20万行正式metadata/当前权限/undo仍未做性能验收，不擅自放大普通客户端8秒HTTP超时。

资源名称需求仍仅来源本人上传文件；备注/金额不进入mapping requirements。原生图片manifest包含原ID/hash/size/media；本人选择原件并走既有user-scope上传，不主动抓链接。逐页预览基于同一个已完成preview版本；任意映射变化后旧token/预览必须失效。

0015现实现持久requirements：同adapter在金融convert前采已知原始引用，invalid金额或未选映射的V10行仍提供原名；native JSON/CSV/XLSX排除文件内定义（包括前向source ID），外部UUID只作为待选择引用。`kind`为account/category/tag/image/scope/resource，`source_kind`为name/identifier，`resource_type`给闭合expected type；source_key保原字符串且≤2000，first_line按真实CSV/XLSX物理行，不能误限为20万记录数。optional AttachmentSource只来自经验证的原生manifest，不含href。按首次遇见顺序分配连续position，组合identity SHA窄unique且碰撞重核正文；整体SHA等于canonical完整items数组（含null字段，键排序、UTF8、不转义中文）。每页cursor绑定stage ID/version及此SHA，最多100且最终JSON≤1MiB，超体积短页显式continuation。

Stage nullable requirements_version/hash与count配对：旧0014没有派生的stage返回409，不能伪称空成功；合法零项保存SHA256([])。同parse外层事务逐500项持久写入，失败/预算/失租全回滚；映射与未发布reauth清旧并重解析，published只采保留引用的显示版本，不重做金融effect。cancel/expiry与显式source release实际删除此stage派生；source release audit新增deleted_requirement_rows，旧audit通过DB default0保原事实且不UPDATE。清源后requirements与rows均410。模型上限为20万唯一对外引用，暂存前向候选另有40万防护；这些不是性能承诺，也不改变普通HTTP1MiB，任意20万项映射不能被当成一次JSON已支持。

5新DTO/DDL与旧schema同次17/17（0.24秒）；17旧adapter与新5schema为22纯目标（0.51秒）。新2362库首轮PG组合21通过/1失败（published reauth先采requirements_version，_current autoflush在stage_version递增前触发CHECK），红回执保留；修到版本同次推进后17PG+5schema为22/22、0skip、4.91秒（`requirements-pg2.xml/log`）。真实目标核61行CSV/XLSX invalid原名、三native格式/前向关系、物理行、manifest、205需求无源重读分页、legacy409/正规空hash、版本/错generation、实际1MiB短页/私有HTTP、cap/碰撞/预算回滚与释放审计实数。主代理已独立核0015升降升/metadata[]；不由此声称主app能力或客户端旅程已开放。

随后159必要回归先158通过/1旧测试定位失败（88.00秒）：旧无audit marker夹具先撞0015 released_requirements CHECK23514，补在同一savepoint清requirements metadata以单独验证原FK，仍严格断言23503。后补status.mapping_hash（nullable兼容默认、生产始终给规范化当前值），供mapping PUT N→N+1丢回复后GET确认；仅恰N+1且hash等于原冻结正文的规范化期望可ACK，不能把更后版本或hash当金融授权。原mapping CAS和冻结body不变。owned `fixtures/stage_mapping_golden.json`含完整input/normalized/canonical_json/sha256，测试Unicode scalar键排序（特含U+E000/emoji）及空默认/native UUID映射。GET丢回执/legacy{}、4类malformed native、隔离FK共10/10、4.25秒；最终requirements+mapping_hash与源释放必要回归同次**168/168、0skip、79.71秒**（`requirements-regression2.xml/log`），只有既有Starlette/httpx弃用warning。168包含这些分项，不能把分次结果相加；脱敏回执`outputs/validation/P5/requirements-receipt.json`保两次红回执与当前released无残派生证明。

0015非空派生恢复另独立**1/1、0skip、4.17秒**（`requirements-backup1.xml/log`）：新source `flowtrace_test_p5_backup_source_6cb4a1fc9f2f4f8c`、互异新空target `flowtrace_test_p5_backup_restore_f57adcf05ca8457f`，真实pg_dump→受SH保护verify→受SH保护restore。9张stage/Requirement/Batch/Items/Publication/audit表全部值完全相等；retained stage有967-byte BYTEA/4rows/1真实scope引用，released audit.deleted_requirement_rows=1且无残派生。77-byte PNG/9875余额/received历史保持，目标epoch轮换、旧会话撤销、原源会话有效；receipt/包/原件在`outputs/validation/P5/requirements-roundtrip-6cb4a1fc9f2f4f8c/`保留。0014旧包、source/restore及2362未reset/drop或清源。此1与168不合成同次169，不改写此前0014的8表恢复事实。

## 权限、附件与job围栏

- 创建、上传、重开及状态仅本人stage，绑定当前服务实例/epoch和原client；另设备接续需显式创建新版本/请求，不默默把旧身份请求换client。管理员job操作权不包含私人金融原文读取权。
- `require_current_client`会复核真实session、purpose、access/idle/full期限与撤销状态，stage须存`origin_session_id`（实际表名`sessions`）及严格api_native/api_web purpose，不存token或密码。worker从该真实会话重建principal；退出/失效必须显式重新授权，版本递增并作废旧preview与旧job，不能用管理员或伪worker principal替代。最终执行预算也受剩余会话期限约束。
- parse只检查本人文件，preview涉及现有资源时检查当前read/write需求；最终apply/undo重新锁当前用户、stage、全部写scope。stage的`permission_versions`字段采用独立`StageScopeVersion`闭合嵌套向量：`scope_id -> {permission_version: str, revision: str}`，preview_hash绑定该向量；`lock_preview_scope_versions`重新锁定、授权并核对两项。新book不在existing scope向量，其owner/control scope及create意图仍需锁/复核。撤权、普通金融更新、禁用、恢复换epoch、源/映射版本变化均使旧预览失效。**ImportPublication.permission_versions仍应是纯scope→permissionVersion字符串，checkpoint应存发布后修订，不能直接复制stage嵌套旧向量。**
- stage可引用已上传本人ready私有孤儿，必须有受控job hold避免预览等待期间被清理。现`AttachmentHold.kind`已有job，且没有自动过期；取消/过期清理需显式释放。最终事务仅释放**此stage自己的已授权hold**后再走现无其他hold/无引用校验；失败回滚恢复hold，不能豁免其他stage/backup hold。
- 当前hold ID为`UUID5(stage_id,'attachment-hold:v<version>')`，只对映射内当前本人ready无ref私有orphan建立kind=job hold；已book原件不提前一律拒绝，交实际领域preview区分合法duplicate与非法新迁移。preview的独立rollback-only savepoint临时释放自己hold，回滚后仍保留；最终apply同事务释放。取消/映射/一般reauth精确释放旧version自己hold；`expire_owned_stages_in_transaction`只清未发布stage，真实删源chunks/行、取消未完成job并精确释放自己hold后才释放quota，尚无定时/HTTP挂载。另一stage/backup hold均实测阻挡，错owner/oldversion不能移除别人hold。原生manifest在preview/apply核实际授权图片SHA/size/media，CSV缺manifest仍显式手选，不抓URL。
- 原有`attachment_transfers`移转、旧票据失效、失败rollback、撤销冲突规则继续使用；客户端凭正式receipt及当前GET/hash正反采纳，本地刷新失败可由主代理的`local_refresh.dart`持久重试。
- 当前intent统一用`action`字段：`import_preview`为parse/preview、`import_apply`为apply/undo，payload闭合且只含stage ID/version/hash，不塞文件/所有rows。稳定occurrence_key含stage/version/action；重复请求复用同job。仅完成parse不advertise整个import_preview kind；主代理待parse/preview两项实测后一并注册。
- 当前parse每500行批量插入**仅stage表**，整体仍由同一`jobs.complete`外层事务提交，不声称已经实现分事务解析续跑；完整版本完成前不对业务页可见。最终金融callback调用`apply_publication_in_transaction`/`undo_publication_in_transaction`，禁止再调用会先rollback的`run_transaction`包装函数。apply publication ID为stage UUID，undo metadata ID为UUID5(stage,'undo')；sync namespace保持原规则。各chunk保存真实commit/事件数及规范完整private事件SHA，整体SHA按chunk顺序串联完整事件数组；flat权限与发布后checkpoint同事务保存。这些内部namespace、原index、总count/hash均不得发viewer，授权group必须重投影/重算hash。

### 公开前仍需闭合的生命周期

此前retained quota把applied长期计入，默认8次成功后可能永久阻断新迁移；该原缺口及原169恢复stage表为空的证据边界保留。主代理现串行发布0014（51 public tables/metadata无差异），新增nullable `source_released_at`与append-only `import_stage_source_releases`。stage marker通过复合FK配对audit(stage_id,released_at)，audit再绑定原stage/batch；真实origin/session/client/epoch、固定request/body SHA、source/preview SHA、历史received快照与实际删除计数同事务记录。两个invoker/pg_catalog函数及三个trigger拒audit UPDATE/DELETE/TRUNCATE和非NULL marker改写/清零。首次释放只applied/undone；CHECK允许正式undo事务内的undoing暂态，保完整received历史，不用received_bytes=0伪释放，不把金融status变回上传。

`source_release.py`按当前真实owner/origin/epoch、stage_version CAS与PublishedStageContext验证；applied还需全部batch当前write，undone不复活已删book权限。实际删除本stage源chunks和preview rows后才写audit/marker，quota只排除有正式marker的stage。stage版本不推进、不取消已排队undo；同冻结body重放只回原receipt，异body/nonce/stale版本/新origin拒绝。budget在两次DELETE后及audit+marker flush后采样，异常整批回滚。当前没有定时GC或后台扫描清理，也不对既有stage执行释放。

status闭合DTO显式给出source_released与时间；释放后当前rows入口410，不假报空成功。当前没有原件下载接口，本包没有为泛指“下载410”另建API。原PUT上传、映射、解析入口对已发布stage的拒绝保持，缺rows不能变回parsed。0014该包当时router共12个operation，仅隔离测试include；随后扩展至17个并由主代理挂普通main。旧快捷导入50行/5MiB及导出1000不变。

0014候选模型/DTO冻结与旧DTO纯目标**12/12，0.21秒**，实际新c76库核心先16项通过（12.20秒，首次flush(objects)弃用warning已改普通flush），后为**23实际PG+5schema同次28/28、0skip、12.65秒**（`source-release-pg2.xml/log`）。核真实重复/并发两连接仅一audit、异body/CAS/owner/权限/会话/epoch拒绝、实际quota归还、其他批源不变、清源后undo/新会话reauth、最后audit+marker已flush的取消全回滚；原SQL immutability/marker FK/CHECK及ORM guard均实测。仅新合成stage被显式释放，旧库、旧stage源和既有包未迁移或清理。

独立补真实非空恢复目标**1/1、0skip、3.39秒**（`source-release-backup1.xml/log`）：新source库`flowtrace_test_p5_backup_source_c94fb48632db4560`、互异新空target库`flowtrace_test_p5_backup_restore_060a3eb9cdbf4af8`，两条applied stage中一条保留967-byte真实BYTEA/1chunk/4rows，一条已释放并保1audit与received历史；2Batch/8Items/2Publication/2PublicationChunk。真实pg_dump→有SH保护verify→有SH保护全新restore后，8张stage/正式业务/audit表所有值逐项完全相等，77-byte PNG原件及9875余额、源身份不切换、目标epoch轮换/会话撤销均核。旧stage epoch作为历史元数据保留，不由restore隐式重授权。包、原件、目标目录与脱敏receipt保留在`outputs/validation/P5/source-release-roundtrip-c94fb48632db4560/`；不重置c76或旧三个恢复目标。此新非空目标独立补足旧169的空stage备份边界，不改写旧结果。

必要source/stage回归同次**120/120、0skip、73.79秒**（`source-release-regression1.xml/log`），涵盖源释放与其schema、upload/parse/preview/publish/hold、PublishedStageContext、测试专用HTTP和旧DTO。只有既有Starlette/httpx弃用warning；独立非空restore1不累加为本次总数。

### 时限与性能

完整89中的五个内部目标分别16.593、5.685、10.996、0.511、17.995秒，包含setup/多次apply或undo，不能据此直接估算正式大文件耗时。现`allocated_by_type`对所有live bill扫描，来源summary刷新有明显规模成本；共享领域优化须主代理独立核守恒，不在数据代理路径悄改。

当前采用主代理已实现的服务器固定预算：import_preview 300秒、import_apply 900秒，claim/renew均按kind赋值。`jobs.complete`持job行期间不并行续租、不从同effect反复renew延长上限；handler的cooperative budget使用剩余claim时间减5秒并受真实origin会话剩余期限约束，超预算抛错全回滚，最后再次按DBclock/lease generation复核。每条SQL原10秒statement timeout及3秒lock timeout保持，进程死亡由PG回滚；其他worker的SKIP LOCKED不获取正在最终事务中的job。本段替代早期“同effect内renew”的建议；固定900秒不代表20万行性能已验，最终金融handler仍需整体预算/迟到提交/强制终止目标。

## 端到端publication group：需共享协议与客户端配合

主代理现已完成普通main的group-sync-v1能力与SyncEngine协商（含空cursor）、DataToolsLease桥接和旧v1多chunk resync保护。旧guard+分页真实PG6/6（7.91秒），单可见commit与无关旧已物化页原JSON/hash保持。新164327/head0013真实TCP1/1（约7秒）用201expense/三chunk，owner/viewer丢成功页后SQLite离线重开、同token恢复，均3receipts/唯一publication、精确25125支出与9007199254715868私款/图片权限、冻结outbox及草稿且0push；结束session0/forced0。事实和边界详见[共享group实施](group-sync-implementation.md)与[真实TCP验收](../../../tests/e2e/sync/group-http/README.md)。以下设计仍作为完整规模/恢复约束；stage主入口与大批普通UI需新requirements联测后再开放。

1. 新能力/版本协商和独立DTO。旧sync-v1完整commit≤200、旧已物化pull/snapshot页及其SHA保持原字节，不能给旧响应补默认字段重算；旧客户端不被误告知已支持group原子迁移。
2. reader按固定pull会话的epoch/权限向量为publication生成**当前授权投影manifest**：可见chunk IDs/顺序、每chunk可见事件count/hash、整体可见count/hash、最终向量。全量内部私有count/hash不出现在shared viewer响应中；看不到的空chunk不强制viewer下载或参与核验。
3. 若任一所选commit属于publication，必须完整物化本会话应见的group并固定manifest；不得因cursor/page边界漏掉同组已授权部分。组内顺序以manifest为准，不能假定UUID表示事务先后；独立scope的现tie-break不能替代publication顺序。
4. 客户端在独立暂存表收取和验证跨页group，绑定space/epoch/权限向量/publication ID/hash；不写正式entities、余额投影、账务关系或正式cursors。完整校验后一次SQLite事务应用全组并推进对应正式checkpoint，保留幂等group receipt。
5. 暂存可重开续传。丢片、重复片、SHA错误、错序/循环token、权限撤回、epoch变化、会话过期及本地配额不足都不能留下部分业务结果；只能清/保留可恢复暂存并显式提示，不能伪报成功或推进cursors。
6. 完整pull超过现50,000事件时须有真正有界的group流或新完整snapshot切换机制；分页/内存/SQLite写入预算及离线恢复都要实测，不能把私有完整数组直接返回普通1MiB JSON transport。

## 执行顺序与验收

2026-10-23新c462隔离库/0016的首条真实TCP旅程由主代理独占执行**1/1、19秒**：真实AppController、StageCommands、SQLite与普通main/Worker处理204Items、两片614400B原件和77-byte原图，chunk/apply各真实成功回复丢失一次、两次离线重开、同冻结body恢复；preview零正式金融写入，两个publication chunk一次group安装，101支出/101分类、支出12625/余额9007199254728368，冻结outbox/草稿保持且0push。退出后独立SQL0本人活跃会话、owned API/Worker关闭且端口无监听，首条client receipt不覆盖。新会话显式reauth、释放源后正式undo以及CSV/普通Chrome各自继续；VM沙箱目录桥/内存vault不能代替原生Windows或系统vault验收，50MiB/20万性能未验。详情与恢复路径见[验证入口](../../../tests/e2e/import_restore/README.md)。

该c462后续独立测试14秒在末pending全行断言失败：测试为窥读调用会写attemptCount的nextPush，3变4。失败保留，不能声称整条通过。真实清源/undo/本机释放已发生；独立mode=ro SQLite与只读PG后验确认正式原metadata/audit保留、2源片/204行/2需求清除、undo2chunk、分录0/期初恢复/图回私域及0会话，受保护原文件hash不改，未重跑金融操作。修正仅测试窥读为StoredOperation实际冻结正文读取，初次建立冻结仍1次nextPush，全行含attemptCount断言保持。新d1ba来源/actor及新b77a库head16已prepare/seed，等主代理串行native→followup实跑；c462保持已撤销/已清源现场，Chrome8bb7保持未消费。

| 切片 | 执行者与依赖 | 可接收证据 |
|---|---|---|
| LI-01内部PG发布 | 数据代理，已实现 | 13目标及全89回归、真实跨chunk关系/回滚/pull；仅服务器原子边界 |
| LI-02持久stage | 0010及内部upload/session/version/create重放34、17操作HTTP已分次验证，现普通main已挂；自动GC未接 | 新库迁移、分片断线重开/同片幂等/冲突、文件总SHA与配额、私有权限/TTL清理 |
| LI-03parse/preview jobs | 65内部目标、真实Worker及HTTP已验，普通客户端链已接；新真实大批旅程继续 | 真CSV/XLSX超过50行，定位/中文映射/大额精确/跨文件关系，不抓URL；版本CAS与失败stage不发布 |
| LI-04最终apply/undo jobs | metadata/hold/reauth14真实PG、完整data_tools169、jobs62及专库图片1分次已验；普通main17含四阶段 | 最后行/最后chunk/外层complete失败全回滚、并发映射/撤权/换epoch/失lease、精确重放、附件hold和原件不丢 |
| LI-05group协议/客户端 | 主代理共享sync/契约/存储与普通main已有真实TCP分项；大批迁移UI由Web代理继续 | 真实多页只在全组完成后一次业务可见；重开、旧客户端/旧页兼容、viewer无私有计数泄漏、>50,000路径 |
| LI-06完整旅程 | 独立Chrome、Windows真实普通入口 | 文件选取→映射→分页预览→一次确认→服务端/本地全批一致→导出/图片核对→受保护撤销；不使用用户浏览器或安卓设备 |

下一步：使用[隔离stage联测入口](../../../tests/e2e/import_restore/README.md)的新TCP与普通Chrome独立夹具，实际验证固定版本/hash、真实资源原名/原book、任务终态和大批映射/确认/重开；新会话probe后只能显式reauth或discard，不能自动改绑定。任意20万资源映射的1MiB请求容量及性能另需闭合。共享group协议/物化与客户端由主代理协同实现。最新129与旧HTTP18、原113、去源依赖48、源释放120/独立restore1及requirements168/独立restore1均分次留证。迁移、main/能力和共享sync由主代理独占维护，已有内部模型上限不作为性能验收。普通50行客户端的独立Chrome功能分项已另记[浏览器记录](../../../tests/e2e/import_restore/BROWSER.md)，其中旧6f72候选的地址保存后立即进入账号语义缺口仍保留，由主代理以独立新候选调查；该结果不代替LI-06大批旅程。

停止扩大公开能力的条件：任何一端出现部分业务可见、超时被误判回滚而重建批次、当前权限变化后仍发布、私有元数据泄露、来源/金额/附件守恒不一致、或无法证明整个最终effect受同一围栏事务保护。此时保留stage/失败证据，修复后复验；不清空已有数据库或覆盖历史回执。
