# 精确汇总投影 v1

日期：2026-10-21（Asia/Shanghai）。本契约实现 [账务规则](ledger-rules.md) 与 [金额时间](money-time.md)；跨期归属、隐藏资料处理和明细尾差分配为 FlowTrace 默认 N，不是钱迹运行实测。函数只计算已授权输入，不负责数据库读取、授权、同步完成判定或汇率获取。

## 入口与输入

Python：`domain.reporting.build_report(bills, query, *, category_parents=None, budget=None)`，输入为 `ReportBill`、`ReportQuery`、可选 `ReportBudget`。Dart：`domain/reporting/reporting.dart` 的 `buildReport(bills, query, {categoryParents, budget})`；两端字段名分别遵循 snake_case 与 camelCase，`toJson`/返回字典采用下述相同 JSON。

`ReportBill` 包含 `id`、规范账单 `payload`，以及独立于 payload 的 `remaining_allocatable_minor`（可空）、`allocations_complete`（默认 false）、`hidden_allocation_count`（默认 0）。这些是读取方提供的证据，不允许客户端伪造它们来授予服务器写入权限。Dart 构造与结果深复制 JSON，投影不修改调用者数据。

`ReportQuery` 明确指定账本 ID、报表币种/精度、`start_date` 和 `end_date_exclusive`；区间左闭右开。调用者传入该账本全部可见历史以及关联来源和跨期回款，不能先按本期过滤后再调用。函数自行按 `business_date` 选择本期源单；不读取设备时间或依据 `occurred_at` 重新解释历史日期。`month_at`/`monthAt` 复用固定月起始日规则，例如起始31、2026-02-10→2026-01-31至2026-02-28，2月28日→2月28日至3月31日。当前业务日应由调用者按账本时区取得。年报或自定义范围使用显式边界。

分类父子映射必须来自本账本可见的完整分类集合，包含归档但仍被历史账单引用的分类；函数检查环/异常深度。未提供映射表示平面汇总，不能把平面结果宣称为完整父类汇总。无分类统一键 `uncategorized`。分类名称/图标由已授权界面另行映射。

`ReportBudget` 需明确起止日期，与查询严格相等；`total_limit_minor` 可空、`category_limits` 为分类 ID→最小单位字符串。金额均为查询的报表币种；从同步 `BudgetPayload` 适配时先核对 Money 币种/精度，不能直接丢弃币种。

## 结果与不可用边界

结果固定包含 `version=1`、查询字段、`available`、有限错误码 `issues`、`allocation_breakdown_available`，以及以下投影。所有金额是带范围检查的有符号64位十进制字符串，计算只用 Python int/Dart BigInt，绝不转 double。

| 字段 | 含义 |
|---|---|
| `totals.income_minor/expense_minor/net_minor` | 主收支；净值=收入−支出 |
| `totals.budget_eligible_minor` | 独立预算标记后的净费用，尚未按预算分类筛选 |
| `totals.gross_expense_minor/allocated_expense_minor` | 进入主统计的源费用原报表额/累计冲减额；原额−冲减=净支出 |
| `totals.refund_minor/reimbursement_minor` | 进入主统计的源单退款/报销冲减分量；无法证明拆分时都为 null |
| `category_income_minor/category_expense_minor/budget_category_expense_minor` | 按账单直接分类，不重计父级；各自之和等于对应总额 |
| `category_income_rollup_minor/category_expense_rollup_minor/budget_category_rollup_minor` | 本分类与后代合计；父子同时存在，不能把整张 rollup 表再相加 |
| `calendar` | 稀疏业务日期→同结构 totals，包含源单日期的净额；无活动日期不制造记录 |
| `budget` | 未请求时 null，否则实际额度、占用、剩余及分类分组 |

无法证明任一必需净额、外币折算、分类结构/预算配置非法或聚合溢出时，`available=false`，全部金额投影为 null，返回固定原因码；不以部分数字或零冒充完整汇总。主要原因包括 `report.allocations_incomplete`、`report.source_unavailable`、`report.allocation_stale`、`report.category_cycle`、`fx.report_unavailable`、`fx.amount_mismatch`、`money.out_of_range` 及预算校验码。原因不包含来源单/私人账户 ID、正文或任意异常文本。

只有拆分明细不足而总净额可证明时，允许 `available=true`、`allocation_breakdown_available=false`，`issues=[report.allocation_detail_unavailable]`。这时原额、累计冲减、净额仍可展示；退款/报销分开金额均为 null，不能补零。

Dart 本地读取适配可用 `ReportResult.unavailable(query, issues)` 组合已知失败：有限本地码为 `report.scope_unavailable`、`report.sync_unavailable`、`report.local_conflict`、`report.budget_unavailable`，也接受既有领域有限码；未知或空原因统一为 `report.invalid_data`，去重排序，所有金额/分类/日历/预算为 null。该工厂不引入授权能力，也不能把任意异常/私人 ID 写入 issues；HTTP 服务只返回其闭合 schema 声明的服务端码集合。

## 退款、报销与权限投影

源费用 P 的累计分配 A 必须满足 0≤A≤P。全量模式只有调用者确知输入包含全部回款时才设 `allocations_complete=true`，从全部可见回款的 `source_amount_minor` 累计；日期在查询范围之外的回款仍冲减原单。

公开共享投影优先使用服务器 `remaining_allocatable_minor`，令 A=P−remaining，从而在不暴露其他账本来源 ID 的情况下证明净额。已显示的分配不得超过 A；若同时声明分配完整，必须恰好等于 A，否则 `report.allocation_stale`。没有可信 remaining 又未声明完整的源单直接不可用。公开回款的隐藏分配只计数，不进入输出；该计数存在时拆分明细保守标为不可用。

公开投影中可见 allocation 的来源应在同账本可读输入中；缺失来源返回 `report.source_unavailable`，不输出缺失 ID。调用者不可拿隐藏私人 finance 或 ReferenceLedger 内存状态填洞，也不能通过全库读取绕过账本授权。

remaining 必须对应当前输入状态。已有来源/回款存在本地待提交金融修改、删除或分配变动时，旧服务器 remaining 不是当前证据；调用者应保留不可用状态，或先在有完整来源证据的独立本地投影中证明净额后再调用。新建 revision0 源费用可以由已冻结且完整的本机创建意图证明，但不能把相同推断推广到已有共享源单。同步、恢复和角色变化后的剩余值不得无校验复用。

报表冲减为 `round_half_up(P_report×A/P_original)`，净额=`P_report−累计冲减`。已知回款拆分按 `(business_date, receipt_id)` 稳定排序，逐个用累计比例差额归属退款或报销；这是显示尾差的 N 默认，不改变原币回款/账户分录，不以设备时间裁决。全部冲减恰好回到0，输入排列顺序不影响结果。

回款自身不再次作为普通收入。只有 refund 的显式 `income_component_minor` 按回款日期进入收入；跨币种使用该回款冻结报表额按收入分量比例进行一次最终舍入。reimbursement 无超额收入能力。源单的两项排除标记分别决定主统计和预算，回款自己的标记不能绕过源单排除；额外收入分量使用回款自己的统计标记。

## 手续费、分类与预算

转账/借贷/信用卡还款本金不进入主收支或预算。嵌入 `fee` 只生成一个费用分量，日期沿用主记录，使用自己的 Money、reporting、分类和 flags；不再把主记录金额算成费用。生产 Fee 必须有 flags；仅兼容原黄金样本缺省时继承主 flags。折扣只使用 money 实付，不重复扣 discount。

外币只接受账单/手续费的冻结 reporting，校验报表币种/精度、固定 rate 与 report_amount 一致；不查当前估值汇率、不按其他账单汇率补全。主统计和预算均排除的费用不要求无关折算资料。跨币种转账本金不属于费用，也不为统计猜换算。

预算遵循三组合及两个混合分支：仅总额→全部预算合格净费用；仅分类→所设分类及后代；总额大于分类和→全部并给其他分类差额；等于分类和→仅预算分类；总额小于分类和拒绝 `budget.total_below_categories`。父子分类不能同时设预算，返回 `budget.overlapping_categories`。每笔费用最多一个预算分组；类别覆盖不会重复花费。剩余额可负以表示超支。不得用主收支排除代替预算排除。

## 验证与接入状态

纯 Python 与 Dart 实现独立于 reference ledger；目标测试直接重放黄金 L01–L04、L08 中已接受的 create/update/delete 输入，逐步比较现有期间/分类/预算期望，不执行 ReferenceLedger 生成期望。补充测试覆盖父类预算、源单日期日历、隐藏剩余额、缺来源不泄漏 ID、过期 remaining、分类环、溢出、缺汇率与稳定累计尾差。

纯域完成不代表客户端界面已验收；现有账户余额/净资产属于独立账户投影，不从本报表总净值反推。

## 服务端读取协议

`GET /api/v1/books/{book_id}/report?start_date=YYYY-MM-DD&end_date_exclusive=YYYY-MM-DD&budget_id=UUID`，budget_id 可省略。币种/精度由当前授权账本决定，不能通过查询参数改用临时汇率。响应闭合为 `{sync_epoch,scope_revision,permission_version,report}`，report 为上述投影；无缓存、nosniff。owner/editor/viewer 均可读；后台用途会话及陌生成员被拒绝，管理角色不赋予私人账本业务权限。

先结束早期认证 RC 读取，再在首条业务 SQL 前设置 REPEATABLE READ，按 user/session→稳定 UUID 的本人控制/账本 scope 锁复查当前权限；在同一快照读取全部有效账单、历史归档分类和预算，结果固化前再次复验。不存在缓存授权捷径。外账本回款只聚合已授权源单的累计 source_amount，不向结果传入回款 ID、正文或私人 finance。与 canonical public 剩余额规则核对；隐藏分配可能使拆分 null，但有证据的净额保留。

未传 budget_id 时只自动选取完全同区间的本账本有效预算：没有则 budget=null，多份则 `report.budget_ambiguous` 且 unavailable。显式 ID 若不属于当前账本/已删除返回404，区间或币种不符明确 unavailable。预算写入仍使用既有 sync entity 事务，不由读取接口创建配置。

单次读取最多50000个实体、8 MiB规范输入、1 MiB响应及10秒应用生成预算；超过返回安全413 `report_limit`，不返回部分统计。数据库 SQL/锁仍有独立超时及可安全重试的事务失败策略。已授权响应固化后才发生的撤权无法收回网络中已生成的响应；后续请求重新授权，不能把旧响应当作新的权限证明。
