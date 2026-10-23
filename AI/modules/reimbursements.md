# 退款、报销追踪与来源进度

> **速查**
> - 职责：维护expense追踪兼容、公开来源授权/因果读取、精确分配预览及单笔确认；历史/UI和原子重构按后续切片实施。
> - 入口：`contracts/refund-reimbursement-v1.md`、两端同步/本地账务模型、`apps/flowtrace/lib/domain/receipts/receipt_state.dart`、`lib/data/receipts/`及`test/domain/receipt_state_test.dart`、`server/tests/sync/test_receipt_tracking.py`、`apps/flowtrace/test/receipts/`。
> - 不变量：追踪不制造现金/应收/报表冲减；原JSON、影子hash和冻结请求不补默认值；来源聚合守恒且不暴露foreign回款身份。
> - 必跑测试：根目录契约unittest、独立receipts专库的服务端目标与完整回归、客户端receipts/ledger目标及分析；实际回款界面接入后补真实浏览器和最终Android。
> - 相关：[正式契约](../../contracts/refund-reimbursement-v1.md)、[实施细化](../plans/flowtrace/p4-02-implementation.md)、[进度](../plans/flowtrace/progress.md)、[本地账务](ledger-data.md)、[同步](sync.md)。

## 当前范围

P4-02目前已接收A中的追踪/聚合兼容和B纯读取模型；B授权读取与ACK因果证据已通过新增SQLite目标，尚未接入回款页面。已有refund/reimbursement仍为实际到账的11类账单之一；此模块不新增账单类型，不将待报销提前计成资产。专用退款/报销表单、完整历史维护、普通linkedsource严格边界与typed原子修订尚未接收，`receipt-tracking-v1`及未来`receipt-restructure-v1`均未advertise。

正式合同和独立1.1固定样本已冻结；旧1.0的8场景57步、L02/L04输入与精确期望保持。初次合同检查21项为17通过/4真实新模型未实现skip；后端模型落地后21/21通过。服务端完整425通过，含新PG/ASGI12项，随后独立18086真实socket1项通过并正常清理/关闭；这些与静态样本算术分列，不重复相加作整回归数。

## 追踪意图与存储

`reimbursement_tracking`仅expense可选携带strict boolean，显式null/其他类型及非expense任何显式presence均拒绝。缺失只在显示上视为false；同expense更新省略时保留旧presence/显式值，旧缺失不回填。合法改成其他类型时不自动继承追踪字段。

该字段属于metadata，排除金融指纹，原账户/分录、统计与预算不随追踪改变；隐藏金融内容的metadata路径仍保留完整原关联。服务端真实模型/投影已接入，客户端本地写入兼容新29项与旧ledger114项合并143/143通过、owned分析无问题；首轮测试误要求metadata待传仍confirmed，改为明确pending，金额/报表/预算断言保持。尚无新UI入口，不能据字段可解析就向不声明能力的旧服务器发送。

## 来源累计与读取边界

expense的BillPublic外层`source_summary`提供源币R/E/A及open/refunded/reimbursed/mixed原因，与源单revision及同一授权切面绑定。P严格正额、P=R+E+A，A与旧remaining一致；它不是可写payload，不含回款ID、其他账本、日期、备注或账户。新snapshot可生成新投影，旧已物化页保留原字节/hash。

旧canonical无summary时R/E细分未知；可信remaining只证明总剩余，不代表退款/报销各为0。无summary且remaining缺失或显式null均保留总额unknown，有summary却remaining null仍拒绝。读取不能借private finance或不可见关系补证。追踪状态与实际到账历史分离，取消追踪不抹掉历史，全退款结清不能显示已报销。纯读取领域模型ReimbursementTracking保留presence，SourceReceiptSummary校验闭合/守恒，ReceiptSourceState消费公开投影；独立69项目标与窄分析通过，legacy显式null先复现68过1失败再修复。它不验证授权，必须由上层先确认当前授权/修订切面，不含网络、SQL或余额写。

## 验证与恢复

服务端使用全新`flowtrace_test_receipts_local`，未复用或清空assets/dev库；18080仍P3已验旧wheel。新源不新增迁移、不替换运行wheel，实际OpenAPI只随真实模型导出，当前41路径/113schema/47操作。summary可省略但显式null拒绝，最新schema注解与runtime一致，33组模型行为/序列化等效、21合同通过；425为此前等效runtime基线，未为schema元数据重复跑PG/全量。最新wheel位于`server/dist/receipts-schema/`、141467bytes/96资源一致、SHA38c45977b2b4350b993994abe3bac6afd1a1557a66c7c5beefa70df00ca38d84，未安装。

客户端合并初601通过后，legacy null修复最终完整602通过/5需QA配置的live默认跳过（28秒），完整analyze无问题（4.9秒）；当前没有本模块新UI或真实Flutter HTTP回款结果。P4-01固定c974/504浏览器产物保留，602是此前源码Native回归，不包含本次新增B数据层，也不能当成新Web构建或页面已接入。B读取前因果屏障与9组时序矩阵已记入[实施分册](../plans/flowtrace/p4-02-implementation.md)；精确恢复动作以[进度](../plans/flowtrace/progress.md)为准。

## B授权离线读取

`receipt_command_repository.dart`的`ReceiptCommandRepository.create`只确认新建一笔refund/reimbursement，调用方必须提供稳定entity UUID。读写必须同AppDatabase，完整payload先深拷贝并校验原v1分配/金额/显式收入与预览一致；同一`atomicWrite`内复核当前角色/权限、逐源fresh read与revision/permission/checkpoint，拒绝任何source pending/conflict，再重算预览并调用既有LedgerRepository保存，最后核lease。没有网络、独立余额写或多项远端原子承诺。`AppController.receiptCommands`使用同一个receiptReads和ledger供后续页面接入。

重复点击只可找回同一scope、原完整payload、本机完整可编辑正文和同revision的单个原create，且无后续变更/其他待传冲突；返回known entity/operation ID及alreadySaved，不再次save，不重新确认旧分配，不返回旧canonical金额。已拒绝/废弃或远端revision前进后即使正文恢复相同也拒绝。commit前失去lease整笔回滚；在异步commit返回窗口失去lease仅抑制迟到成功，已经提交的旧空间单账保留，不能冒称事后回滚。

确认适配42项目标与窄分析通过，其中提交返回窗口/远端rev3还原相同正文两项均先实际失败后修复；独立复核确认测试分别验证保留已提交数据与拒绝旧create，不以清库/重写操作规避。最终整工程集成回归以progress当前回执为准；该42不是实际新UI/Flutter HTTP或typed生命周期验收。

最新源码接收：ACK25/读取45、纯分配预览46/应用lease4、单笔确认42均纳入最终完整764通过、5默认live跳过，完整分析无问题；授权回款历史/追踪列表与新UI仍待后续。实际OpenAPI因只读lookup变为42路径/114schema/48操作，旧receipts-schema wheel及上述41/113/47仅为前次快照，不代表运行服务已升级。

`receipt_preview.dart`提供1–100个授权ready源的纯预览：保留每源独立币种/精度剩余，到账额仅累加同币Money，跨币复用冻结rate与HALF_UP，退款显式收入分量守恒、报销不得含非零收入分量。重复源/未知剩余/失权或pending金融cut拒绝，输出原v1四字段allocations及source revision/permission/checkpoint绑定。`matchesCurrentRead`只是比较值，调用者必须真实fresh read；DTO不能证明其read来源，也不能作为写权限或正式确认凭证。应用lease桥见[客户端](client.md)。

`ReceiptReadRepository`复用同一个`LocalRepository/AppDatabase`，不调用网络、不建立第二个受控缓存。`read(ReceiptReadLease, ReceiptSourceQuery)`在同一`readSnapshot`读取实体、公开影子、outbox、同步状态及权限/ACK设置。lease绑定space/client/epoch及登录generation的`isCurrent`闭包，前后核验；状态必须active，角色详情必须与同epoch确认的scope权限版本一致，revoked优先拒绝。本机新账本创建意图不证明服务器已确认owner。结果只接受所选scope的非墓碑、正entity revision、真实`bill_public` expense；raw ACK及private finance均不能补来源正文或聚合。

`ReceiptSourceCut`分别返回source ID/scope、entity revision、`ReceiptScopeCheckpoint`及permission version/role，不跨序列比较revision与scope checkpoint。canonicalState保持服务器追踪值，本机tracking与pending/conflict另列。严格可证的metadata更新可保留公开进度；源单金融变化、关联回款before/after来源、删除或来源不完整的待传操作先隐藏canonicalState并返回明确awaiting/unavailable，不把旧summary附给新金额。缺少summary、remaining缺失/null仍按纯模型保留unknown。ACK等待使用同步owner的持久化因果helper；只有当前source scope正式checkpoint达到相应门槛才能解除，中间页看见完整commit仍不能提前推进。缺旧证明有明确missing原因，不能用任意一次同步或私人投影代替。

`watch`监听上述五类表，先订阅lease所需的显式authority invalidations，再读取初值；无轮询计时器。每个authority及数据库变化事件先发无受控正文结果并推进读取generation，即使同一lease仍current也先清空再重读；通知前已经取得的旧读不能在通知后再次发布。authority或数据库流error/done也清空并结束。调用方保留的页面应使用watch；一次read只保证本次返回切面，离线权限仍是最后确认权限，正式写入继续由服务器重新鉴权。原命令、本机输入和冻结字节均不由本读取层修改。

2026-10-22由同步owner在全团队唯一Flutter窗口实际联合执行新增读取43项与ACK25项，最终68/68通过，两组相关生产/测试文件窄analyze无问题（3.3秒）。覆盖角色/权限版本、epoch/client/active、撤权、真实public/rawACK/private/墓碑区别、legacy未知、本机metadata与金融冲突、A换B及删除旧源、authority事件与done/error、五表变化、正式ACK先/完整pull先、非尾页完整commit不提前推进、exact replay补旧证明以及2^53以上同scope差1。没有制造同一commit拆页。初轮62通过/5失败为读取测试正式Applied遗漏`replayed`；补标准字段后66通过/1失败为大游标测试错误回退另一scope checkpoint。两次均由严格生产校验拒绝，只修fixture、保留原金额/因果断言，原失败日志保留。该68是SQLite目标，不等同于本次完整客户端回归、真实HTTP或Android新回款UI验收。

随后独立审阅发现两个真实读取缺口，均先新增目标实际复现失败，再修复。其一，回款A→B已确认并追到source checkpoint，后继B→C仍未冻结时，入队base仍是A；旧实现会漏掉正在被移除的B。现对未冻结且有predecessor的关联before保守标unproven，等`nextPush`冻结点记录真实前态，不能用过时base缩小影响集合。其二，数据库已通知撤权后，先前已取得的读future延迟返回会重发旧cut；现数据库事件与authority事件同样先清空并推进generation。专项修后2/2通过，最终联合读取45项与ACK25项合70/70通过（约2秒执行），读取源/测试窄analyze无问题（2.7秒）。68是前次目标基线，70包含这两项，不累加。最初误用`--plain-name`传正则未选中任何测试的日志保留，不作为故障复现；正式`--name`实际2失败与修后2通过回执独立保留。
