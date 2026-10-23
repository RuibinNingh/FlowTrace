# 客户端同步与本地恢复

> **速查**
> - 职责：分离本地编辑意图、确认影子、不可变发送队列与冲突；验证分页及快照后写本地库。
> - 入口：`apps/flowtrace/lib/data/sync/`、`lib/data/local/app_database.dart`、`test/data/`。
> - 不变量：每次请求绑定服务器实例/用户/client/epoch；重试正文不变；旧回执不覆盖新意图；最终页才提交游标；恢复先备份且不自动重放。
> - 必跑测试：`flutter --no-version-check test --no-pub test/data`、`flutter --no-version-check analyze --no-pub lib/data test/data`；网络模拟不代替两端真实联测。
> - 相关：[客户端基础](client.md)、[同步契约](../../contracts/sync-v1.md)、[计划进度](../plans/flowtrace/progress.md)。

## 当前实现

2026-10-23当前schema5全量1009通过/6专用live默认跳过（59秒），完整analyze No issues（8.1秒）；大文件相关122/122包含原件恢复、明确续接和discard错误/晚SQL失败保BLOB与ACK回滚。更新屏障同时覆盖stage store busy；普通映射页与现有root刷新已接，正式金融结果必须fresh group+相位复核。真实stage TCP/普通Chrome仍待专项；以下908/29/44/42等各自快照保留，不合计成新的测试总数。

schema5现增加大文件source/chunk/冻结command三表及独立恢复chunk表，上传/封存/完整清单reader与普通页面首片已接，跨页映射草稿/显式reauth继续。恢复checkpoint同事务保存完整source/command元数据及chunk摘要、原ack，SQLite用INSERT SELECT独立复制BLOB；不把最大200MiB原件编码到JSON，也不依赖将来可清理的活跃source。晚复制失败连checkpoint/状态回滚，原输入保留；epoch/client恢复不自动发送stage命令。新schema4→5保持partial group/草稿及schema1/2/3相关、source备份/旧小迁移备份、专用binary transport合并29/29通过，能力/清单/更新屏障44/44为后续分次结果；窄分析clean，JIT生成29秒。此前908完整回归属于schema5前快照。

正式stage刷新使用`pullLatest(requireFreshGroup:true)`，最多完成两份既存固定pull后再完成一份本次新建的pull，64步/128页是整个调用总预算；旧cleanup-only仍抛pending，任何未完成不标投影已更新。相位/version/mapping/preview在pull后再次fresh GET核对，applied期间另一设备undo最多再拉一轮，转undoing或仍变化返回待刷新，不按旧GET伪报导入成功。group与stage命令/首片页面/旧页面相关42/42通过，含三项fresh-pull与两项真实复现的跨设备相位竞态修复；该证据不等于后续完整映射UI/普通HTTP已验。

整合复核补齐迁移页的DataToolsLease→SyncLease能力传递和其他四处受限lease复制；普通迁移成功后的刷新同样保group协商，134相关目标通过/1专用live默认skip（12秒），窄分析clean。此分项在schema5之前，不能扩大为后续大文件协调器/UI已完成。

2026-10-23普通`SyncEngine`已按真实server-info的`group-sync-v1`协商新协调器，包括首次空cursor初始化和冲突后的拉取；显式epoch恢复仍走原备份/快照流程。协调器在POST前保存原request/body/base，持久化handle/token、固定步页预算，fresh权限后原子安装；旧缓存只清理未刷新时返回`group_pending`。scope清理保留UUID-only远端回收标记，不删除其他设备active pull。schema4协议/存储/多unit/协调器34项目标及普通入口合并data/sync/identity223/223通过，窄分析无问题。生产HTTP专项1/1（owner/viewer、201真实expense/三chunk、成功页丢失、同token重试、离线文件重开、冻结队列/草稿/精确报表/私人图授权）通过；完整证据与容量边界见[分册](../plans/flowtrace/group-sync-implementation.md)和[契约](../../contracts/group-sync-v1.md)。下述逐页可见语义指旧sync-v1分支。

跨账本同步支持相同bill UUID的来源tombstone与目标public按各自scope落shadow，实体revision作全局先后判断；来源墓碑不覆盖已安装的目标，来源旧public不回退较新目标。可选QueuedCommand.move使本机意图和ACK归目标，冻结网络命令仍以来源鉴权；普通操作序列化省略move字段。双方撤权隔离整条关联pending链，恢复仍授权canonical或移走未确认raw，本机输入留在conflicts/journal。ACK/接受服务器版本按当前授权最高public shadow安装，排除私人finance；旧ACK不回退第三域新版本。

独立审阅回归覆盖target/source两序、迟到ACK、撤权与pending隔离；fresh GET15项、engine10项与共享权限刷新7项合并32通过。数据库监听立即清除撤权服务器正文并保留本机输入，跨scope serverJson目标引用同样清理。正式搜索移动入口已接，P3最后完整客户端411通过/4默认live跳过、完整分析无问题；18084专库两端真实移动HTTP1项及实际Chrome移动主路径通过，包含丢响应冻结重试、原图及余额。协议见[跨账本移动](../../contracts/book-move-v1.md)，实际结果见[联测记录](../../tests/e2e/sync/README.md)。后续P4源码另有目标结果，不能计入这份411基线。

当前schema4在schema3的设置、资料空间、草稿、实体/outbox、确认影子、同步状态、冲突、恢复备份及快照暂存页之上增加group_pulls/pages/receipts。schema1/2升级保留已有记录；schema2实体scope仅从自己的已存命令恢复，无法判断的行保持空scope隔离；schema3→4只新增三表，原冻结命令/草稿保持。生成代码通过build_runner JIT生成。

2026-10-23新group协议/进度handle/收页暂存/单unit原子安装与多unit重开20/20通过，包含独立审阅的prefix先红后修、满配额净回收、真实abandon墓碑和多index/metadata页。接收不写账务，安装前fresh授权和当前lease/cursor CAS，投影/最终cursor/receipt/净删页同事务；原pending overlay与字段presence保留。旧data+sync159通过是这些审阅修复前快照；协调器/能力协商/真实两端与完整回归接续，见[同步组分册](../plans/flowtrace/group-sync-implementation.md)。

本地同步写边界使用AppDatabase.atomicWrite，内部LocalRepository写入复用外层事务且失败使整笔回滚，避免Web远程savepoint外层提交等待；读快照复用规则见[客户端](client.md)。普通冲突重基在页面和SyncStore事务内部同时检查整条同实体pending链：任一移动标记或多个scope均要求重新预览，不能只检查最后一次编辑后丢弃移动意图。三操作链页面专项及确认期间新增移动的存储层独立回归均已包含于P3最后完整客户端411通过/4默认live跳过；原冻结正文、状态、依赖与用户最新输入保持。完整分析及新增独立测试窄分析均无问题。

`SyncEngine.refreshScopes(SyncLease)`以现有同步通道刷新角色/权限版本，先移除失权scope受控缓存及附件，再写新角色；epoch或服务器要求恢复时保全备份并转只读。它不发送outbox、不拉业务事件，且与同步、恢复、冲突读取互斥。`AppController.refreshAttachmentPermissions`将相同space/client/epoch/generation的附件lease桥接给该通道，页面失效也会停止。新增独立7项与current15、engine10合并32项通过，覆盖撤权保留本机输入、降viewer、恢复备份、缺state、互斥及迟到身份响应；移动准备/确认复用它，不再只发权限GET后拒绝而留下受控缓存。

每次编辑在同一SQLite事务保存可见意图与命令。连续编辑以本地predecessor串行；前序回执到达后才冻结后继的base_revision/depends_on。原命令意图与首发HTTP正文分别保存，网络重试使用相同字节和operation_id。确认回执只推进影子；后续编辑仍可见。拉取早于回执时也不能被较旧回执回退。

完整commit组在同页SQLite事务中应用，中间页可持久化投影但不推进正式游标。最后一页验证完整向量后才写游标；失败重拉幂等。共享账单与用户私有资金投影分别存影子；私有资金事件不覆盖共享账单编辑视图。业务页面已通过LedgerRepository接入；存储记录可能是本地payload或服务端projection，由账务读取层统一识别，页面不能将两种原始形状混用。

P4-02 B新增持久化来源因果证据：首次`nextPush`冻结事务将已授权完整canonical before或已确认前序冻结after与本次after的来源并集存入`sync.receipt-bindings.v1.<space>.<operation>`；重试不从当前本机正文或更新的shadow重算。不完整旧before/隐藏分配明确标记不完整，不恢复未知foreign ID。正式`SyncEngine`响应进入`SyncStore.acknowledgeApplied`后再次核对space、instance、user、client、epoch、operation、原冻结字节SHA256、commit、entity revision及完整scope向量，在同一SQLite事务写applied、既有shadow与`sync.receipt-acks.v1`证明；legacy revision-only `acknowledge`不生成ACK证明。相同结果仅`replayed`变化允许，commit/revision/vector矛盾回滚且不覆盖原证明。

`receipt_ack_proof.dart`的`receiptCausalStatus`供读取层在同一`readSnapshot`消费当前state、settings、operations。它只证明当前本机已追到有关操作，来源的授权、非墓碑public canonical及summary修订仍由业务读取层核对。所需scope checkpoint与**同一scope**正式cursor用BigInt比较，不能用entity revision或设备时钟；非最终页即使已安装public事件也不能解除等待，完整pull先于ACK时无需额外多拉一轮。完整来源映射明确指向某scope而正式ACK向量缺该scope时视为矛盾；不完整历史映射只有取得正式完整ACK向量后，才能由向量证明未列scope未受本操作影响，对已列source scope建立保守屏障，达到正式checkpoint后可解除。没有ACK不能推断任何scope未受影响。证明缺失、身份/hash不符和等待来源同步分别返回原因，不把unknown当零。隐藏关联metadata的严格金融不变映射还保存`preserves_hidden`，即使不touch来源也必须有正式Applied证明，legacy revision-only确认不能替代。

历史applied缺证明通过显式`SyncEngine.reconcileAppliedReceipts`核对：最多100个指定operation，只允许当前相同身份/epoch/client的原冻结正文，发送到只读`POST /sync/receipts/lookup`，要求原Applied revision与`replayed:true`；它没有`/sync/push`回退，不重建operation或金额。服务器lookup端点及真实网络接收由服务端工作包独立实现和验证；本节客户端接口与模拟测试不代表端点已经部署。缺失、授权不足、身份变化保留原字节并报告具体恢复原因。当前没有仅Engine能构造的opaque proof token；`acknowledgeApplied`是公开的完整正式响应入口，实际边界是存储层重新核验原冻结上下文和结果、事务原子性，以及revision-only接口不产证明，不能将类型隔离写成已完成。

每个journal operation最多一份冻结绑定和一份ACK证明；before/after各最多100个分配、ACK向量最多1000个scope、单行最多128KiB、每个space两类sidecar合计最多32MiB，超限整笔事务失败，不静默淘汰未解除证据。证据与现有journal同生命周期，不按设备时钟过期；当前未新增journal压缩器。恢复备份`receipt_evidence`保全原行，显式新身份snapshot恢复清旧sidecar且不重放旧操作。scope撤权及permission version变化删除包含其受控位置/向量的证明与绑定，保留原冻结请求和输入；后续核对只能基于当前授权。

授权失败/修订冲突保留本地输入、原基线和可授权读取的服务端版本；后续同实体操作阻塞。显式解决创建新operation_id，不修改旧冻结请求。撤销scope清理受控实体/影子/游标以及冲突中的基线/服务端正文，保留独立的未提交输入；重新邀请不会自动重发旧输入。已经导出的材料和恢复备份不宣称可远程抹除。

epoch/client变化、设备过期或游标需要重建时，完整备份包括已确认实体、影子、全部操作、草稿、冲突与未传附件队列元数据，保存在本机同资料空间的恢复表，原工作数据保留、正式修改暂停，仍可保存草稿。快照manifest和每页按Python同等规范JSON计算SHA256，核对实例、epoch、期限、权限版本、分页编号、数量与向量。全部暂存页复核后才在一个事务替换；失败回滚，草稿保留。恢复安装要求显式选择和新client_id，旧操作保留但不自动重发。恢复核对包含账单/资料内容、账户派生余额及仅留在私人资金影子的差异，可查看并复制保留内容。

`SyncEngine`提供有界的前台同步：检查scope→首次快照或拉取→最多100个串行操作→复查权限并拉取。身份调用提供expectedSpaceId/clientId/epoch及登录generation核验。首次快照允许由本空间私人域book-create命令证明的新账本子记录保留为本地意图，不制造服务器游标；发送时先等账本创建回执。中途分页权限变化会立即复查scope并清理已撤缓存。

账号页已连接“同步与恢复”，提供前台同步、冲突选择、本机副本查看、重新登录后显式恢复，以及备份差异核对。Android两次真实冲突选择及备份查看1/1通过，专用PG真实回滚后的Windows VM恢复1/1通过；具体平台边界见联测记录。

## 已执行验证

独立审阅随后新增只拉取撤权两例：第一次scope有权但pull返回permission_changed/scope_forbidden时，原pullLatest缺少普通同步的即时_scopes重读，两例先红。补同一撤权清理路径后，原用例与engine/权限/迁移/附件目标**45/45通过**；受控shadow/缓存及附件cleanup清除，原冻结输入保留且无push。此前完整854与10秒全分析是该修复前快照，修复后完整回归/普通Web构建尚待跨设备撤销修正一并执行。

2026-10-23新增`SyncEngine.pullLatest`供服务器迁移/撤销后读取当前scope及snapshot/pull，复用恢复/撤权路径和同一busy互斥，不发送任何outbox push。相关12个engine目标通过，新增两例验证已冻结待传行逐字段保持、服务器新投影已安装，以及互斥和迟到身份无写；包含在root迁移集成54目标中。首次两红为fixture误读projection外层、错误把同步throw当Future捕捉导致超时，分别修测试后原精确断言通过。普通HTTP分页仍按现协议完整commit逐页可见，大批迁移出版group尚未接入。

2026-10-22独立审阅补未冻结后继链与数据库通知迟到后，ACK25+读取45最终70目标通过；再接预览/lease/确认适配，root最终完整客户端764通过/5默认live跳过、完整分析无问题。后端只读lookup实际PG/HTTP及socket已另验，运行18080未升级；当前客户端没有新回款UI或对应真实Flutter HTTP旅程，不能从模拟lookup目标扩大边界。完整响应公开Map入口重验而非opaque token的差异保持。

2026-10-21：数据与同步页面当时的合并测试36/36通过，目标目录静态分析通过。包含首次新账本子链、账户余额/私人影子恢复差异、分页中途撤权、附件预检失败仍保留冻结命令和文件清理失败后的重扫。随后白名单诊断及P4增量已纳入2026-10-22完整客户端500通过/5默认live跳过，完整分析无问题；36是原专项基线，不是当前整工程总数。其余覆盖事务注入失败、磁盘关闭重开、schema1/2升级保留、连续编辑/ACK交错、完全相同重试、epoch完整备份、坏摘要/漏页拒绝、快照写失败回滚及显式新设备恢复。

规范JSON摘要的中文、表情、组合字符、转义及2^53以上金额字符串样本与独立Python hashlib结果一致。磁盘重开测试与另一独立内存库并存时Drift打印多实例提示；实际未共享executor/文件，测试通过。真实HTTP双客户端、Android冲突UI、专用PG回滚恢复各1项通过，见[联测记录](../../tests/e2e/sync/README.md)。恢复演练未包含Linux、生产或附件字节/安全库恢复。

P4私有资产配置不是六类同步实体。恢复备份的 `asset_configuration` 数组收集同space的 `assets.config.v1` 与 `assets.outbox.v1` 两前缀全部旧epoch/client行，保留原冻结body；重建不自动重放。账户组只有当前绑定、已REST确认且未排队删除才能引用；不同空间配置不混入备份。新账户11项及既有账务22项合并33通过，配置13项与资产合计12项合并25通过；相关目标与后续资产读取15项、独立账户审阅6项已纳入完整客户端500通过/5默认live跳过，完整分析无问题。实际恢复与读取边界见[资产模块](assets.md)，未执行的Android/Linux验证仍按[工作区](workspace.md)保留。

删除账单的canonical来源证明单独存于 `sync.tombstones.v1` 设置行，仅实际pull/snapshot安装生成；raw ACK不生成。同scope较旧事件不覆盖，等revision的迟到ACK保留已拉取证明；正文/hash和epoch不匹配即不采用。撤权清除该scope证明，完整snapshot替换前清理整空间旧证明，恢复备份以 `tombstone_proofs` 保全原证据。该修改未增加数据库schema或变更服务端事件格式。

删除余额两种到达顺序已实际先2失败、修复后2通过；独立来源证明9项通过，覆盖ACK前后、空间/epoch/修订/hash不符拒绝、旧来源与目标区分、失败回滚、备份/撤权、snapshot替换和较旧live事件。它们已纳入完整客户端500通过/5默认live跳过与完整分析。当前服务端snapshot过滤deleted实体，含墓碑的合成manifest只验证客户端对应兼容分支，不证明服务端实际返回已删行。

生产Flutter VM/文件SQLite对候选wheel的真实资产HTTP复验另1/1通过（约6秒）：正常删除后bank100000/EUR0/card-10000准确恢复，服务端有效资金分录和附件引用均0，两测试会话退出、专用线程停止；首轮失败及修复因果保存在[开发记录](../logs/2026-10-21_develop-flowtrace.md)。这项结果不由默认跳过的live测试推算，也不替代真实浏览器或最终Android/Linux验收。

2026-10-22 P4-02 B的独立ACK存储目标25项与授权来源读取目标43项联合68/68通过，`flutter --no-version-check test --no-pub test/data/receipt_ack_proof_test.dart test/receipts/receipt_read_repository_test.dart`；窄分析`flutter --no-version-check analyze --no-pub lib/data/sync lib/data/receipts/receipt_read_repository.dart test/data/receipt_ack_proof_test.dart test/receipts/receipt_read_repository_test.dart`无问题。覆盖ACK/pull两序、合法完整commit位于非最终页、错误checkpoint回滚、>2^53同scope精确比较、A换B/delete/前序链/冻结重试、hidden-preserve与伪metadata、事务末身份失效、磁盘重开、撤权/备份、单行向量与总量拒绝、旧applied只读lookup及无push回退。首轮62通过5失败是读取fixture漏标准`replayed`字段；补齐后66通过1失败是大cursor测试回退另一scope，改为合法单调checkpoint后67通过，再加入读取authority通知加固后68通过；首次窄分析6项格式/import问题已修，失败日志保留。上述是SQLite与模拟网络分项结果，不代表完整客户端回归、真实lookup HTTP或退款报销UI/Android旅程已经通过。
