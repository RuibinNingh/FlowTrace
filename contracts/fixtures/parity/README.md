# 钱迹参照证据夹具

> 职责：保存钱迹 Android 4.5.4 的脱敏证据索引与待补测项，供 P0-02、P0-03、P0-04 及后续功能任务使用。
> 入口：[证据矩阵](../../../AI/plans/flowtrace/evidence-matrix.md)、`manifest.json`、`states.json`、`features.json`、`retest-cases.json`。
> 不变量：历史页面、静态代码、官方指南、未验证事项和流迹默认分开；不复制用户真实截图/层级文本或账目。
> 必跑检查：在仓库根运行 `python contracts/fixtures/parity/verify.py`；有本地原始资料时加 `--local-sources`。
> 相关：[产品范围](../../../AI/plans/flowtrace/product-scope.md)、[实施任务](../../../AI/plans/flowtrace/tasks.md)。

## 文件职责

| 文件 | 内容 |
| --- | --- |
| [manifest.json](manifest.json) | 固定版本、历史观察条件、本轮操作边界、21 个本地事实/代码/布局来源和两份官方指南。 |
| [states.json](states.json) | S01–S56、通用说明、重建入口/前置/退出计划、F 编号、原 PNG/XML 路径及哈希、尺寸/结构计数。 |
| [features.json](features.json) | F01–F22 到 S/C/G/V/J、实现任务和 E 验收编号的证据映射；不替代产品范围定义。 |
| [claims.json](claims.json) | K01–K09 的有界静态/指南结论，包括独立标记、债务转账限制、ID 冲突和当前预算指南等。 |
| [retest-cases.json](retest-cases.json) | V01–V10 的隔离前置、动作、责任角色、结果记录要求和 33 条显式流迹默认。 |
| [journeys.json](journeys.json) | J01–J12 的实施与补测承接；业务金额样本归 P0-02，平台可运行场景归 P0-04。 |
| [verify.py](verify.py) | 仅使用 Python 标准库的证据数据/来源完整性检查；不启动或写入任何应用。 |
| [validation-results.json](validation-results.json) | 本轮 `--local-sources` 实际结果；明确列出原应用及流迹业务测试均为零。 |

本目录没有私人金额、账号凭据、账单备注、OCR 文本或图片副本。图像只记录文件名、大小、尺寸和 SHA256；XML 只记录文件元数据、根类型及节点数。通用控件说明源于原调研清单，不从私人节点摘录文本。

## 验证方式

在仓库根执行：

```powershell
python contracts/fixtures/parity/verify.py
python contracts/fixtures/parity/verify.py --local-sources --report validation-results.json
```

第一条可在不包含 `work/` 的源码包中检查编号、映射、声明边界和任务引用；第二条额外检查当前机器的 56 对 PNG/XML 及 21 个定向来源是否与建档哈希相同。原资料不在源码包里时，不执行第二条；不能为获得通过结果重新造一份原截图。

`verify.py` 是本任务证据校验工具，没有接入提交、CI 或文档门禁。它验证索引和来源文件，不验证截图内容的业务正确性，不等同于原应用实测、FlowTrace 单元测试、平台验收或部署。

## 接续规则

- `O` 代表 2026-10-20 历史真机页面观察；入口和退出路径标为继承或重建，没有在本轮重新执行。
- `C` 仅支持客户端可读代码/布局的结论；`G` 标明来源平台和适用版本。当前指南不自动升级成 Android 4.5.4 的动态事实。
- 本轮 V01–V10 均未在隔离原应用环境运行；保留 `U`，采用 `N` 流迹默认可以继续独立开发，不能因此声称已完整复现原结果。
- 业务/权限/同步契约固定后，默认值以 `contracts/money-time.md`、`ledger-rules.md`、`permissions.md`、`sync-v1.md` 为权威；本目录记录来源和未知，不各写一套竞争算法。
- 后续补测更新时，记录新环境、输入、输出和证据身份；只把对应结论从未知变为观察，不将整模块全部标记实测。
