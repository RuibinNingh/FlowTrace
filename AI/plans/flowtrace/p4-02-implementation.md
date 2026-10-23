# P4-02 退款与报销：候选实施细化

> 状态：**A追踪/summary与B来源授权/因果读取、纯预览、lease桥及单笔确认适配已接收，最终764完整客户端回归通过。授权历史/追踪查询及C/D完整UI/严格来源/typed复合未实现**。日期：2026-10-22，Asia/Shanghai。
> 责任角色：主代理负责契约冻结与集成；领域/服务端角色负责账务与事务；客户端角色负责读取、表单及本机命令；独立审阅角色负责并发、隐私与验收。实际委派和接收见当前进度，职责表不等于任务已完成。
> 初始依据为实际工作区只读检查，后续结果在下方接收状态中登记。Git `main` 尚无提交，以当前文件为基线；未来接口和未验收目标不能作为实现证据。

本分册承接[完整任务 P4-02](tasks.md#p4-02-退款与报销完整生命周期)、F03/F13、J04 和 E10；用户原话“完全模仿钱迹就行”及平台顺序保存在[总计划](plan.md)。完整目标与[产品范围](product-scope.md)继续有效。执行恢复先读[当前进度](progress.md)。

已将A的追踪字段、权威source summary、方案A规则及兼容边界纳入[正式契约](../../../contracts/refund-reimbursement-v1.md)和独立1.1样本。初始合同检查17通过/4模型缺失skip，模型落地后21/21通过；新模型/生产wire与原有规则的接收边界如下。P4-01固定c974已通过即时表单ARIA/Tab输入并完成正常清理，18085/18185及专用Chrome已关闭；18080旧运行基线保留。未来typed路径/DTO尚未冻结的建议不能当成已发布API消费。

## 当前接收状态

| 部分 | 实际接收依据 | 尚未实现 |
|---|---|---|
| A合同、两端追踪/presence及服务端summary | 新receipts专库完整425通过（含12 PG/ASGI），后续18086真实socket1通过并关闭；合同21/21。实际OpenAPI41/113/47；nullable表达窄修后33组runtime接受/序列化完全相同，独立新wheel仅构建未安装。 | 普通linkedsource严格金额锁与两端Reference仍按原实现，未宣告`receipt-tracking-v1`。 |
| 本地兼容及B来源读取、预览、确认 | 新29数据+原ledger114合并143，纯模型69；ACK25/读取45/预览46/lease4/确认42均纳入最终完整764通过/5默认live跳过、完整分析无问题。四个独立审阅边界均先红后修。 | 实际授权回款历史/追踪列表及C退款报销UI未接；纯模型/预览不具授权写凭证。 |
| D/E/F后续 | 已有独立只读审阅无阻断，真实回款新增/改额/删及源revision同commit、重放/并发/隐藏聚合有目标。 | typed revise_source/复合队列/部分解绑拆income、回款换来源或类型的双源回归、实际新UI及最终Android完整旅程仍待实施。 |

601/602及722为此前Native回归，最新764纳入B来源数据/预览/lease与单笔确认；c974浏览器产物对应此前504快照。Android独立fixture的系统选图/取消/超限及修复QA helper后同APK无重装第二次force-stop/COLD只读恢复已通过，普通main已恢复并实际冷启；不当作新回款UI或完整旅程。普通多项push继续逐项提交。

## 已有基础与三处差异

以下记录开工前梳理：G1已通过上述追踪/summary部分实现补齐，G2/G3仍是后续D的缺口；当前状态以本节上方接收表为准。

已有基础可复用：

- [账务规则](../../../contracts/ledger-rules.md)已经固定 11 种 `bill_type`，其中 `refund`、`reimbursement` 是实际回款；`allocations` 明确源币金额、到账币金额与可选汇率。没有增加第 12 种账务类型的需要。
- `server/src/flowtrace_server/sync/schemas.py`、`commands.py`、`writer.py` 已有严格分配守恒、来源写权限、作用域锁、账户分录、幂等回执和单操作事务。现有退款/报销是已存在的生产账单能力，完整用户流程尚未实现。
- 客户端 `lib/data/ledger/` 已有本机事务、完整草稿、冻结队列、分录提示及可见/可编辑投影；`LedgerReportingService` 与两端报表已经按原单期间冲减，不能在新页面另减一次。
- [共享黄金样本](../../../contracts/fixtures/ledger/README.md)中的 L02/L04、服务端 `test_fx_refund_and_reimbursement_allocation_conservation`、`test_cross_book_refund_redacts_source_but_authorized_read_reconstructs` 以及客户端 `reporting_adapter_test.dart` 提供现有行为证据。本次只读检查这些测试源码，没有重新执行测试。
- `BillDetailPage` 的基础编辑类型集合不含退款/报销；当前没有专用 `features/refunds/`、`features/reimbursements/` 完整页面。`LedgerBatchService` 已拒绝隐式复制回款，且批量删除先处理明确选中的回款、再处理明确选中的源单。

| 差异 | 当前文件事实 | 候选处理与接收前证据 |
|---|---|---|
| G1 待报销意图缺失 | `BillPayload` 与 `Flags` 没有待报销的持久字段；已有 `reimbursement` 表示实际到账。 | 为 `expense` 增加可选追踪意图；余额、应收、收支和预算均不因标记改变。兼容测试确认旧 JSON、哈希及冻结请求不被回填。 |
| G2 原单修改边界不一致 | 合同要求已有分配的原单改类型/币种/金额或删除先解绑/显式复合；生产服务与本地验证主要拒绝币种变化、低于已分配额。`ReferenceLedger` 额外锁账户/业务日期，客户端报表专项另有“允许增额”的测试。 | 按现有合同统一四项限制。账户/日期不额外禁用，按已有权限、账户/时间校验及完整分录重算处理；同步调整实现和上述行为测试，保持 L02/L04 历史期望。 |
| G3 远端多记录原子性缺失 | `saveBatch` 是一个 SQLite 事务；通用 `/sync/push` 对每个 operation 独立提交。 | 整笔回款转 income 可用单记录原子更新；部分解绑并拆 income、关联多回款联动需专用事务 operation。专用协议未实现时明确拒绝，不能宣称通用批量远端全成全败。 |

G2 是已识别的合同/实现差异，本轮没有用新执行用例复现，也没有修改生产源。G3 是现有事务边界，不代表普通单笔回款缺少原子性。

## 主代理已采纳的实施决策

以下由主代理在2026-10-22明确选定，属于P4-02实施约束；**追踪/summary/方案A合同已冻结并有静态样本检查，生产规则尚未对齐，实际业务测试未完成**：

1. G2选择沿用现有`ledger-rules`的严格方案A。原单存在有效分配时，普通更新不得实际改变type、Money币种/精度/金额，也不得删除。金额更正进入用户明确确认的typed `revise_source`，不能仅因调整后仍大于已分配额而继续走普通save。
2. `ReferenceLedger`须比较前后实际值，不因完整表单重复携带未变化的`money`而拒绝。账户与业务日期不额外锁定，继续执行当前资金权限、开户日、时区/精确时刻及分录校验；改期重算原单净额所属期间，不改回款自己的历史时刻。
3. 旧“允许增额”的行为测试不能直接删除或换掉金额期望。普通更新新增明确拒绝用例；原增额后的精确报表/余额期望迁到复合修订验证。L02/L04的输入和期望继续保留。
4. 采用expense可选`reimbursement_tracking`及缺省显示false、旧raw/hash/冻结字节不回填、无关更新保留原值的兼容原则。它是追踪意图，不能提前制造到账、应收或报表冲减。
5. 新增最小无标识权威source summary：源币累计R/E、remaining和结清原因，跟随源单revision；可读源单者可以读取本单聚合。它不返回foreign receipt ID、日期、备注、账户或其他账本信息。旧投影尚无summary且只能证明总剩余时，R/E细分仍为unknown，不能以未见回款当E=0，也不借私人finance补出失权来源。
6. 整笔回款保现金、解除全部关联可采用同UUID单次更新为income；部分报销解绑拆income及多回款联动必须专用远端原子事务。普通`saveBatch`的本地原子性不改变远端逐项提交事实。

未采纳的兼容方案B是保留当前生产允许`P' >= R+E`的普通增减额，再修改契约和Reference。该方案解释了现有测试行为，但不作为本轮实施默认；不能在新页面锁金额、远端普通save仍允许的状态下宣称已经完成方案A。

## 候选契约与兼容边界

### 追踪意图与派生状态

字段名已在A合同冻结为 `reimbursement_tracking`，仅expense可选携带strict boolean，显式null及任何非expense携带均拒绝。`receipt-tracking-v1`同时约束该字段、source_summary及方案A；实际模型/规则闭合并验证后才advertise，当前尚未成为已验运行能力。

- 缺失在显示语义上视为 false。旧服务端 payload、shadow 原 JSON、projection hash、旧请求内容与已冻结 outbox 不回填 false。只在用户显式改变意图时产生正常修订；无关字段修改保留原有缺失/显式状态。
- 追踪沿用原单账本的读写权限；写入由 owner/editor 授权，viewer 只读。它不授予私人资金账户或其他账本权限。受限金融内容的元数据更新必须保留隐藏关联。
- `tracking` 只是追踪意图。对源单实际支付额 P、源币累计退款 R、源币累计报销 E，仍使用 `A=P-R-E`，且 `0<=R+E<=P`。标记或取消追踪不产生资金分录、应收资产或报表冲减。
- 追踪且 A>0、E=0 时显示待报销；A>0、E>0 时显示部分报销；A=0 显示已结清，并区分全退款、全报销或混合结清。不能把全额退款无报销的记录标成“已报销”。具体标签随产品审阅冻结。
- 取消追踪不撤销既有到账，也不删除关联历史。旧记录即使没有追踪字段，已经发生的实际报销仍可在历史中核对。尚未同步的意图/回款明确显示本机状态，不能冒充服务端已确认。
- 拆分证据不足时，已可信的总剩余与净额可以显示；退款/报销各分量显示不可用，不能用私人 finance 或隐藏来源重新拼出无权正文。

当前`BillPublic.remaining_allocatable_minor`只证明`P-R-E`，不能单独分解R和E；expense自身的`hidden_allocation_count`也不表示全部入向关系是否可见。主代理已采纳的新增source summary由服务端在同一一致切面计算源币累计R/E、剩余和结清原因，并与源单revision绑定。其可见权限为读取该源单，无需获知全部foreign回款身份；响应不携带其他账本/回款ID、账户、备注或日期。客户端对尚无summary的旧canonical仍需完整可证回款集合才能细分，否则保留可信总额并返回细分不可用。新投影序列化须继续保护旧物化页与哈希。

追踪意图的元数据写权限不包含他人私人账户权。新字段需加入严格metadata允许列表、从金融指纹中排除，同时保留其余隐藏金融事实的精确比较；旧客户端完整替换省略字段时仍须保留true。历史物化页继续按原字节返回，不通过默认值注入重算旧page hash。

### 原单和回款维护

原单已有有效分配时，普通修改若实际改变 `bill_type`、Money 币种/精度/金额，或尝试删除，应以 `bill.has_allocations` 拒绝。比较实际字段变化，不能因完整表单携带未变字段而拒绝备注编辑。只有明确的解绑/删除关联或经正式契约定义的复合操作才可改变这四项。

判断“已有分配”需采用可信 canonical remaining/授权聚合与可证本机变化；不能只遍历当前可见回款，因为其他账本的合法回款可能隐藏。剩余额证据不足时拒绝依赖该证据的资金修改，不将不可见关系当成不存在。

账户与业务日期遵守已有可编辑权限、账户种类/归档/开户日、精确时间与时区约束，不增加参考实现中未经合同要求的额外限制。合法修改按“撤回原分录、应用新分录”处理；原单改期使其净支出归属随原单移动，实际回款自己的账户、业务日、历史时刻保持。修改日期不凭最新估值汇率重写历史 reporting。切片 A 需同时对齐两端 ReferenceLedger、生产验证器及客户端旧“允许增额”回归。

退款或报销有独立的 Money、账户、业务日期、备注、标签、附件和 reporting。一个回款可以关联多笔有权源单，每项保留源币/到账币金额；不能混加不同币种裸整数。全部分配到账额加显式收入分量必须等于实际到账额。

保留现有口径：仅退款允许非零 `income_component_minor`，超额分量按到账期作为普通收入；报销超额拒绝。分配冲减使用原单 reporting 的累计比例舍入，源单的统计/预算两标记独立生效。原账面余额、资产估值与净支出继续分别由既有投影计算。

### 解除关联与原子操作

确认界面区分“撤销到账”与“保留到账、解除关联”：

- 删除整个回款，撤销其实际账户分录并恢复各源单的可分配额；不删除源单。
- 全部解除报销关联且保留现金，在同一个操作中把原回款转换为普通 `income`，清除分配、保持真实到账一次，并明确新的收入统计标记。不能留下正金额且空分配的 reimbursement。
- 部分解除退款可在同一记录中将解除部分转为显式收入分量，前提是仍满足既有 refund 守恒并经用户确认。
- 部分解除报销且保留现金，需要减少原报销金额/分配并生成独立 income；两记录的实际现金合计等于原回款，源单净额恢复对应部分。子 ID、日期、标签、图片和历史关联处理在预览中明确。
- 多记录方案通过专用生命周期 operation 提交；协议形状在切片 A/D 审定。它复用当前 11 类型及精确规则，不增加账务类型。冻结所有子 ID、原修订、授权 scope、正文和 operation_id；锁内重新检查权限、剩余、金额与所有引用，分录、实体、附件引用、变更投影和回执在一个服务端事务提交。
- 丢失成功响应后以相同 operation_id/正文重试应回同一结果。相同 ID 不同正文拒绝。失败不留下半个回款、income、余额变化或附件引用；未来复合队列必须纳入既有身份租约、冻结字节、冲突与恢复机制。
- 关联变更回执应保留受控的前后引用/结果，使用户能区分解除、删除与普通到账；历史读取逐次校验相关 scope，不借历史恢复失权正文。未实现专用服务的操作显示不可执行，保留草稿和原关联。

普通批量追踪/选择不需要财务复合语义；若远端逐条接收，界面仍须逐条说明确认状态。原单复制不带退款/报销关系；已有跨账本移动对回款/被关联原单的限制在本切片保持，不能顺手放开。

### 专用原子接口的待冻结建议

本节是供切片A/D落实的接口建议，**路径、能力标识和DTO尚未实现或发布**。建议以`receipt-restructure-v1`能力下的`POST /api/v1/receipts/restructures`承接封闭的业务动作，避免新增“任意operations数组”作为通用事务后门。

| 候选动作 | 必须冻结的业务意图 | 边界 |
|---|---|---|
| `detach_all_keep_cash` | 现有回款ID/scope/base_revision、完整income结果及明确解除的来源集合 | 可以优先映射为现有同UUID单次update；金额、入账账户和业务日期/精确时刻保持，allocations清空、income_component_minor归0；收入类别/flags/reporting必须显式合法，不能沿用不兼容的支出类别。显式复合中真正修改的源单另带base_revision；普通单次更新继续现行锁内关联校验。 |
| `split_unlinked_income` | 真正改动的回款/来源的期望修订、剩余分配、原回款最终金额、明确新income UUID与完整payload | 原回款`C→C-D`，新income为`D`，同一到账账户/币种/时刻的signed现金合计仍为C。不能自动生成子ID、丢剩余关联或创建零金额回款。只退款可另选同记录income_component方案；选择在确认前冻结。 |
| `revise_source` | 原单期望修订、明确最终Money/reporting；只有同时修改的回款才显式给ID/scope/base_revision及最终关系 | 同币同expense、`P' >= R+E`的金额修订是最小安全分支，不要求提交未变foreign回款的隐藏ID/revision。减到已分配额以下需同操作显式重构有权修改的相关回款，按最终图验证；没有完整授权方案时安全拒绝且不返回隐藏关系清单。type/币种变化或删除仍不得保留指向非expense/不同原币含义的旧分配，不能替用户猜跨币重写。 |

信封复用`operation_id/client_id/instance_id/sync_epoch`；每个真正修改的现有receipt/source均携带明确的`scope_id/base_revision`，确认时冻结所有新实体ID、完整子意图、分配双方金额、汇率、日期、类别、flags和附件处理。内部只读、未修改的foreign关系不是调用方的输入清单，不能为了锁住证据而要求暴露隐藏ID。动作不是另一次真实到账，不能重复给账户加整笔钱。离线队列须保存同一信封原字节，身份/epoch/client变更后保全待核对而不自动重放。

回执建议返回单一`commit_id`、实际修改的`scope_revisions`、有权参与实体revision映射与新建ID映射，不包含内部核验的未变foreign回款。现有`Applied`只表达一个entity，不能用它假称已经确认全部子结果。可评估复用`SyncReceipt`而不新增表，但摘要必须包含明确的operation_kind命名空间，避免与普通sync命令共用ID时误识别；响应schema与重放路径需闭合。`required_scope_ids`来自真正写资源及既定关联权限，不能把内部扫描/加锁的foreign关系全纳入调用方授权集合。当前鉴权及原回执的必要域权限先于缓存正文读取，失去任一真正必要域权限后不返回旧成功内容。

事务实现要求：

1. 先锁当前user/session，再稳定UUID锁真正写资源及既定关联需要的scope，随后稳定锁有关账单/账户行，最后合并排序附件UUID。锁后重新发现作用集合；集合变化整项重试，不逆序临时补锁。普通来源关联只要求其账本编辑权；确实修改源金额/账户/日期等资金事实时另需相关账户写权，不因共享editor获得他人私人资产权。来源聚合可依赖已有“所有分配写都锁源scope”的串行边界；若内部还需锁未变foreign回款，只用于验证证据，不因此touch它、要求调用方提供隐藏ID/修订、扩大授权集合或在回执返回它。
2. 核对每个真正修改的旧实体revision，内部读取的未变关系在锁内验证当前一致性；先构造全部最终关系图，再核对每源`0<=R+E<=P`、回款双方币种/金额守恒和冻结FX。不能简单循环调用现有`apply_command`：中间态可能超额而最终态合法，且会重复touch源单、难以表达统一结果。
3. 按最终图一次计算全部分录delta并落库，源单聚合变化不重复冲回其原账户；需要的实体、分录、余额、附件refs/孤儿状态、public及privatefinance投影和正式回执同事务。每个受影响实体revision一次，每个scope revision一次，以同commit发布。已有私有投影的修订/evidence兼容须覆盖，不把聚合变化误解释成第二笔资金。
4. 可先将一次复合限为最多20回款/20来源；确认实际事件总量不超过既有200事件上限，超限明确拒绝，不隐式拆成多个独立commit。金额溢出、权限/修订冲突、任一来源无证、附件未ready和回执写入失败均整项回滚；诊断失败不影响已提交结果。

例如CNY回款100.00原分配A60.00/B40.00，解除A中的20.00并保现金：原报销应变为80.00（A40.00/B40.00），新income20.00，总现金仍100.00，A的净支出恢复20.00，B不变。不得先减少关联后留下100.00的空缺报销，也不得先另入20.00再等待远端修改原记录。

## A–F 依赖与可派发边界

下表定义原始A–F依赖及接收目标，实际实施/通过范围以上方接收表和progress为准。全局前置为 P3-02、P4-01 接收；E11 的分期关联另在 P4-03/P4-04 联动接收，独立退款到账不等待 worker。

| 切片 | 前置 | 责任与独占边界 | 输入、具体任务与候选产物 | 接收证据/失败处理 |
|---|---|---|---|---|
| A 契约与兼容冻结 | P4-01 接收，G1–G3 审阅 | 契约/领域角色持共享 schema、迁移及黄金；客户端 UI 角色只读此部分 | 固定可选追踪、四项源单限制、account/date 规则、状态、解除语义、复合操作与能力识别。修订 `contracts/ledger-rules.md` 并形成候选 `contracts/refund-reimbursement-v1.md`；增量样本 `contracts/fixtures/ledger/refund-reimbursement.json`。列出旧客户端遇新能力的受控拒绝。 | T01/T02/T08 的精确预期可供两端消费；L02/L04 不改期望。合同未闭合不得并行自行扩 schema/统计。 |
| B 来源/回款读取与预览 | A；可先搭只读模型 | 客户端账务读角色持候选 `lib/data/ledger/ledger_receipts.dart`；涉及 LedgerProjection 由集成者串行处理 | 提供授权源单、当前可证剩余、实际回款历史、追踪列表/过滤和多源分配预览；绑定 space/client/epoch/permission/revision，确认前重新读取；证据不足、隐藏分量及本机未同步明确标识。 | T02/T05/T11/T12；DB/身份/授权变化后清旧视图。来源不可用拒绝选择，不把缺失当 0 或从私人 finance 补齐。 |
| C 追踪与回款用户主路径 | A/B；账户、附件、草稿可用 | 客户端 UI 角色持 `features/refunds/`、`features/reimbursements/` 及对应 tests；详情/Home/路由交集成者 | 从原单详情进入退款；专用页面标记待报销、查看部分/结清历史、多选源单分配到账；完整表单含账户/日期/币种/锁定汇率/备注/标签/附件。先同币单源，再多源/跨币；持久化完整草稿、稳定实体 ID，调用既有单笔 save/outbox，不另改余额列。 | T03/T04/T05/T09/T14。用户取消不生成到账；回包未确认不新建第二笔；附件未 ready 保留正式命令重试及原件。 |
| D 生命周期与远端复合事务 | A/B；单笔 C 可与其并行 | 服务端角色持专用生命周期服务/接口及 PG 测试；客户端复合队列由同步集成者独占 | 落实方案A普通源单限制、typed revise_source、回款修改/删除、全解绑转income及部分解绑拆income；单记录优先复用现有操作，确需多记录才进专用事务。输出候选 `server/src/flowtrace_server/reimbursements/`、闭合响应/回执及队列适配；是否需要迁移在复用回执可行性审查后决定，不默认新增表。 | T06–T10；真实 PG 故障注入、锁等待、重放。任一校验失败整笔复合回滚；协议未落前拒绝对应按钮，不拼成多次普通 push。 |
| E 并发、隐私、币种与恢复审查 | A，B/D 可用后增量审阅 | 独立审阅/测试角色只写独立目标；共享实现由各 owner 修复 | 两设备争抢剩余、来源与到账 scope 的授权差异、隐藏关联元数据、跨期/币种、冻结请求重试、离线多源依赖与恢复备份；复用 current canonical、tombstone proof 与既有 reporting，不另造净额统计。 | T10–T13，含真实双事务/双客户端结果；无权请求不回显 private ID；恢复换 epoch/client 只核对不自动重放旧复合。 |
| F 集成与分平台接收 | A–E 对应目标通过，正常 main 构建 | 集成者持共享入口/正常包；浏览器与最终设备角色串行使用工具 | 建立 `AI/modules/reimbursements.md` 并按实际代码核对根映射/导航；合并 DTO、测试、主路径，隔离 Chrome 走真实 UI；手机重连后再统一 Android、选图、进程终止恢复和正常 main 恢复。 | T01–T15 分层回执与失败证据齐全；服务端/Flutter 单测不能代替真实 UI，Chrome 不能代替 Android；只接受真实清理/退出结果。 |

建议并行批次：A 先冻结；B 与 D 的独占服务可并行，C 等 B 稳定接口后接入；E 随 B/D 独立审阅；F 最后集成。共享 `BillPayload`、OpenAPI、LedgerProjection、SyncStore、pub/锁、迁移和同一个测试运行窗口均指定唯一写入者，其他角色提交接口需求，不同时修改。

直接派发时附上：切片 ID、已冻结契约版本、可写路径、禁止触碰的共享路径、当前可运行隔离服务/fixture、前置回执、必跑目标、预期金额/授权变化、失败保留与清理方式、完成后的下一 owner。普通实现选择在既有授权内完成；范围/契约冲突先报集成者，不反复要求用户批准常规步骤。

### B补充：回款ACK与来源聚合的因果屏障（初始设计与实施差异）

本节以下保留开工前问题与设计依据。2026-10-22已实现`SyncStore.acknowledgeApplied`的完整正式响应重验、冻结来源绑定与ACK侧车、同scope BigInt门槛及`ReceiptReadRepository`授权/watch。独立审阅后两条读取边界先复现后修，ACK/读取70专项通过，另预览/应用lease50通过，均纳入完整722/5默认live跳过与完整分析通过。类型实现差异：没有opaque `VerifiedAppliedAck` token，Store的公开Map入口自行重验原冻结上下文/结果且同事务写，revision-only旧入口不生成证明。

旧Applied的补证采用真实只读`POST /api/v1/sync/receipts/lookup`，恰好一项原冻结push，只读取同用户/client/epoch的已有正式回执并重新检查原scope写权限；无回执不重执行、不续期设备。服务端445完整回归（含首批19新目标）、后补撤权secondary scope/会话2项、增强真实socket1分别通过，不重复累加成一次全量。实际OpenAPI42路径/114schema/48操作。未实现能力继续不advertise。

不完整before只有取得校验过的完整ACK向量，才可证明未列scope未受本操作影响；对已列候选source scope等正式checkpoint。完整binding指定source scope却不在向量仍为矛盾，缺ACK不能推断。hidden-preserve必须有严格金融不变证明及正式ACK，不能单信本机metadata声明。后续回款预览与页面确认仍须重新读取当前授权切面。

2026-10-22只读核对发现，B读取服务还缺一条持久化因果证明：回款自身已经`applied`或已取得其public canonical，不能单独证明另一source scope的旧`source_summary`已经包含这次到账、改关联或删除。本节只登记源码事实、候选设计与待验时序，未改同步存储/schema/服务端，也没有执行该时序的业务复现；不能把它写成B读层已实现或故障已修复。

**当前证据链：**

- 服务端[Applied响应](../../../server/src/flowtrace_server/sync/responses.py)包含`operation_id/entity_id/revision/commit_id/scope_revisions`；[writer](../../../server/src/flowtrace_server/sync/writer.py)将受影响来源投影和回款放在同一服务端commit。这里的entity revision与每个scope的提交计数是不同序列。
- [SyncEngine](../../../apps/flowtrace/lib/data/sync/sync_engine.dart)接收成功项时校验`commit_id`和`scope_revisions`，但随后只把operation ID和entity revision传给[SyncStore.acknowledge](../../../apps/flowtrace/lib/data/sync/sync_store.dart)。当前方法名是`acknowledge`；没有保存完整result scope checkpoint的`applyReceipt`接口。[StoredOperation](../../../apps/flowtrace/lib/data/local/app_database.dart)只有`appliedRevision`，尚无ACK向量/来源屏障字段。不能从该单一修订重建来源所需的scope高水位。
- `SyncStore.applyPullPage`将整页commit组原子应用，仅最终页把正式checkpoint写入`SyncStates.cursorsJson`；完整snapshot安装也原子写入manifest checkpoint。正常协议禁止把同一授权commit组拆成半组跨页，因此测试不得制造违反协议的“同组分页”来冒充HTTP复现。风险设计须覆盖ACK、单实体读取、不同拉取范围/轮次和最终游标尚未推进的中间状态，而非宣称现有正常完整pull必然拆散来源与回款。

**最小候选屏障：**

1. 在同步owner控制的持久化位置保存受控ACK证据，可评估版本化sidecar以避免立即加表，最终落点另行审定。每份证据绑定`space/instance/user/epoch/client/operation_id`、原冻结请求摘要、`commit_id`、回款entity revision、完整`scope_revisions`，并关联该操作影响的source ID及source scope。它不是新公开投影，不能写回旧raw/shadow/frozen请求或重算旧哈希；已有恢复备份、撤权清理和体积/生命周期边界须一并接入。
2. ACK向量、applied状态及原有影子处理在同一SQLite整体事务持久化，不能先显示已确认再补屏障。重放只接受同operation/冻结正文/身份的相同正式结果，`replayed`变化不改变证明；结果向量矛盾拒绝覆盖。屏障来源映射不得在每次重试时从当前用户输入重算。
3. 对每个受影响source，将`scope_revisions[source_scope]`保存为该操作的`required_cursor`。读取时，在同一`readSnapshot`核对当前身份、active状态、权限/撤权、源public canonical和正式`cursorsJson[source_scope]`。只有该scope当前游标达到此屏障，且源正文确为当前授权public投影、不是raw ACK/墓碑，才允许将该聚合用于当前进度。只比较**同source scope的scope checkpoint与scope cursor**，使用规范字符串/BigInt；绝不比较entity revision与scope revision，也不用本机墙钟/确认时间。
4. 同一source有多个操作时保留各自因果证据，可按同scope最大required cursor计算等待条件，但不能丢掉操作归属、原/新来源或身份绑定。正式final-page checkpoint与事件在同事务应用后即可解除已满足的等待；pull先于ACK时，ACK持久化后当场核对现有cursor即可，不要求多拉一轮。中间页即便已经看见相关public实体，也不擅自推进正式cursor或提前解除屏障。此条件证明本机已追到该次操作，不能冒称服务器此刻不存在后续更改。
5. 无有效ACK向量、来源映射不完整或source scope尚未追到时，当前进度显式`unavailable/awaiting_source_sync`；可单列上次确认快照与本机待同步意图，不能贴成“当前已报销/可继续分配”，也不能借private finance补证。缺少旧summary的R/E仍为unknown，与“正在等待来源同步”分开，不把暂态等待永久化。

**旧/新来源识别与baseDataJson限制：**

| 操作分支 | 可以使用的证据 | 读取/屏障要求 |
|---|---|---|
| create回款 | 冻结请求payload中的完整allocations，及同切面的已授权source public位置 | 绑定每个新source；不能只等回款scope或私人账户scope。 |
| update金额/换来源/转income | 已确认before allocations与冻结after allocations的并集；从A换B时两者都受影响 | 为被移除的A及新B分别设置屏障，重复source与多币金额仍由正式账务验证。不能仅遍历最终payload漏掉旧来源。 |
| delete回款 | delete payload为空，必须依赖可信before/原冻结前序链 | 所有旧来源都需恢复进度；回款墓碑到达本身不能解除source屏障。 |
| 同实体连续离线修改 | `predecessorId`、冻结请求及对应base revision提供链条；每次变化的真实before须可定位 | 在冻结点固定可证明的before/after映射。未发送时的最新本机正文不是较早操作的before，不能倒推覆盖原证据。 |
| hidden metadata preserve | 成功的`preserve_hidden_financial_links`元数据路径与严格金融不变证明 | 服务端该路径不重算分配、不touch来源；不要求恢复隐藏source ID或等待未修改的foreign scope。普通完整更新即使只改备注仍可能touch已知来源，若使用其ACK屏障则等待实际cursor即可。不能仅信客户端自称“metadata”而跳过金融比较/服务端结果。 |

`LocalRepository.saveEntityAndQueue`在入队时保存当前shadow的`baseDataJson`；`nextPush`首次冻结时会再取当时shadow更新它，已冻结重试不改。它可帮助读取**仍保留且完整的公开**旧allocations，但不是完整关联账本：foreign allocations可能已被public投影裁剪，`hidden_allocation_count>0`时无法枚举全部旧source；raw ACK也不是canonical，空base不证明无关联。撤权还会主动清掉`baseDataJson`。故它不能独自保证换源/delete的旧source集合完整，也不能把队列中任意一个历史base当成当前操作的before。

可行最小补充是在正式意图/冻结事务内保留当时已验证的受影响source集合与授权位置，随后用ACK向量绑定；不得增加读取失权正文的能力。对已存在且无法枚举旧来源的操作，若ACK向量可用，可采用显式`bindings_incomplete`的保守scope屏障：对结果向量中可能涉及来源的授权scope内候选源暂缓，待这些scope正式checkpoint追到后读取各自canonical，不伪造隐藏source ID。来源scope不在结果向量、当前无权或正文缺失时仍拒绝可选来源，不能默认required cursor为0。

历史applied记录未保存ACK向量时，不能从任意“同步过一次”推定证明已补齐。候选恢复路径由同步owner审定：在相同身份/epoch/client下，以原operation ID和冻结字节受控核对正式幂等回执，补齐向量；或以明确建立在已观察ACK之后、覆盖当前授权scope的全量新snapshot完成因果重建，并记录本轮snapshot与待核对操作集合的绑定。两者都需独立验证，不是当前已有行为。换epoch/client仅保留恢复备份，不自动跨身份重放；回执超期/授权不足则显示具体恢复原因并保留输入。有效证明到达后应能解除等待，不能设计成永久unknown。

**B屏障必须新增的时序矩阵（均待执行）：**

| 时序 | 必须断言 |
|---|---|
| ACK先、source scope尚未pull；先见回款单实体public而source仍旧 | 不以回款已applied/public revision解除等待；source正式cursor未达required时旧summary不可作为当前进度。 |
| 完整pull先、ACK后；同一ACK重放 | ACK到达即用已持久cursor判定，满足时直接可用；同ID/字节不新增屏障或重复金额，结果向量不一致拒绝。 |
| 来源/回款跨scope及不同合法拉取范围、先后到达 | 按各source自己的scope计数比较；不等待无权私人账户，不用回款scope替代来源scope。完整正常pull仍保持commit整组原子。 |
| 多页pull、相关完整组在非最终页、尾页网络失败后重开 | 中间页不推进正式cursor；屏障和已应用组重开保持，最终页确认后解除，不漏页、不重复应用。 |
| ACK事务故障、ACK后进程关闭、pull先落库后关闭 | applied与ACK证明同事务；重开能恢复同一结果，不能出现已applied但新屏障丢失的成功窗口。 |
| A换B、部分分配增减、多源、delete及连续前序链 | 旧/新来源并集均被约束，delete空payload仍约束旧source；达到各自checkpoint后R/E/A精确恢复。 |
| hidden-preserve metadata、旧base被裁剪/null/raw ACK、撤权先发生 | metadata不臆造隐藏关系；不完整映射走明确保守scope/恢复路径，撤权清受控引用并隐藏，未发送输入与原字节保留。 |
| 多操作共源、换epoch/client、旧记录缺ACK向量、回执重放/新snapshot恢复 | 同身份屏障可有限解除；跨身份不自动重放，缺证明有可执行的核对路径和具体错误，不永久unknown。 |
| entity revision很大但scope cursor仍落后；scope计数超过2^53 | 故意使用不同序列数值，禁止跨序列比较；BigInt精确判定同scope cursor门槛，不用墙钟或double。 |

上述目标补入B/E的SQLite、同步两序/分页、恢复及后续真实HTTP接收；纯`ReceiptSourceState`的69项读取测试仅验证传入数据形状与状态，不能代替这些授权/因果证明。

## T01–T15 候选验收矩阵

下列均为**待实施、待执行**，不是当前通过数量。金额若未注明均为 CNY，精确字符串最小单位由测试输入指定。

| ID | 场景与动作 | 必须断言的结果 | 目标层/证据 |
|---|---|---|---|
| T01 | 旧账单缺追踪字段；重开、拉取、快照、无关元数据编辑；新旧能力端互通 | 显示未追踪；旧 shadow/raw hash/已冻结请求原字节不变，不批量补修订；新字段仅正常显式操作进入。未知新操作不能被旧客户端误解释后重放。 | 两端序列化/共享夹具、SQLite、sync 契约 |
| T02 | 标记/取消待报销，含已有实际回款的旧记录 | 资产、分录、净支出、预算不变；实际到账历史保留；R/E 派生待报销/部分/结清及原因，退款结清不称已报销。 | 领域、Repository、列表 widget |
| T03 | 独立银行期初 1000.00，原单支出 100.00，再退 30.00、20.00 | 余额依次 900.00→930.00→950.00，原期净支出/可分配额 100.00→70.00→50.00；到账期普通收入 0。同一次退回重试不增加记录或现金。 | 新增补充黄金、真实 PG/SQLite、真实 UI |
| T04 | 原样消费 L02/L04，再追加多次到账/撤销 | L02 保留退 20.00、报 30.00/50.00、超额收入与删除拒绝的原期望；L04 原币和冻结汇率/累计舍入不变。100 退 30/20 是新增独立场景，不替换旧样本。 | 两端固定 JSON、生产 reporting 适配 |
| T05 | 多源一次回款，部分到账再结清；相同 source 重复、101 项与金额不匹配 | 每源独立剩余不负；单笔到账额等于所有分配到账额加允许的收入分量。100 项上限不放宽，重复/多项越界整笔拒绝；不能混加币种裸额。 | 严格 schema、Repository、PG、预览 widget |
| T06 | 全解绑报销但保留实际到账 | 同一记录原子转普通 income；原单净支出/剩余恢复，银行现金不变；收入按到账日期，来源历史/统计标记可核对。 | 领域、单操作 PG/SQLite、确认 UI |
| T07 | 部分解绑并拆普通 income；多记录处理中任一步故障、成功回包丢失 | 回款拆分总额等于原金额，无未归属现金；失败时实体/分录/附件引用/投影全回滚；成功重发原 operation_id 只产生同一组子记录，变正文同 ID 拒绝。 | 专用服务 PG 故障注入、真实双客户端、冻结队列 |
| T08 | 已分配源单实际改 type/currency/amount/delete；另改 account/date/note/tags；再用typed revise_source明确增额 | 四项普通修改拒绝，原单、回款、余额、净额及 outbox 无半变更。合法账户/日期修改只调整原分录/原单期间，回款自己的金额/账户/历史时刻不变；未变字段不误拦截。旧增额后的精确金额期望迁到复合修订，不删旧数值断言；修订冲突保持原图。 | 两端 Reference/生产校验、旧差异测试对齐、typed服务PG/SQLite |
| T09 | 改回款来源/金额/账户/日期，删除一个或多个回款 | 撤旧分录再加新分录，各原/新源剩余准确；删除恢复对应净额/现金，未选源和其他回款保留。ACK 先/实际 pull 先两序均不重复；真实 canonical tomb 到达后余额恢复，不永久 awaiting。 | Repository/PG、同步两序、独立 tomb 规则回归 |
| T10 | 源单剩余 50.00，两设备并发各申请 40.00；来源/到账位于不同 scope | 只有一个可成功，另一请求拒绝且无资金/附件/半条关联；实际锁顺序、二次校验与超时回滚可验证。并发修改源单/撤销回款也保持守恒。 | 真实 PG 双事务 barrier、双客户端 |
| T11 | 来源或到账账本撤权、仅 viewer、私人账户隐藏、先发后撤再授权、关联历史读取；源单存在不可见foreign回款 | 无权新写/重放拒绝；不泄漏private/foreign receipt ID或正文，页面/弹层/缓存隐藏旧内容；元数据修改保留隐藏关联。新source summary只返回与源revision绑定的R/E/剩余/原因，旧证据不足才显示细分不可用。仅改有权源单且不改foreign回款时，不要求提供隐藏ID/revision、不touch或返回该回款；真正修改它仍须完整授权/修订。 | 权限矩阵、PG投影/专用服务、SQLite/迟到请求、widget |
| T12 | 离线新源/多源到账、同单连续编辑、关闭重开；冲突/恢复换 epoch/client | 新源未确认时按实际依赖有序发送；多个依赖不能仅凭最后一个确认推断全部成功。稳定实体/operation ID 与冻结字节保持，失败不绕过复用；完整备份保全草稿/关联/原件，恢复后核对而不自动重放旧到账。 | SQLite、真实同步、恢复备份专项 |
| T13 | 跨月、统计/预算四组合、0/3 位币、超过 2^53、手工估值改变、多次 FX 分配 | 净额仍归原单期，现金按到账期；两个排除标记独立；只退款显式超额收入进到账期；精确到账/原币与累计比例舍入守恒，当前估值不改历史 reporting。 | 两端金额/报告、L02/L04、PG 与 UI 精确值 |
| T14 | 390 宽、1.8 字体、长金额/多源、草稿重开、真实图片、弹层时空间/权限变化 | 无布局异常，不截成误导金额；退出/失败保留完整草稿及原件；取消不入账；失权清屏且禁止旧预览确认。 | widget、真实隔离 Chrome；Android 图片另列 |
| T15 | 正常 main：追踪→多次退款→分次/多源报销→全/部分解绑→编辑删除→同步第二会话 | 实际 UI 录入/预览/确认，核对原/到账书详情、余额、净额/预算、历史与图片；HTTP 只辅助核对，不能替代按钮路径。新 scope 正常墓碑、测试会话退出，失败收据不覆盖。Android 重连后完成相同旅程与最终正常包恢复。 | 正常包真实 Chrome/服务端隔离库，最终 Android 独立回执 |

正式实现后的预定检查包括：Flutter 对应 `test/refunds`、`test/reimbursements` 及受影响的 ledger/domain/data 目标，服务端专用 pytest/PG 目标，契约夹具检查、实际 OpenAPI 导出和完整分析；确切命令由落地目录与隔离服务固定后写入运行记录。本轮没有运行这些命令，未来不存在的测试目录不能作为已通过依据。

## 原应用证据与接收边界

[证据矩阵](evidence-matrix.md)、[状态/特性映射](../../../contracts/fixtures/parity/README.md)与 V03 是对照依据：

- S12 观察到退款表单；本地 `work/qianji-research/27-refund-form.png/.xml` 证明表单状态，未证明退款已提交。
- 静态 `RefundPresenterImpl.submit` 可见原单 ID、修改回款 ID、金额、时间、到账账户、币种、备注、图片、标签请求字段。`frag_refund.xml` 提供原单区和回款表单结构。这些是 C 线索，不能从客户端代码推断钱迹服务端全部验证规则。
- 静态 `BxPresenterImpl` 可见待/已/全部列表、按原单关联分配、撤销与旧版本升级分支；`Bill`/`BillExtra` 可见源/到账记录及关联映射。原应用 type5/type20/type21 的编码不直接照搬 FlowTrace 的既定 11 类型。
- S51 只观察到旧数据升级提示；新报销列表、提交、撤销和升级结果仍未动态实测。流迹新库不制造此升级阻塞；真正导入旧数据的兼容说明由 P5-02 承接。
- V03 明确没有隔离原应用账号/设备，禁止用用户私人流水做升级/写入实验；现有未实测项不阻止按已登记 N 默认开发。P/R/E、跨期归属、超额分量与精确舍入保持 FlowTrace 已冻结默认，不能把实现结果写成钱迹实测。

本轮分册不含私人原始节点文本、账号或凭据。原始研究材料保持原位，不为编写计划重复截图或操作原应用。

## 交接与停止条件

下一动作是 P4-01 接收后，由契约 owner 完成 A 的兼容与生命周期协议审定，再把稳定输入派发 B/D。A–F 切片不改变总计划工作包数量与用户目标；实际开始/通过位置由协调者更新 progress 和任务日志。

遇到以下情况停止相关写入路径并报告具体差异：四项原单限制尚未统一；必要私人/来源权限或金额证据不足；需要多记录却没有远端原子服务；新字段会改旧 canonical hash/冻结请求；恢复租约不匹配；PG 锁/回滚、真实浏览器或平台环境不能验证。可以继续不依赖该阻碍的独立切片，不能用吞异常、清数据或修改黄金期望把失败改成通过。

剩余手机验收按用户约束统一最后；不使用用户 Edge/个人浏览器会话。Linux 验证仍按原环境边界延后。提交、推送、外部发布、生产部署状态由实际授权与执行记录单列，计划写入不代表这些操作已经发生。
