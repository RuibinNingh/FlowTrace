# 服务端同步与账务事务

> - 职责：闭合输入、精确账务写入、幂等回执、当前权限投影、增量分页与快照。
> - 入口：`server/src/flowtrace_server/sync/router.py`、`service.py`、`book_move.py`；迁移 `0003_sync_transactions.py`。
> - 不变量：先重新鉴权后读回执；一项操作一个事务；分录、修订、变化、正式回执一起提交；不向共享域发布私人账户标识。
> - 必跑测试：`python -m pytest tests/test_sync_canonical.py tests/test_sync_schema.py tests/test_sync_input.py tests/sync tests/domain -q`，其中 `tests/sync` 必须连接明确的本机隔离 PostgreSQL。
> - 相关：[同步契约](../../contracts/sync-v1.md)、[原子移动](../../contracts/book-move-v1.md)、[管理补充](../../contracts/management-v1.md)、[账务规则](../../contracts/ledger-rules.md)、[服务端](server.md)、[领域参考](ledger.md)、[工作区边界](workspace.md)。

## 当前入口

2026-10-23group-sync-v1已挂普通main并真实协商，六操作及层级摘要见[共享契约](../../contracts/group-sync-v1.md)。纯33+实际PG20同次53/53（含50,001新增合成历史）、独立HTTP与相关58/58及认证offloop6/6为分次证据。生产SyncEngine真实TCP专项1/1已通过：201真实expense的三chunk publication在owner/viewer各丢一成功页后SQLite离线重开、同token恢复、整组唯一receipt/精确报表/私人权限/冻结outbox保持；两会话正常退出、无强制撤销、宿主关闭。stage仍test-only。旧增量多chunk guard及旧分页6/6通过，单可见commit/无关旧页保持原wire。容量、完整记录和私有整批冗余SHA边界见[实施分册](../plans/flowtrace/group-sync-implementation.md)，不将合成历史当金融性能。

2026-10-22数据迁移调用同一授权账务writer，新增仅内部导入使用的`historical_adjustment_minor`显式参数：bill/create/balance_adjustment且非零、绝对值与原money相等才能保留真实历史有符号分录和原target正文。普通sync请求没有该字段，也不传此参数，仍按原target/current余额验证；不扩展旧raw、回执或sync wire。实际JSON/XLSX历史调整往返与新book图片同批验证见[数据工具](data-tools.md)。

2026-10-22新增只读receipt lookup，完整服务端445项（含首批19个lookup目标）及后补secondary source/会话撤权2项、增强真实socket1分别通过；查询前后实体、分录、scope、回执、设备及会话数据保持。该查询不续期设备、不执行原命令，旧Applied补证禁止退回push。客户端ACK证明及BigInt屏障对应[客户端同步模块](client-sync.md)；实际OpenAPI为42路径/114schema/48操作，运行18080仍未升级。

P3 账本显示元数据包括 `display_mode=month|year|all`，缺省 month；旧 v1 更新省略时保留当前值。它和封面/模板等属性只存 SyncEntity JSON，不改变账务周期、余额或 Book 核心列。对应闭合输入、旧 JSON 默认及已物化页哈希兼容规则见[管理补充](../../contracts/management-v1.md)。

P4源码候选扩展账户 `prepaid/investment` 和分组、排序、归档、银行/服务商、期初日期、信用卡条款；新增字段省略保留，旧不可变页不注入默认。私人组只允许本人user域引用，共享account必须null。已有有效分录的账户禁止改变期初金额/日期/币种/精度/kind；资金更正走调账单，归档禁止新增引用、已有引用可维护，已知期初前的分录拒绝。两账户账单新增可选冻结 `transfer_fx`，精确匹配target_money，旧update省略保留/显式清除已有冻结值拒绝；move及preserve-hidden比较均覆盖该金融事实。完整字段与N事实边界见[资产契约](../../contracts/assets-v1.md)。

P4配置REST仍不增加第七类同步实体，也不把组ID塞depends_on；组获确认后才push引用账户。0006五张私有配置表不改写旧JSON/change/page。P4服务端完整411加独立RR2通过、独立wheel18085实际HTTP36通过，详见[服务端](server.md)；当前18080仍是P3的377固定包，不因源码head0006自动更新。

2026-10-22生产Flutter VM资产链在同一18085候选包 **1/1通过**：配置冻结重试、组确认账户同步、资金/估值独立、撤权/重新授权及四账单正常墓碑后有效分录/附件引用0、余额精确恢复。首轮真实失败来自客户端已拉取public/private墓碑与仅ACK状态识别不清，服务端本身已正常提交；主代理修删除proof后保持原断言通过，未重置/重建/补pull规避。回执和边界见[资产联测](../../tests/e2e/assets/README.md)。

以下路径由 `sync.router.router` 提供，随独立 Python 服务端安装。实际发布的请求与响应结构由服务端生成的 [OpenAPI](../../contracts/openapi.json) 为准。

| 方法与路径，前缀 `/api/v1/sync` | 行为 |
|---|---|
| GET `/scopes` | 当前用户控制版本、授权域/角色/权限版本、曾授权但现已撤销的域 ID、设备是否须重建；不包含失权账本正文 |
| POST `/push` | 六类实体的闭合领域命令，按请求顺序逐项独立提交 |
| POST `/receipts/lookup` | 单项原冻结push的只读回执核对；当前同用户/client/epoch与原scope写权限，缺失不重执行、不创建或续期设备；返回原Applied向量供因果追赶 |
| POST `/pull` | 在固定授权向量内物化不可变整 commit 分页，仅最终页含正式 checkpoint |
| POST `/snapshots` | 固定生成函数在请求事务中物化 ready 快照；不启动或声称存在异步 worker |
| GET `/snapshots/{snapshot_id}` | 绑定用户/设备/权限的状态与 ready 清单；过期不返回清单正文 |
| POST `/snapshots/{snapshot_id}/pages` | 校验身份、设备、epoch、当前权限和期限后返回物化页 |
| GET `/entities/{entity_type}/{entity_id}?scope_id=...` | 当前允许投影；主账本及全部财务引用可写时另给完整 `editable_payload`，否则为空；有读权且实际scope匹配的软删除只返回最小墓碑 |

同步继续复用 `authenticated_request` 的原生访问凭据和 Web Origin/CSRF 检查。后台 Cookie 不能当作记账主体。所有查询都按当前主体计算权限；UUID、scope 或页面 token 不是访问许可。

## 输入和摘要

### P4-02服务端追踪与来源聚合切片

2026-10-22源码候选已实现expense可选严格bool `reimbursement_tracking`。`schemas.bill_storage_payload`只为既有字段解释默认，单独保留新字段presence：旧expense更新省略时继承旧true/false或旧缺失；明确转非expense不继承，非expense显式携带任何值拒绝。原文哈希仍由`input.py`计算，缺省/false不合并。字段是expense metadata，preserve-hidden及同UUID move的金融指纹均排除它；其他类型的`nonfinancial_editable_fields`不宣告该字段。

`projections.allocated_by_type`在一致事务切面内按`source_amount_minor`分别累计有效refund/reimbursement。expense公开投影新增外层`source_summary`四个闭合字段，P=R+E+A、A等于remaining，使用源币而非回款币或超额收入；不返回foreign回款标识/时间/账户。回款原有来源集合锁与同commit `_touch(source)`复用，内部只读聚合不扩大required_scope_ids或touch未变foreign回款。客户端可读源单时可读该聚合，viewer仍不能写，后台不获得隐式读取权。

新投影和GET/push/pull/snapshot响应均使用精确field-set省略语义。旧JSON不回填追踪；新snapshot可生成summary，已物化旧页不补summary/false/null、不改canonical/hash。相关实现依据[Pydantic序列化](https://docs.pydantic.dev/latest/concepts/serialization/)与[FastAPI响应参数](https://fastapi.tiangolo.com/tutorial/response-model/#response-model-encoding-parameters)，实际最终wire另由生产路由测试证明。

这只是A的字段/聚合部分：普通linked-source旧增额行为和Reference额外account/date锁尚待D对齐，原允许增额精确回归未删除；`receipt-tracking-v1`与`receipt-restructure-v1`均未advertise，没有typed空路由或新迁移。真实字段已进入唯一OpenAPI导出41/113/47；18080仍原377/0005，P4-01固定185已完成精确正常清理并关闭，不能把源码候选视为已更新运行服务。

专库`flowtrace_test_receipts_local`从空public schema按原0006链升级，conftest要求test/loopback/flowtrace_test_*，私有runner再限定确切库/端口/owner；未重置assets/dev或旧fixture。新增`test_receipt_tracking.py`12项真实PG/生产ASGI通过，完整server425通过（66.21秒），随后新增`test_receipt_wire_socket.py`独占18086真实HTTP1项通过并正常删账单/退出/关端口。W08实际核对源revision2/3/4/5与新增/改/删回款同commit、原正文重放不重复touch或入账、原费用private finance仅1条；另有隐藏foreign、并发越额、提交前回滚、跨币/超额收入及旧物化页hash测试。合同21/21及Ruff通过；新wheel96资源逐字节核对，仅构建未安装/启动。脱敏证据`outputs/validation/P4/receipt-tracking-server-receipt.json`；客户端/Reference/UI/typed复合未执行。

后续仅schema元数据收窄：`source_summary: SourceSummary | SkipJsonSchema[None] = None`保留内部缺失sentinel及原runtime validator，生成的optional属性不再列null branch。真实模型33组接受/拒绝与序列化摘要不变，新增导出nonnull断言先失败后合同21通过；导出差异严格限一个属性。425与socket1保持为修正前等效runtime证据，本次未重跑PG/HTTP，当前新候选wheel及小回执见[服务端](server.md)。能力仍不声明，其他paths/迁移不变。

### 通用原始输入校验

`input.parse_push_body` 对原始 UTF-8 字节执行大小、重复键、整数、深度和 Unicode 检查，再运行闭合 Pydantic 模型，最后计算原始 operation 的摘要。不可用 `model_dump()` 的解释后默认值生成回执摘要。省略、显式 null、显式默认值保持不同摘要。

控制整数范围为 0 至 2³¹−1，协议版本必须是整数 1，布尔值和浮点数不能替代。拒绝 JSON 控制数 `-0`、float/NaN、非法代理码点和 PostgreSQL 文本/JSONB 不支持的 U+0000；对象键必须是 ASCII 协议名。金额、汇率、修订使用已固定的十进制字符串；金额与修订继续检查有符号 64 位上限。

时间使用 `YYYY-MM-DDTHH:mm:ss[.1至6位小数](Z|±HH:mm)` 的项目格式，拒绝紧凑日期、缺失偏移、偏移分钟 60 和无效公历日期。业务日期必须与精确时间的 IANA 日期一致，日期型记录可不提供精确时间。同步与领域使用相同的锁定 tzdata，不依赖主机时区数据库版本。

模型先检查不依赖数据库的约束：账单类型字段互斥、两账户转账、优惠金额、退款/报销回款守恒、折算结果、预算日期/非负额度/组合、重复 ID 与直接自环。资源存在性、币种目录、当前权限、账户类型、分类层级、累计剩余额和实体修订由写事务核对。

## 持久化与写事务

`0003` 建立设备状态、六类实体、精确账户分录、回执、不可变变化、pull 会话与物化页、快照与物化页，并给已有 `books` 增加 `deleted`。附件引用的唯一权威关系来自 `0004` 的 `attachment_refs`，不另造影子表。

`writer.push_operations` 每项先锁当前 user、session，再按 UUID 排序锁涉及的 scope，最后按 UUID 排序锁账户行。字段引用在锁前发现、锁后重新核对；涉及域变化时整体重试，不临时逆序补锁。权限撤销与成员版本变化共用 scope 锁，用户禁用与会话吊销共用身份锁。

幂等主键为 `(user_id, client_id, operation_id)`。同正文返回原正式回执，只有传输用的 `replayed` 改为 true；不同摘要拒绝为 `idempotency_mismatch`。在读取正式回执正文前还会重新检查原回执涉及的域。依赖操作必须是当前用户同一 client_id 已成功确认的 operation，或同批中已经成功的前项；后项依赖不能抢跑。

成功项原子完成实体、账户分录与余额、关联源单修订、各域修订、不可变 changes 和回执。修改与删除撤回旧分录后应用新值；余额、单笔与写回值检查溢出。拒绝不留账务变化，可保留有限的 rejected 回执锁定原始意图；附件尚未 ready、当前权限或认证失败不会伪记成成功。`revision_conflict` 可附当前授权投影，删除冲突不自动复活。

历史 balance_adjustment 的资金定义未变时，更新复用其旧 LedgerEntry 的 signed delta；只改备注、时间/日期或 flags 不重新用今天的余额解释历史目标。金额、目标余额、账户或类型显式变化才在扣除原分录后的基线上重新核算。新增独立 PostgreSQL 5项回归覆盖10000→支出1000→调账+500→收入1000的10500余额保持、删除撤回原+500、显式重算及拒绝后不变；无迁移或路由变更。

同一 commit 每个被影响域只增加一次 scope 修订，域内事件有稳定 `event_index`，合组最多 200 个事件。死锁、序列化失败、锁等待及唯一约束竞争至多尝试三次，始终沿用原操作 ID 与摘要。SQL 语句超时 10 秒，行锁等待上限 3 秒；失败返回安全的服务错误。

单项请求拒绝使用标准 HTTP 错误，例如幂等/修订冲突为 409；多项批次返回 200 和逐项结果，前项已提交不会被后项失败回滚。诊断事件只在实际事务结束后尽力写入，不含正文或凭据；诊断失败不能反推正式回执失败。

## 六类领域行为

| 实体 | 当前事务约束 |
|---|---|
| book | 从本人 user scope 新建；设置和删除要求 owner；显示元数据存同步 JSON，核心四列同步 Book ORM；运行中新建均为 revision 1 与首事件；旧迁移对象为 revision 0 快照基线 |
| account | 私人账户仅本人 user scope；共享账户在账本域授权；期初余额和实时余额精确保存，已使用账户的币种/类型不得偷偷改变 |
| category | 同账本、同收入/支出类型、最多两级；排序/归档；层级移动不能使既有预算父子重叠；禁止自环、无权引用与仍被使用的删除 |
| tag | 同账本普通标签/根分组，支持排序/归档/恢复；分组不能被账单引用或嵌套；非空组明确拒删，使用中的标签禁止转组或删除 |
| bill | 收入、支出、转账、信用卡还款、四种借贷、退款/报销、余额调整；严格验证账户类型/币种、实际成交额、手续费、优惠和关联源单；按真实账户腿写有符号分录 |
| budget | 有效日期区间、受控币种、非负总额/分类额度、分类权限和父子覆盖冲突；总额小于分类和拒绝 |

本阶段服务端目录使用 15 种受控币种及精度；未知币种明确拒绝，不能默认当两位小数。完整币种目录和高级统计界面继续按 P3/P4 接收，不能据本模块的分录测试宣称全套统计、分期/周期 worker 或存钱计划已发布。

退款分配验证源单为有权限的有效支出，关联写需要源账本编辑权；跨币种同时验证双方金额与冻结汇率，累计分配不能超过实付。源单剩余额变化产生该域的新投影。账单删除撤销对应分录和附件引用；被回款关联的原支出不能直接删。历史折算与当前资产估值仍分开，统计口径见领域契约。

读取软删除实体时，当前有读权且实际scope一致才给event.deleted=true/data=null/editable_payload=null，便于明确接受服务器删除；没有旧备注、账户或图片正文。已移动账单的来源scope即使仍有读权，也不是当前实际scope，继续404；陌生/失权请求继续403。新真实PG/HTTP两项覆盖owner/viewer、匿名、陌生、撤权和移后删除。

账本目前只允许空账本软删除；有有效分类、标签、预算、账户或账单返回 `book_not_empty`。不会为删除共享账本而批量撤销他人的私人账户分录。成员收到本人控制域中只含对象 ID 的 book 墓碑，当前 REST 列表和权限服务排除已删除账本。

`service.initialize_book_sync(session, book)` 供注册默认账本、REST 建账本和同步建账本共用。前置是 Book、成员、user/book scope 已 flush，helper 不提交调用者事务。同步调用内部的 `emit_change=False` 后，由同一 operation 写唯一 commit 与 receipt；不能额外生成第二份初始化事件。

## 同 UUID 跨账本移动

Operation 的可选 `move` 进入独立 bill/update 分支，来源 scope 与明确目标 book_id 保留在冻结正文中。当前分支只允许两个账本均可编辑、所有资金引用属于本人、报表币相同且没有退款/报销关系的移动。资金、历史时间、原 LedgerEntry UUID 和 signed amount 保持；分录只换 book_id，不重算历史调账或修改账户余额。分类、标签与手续费分类使用明确目标引用，拒绝来源、归档或分组 ID。

所有源/目标图片先经既有 HTTP 上传得到不同 UUID 的 ready 对象，移动检查原顺序映射及 hash/大小/类型，合并排序锁附件后原子替换 refs。来源原件、scope 和其他账单引用不变。图片未 ready 返回无正式拒绝回执的409，完成准备后同一冻结操作可重试。GC 先获得删除声明时拒绝绑定；移动先提交时 GC 复查新 refs 与孤儿状态而保留图片。

同一事务增加一次账单 revision，在来源发布墓碑、目标发布 public、本人 user scope 发布最小 private finance。各 scope 修订独立，事件的账单 revision 相同；服务器当前实体只有目标一份，来源-only 快照与直接读取不能取得目标内容。缓存回执先读取内部 required_scope_ids 并在这些域加锁/重新授权，然后才读正文与摘要；成功移动后精确重放仍幂等，任一必需账本失权后拒绝旧成功回执。

新增 `tests/test_book_move_schema.py` 与 `tests/sync/test_book_move.py` 覆盖闭合输入、丢响应/并发相同重放、双域撤权、私人资金、历史调账、fee 三分录、反向跨用户竞争、GC 双序、图片映射/内容/越权、正式回执数据库拒绝时整事务回滚，以及完整快照/增量的来源隔离。服务端能力声明为 bill-move-v1；客户端 ACK/pull 双序和旧待传冲突未验收前保持移动入口关闭。协议细节只在上方原子移动契约维护。

## 配置管理与旧版本兼容

P3-01 新增 book 的 template/icon/cover_color/show_assets、category 的 archived、tag 的 kind/group_id/archived/sort_order，闭合字段、缺省和客户端批量约定见[管理补充](../../contracts/management-v1.md)。分组继续属于 tag 实体，owner/editor 均可管理；账本设置仍只允许 owner。资产入口显示不授予私人账户权限。

当前旧 JSON 在投影中解释默认，不自动写新修订。旧客户端 update 省略新增字段会保留现值，显式值才改变设置。归档父分类/分组对子项的选择性生效，但不批量改写子项；原账单/预算可保留原有已归档引用，新引用拒绝。排序、归档或层级转换不修改账务分录；会使现有预算重叠的分类移动拒绝。

模板标识不触发服务端隐式复制。客户端仅将账本元数据与分类/标签配置展开为新 UUID 命令，映射父子/组关系；不复制账户、余额、流水、预算、成员或附件。服务端保持每项独立事务与部分失败结果，客户端整体本地保存能力须另验。

新增字段不回填旧不可变 changes/pull 页/快照页。pull 与快照页响应排除未设置字段，避免响应模型把新默认注入旧 items 而破坏已发布哈希；新当前投影先显式补齐默认再计算快照哈希。无需修改已冻结 0003–0005 迁移。

`tests/sync/test_management.py` 的 13 项在独立 PostgreSQL 通过，涵盖管理字段兼容、当前角色、组内引用/归档、分类转换及预算保护、含手续费账单保留归档引用、批次部分失败、只复制配置与旧物化页 HTTP 哈希。模板目录、图标检索界面、客户端批量本地原子保存和 Android 完整录入仍由 P3 客户端独立验收。

## 共享账单的两种闭合投影

事件 `entity_type` 始终是六种之一；账单投影通过 `data.projection_kind` 区分，不新增第七种 push 实体。

| projection_kind | 允许内容 |
|---|---|
| `bill_public` | 账本可见正文；私人账户 ID 替换为空，标出隐藏字段与付款用户；跨账本源单分配 ID/源币明细被裁剪，给出隐藏计数；列出不触及资金的可编辑字段 |
| `bill_private_finance` | 该账户所有者的必要账户链接、本人账户分录、类型和日期；不含共享备注、分类、标签、附件和对方账户 ID |

个人域快照使用最后一个不可变财务事件；后续共享备注修改不会偷偷更新个人域副本。成员被撤后，个人域仍能核对自己账户的必要历史分录，但不能借此取回共享正文。

普通完整 update 继续要求完整领域输入。仅 update 可使用 `preserve_hidden_financial_links:true`：请求需提交当前公开 payload，只能改变 note、category_id、tag_ids、attachment_ids、flags。服务器逐字段核对其余公开资金数据，合并原内部隐藏链接，再验证完整领域输入与允许的新引用；不重新入账或改变账户曲线。改金额、日期、类型、币种、账户或分配不能借此绕过权限。

完整可编辑数据从当前授权实体读取得到，不能要求客户端永久保留首次 outbox。主账本和全部私人账户/分配源域都满足当前权限时才返回 `editable_payload`；其余情况仅返回允许投影，或安全拒绝。客户端按 scope 与投影保存两部分，不能用 private finance 覆盖公开账单，也不能把公开裁剪字段误当作清空账户指令。

## Pull 与快照

首轮 pull 使用一致的 PostgreSQL REPEATABLE READ 快照取得所有授权域高水位。读事务只锁读取者自己的控制域来稳定成员权限，避免因锁住别人的业务域而阻塞在未提交修订上。写者持有未提交 41 时，独立授权读者仍可看见已提交 40；后续按域顺序得到 41/42。

拉取会话绑定用户、client_id、epoch、控制版本、全部所选权限版本及原 cursors/limit，15 分钟过期。后续 token 只找服务器物化页；不能自报新的高水位。变化按每域顺序构建 commit 先后图，无关 commit 用稳定 UUID 顺序；同 commit 的全部当前授权事件整组分页。任意游标向量若截到半组，会补齐授权部分的重复事件，客户端按事件去重。只有最终页返回 checkpoint。

快照同步物化固定 ready 产物，manifest 包含 snapshot_id、instance_id、sync_epoch、checkpoint、permission_versions 和连续从 0 开始的页清单。每页至多 200 项，`page_sha256 = SHA256(canonical(items))`；`manifest_sha256 = SHA256(canonical(manifest))`，摘要不自包含。每次状态读取和页下载都重新检查当前权限。页面冻结，生成后新写入不改变它们，由安装后增量追赶。

pull 最多物化 50000 个事件、1000 页；snapshot 最多 200000 项、1000 页；物化预算 10 秒，产物下载期限 15 分钟。超限或失败原子返回，不能给出残缺 checkpoint 或清单；客户端须在独立暂存缓存验证全部页和摘要后才能切换。这里没有宣称已完成异步快照任务进程。

设备窗口为 90 天；过期、冻结或旧 epoch 设备拒写。受控恢复需要完整本地备份、重新认证的新 client_id 和已验证快照，不能改旧操作正文后自动重放。当前没有回执/墓碑清理任务，保留时间不会短于设备窗口；未来清理须另实现可证明安全的游标下界，不能直接删回执使旧操作再次入账。客户端恢复行为与实际平台边界由[工作区说明](workspace.md)和客户端模块记录。

## 验证证据

P3同UUID移动补充14项输入、26项真实PG/HTTP移动与2项当前墓碑读取专项，连全服务377/377通过；独立生产wheel实际HTTP15项通过。主代理已显式把自持18080升级至同一377非editable包，ready200、实际OpenAPI29/78/31、bill-move-v1且部署instance/epoch不变；先前335上的浏览器结果仍是历史证据。

新增独立18084/专库的Flutter VM生产移动服务真实HTTP **1/1通过**：双方editor和本人账户的支出125分准备2个不同hash的目标ready原图，同plan复按不增加operation；真正提交后丢弃一次回复，重试保持相同冻结正文且只一份正式receipt；两个磁盘SQLite客户端一致得到同UUID目标revision2、账户9875、来源报表0/目标125，来源-only viewer保留无正文删除墓碑且不能GET目标。另一个25分账单准备后被撤来源权限，确认拒绝、未入队或移动，受控下载缓存实删，用户本机原件和草稿保留，账户最终9850。目标尚缺canonical时本机报表明确不可用，不伪造影子。Python另以真实SQL核对refs/金额/回执与会话退出，专线程结束且18084无监听；此联测不操作18080。详细命令和三次夹具修正见[真实联测](../../tests/e2e/sync/README.md)，结果不能替代移动页面及真机验收。

2026-10-21 在 Windows/Python 3.12 与本机 PostgreSQL 18.6 的独立合成库 `flowtrace_test_sync_local` 验证本模块。运行测试前必须明确设置 `FLOWTRACE_ENVIRONMENT=test` 与受隔离守卫允许的 `FLOWTRACE_TEST_DATABASE_URL`；测试不读真实账目，不以 SQLite 替代 PostgreSQL。

| 输入/夹具 | 实际覆盖与边界 |
|---|---|
| 发布的 canonical-operation | 原始摘要保持不变；顺序、UTF-8、64 位金额与省略/null/默认差异均校验 |
| SYN01/02 | 丢响应重试；并发同键一笔；同键不同 hash 只有一者入账；HTTP 409 |
| SYN03/04 | 改改、改删冲突与当前授权投影；删除不复活；修改/删除精确撤旧分录 |
| SYN05 | 两连接持锁与等待，第三授权读者看到 40，释放后连续得到 41/42 |
| SYN06 | 撤权后回执重放、旧 pull 页与快照下载被拒，不返回旧正文 |
| SYN07/08 | 服务端设备过期/epoch 拒写；完整本地备份与安装仍需客户端和真实平台联合验收 |
| SYN09 | 属于客户端本地影子/outbox/ACK 验收，本服务端测试不冒称覆盖 |
| SYN10 | 私人/共享账户跨域转账整组，页阈值不拆分；公开投影无私人账户 ID |
| SYN11/12 | 失败依赖无账务写入，猜他人账户安全 404，跨域附件安全拒绝 |
| 额外边界 | 六类实体、信用卡/债务/手续费/余额调整、多币种回款、202 项两页快照、真实附件创建/更新/删除、正式回执 DB 失败全回滚、诊断失败仍成功 |

精确计数、实际命令、全套回归和联调结果由[本轮开发记录](../logs/2026-10-21_develop-flowtrace.md)汇总。现有 SYN 文件保留原始设计证据状态，测试结果独立记录；测试夹具本身不是执行证明。没有在本模块任务中执行 Linux 部署、真实 Android/Web/Windows 双端同步或完整应用账务验收。
