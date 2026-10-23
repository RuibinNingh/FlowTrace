# 合成用户旅程夹具

[journeys.json](journeys.json) 固定 J01–J12 的前置、声明式动作、精确金额、可观察结果、功能/工作包/E编号。所有输入均为合成，不含用户真实账本/支付或凭据；所有 `execution.status` 当前均为 `not_run`，不得将资产结构校验称为业务验收通过。

动作是跨客户端的语义描述，**不是直接发送的API请求**。`api_payloads=false` 用于提醒执行器先按 [API](../../api.md) 和真实生成OpenAPI适配；Money字段及期望遵循 [money-time](../../money-time.md)、[ledger-rules](../../ledger-rules.md)、[permissions](../../permissions.md)、[sync](../../sync-v1.md)。符号用户/账户/源ID在测试启动时映射为独立UUID，不传给正式UUID字段。

使用方式：

1. 根据旅程和 [ui-map](../../ui-map.md) 创建专用账号/账本/附件与测试临时目录。
2. 先加载期望值，再用实际客户端、API与数据库执行；故障/时间边界使用可控隔离注入。
3. 把结果写到 `outputs/validation/P阶段/` 并在任务日志引用，不修改本夹具的not_run来冒充对所有平台生效；测试执行报告分别记录平台版本、passed/failed/blocked/not_run和证据。
4. 期望变化先登记领域契约版本和依据；实现者不得降低期望以消除失败。

J03的资金断言只适用于首次同币转账后的检查点；后续信用卡/债务动作另按领域黄金样本复核。J04的归属断言适用于完整20元退款+50/30元报销检查点，随后撤销步骤需要重新计算，不能把中间值当最终全程值。J08的分摊本金/费用分别守恒。

来源是 [产品旅程与补测](../../../AI/plans/flowtrace/product-scope.md)、[任务E矩阵](../../../AI/plans/flowtrace/tasks.md)；原应用未知分支保持U，流迹默认保持N，不由这些合成期望反证原服务端实现。
