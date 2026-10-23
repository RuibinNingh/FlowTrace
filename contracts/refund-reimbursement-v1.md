# 退款、报销追踪与关联维护 v1

日期：2026-10-22，Asia/Shanghai。规则是FlowTrace明确默认N，不代表钱迹服务端算法。首批契约已冻结；**服务端追踪字段与权威聚合已实施并独立验证，关联原单方案A生产/Reference对齐、能力声明及客户端仍待后续切片**。实际接口仍只取[真实OpenAPI](openapi.json)，不改写[P0设计基线](openapi-p0.json)伪造实现。总规则见[账务](ledger-rules.md)、[金额时间](money-time.md)、[权限](permissions.md)、[同步](sync-v1.md)；完整实施切片见[计划](../AI/plans/flowtrace/p4-02-implementation.md)。

## 能力与当前交付边界

| 能力 | 冻结语义 | 本轮状态 |
|---|---|---|
| `receipt-tracking-v1` | expense可选追踪；最小权威source summary；方案A关联原单普通修改边界 | 仅服务端字段/聚合已验；关联维护对齐及客户端未完成，仍不advertise |
| `receipt-restructure-v1` | typed `revise_source`、部分解绑拆income及多回款原子重构 | 未来独立能力；路径/完整DTO尚未冻结、未实现，不在实际OpenAPI放空路由 |

客户端未收到当前部署/身份对应的`receipt-tracking-v1`时，不能向旧服务发送新字段；不能把字段塞入flags或备注替代正式契约。能力不等于客户端页面已经交付。普通同步的多项operation继续逐项提交，本机SQLite `saveBatch`原子性不能代表远端全成全败。

## 可选追踪字段

`BillPayload.reimbursement_tracking`仅expense可携带，为可选严格boolean。expense显式true/false有效；显式null、数字、字符串、数组和对象拒绝。非expense无论显式true或false都拒绝，null同样拒绝。

- 缺失仅在显示语义上视为false；不回填旧raw/payload、shadow、冻结outbox、不可变changes或物化分页。
- 同expense的旧update省略字段时，保存旧显式值或旧缺失状态；不能由模型默认false把旧true清掉或把旧缺失补出。
- 合法且明确的expense→非expense类型变更不继承追踪字段，调用者构造的新payload必须去除它。已关联源单的普通类型变更仍按方案A拒绝，不能借此取消关系。
- 标记/取消追踪不改账户余额、分录、应收、收支或预算；实际报销历史不因取消追踪删除。追踪与实际回款进度分别展示。
- 此字段属于本单允许的metadata，需纳入严格允许字段并排除金融指纹；其他隐藏金融事实仍精确保留。共享editor不因此获得他人私人账户权，viewer不能写。

## 无标识权威来源聚合

仅expense的`BillPublic`外层可携带`source_summary`；非expense省略。该字段不是客户端可写BillPayload，也不写回原始账单JSON。形状如下，字段闭合：

字段可省略，显式null拒绝。实际OpenAPI采用optional且nonnull的`SourceSummary`引用；内部None只作旧字段缺失sentinel，不改变原校验或最终wire省略语义。

```json
{"refund_source_minor":"3000","reimbursement_source_minor":"2000","remaining_source_minor":"5000","settlement_reason":"open"}
```

三个金额均为非负canonical十进制整数字符串，使用源expense币种/精度，范围沿用有符号64位上限；不能用到账币裸整数相加。P是源单实际支付额且严格大于0，R/E是有效refund/reimbursement的`source_amount_minor`累计，A是剩余：

`P = R + E + A`，且`A = remaining_allocatable_minor`。

| 条件 | settlement_reason |
|---|---|
| A>0 | `open` |
| A=0且E=0 | `refunded` |
| A=0且R=0 | `reimbursed` |
| A=0且R>0且E>0 | `mixed` |

expense的PositiveMoney已经拒绝P=0，因此不存在R=E=A=0时在多个结清原因中任选的问题；账户余额/预算允许零不改变它。P/R/E/A任一不守恒、旧remaining不一致或reason不符不能作为有效权威summary。

可读源单者可读取本单聚合，包含不可见foreign回款对该源的累计贡献；只暴露以上四字段，不提供回款/其他账本ID、账户、日期、备注或隐藏关系列表。服务端内部读取/锁定未变foreign关系，不授予调用方对应资源权限、不touch其revision，也不把它们返回或无条件纳入回执required_scope_ids。真正修改的实体仍须完整权限。

summary与外层源单revision及同一一致数据切面绑定，不单独当作永远有效的缓存。回款新增/修改/删除、关联解除时，源revision、summary与变化在同commit更新。历史旧canonical缺summary表示R/E拆分未知，不解释成R=E=0；可信旧remaining仍可支持净额。客户端只在同一当前授权/修订切面有完整可证数据时作本机增量，不借私人finance填隐藏关系。

新snapshot页可使用新投影；旧已物化pull/snapshot页保留原JSON和SHA，不注入false、null或summary后重算。缺失与显式值的原始输入哈希继续不同。

不能只在数据库JSON中验证缺失状态：投影经过`BillPublic`/`PublicBillFields`模型，FastAPI还会再次序列化嵌套响应，新增optional默认值可能在任一处被补成false/null。实现逐层保留field-set并使用`exclude_unset`，同时验证真实create回执、GET的公开/可编辑payload、pull与snapshot的最终响应；非expense不能被补出tracking或`source_summary:null`。固定样本W01–W08定义这些真实HTTP/PG验收，后端实际证据见末节；模型序列化单测不能替代它们。

## 已关联原单的方案A

存在有效分配时，普通update实际改变bill_type或Money币种/精度/金额，或者delete，拒绝`bill.has_allocations`。增额或仍高于R+E的减额也拒绝。比较实际前后值，重复提交同值Money并改备注不能被误拦；结构/格式/schema错误可在领域边界检查前按原安全校验拒绝。

账户、业务日期/时区/精确时刻、类别、标签、flags及追踪不因关联额外禁用。它们仍执行原有授权、归档/开户日、时间一致性、类别与冻结reporting规则；合法改账户只撤销/重记原单分录，改期只移动源单净额/预算归属。既有回款自己的金额、入账账户和历史时刻保持。

两端Reference须从“changes包含某键即拒绝”改为比较实际受限值，并移除其额外account/date锁。旧允许普通增额的实现回归保留原精确数值，迁到未来typed修订验证；同时新增普通路径拒绝断言。旧L02/L04不改输入与期望。实现尚未对齐前不得宣称本方案已在运行服务生效。

## 未来复合能力边界

整笔回款全部解绑、保现金，可采用同UUID单次update转换为income：清allocations、income_component_minor归0，金额、入账账户及真实到账日期/精确时刻保持，income类别/flags/reporting显式合法。仍要求现行关联域与资金授权。

部分reimbursement解绑并保现金需专用事务：原回款C→C−D，新冻结UUID的income为D，同账户/币种/时刻现金总和仍C；不得创建零额报销。refund可显式选择同记录income_component，若选拆income也必须同事务。多个回款、源单联动同样不能用普通多项push拼接。

typed `revise_source`的最小安全分支为保持expense及源币种/精度、明确改P且P'>=内部当前R+E。调用方只提供真正修改源单的scope/base_revision和明确最终Money/reporting，不索要隐藏、未变foreign回款ID/revision。低于已分配额的更正，必须另有完整授权且显式冻结的回款重构，否则安全拒绝，不返回隐藏关系列表。type/币种变更或删除不能保留含义已失效的旧分配。

未来动作信封需冻结operation_id/client_id/instance_id/epoch、真正修改实体的scope/base_revision、全部新ID和完整子意图。按身份→稳定scope→有关实体/账户→附件锁顺序，在锁内按全部最终关系验证并同commit写实体、分录、余额、refs、来源汇总、投影和正式回执；不以循环独立apply_command模拟原子重构。回执重放先核对当前必要权限，内部证据锁不扩大调用方权限。未实现时不能advertise该能力或把未来DTO塞入实际OpenAPI。

## 固定样本与验证状态

新增[refund-reimbursement.json](fixtures/ledger/refund-reimbursement.json)为契约1.1的独立增量，包含16个严格追踪输入、6个省略保留向量、17个来源聚合向量、12个关联维护向量、账户/日期变更及18步生命周期。关联维护包括R+E<P及R+E=P完全结清时的同值允许/金额改变拒绝。逐步给出原币余额、源revision/summary、统计、预算与净资产期望；包括多次退款/报销、取消追踪、重放/拒绝、逆向正常删除。另固定旧pull/snapshot合成页的canonical UTF-8和SHA，保留1.0的L02/L04摘要；不替换原8场景57步。

[契约测试](../tests/contracts/test_receipt_tracking_contract.py)单独遍历`openapi.json`实际导出的引用与operation IDs、检查共享模型闭合及金额字符串；旧P0测试继续保留。样本自洽检查与真实旧分页模型序列化可立即执行。新追踪输入、source summary、公有省略与导出一致性四项模型检查在真实字段尚未加入时明确skip，不能据此声称新能力通过；未来typed修订样本只验其设计算术，不调用未实现命令。

前置合同阶段21项为17通过/4新模型未实现skip，该历史回执保留。后续真实模型接入后合同21/21通过，源码实际导出为41路径/113schema/47操作。独立`flowtrace_test_receipts_local`的服务端完整425通过，其中新增12项PG/生产ASGI验证W01–W08的追踪/聚合部分；随后独占loopback18086的真实socket HTTP1项通过，正常墓碑和退出会话后端口关闭。旧物化页对象/canonical hash不变、foreign聚合无标识、源修订同commit、回放不重复touch/入账及两外域并发回款均有实际测试。

固定JSON只保存设计输入/期望及创建时的证据边界，不充当动态验收进度；最新执行记录在服务端/同步模块及`outputs/validation/P4/receipt-tracking-server-receipt.json`。本轮没有Flutter/UI、Reference变更、typed复合、能力发布或运行服务升级；未实现能力继续按[实施计划](../AI/plans/flowtrace/p4-02-implementation.md)推进。
