# 导入导出与恢复工具

> - 职责：原子导入/撤销、授权JSON/XLSX导出、数据库与附件同恢复点备份及隔离恢复。
> - 入口：`server/src/flowtrace_server/imports/`、`exports/`、`backups/`、`persistence/maintenance.py`；客户端`data/data_tools/`、`features/data_tools/`及设置菜单；验证入口`tests/e2e/import_restore/README.md`。
> - 不变量：预览不持久化账务效果，stage只保存原件/闭合预览元数据；稳定来源去重而合法同额保留；金额不经浮点；撤销不覆盖后续合法修改；后台身份不隐含私人账本读取权。
> - 必跑测试：`server/tests/data_tools/`、`server/tests/test_maintenance.py`、客户端`test/data_tools/`与附件/同步相关目标；真实备份需全新且不同的source/restore测试库和受控pg_dump/pg_restore。
> - 相关：[服务端](server.md)、[附件](attachments.md)、[同步](sync.md)、[stage契约](../../contracts/import-stages-v1.md)、[恢复验证](../../tests/e2e/import_restore/README.md)、[实施计划](../plans/flowtrace/p5-p7-implementation.md)。

## 当前行为

2026-10-24已上线[钱迹原始导出兼容](../../contracts/qianji-export-v1.md)：识别19列及不可信A1范围，按原文本ID稳定去重，并保留退款与原支出关联；收支同名分类使用分型映射键。普通50行限制保持，页面提供“钱迹原始导出 / 超过50条完整导入”，将当前文件先持久保存再进入已有stage全批预览/确认/发布。用户原文件105条/3退款在全新Linux隔离库导入、逐条金额/报表、重放和撤销通过；同版Web以合成105条完成真实文件选择/导入/同步/重开。具体原因、行/字段、错误码和请求ID已显示，脱敏诊断已在生产开启；真实账本没有自动导入生产。版本、失败现场与验证边界见[本包记录](../logs/2026-10-24_qianji-export-import-fix.md)。以下为此前分项快照。

2026-10-24在Linux原生PG17首次实际生成生产维护备份并校验，随后以全新测试库/资料目标执行真实隔离恢复：表内容摘要、余额重算、78B原图及缩略图hash、epoch更换/旧会话撤销均通过，生产源身份/数据保持。首包与定时器、私有配置独立归档、同机备份边界见[生产部署](production-deployment.md)。本次测试账号已禁用，验收目标/失败启动日志保留；未操作旧恢复资料。

内部大批发布primitive已通过13专项及新四库完整89/89：202行分3个<=200 event commit，在同一PG事务写入，末项/末chunk失败全回滚，去重和undo保持同一业务结果。0010五张stage/publication表已在新库完成升降升及metadata diff[]；内部持久上传/会话/版本/固定stage ID恢复为27项PG+7DTO同次34通过。parse/preview事务callback与私有分页的65同次目标通过；金融apply/undo、metadata、hold及已发布reauth的14项真实PG通过。四阶段真实Worker现由主库完整jobs62通过/图片独立库1通过分开留证；早期测试专用stage HTTP17通过，此后主代理已将完整17个操作挂入普通main并声明import-stages-v1；大批普通UI/TCP旅程仍继续。旧sync-v1增量遇当前授权可见多chunk publication会resync_required→旧完整snapshot原子安装；普通main已协商group-sync-v1和一次SQLite安装，当前主代理真实TCP丢成功页/离线重开/同token恢复已验，见[共享group实施](../plans/flowtrace/group-sync-implementation.md)与[大批实施分册](../plans/flowtrace/large-import-implementation.md)。

最近完整`server/tests/data_tools/`为**169/169、0skip、107.63秒**：四个全新UUID库在稳定0012上升级，真实dump/verify/隔离恢复与JSON/XLSX跨库目标均执行；全部79 stage目标已包含。首轮共享0012施工中Text错误与四空库DDL回滚证明保留，未drop/reset，详见分册回执。normal实际57 stages/18 publications/16 chunks；本次备份source/restore的stage表为空，不声称非空stage源字节/Publication专属恢复已验。随后Worker和17 HTTP为独立分项，不累加为新完整总数，不从此直接推出外部stage能力已开放。

`imports/staging_router.py`的前缀为`/api/v1/data-tools/import-stages`，当前17个operation覆盖固定ID创建、512KiB受控原字节/片SHA上传、seal/status/jobs、映射更新、preview/rows/requirements/source-books、apply/undo、重新授权前只读核对与显式reauth/cancel/discard/source-release。当前已挂普通main，server-info声明import-stages-v1并要求客户端沿真实能力使用；旧公共导入50行/5MiB和导出1000保持。HTTP创建强制先持久stage_id，返回闭合metadata与最多100行/1MiB分页，不返回整批entity ID。认证SQL与域调用均在线程池执行，真实会话/CSRF与每次服务授权保持，中文资源名key可用；已发布reauth只续undo并保原apply hash，5秒与当前真实会话剩余时间取小的协作预算失败全回滚。原SQL10秒/锁3秒不变，5秒不是硬截止。原stage+public HTTP组合113/113（63.97秒），后补认证offloop的HTTP专项18/18（14.26秒）是此前快照，源释放及新增元数据分项另计。

主代理本轮正式main导出72路径/176schema/79操作，OpenAPI SHA256为7e9287a91ffae00d05a81262c5ecd995c4d580d5fea3d9aa2d92d05f9799dd0b；合同21/21（0.465秒）。新1d246库main相关87目标首轮86通过/1夹具把typed空正文422误期望401，保留失败；只改该目标为POST空body422及合法GET无凭据401后，单项复跑1/1（1.98秒），不合并成同次87绿。17stage/6group、元数据/放弃/CSRF/CORS主app均在该包实跑；普通Flutter/Chrome大批旅程仍独立验收。

`published_context.py`将已发布undo/显式reauth与原源文件及预览行分离：纯读本人正式stage/Batch/Items数量/Publication、最多2000个连续chunk元数据，核epoch/原version/hash/确定commit ID与flat checkpoint；不读历史BackgroundJob/SyncChange payload、不重建原ImportDocument。历史event SHA交group reader，真正undo仍按原writer逐item核当前revision/payload/ref/附件与write授权。新合成缺源fixture可正式undo及新会话reauth→undo，原apply不可重做；合法后续修改仍整批拒绝。此前12项目标与原publication/hold/HTTP组合48/48（109.09秒），真实Worker普通3及独立图片1另跑通过，分次回执与图片原件见`outputs/validation/P5/published-context/receipt.json`。

主代理现注册0014，`source_release.py`提供当前owner/真实origin/epoch与stage_version CAS保护的显式源释放；applied再核全部batch当前write，undone不复活旧scope。实际删本stage chunks/preview rows、append-only audit及配对source_released_at marker同事务完成，之后quota才排除此stage；保received历史、金融状态、原preview hash与全部Batch/Items/Publication，不推进version或取消正式undo。DB/ORM拒改写audit，复合FK拒无audit marker、窄trigger拒marker复活；两次DELETE及最后marker/audit flush后的预算取消均全回滚。status明确source_released，rows释放后410；当前没有原件下载接口，也未新增下载或定时GC。23真实PG+5schema同次28/28（12.65秒）通过；仅新合成stage显式释放，既有source和旧库不动。

非空stage恢复另1/1（3.39秒）实测：全新互异source/target，retained 967-byte BYTEA/4rows与released audit并存，8张stage/业务/publication/audit表完整值一致，77-byte图片原件、9875余额、epoch轮换与会话撤销均核。源仍可用，旧stage epoch仅作为历史保持；包与原件保留在`outputs/validation/P5/source-release-roundtrip-c94fb48632db4560/receipt.json`同目录。旧169虽完整但源stage为空的边界仍保留，本项是独立补验。完整容量/20万性能及大stage分页资源映射、普通客户端旅程仍待验。

源释放与必要stage回归同次**120/120、0skip、73.79秒**（`source-release-regression1.xml/log`）：覆盖upload、parse、preview、publish、hold、PublishedStageContext、测试专用HTTP和DTO；仅既有Starlette/httpx弃用warning。独立restore1不累加为同一次完整回归。

0015另持久保存固定版本资源需求：`staging_references.py`从同一V10/native adapter的已知原始字段采引用，先于金额/映射校验，故invalid row也保账户/分类/标签/图片原名；不含金额备注，不抓URL。native仅给原UUID引用及expected type，排除文件内定义的source IDs，不由此推定现有ID可读写；可信原生manifest可附闭合hash/size/media。`staging_requirements.py`保存最多20万唯一项（暂存forward候选40万保护值），按首次遇见顺序去重及连续position，首次物理行不等于行位置。Stage保存nullable version/hash/count；旧stage缺派生返回409，正规零项有SHA256([])，清源410。GET每页最多100项且实际JSON≤1MiB、cursor绑定stage/version/完整派生hash，不重扫文件。parse和映射/未发布reauth全事务重建；published reauth只采显示version；cancel/expiry/release实际删派生，source release audit新增deleted_requirement_rows实数，旧audit default0不改写。首轮21通过/1 reauth autoflush时序失败保留，修复后17PG+5schema同次22/22、4.91秒；最终requirements+源释放必要回归同次168/168、0skip、79.71秒（`requirements-regression2.xml/log`），只含既有Starlette/httpx弃用warning。模型20万映射dict不代表单次1MiB HTTP能提交任意20万映射，完整大批UI及容量性能仍待验。

stage status另给当前规范化StageMapping的mapping_hash，按完整默认/null值、Unicode scalar键排序的紧凑UTF8 JSON计算；legacy `{}`同样先归一。只供丢失PUT回复后核version恰为N+1且hash等于原冻结期望，不授金融写权；旧N的mapping CAS仍409。三组合成golden（空默认、中文/emoji及U+E000名字、native资源）在`server/tests/data_tools/fixtures/stage_mapping_golden.json`供两端复核，避免UTF16排序差异。丢mapping回复GET、原body不改、同hash已v3与legacy{}等后补目标同次10/10、4.25秒；其中含原SQL marker FK隔离及malformed native回归，不与此前22相加。

`GET /{stage}/reauthorization`只给本人上传源的最小核对信息：stage/batch/version、format、expected_bytes、source_sha256、规范化mapping_hash、持久status、source_released、源TTL expired。允许当前本人新API会话在旧origin失效后核对；不回旧session/client、映射内容或金融数据，不改版本、续client或排任务。现有frozen/过期/旧epoch client仍拒绝，尚无SyncClient的新真实client可读而不创建。`staging_metadata.py`共用纯读当前身份围栏；普通GET和所有原写入口仍严格origin，probe不能证明当前origin已属于调用方。显式reauth的丢回复恢复必须再以普通GET核当前绑定，A/B并发赢家不可被元数据版本/hash冒认。新probe及相关HTTP/DTO同次53/53、0skip、23.16秒；零DML监听和全部52表前后fingerprint一致，见`stage-probe-regression2.xml/log`。

`POST /{stage}/discard`是本人明确放弃未发布源的独立动作：closed body固定stage_version/batch_id/client_id/epoch/source_sha256，取当前真实API会话的5秒/会话期限协作预算，允许旧origin或源TTL已结束。拒applying/applied/undoing/undone、任意正式Batch/Publication；不凭失败job推断金融效果安全。实际删除chunks/rows/requirements、精确释放自己版本的图片job hold并取消旧未完成意图后，N→N+1 cancelled，quota才排除；原SHA、mapping、created/binding与金融历史保持。已cancelled的N或N−1输入只确认实际空源的desired state，既不制造原请求重放ACK，也不重绑定；不完整清理409。当前没有定时GC或旧包扫描。18/18真实PG、0skip、8.39秒覆盖旧会话、TTL、wrong body/owner/epoch、真实删除后预算全回滚、其他stage/backup hold和77-byte原图保持及配额；前两次各17通过/1测试夹具错误保留。持久applying且job已failed的未知状态恢复另待设计，不能用discard猜测清理。

`GET /{stage}/source-books`从当前parsed_version的合法持久book行给原source_id/name/currency/timezone及原行position，位置允许稀疏；outer有真实count、版本和分页，最多100项/1MiB。origin/owner/epoch/version严格，游标绑定source SHA、规范化mapping SHA和requirements SHA；不重读源、不授当前目标写权，清源410、未parse409。它使本人可明确选择图片要进入的同批原book source。图片黄金`fixtures/stage_image_mapping_golden.json`以真实native/V10 adapter→operations_for→target_ids→plan_transfers验证“原image→uploaded orphan→原book source→实际UUID5 book”；两例含77-byte PNG原件/base64/hash及实际scope/附件期望。5纯目标、0.24秒，包括旧source ID作transfer键和错目的地的真实拒绝；它不代替数据库附件授权或普通页面验收。source-books、discard和原stage HTTP同次40/40、0skip、26.85秒。

`GET /{stage}/jobs?stage_version=N`独立返回stage已存的至多4个任务：action、job_id、实际payload版本、status/attempt/安全code、available_at/lease_until；仅当前本人origin/epoch/版本可读，源TTL或正式源释放不隐藏任务元数据。纯读身份不续SyncClient；逐项核owner/kind/epoch/closed intent/源SHA或batch及真实payload hash，错绑409，不回payload/result/raw error，不查任意job UUID。stage ready不表示apply job成功，失败job重复原apply只回同任务，不自动重新入队。11新jobs与13原probe同次24/24、0skip、20.07秒，含真实claim→fail、发布reauth后旧v1任务事实、错绑/安全code及零DML/52表不变。

原件50MiB/20万行、唯一需求20万、页100项/1MiB、单片512KiB和mapping整次JSON 1MiB是独立防护值。当前模型dict上限不保证任意20万资源映射可一次提交。使用完整规范化StageMapping、`stage_version=1`及紧凑UTF8 PUT正文实算：仅UUID→UUID resource_mapping最多13441项（1048552字节，下一项1048630）；仅六位ASCII账户名的V10映射21838项（1048558/1048606）；1994个中文字加六位后缀的2000字符名173项（1043524/1049554），同长emoji名130项（1043454/1051478），转义控制字符名87项（1045378/1057390）。这些仅是指定shape的实算，混合映射、wrapper或更长版本会减少容量，原名不能截断。20万UUID该shape实际15600154字节，六位名9600334，均超过普通正文；详见`outputs/validation/P5/stage-mapping-capacity.json`。大量不同资源映射的分段协议和20万行性能仍需闭合，未扩大HTTP/sync或客户端8秒超时。

本包新增元数据/放弃/源book/jobs/图片golden与upload/parse/hold、旧HTTP/DTO/mapping必要回归同次**129/129、0skip、55.14秒**（`stage-metadata-regression1.xml/log`），仅既有Starlette/httpx弃用warning。该快照stage尚test-only；随后普通main接线证据见上段，不能把129追溯当新main全量结果。专用新2efbbd库保持0015，不升级既有库；与此前168和独立恢复1均为不同范围/快照。脱敏回执`outputs/validation/P5/stage-metadata-receipt.json`，17操作权限与终态证明见[stage契约](../../contracts/import-stages-v1.md)。独立Dart四映射再喂真实Python adapter/operations_for/plan_transfers为4/4，包括重选无旧transfer；`stage-image-dart/f2fc323a-476d-451d-91d2-38a2f25562e5-python-verified.json`只证明跨语言纯规划，不代替原图授权或页面。新隔离TCP/普通Chrome夹具及初始化断言失败后的只读恢复见[验证入口](../../tests/e2e/import_restore/README.md)；后续TCP与页面业务旅程分项继续，未操作设备、提交、推送或部署。

新c462专库/0016首条真实TCP目标已由主代理独占运行**1/1、19秒**：实际AppController+磁盘SQLite+普通main/Worker，204Items（101分类/101支出）由两个publication chunk全批安装，614400B原JSON两片、chunk/apply各丢一次真正成功回复、两次离线重开、原请求/outbox/草稿保持且0push。preview独立SQL零金融写入，正式支出12625/余额9007199254728368，77-byte原图scope/hash核对；退出后0本人活跃会话、owned API/Worker关闭，18094/18194无监听。回执与失败初始化恢复边界见验证入口。此VM注入沙箱目录桥/内存vault，不代替Windows原生目录租约、安全存储或普通Chrome UI；源释放/新会话撤销与CSV另验，50MiB/20万性能未验。

c462后续新会话清源→撤销→本机释放已实跑到末，但**14秒整条failed**：测试窥读误用会写attemptCount的nextPush，末完整pending断言3→4。独立纯只读后验确认stage/Batch undone、原204Items/apply metadata及audit SHA保留，真清2源片/204rows/2requirements与本机BLOB、正式undo2chunk/分录0/账户期初恢复/图回私域、0session/空端口；没有重跑金融操作或改原失败证据。仅改live窥读为StoredOperation只读，保留初次真实冻结和全行计数断言。新d1ba/另新b77a库head16已prepare+seed、0stage/batch，修后两阶段待独占SDK；分次事实及原只读文件hash证明见验证入口。

0015恢复另独立1/1、0skip、4.17秒（`requirements-backup1.xml/log`）：两个新UUID source/target，精确9张表（含非空requirements）恢复完全相等，retained原引用1项、released audit实际删1项；967-byte源/77-byte原图/9875余额、epoch轮换、目标会话撤销及原源会话继续有效均核。包/原件/脱敏receipt在`outputs/validation/P5/requirements-roundtrip-6cb4a1fc9f2f4f8c/`；原0014包/源/目标保留不迁。168与独立恢复1分次记录；主回执`outputs/validation/P5/requirements-receipt.json`保红绿及当前marker无残派生证明。

stage只保存受控BYTEA原件与闭合中间行，不从路径/URL抓取；公共导入仍50行/5MiB。大source adapter复用真实公开V10与原生JSON/CSV/XLSX，17纯目标核对真实物理行、SHA、金额presence、signed posting及图片manifest；parse在jobs.complete外层事务中逐500行写stage，格式失败保原件且无账本结果，权限/预算/失租抛错回滚。未领域预览行响应`parsed`，不伪称可导入；分页最多100行且最终JSON<=1MiB、短页显式continuation。实际领域preview使用rollback-only savepoint，首轮6真实PG含202行退款依赖、余额不变与最终失租回滚；stage预览向量为scope→闭合`{permission_version,revision}`，普通金融更新使旧预览失效。当前阶段与各次结果边界集中在分册，不把模型20万行上限当性能验收。

`staging_publish.py`将金融effect、ImportBatch/Items、分片commit及真实正反ImportPublication/Chunk、stage终态和安全job结果放入同一jobs.complete事务，逐行/投影刷新/每chunk采样固定预算；flat permission_versions与发布后checkpoint不混用stage预览嵌套向量。全duplicate允许0chunk/0event，结果不把大entity/transfer数组塞进普通响应。已发布显式新会话reauth保原apply正文/hash/metadata并只续undo；原item修改/新引用冲突拒绝，无关新增仍允许undo。applied/undoing/undone不被源TTL阻断或清理成可重做；retained源默认保留，0014提供本人显式释放及真实quota归还，尚无自动源GC。

目前提供Python应用服务和`/api/v1/data-tools`下parse/preview/apply/history/undo-preview/undo、JSON/XLSX导出路由，真实ASGI/PG目标已通过。客户端普通设置菜单已挂载`/data-tools`：资源映射、预览/确认、冻结请求重试、本人分页历史、撤销和授权POST下载。普通6f72 Web候选在独立Chrome/新UUID库已有文件选取、映射、图片原件、JSON/XLSX下载、撤销及完整离线冷开等功能分项；旧地址保存→账号页语义缺口与过程失败仍保留，详见[真实浏览器记录](../../tests/e2e/import_restore/BROWSER.md)，不能标成全尝试通过或大stage旅程通过。完整后台备份下载/恢复仍实施中。迁移只在隔离P5库执行，未迁移原开发库。multipart parse精确POST请求上限5MiB+64KiB，文件仍5MiB，其他普通写请求仍1MiB。

2026-10-23此前服务完整84项通过，含真实新source/restore/migration库dump、全表摘要、原设置/金融/图片往返及16实际HTTP目标；后续内部publication纳入完整89，当前新stage包完整回归按分册逐次记录。原生JSON/XLSX `attachment_sources`只返回源ID/hash/大小/媒体类型，缺manifest时由用户手动映射，不自动抓URL或解包任意目录。该次实际OpenAPI50路径/139schema/56操作、合同21通过，后续公共契约由主代理统一导出。大批持久staging和端到端原子发布仍开发中，对外当前50行导入/1000行导出界限未放大，不把多个HTTP小批视为一个原子迁移。

本机批次先持久化正式applied/undone回执，再拉取服务器投影；`SyncEngine.pullLatest`不发送原本outbox。附件经当前GET核对目标scope/hash后，复制到由新scope派生的私有blob key、清旧票据并原子更新本机队列；原图旧副本保留。撤销可将已撤旧账本缓存中的原件采纳回本人scope，仍需当前服务器确认/epoch/client/权限。`DataToolsLocalRefresh`单独保存成功标记，失败不重复apply/undo，重开/刷新按原回执补做；旧epoch/client记录只保留、不标为新身份已完成。根集成相关54目标通过，后补旧身份保护目标及普通根页面完整回归另待接收。

原生文档以六种同步实体、稳定source UUID和显式scope/resource映射表达创建批次。公开钱迹V10模板按官方列、时区、账户/分类/标签资源映射解析CSV/XLSX；官方“报销”是待报销垫付支出，已映射expense追踪标记，不能误当缺来源的回款。实际“报销入账”关系不可凭无关系列猜测，不猜测私人格式或抓取图片URL。预览在真实领域校验的rollback-only savepoint中执行，无持久batch/receipt/client lease；apply同一事务生成最终去重事件和来源索引。undo先核对修订/正文/权限与关联，后续编辑或引用冲突时整批拒绝。

JSON导出外层信封可供解析器读取，XLSX金额和有公式外观的文本按字符串保存。`posting_hints`仅用于历史余额调整：从真实principal分录导出有符号minor，校验非零且绝对值与原金额相等，再走显式import-only `historical_adjustment_minor`入口；保留原历史target/body而不按当前重建余额重新计算。普通sync不传此参数，原余额调整验证保持。

图片先经现有授权上传管线成为本人user scope的ready孤儿，`attachment_transfers`显式要求同批采纳到目标账本。服务锁定并核对本人/ready/无引用或hold，原子迁移metadata并废止旧票据；预览/失败回滚原孤儿状态。撤销在无后续引用、权限版本变化等冲突时转回本人孤儿，原字节不改动。stage按stage/version专属UUID5建立kind=job hold，等待preview保原图，rollback-only preview临时释放自己的hold后自动恢复，最终apply精确消自己hold；另一stage/backup hold均不能豁免，取消/改映射/受控过期精确释放且不删原图。原生manifest实际hash/size/media在preview/apply复核。普通Web两个新合成来源的77-byte原件已有真实UI选取/导入/离线显示和独立跨设备撤销刷新分项；stage及group客户端生产链已接，新的大批原图旅程单独验证。

`build_engine`每次事务获取共享数据库维护闸门，维护CLI取得排他lease并锁所有public表SHARE，等待在途及旧版本写者结束，允许pg_dump读取。维护期间普通engine事务安全503。备份含custom dump、非秘密设置、版本/instance/epoch、数据库全表计数/摘要、原件/缩略图hash，校验后才发布。隔离恢复只接受全新空测试库/新目录，先核对源身份和表内容再轮换epoch、撤销会话，复算账务/文件。原源库不修改；这不是Linux服务级恢复。

## 验证边界

数据工具67项真实隔离PG/格式完整目标已通过，含新账本设置/图片和金融往返；随后真实HTTP8项通过权限/历史例外，mapping_requirements扩展后HTTP10项通过。本人操作历史仅返回不可变元数据，不因原账本删除/撤权隐藏，不授予当前写权，详见权限契约。最初48/60/65项回执与失败场景保留，不累加成新总数。公开V10“报销”已正确映射垫付expense追踪标记（实际10000−900=9100），不伪造报销入账。

旧快捷导入50行与导出1000实体不因新stage链而放宽；大批普通迁移旅程、任意大量不同资源的映射容量与性能、全量后台权限及Linux恢复仍需继续，不能据此缩小原完整目标。
