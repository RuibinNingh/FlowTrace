# 精确金额与账务参考实现

> **速查**
> - 职责：Python/Dart 独立计算同一组金额、业务日期与账务黄金样本。
> - 入口：`server/src/flowtrace_server/domain/`、`apps/flowtrace/lib/core/money/`、`apps/flowtrace/lib/domain/ledger/`。
> - 不变量：金额不经浮点；拒绝和重试不产生额外账务；样本期望不为迁就实现而修改。
> - 必跑测试：服务端 `python -m pytest tests/domain -q`；客户端 `flutter test test/domain`。
> - 相关：[领域契约](../../contracts/ledger-rules.md)、[金额时间](../../contracts/money-time.md)、[当前进度](../plans/flowtrace/progress.md)。

## 当前行为

两端已实现有符号64位范围检查、整数字符串/显示金额、精确汇率折算、负值对称四舍五入、分期末期尾差、业务日期/月份边界和计划日期。ReferenceLedger 对合成场景计算账户、收支、独立预算、退款报销分配与计划投影；内存命令失败恢复执行前状态。共享夹具的符号ID是测试别名，HTTP接口仍要求UUID。

Python/Dart 最终各86项测试通过，8场景57步逐字段计算，另含4个真实 IANA 时区向量。Python 使用 tzdata2026.5（IANA2026e），Dart timezone0.11.2 内含2025c；当前上海/洛杉矶/纽约样本一致，不宣称所有地区规则版本等价。此模块是无数据库的确定性规则与参考投影；不提供账号鉴权、并发事务、作业租约或完整UI。领域参考通过不代表 P3/P4 对应功能已交付。

## 集成边界

生产入口先做严格字段及当前权限校验，再在真正数据库事务里调用已接收规则。参考实现编程/形状错误回滚后重抛，不能把任意JSON直接视为有效命令。任务批量数有明确上限；更高层应使用更小产品限额。跨币种缺失汇率、溢出及非法分配保持原状态。

高级原型未实测的规则保留契约中的 N 标记，后续新增来源需审阅契约/夹具/两端实现一起变更。完整缺口统一见[工作区](workspace.md)。

2026-10-22的P4-02服务端候选仅新增expense严格bool追踪/presence及公开来源R/E/剩余/结清聚合，不改变金额、现金或预算事实，金融指纹排除该metadata。源币分配与回款币/超额收入分别校验；源修订/聚合同commit、幂等和并发证据见[同步模块](sync.md)。独立服务端完整425通过，之后真实18086 socket1通过；这些不是Reference或客户端新功能验证。

本轮没有修改两端Reference或Flutter领域代码。[退款报销v1](../../contracts/refund-reimbursement-v1.md)定义的关联源单方案A与现状仍有差异：生产保留旧普通增额规则，Reference仍有额外account/date锁；下一切片比较实际值并对齐，旧精确增额回归必须保留迁移证据。新增1.1固定样本不会自动被原8场景Reference适配器执行，完整capability及typed复合未交付，不把合同自洽/模型检查等同于生产规则全部一致。

P4币种精度扩为SIX冻结数字minor unit目录165项（实际0/2/3/4），由 `tool/update_currency_catalog.py` 从共享assets目录生成Flutter映射和名称，目录来源日期与SHA随文件保留；N.A项目不猜精度，原15币种不变。账户新增prepaid/investment仍按已有Money记账，不声称证券份额或实时行情。生产转账可带冻结transfer_fx，精确折算须等于target_money，指纹包括该事实；估值变更不回写原分录。账户/FX目标11项含完整目录比较，与既有本地账务22项合并33通过。领域与P4客户端相关目标随后已纳入2026-10-22完整客户端500通过/5项需显式配置的live默认跳过，完整分析无问题；五项跳过不计实际HTTP通过。真实资产HTTP与浏览器专项由[资产模块](assets.md)及[平台验证](../plans/flowtrace/platform-validation.md)分别记录，不把参考计算或Native回归视为完整页面、Android或Linux验收。
