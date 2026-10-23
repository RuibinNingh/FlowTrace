# 可跨 Dart/Python 消费的账务黄金样本

基线版本：1.0，日期2026-10-21；退款报销独立增量1.1，日期2026-10-22。输入全部合成，无真实账号、账单或密钥；所有场景的期望为 FlowTrace 契约，不代表钱迹实测。行为依据与 N/C/G 强度见 [账务规则](../../ledger-rules.md)。

| 文件 | 内容 |
|---|---|
| [scenarios.json](scenarios.json) | 8 场景、57 步：基本收支/独立标记/维护/优惠，退款报销跨期及超额，信用卡债务，汇率，分期提前结清/幂等，月末周期，存钱，三预算模式 |
| [money-time-vectors.json](money-time-vectors.json) | 格式/范围/币种精度、汇率舍入、末期尾差、账本周期、月末闰年、时区和七种存钱模式 |
| [permissions.json](permissions.json) | 84 个允许/拒绝案例及共享账单私人账户字段投影 |
| [refund-reimbursement.json](refund-reimbursement.json) | 独立契约1.1增量：追踪16、保留6、summary17、关联维护12（含完全结清）、18步退款/报销生命周期；旧分页canonical/SHA与L02/L04摘要、未来typed修订和wire验收定义 |
| [validate.py](validate.py) | 标准库校验夹具结构、金额、预期内部算术和拒绝/重试不变性；不是业务实现通过证明 |

在仓库根目录执行 `python contracts/fixtures/ledger/validate.py`。真正的 Python/Dart 实现应各自加载原 JSON、按顺序执行 command、将计算结果与 expected 比较，不调用此检查器生成预期，也不能各自修改夹具来迎合实现。

## 消费协议

每场景独立空状态，`setup` 包含期初账户、报表币、固定估值汇率、左闭右开报表查询区间及预算配置。所有 ID 是领域夹具别名；适配真实 API/数据库时使用固定命名空间 UUIDv5 确定性映射，引用同步映射；这些别名不是 API 允许非 UUID 的声明。时间为空的测试输入使用 fixture 的 business_date，不读取运行机器“今天”。

每步 `command.action` 是领域动作，不是宣称 HTTP 路由已实现。`create_bill.bill.money` 与正式金额对象同形；本金双账户动作使用 from_account_id/to_account_id；借贷应付/应收账户方向见规则表。创建计划/发生/结清使用相应专用领域入口，`execute_occurrence` 的费用继承 plan 分类；夹具计划不产生未给出的隐藏消费。

每步 `expected.result` 为 applied/replayed/rejected；rejected 有 error_code。`expected.state` 是该步完成后的完整被断言投影：

- `account_balances_minor`：每账户原币余额。
- `periods`：各查询区间的收入、净支出、结余、独立预算符合额与分类费用；退款报销归源单周期。
- `assets`：固定估值汇率下的资产、负债、净资产；原币与报表币转换分别验算。
- `budgets`：配置模式下占用和剩余；没有该键表示该场景只断言 budget_eligible_minor。
- `remaining_allocatable_minor`、`plans`、`savings`：场景需要的关联剩余/计划/进度。

不得以账户净资产变化必然等于收入-支出来验算所有场景：期初、排除标记、余额调整、估值汇率、未关联合成费用会产生有意差异。L04 历史费用使用冻结 7.2 汇率，当前资产使用 7.1/7.5，正是这两种口径的独立验收。

以下属于负面输入，有意保留无效值：money_vectors 中 accepted=false 的数字型 amount_minor/格式/越界值，以及拒绝命令。检查器不把它们误报为夹具格式损坏。

## 退款报销1.1增量

2026-10-22新增`refund-reimbursement.json`，按[退款报销契约](../../refund-reimbursement-v1.md)独立消费，不修改旧1.0输入或L02/L04期望。`base_expense_payload`及`tracking_vectors[].payload`是完整合成API payload，UUID均为固定合成值。`preservation_vectors`仅描述字段presence合并；`source_summary_vectors`的`accepted=false`有意包含null、非canonical金额、守恒/原因错误及越权字段。

`lifecycle.steps[].command`是领域适配意图，使用fixture别名，不宣称对应HTTP路由已存在。每步`expected.state`断言银行原币余额、源修订/删除/追踪presence、来源聚合、十月/十一月统计预算和净资产；以setup的日期/币种为准，禁止取运行时今日。取消追踪保留实际回款；拒绝/同operation重放的完整状态不变。

`frozen_legacy_pages`同时保存旧pull/snapshot对象、canonical UTF-8和SHA，snapshot的items有独立page_sha256。这些是兼容性固定输入，不是实际线上数据。`wire_verification_matrix` W01–W08定义真实create/GET/pull/snapshot/旧分页/同commit修订验收，`wire_evidence_at_fixture_creation`保留创建时未执行的事实，不代替后续实际回执；`future_typed_revisions`仍属于未实现的独立能力，不能发往当前服务端。

在根目录执行`python -m unittest discover -s tests/contracts -v`检查本增量和实际OpenAPI。真实模型依赖可用时会同时核对现行expense拒绝零额、旧嵌套分页模型的exclude_unset序列化；四项新字段模型测试会在字段未落地时明确skip。前置阶段17通过/4skip保留；后端模型接入后21/21通过。静态样本算术、模型序列化和真实PG/HTTP/Flutter业务执行分别记账，不把前两者算成后者通过；后续服务端PG/wire证据见[退款报销契约](../../refund-reimbursement-v1.md)。

## 待后续集成的验证

本目录验证只证明静态样本自洽；P1-03 执行两端真正账务参考实现，P2 验证真实事务/同步/权限，P4 验证高级作业。更改历史样本须同步契约版本、理由及受影响实现；原钱迹新证据若改变口径，保留旧版本兼容输入。
