# 共享契约与证据样本

> **速查**
> - 职责：固定跨 Flutter/Python 的金额、账务、权限、同步和功能对照样本。
> - 入口：`contracts/`，`AI/plans/flowtrace/evidence-matrix.md` 与 `platform-validation.md`。
> - 不变量：黄金样本不能因实现失败而随意修改；观测、静态证据、指南、设计默认分开。
> - 必跑测试：`python contracts/fixtures/ledger/validate.py`、`python contracts/fixtures/parity/verify.py`、`python -m unittest discover -s tests/contracts -v`。
> - 相关：[总计划](../plans/flowtrace/plan.md)、[证据矩阵](../plans/flowtrace/evidence-matrix.md)、[平台检查](../plans/flowtrace/platform-validation.md)。

## 当前行为

2026-10-24新增[钱迹原始导出v1](../../contracts/qianji-export-v1.md)：19列识别、稳定来源ID、收支分类分型和明确退款关联，复用stage而不扩大普通导入上限。parse/rows以`include_diagnostics=true`显式返回可选请求ID；未选择时旧响应键集合保持。当前唯一OpenAPI仍72路径/176schema/79操作，SHA256为`35c882b686e73a70228755d4aea8c590343d719bc5ffc04f12e2f01963964bc7`；契约21项及113个subtest通过。以下导出hash为对应旧快照。

2026-10-23普通主应用先接[group-sync-v1](../../contracts/group-sync-v1.md)六操作，现再接[大文件暂存](../../contracts/import-stages-v1.md)17操作及`import-stages-v1`能力，含完整清单、原图双映射与显式续接/放弃源。当前唯一导出72路径/176schema/79操作，SHA256为`7e9287a91ffae00d05a81262c5ecd995c4d580d5fea3d9aa2d92d05f9799dd0b`，合同21/21通过（0.465秒）。此前55/151/62与50/139/56是历史快照；P0候选及原raw/hash黄金保持。main HTTP首包86通过/1新夹具错误预期后单项1通过，真实TCP/浏览器及最终产物另验。

P5新增`/api/v1/data-tools`八条实际路由和导入/导出DTO，mapping_requirements及attachment_sources接线后唯一OpenAPI50路径/139schema/56操作，合同21通过；旧42/114/48和50/138/56分别为lookup/前一parse快照。权限契约新增本人不可变导入操作元数据历史，当前资源写权仍独立复核；正式schema/跨端验证见[数据工具](data-tools.md)。大文件任务、完整后台与P4高级前置仍未全部实现，原P0样本/raw哈希不改。

2026-10-22 B因果补证新增真实只读`POST /sync/receipts/lookup`及严格单项`ReceiptLookupRequest`，沿用原PushResponse而不扩张账务实体；重新导出42路径/114schema/48操作，合同21/21通过。旧P0候选/黄金与raw hash规则保持，回款两个完整能力仍不advertise。协议及拒绝行为见[同步契约](../../contracts/sync-v1.md)。

P0 已落盘金额时间、账务、权限、API、同步、附件和作业契约；包含 56 界面/22 功能/12 旅程的脱敏映射、10 个原应用待补验流程、8 个账务场景的 57 步和 84 个权限案例。数据为合成样本及证据元数据，不包括用户账目。

`contracts/openapi.json` 在 P0 为设计候选；P1 起保存候选到 `openapi-p0.json`，实际文件由服务端唯一导出。后续未实现接口仍在 `api.md`/候选中，不伪造成可用。金额/修订大数使用字符串，账务标记与账户分录相互独立，同步不得用设备时间裁决覆盖。

## 验证边界

parity 默认 portable 模式检查元数据；`--local-sources` 可在本工作区验证忽略目录内的 133 个研究文件。ledger 验证器检查样本内部算术与结构，API 契约检查验证固定哈希与引用，不代表业务实现、PostgreSQL 并发或原应用动态流程通过。

P0 后续变更须说明新证据/设计依据并更新相应样本；业务实作测试必须读取这些样本得出计算结果，不只复制期望输出。当前已知缺口统一见[工作区](workspace.md)。

P4新增[资产/币种契约](../../contracts/assets-v1.md)与[冻结目录](../../contracts/fixtures/assets/catalogs.json)：银行11、服务商39及SIX 2026-09-17数字minor unit币种165项，两端使用同精度，旧15项保持。私人组/偏好/日期估值采用独立冻结REST命令，不扩展六实体同步；转账历史 `transfer_fx` 与资产估值分离。新服务端已在专用assets库迁移0006验证目标，当前18080仍为0005/377包，实际OpenAPI导出与发布状态见服务端模块。

## P4-02追踪契约前置

2026-10-22已冻结[退款报销v1](../../contracts/refund-reimbursement-v1.md)的A切片，并同步账务/同步/权限文字。expense追踪字段可选strict bool、显式null和非expense携带均拒绝；同expense省略保留原presence，不回填旧raw/哈希。权威`source_summary`只在expense公开投影外层，三个源币非负整数字符串及结清原因守恒并绑定源revision，不返回foreign回款身份。现行expense PositiveMoney确实拒绝零本金。

关联原单普通维护采用明确方案A：实际改变type/currency/scale/amount及删除拒绝；同值Money、受权账户和日期维护仍按既有规则处理。生产当前允许部分增额、Reference额外禁止account/date的差异尚待后续实现对齐。未来typed重构仍为独立`receipt-restructure-v1`，普通多项push不具远端全成全败语义。

新增[独立1.1样本](../../contracts/fixtures/ledger/refund-reimbursement.json)包含18步生命周期、追踪16/保留6/summary17/关联维护12向量（包括完全结清）、账户/日期变化、旧分页canonical/SHA及8项wire验收定义；L02/L04摘要固定且原1.0的8场景57步未改。[新增测试](../../tests/contracts/test_receipt_tracking_contract.py)直接检查实际`contracts/openapi.json`，独立于旧P0设计候选，验证引用、唯一operation ID、闭合共享模型与字符串金额。

当前服务端追踪字段/presence和权威聚合已实现，真实模型检查不再skip，实际OpenAPI为41路径/113schema/47操作。`receipt-tracking-v1`整包尚未advertise：关联源单严格金额边界、Reference及客户端仍待后续切片，未来复合也未实现。独立PG/生产ASGI及随后socket18086已验证追踪/summary最终wire不注入false/null、旧物化页canonical/hash保持；具体服务端证据见[同步模块](sync.md)。模型测试仍不等同客户端/UI验收。

2026-10-22前置验证：`server/.venv/Scripts/python.exe -X utf8 -m unittest discover -s tests/contracts -v`共21项，17通过、4明确skip；其中旧P0三项继续运行，实际OpenAPI引用/闭合检查与现行旧分页模型序列化均通过。`ledger/validate.py`仍为8场景/57步/84权限样本自洽通过，`parity/verify.py`为portable元数据1389断言通过、原应用动态执行0；脱敏历史回执位于`outputs/validation/P4/receipt-tracking-contract-receipt.json`。

随后仅后端追踪/聚合切片使合同检查21/21通过、无skip；独立receipts库完整服务端425通过，包含12项新增PG/ASGI目标，之后另增真实socket1通过。字段实现不修改旧L02/L04、原模型字段缺失哈希或P0设计基线。更新fixture只追加完全结清两例并将动态状态与固定输入分开，未放宽金额期望。最新回执`outputs/validation/P4/receipt-tracking-server-receipt.json`分别记各类证据；未执行Flutter/UI、Reference、typed复合、迁移或运行服务升级，不把静态/模型数字重复计入业务执行。

一次后续schema表达检查发现实际OpenAPI仍列`source_summary:null`，而原runtime/合同只允许缺失兼容。新增测试直接递归断言实际属性无null branch，先失败后以标准`SkipJsonSchema[None]`修正生成来源，重新导出后21/21通过。33组模型接受结果/序列化摘要前后相同，旧缺失与显式null拒绝均保持；actual41/113/47及P0不变。此为单属性schema修复，没有新PG/HTTP/425全量重跑；独立回执`outputs/validation/P4/receipt-tracking-schema-receipt.json`保留红绿及新旧wheel摘要。
