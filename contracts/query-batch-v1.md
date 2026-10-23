# 本地账单查询与确认批量 v1

日期：2026-10-21，Asia/Shanghai。S13/S14/S55/S56 证明查询与批量表单入口及字段；原应用未实测的提交、余额联动和并发语义采用本文件明确的 FlowTrace 默认。当前实现位于 `apps/flowtrace/lib/data/ledger/ledger_query.dart`、`ledger_batch.dart`，操作经[账务读写层](../AI/modules/ledger-data.md)进入现有同步队列。

## 查询集合与金额

`queryBills(LedgerView, filter:BillFilter)` 只查询已加载、当前空间可见的公开账单投影，不跨用户访问数据库，不推断私人账户或不可见分配。调用者应传未按账本预先缩小的 LedgerView，再由 BillFilter.bookIds 筛选多账本；查询层不能凭空补回调用者未加载的账本。

| 条件 | 解释 |
|---|---|
| fromDate / endDateExclusive | 业务日期左闭右开；不按设备当前时区重新解释历史日期 |
| bookIds | null 不限；空集合明确无结果；使用账单实际 scope |
| keyword | 去首尾空格、大小写无关的字面子串；匹配备注、分类及父分类名称、标签名称、原币显示金额与币种 |
| categoryIds / includeDescendants | 默认包含二级子分类；关闭时只匹配明确分类 ID |
| tagIds / allTags | 默认任一所选标签；allTags 为全部；空集合无结果 |
| currency / minAmount / maxAmount | 同一明确币种的 Money 区间，端点包含；两端不同币种或负数边界拒绝 |
| hasAttachments / hasTags / hasAccount | null 不限；true/false 明确有无。私人账户被裁剪成 null 时，公开 hidden_account_fields 仍表示有账户 |
| sources / types | 来源和十一种账单类型的明确集合；不按显示文字猜类型 |
| excludeFromStatistics / excludeFromBudget | 两个互不依赖的三态条件，null 不限 |

结果包含稳定排序的 bills、ids、idSet、totalsByCurrency，以及无法证明匹配结果的 issues/unavailableIds。排序为业务日期倒序、同日精确时刻倒序、规范 UUID 升序；日期型账单在该日精确时刻账单之后。

`totalsByCurrency` 表示选中账单的**原币名义金额合计**，包含转账、退款和报销，不等同于净支出、预算占用或账户现金流。每个币种分别返回 count、nominalAmount、byType；不跨币种相加，也不把转账合计当收入。净额及关联分配使用独立 reporting 契约。

读取与累计使用精确 BigInt。聚合超过有符号 64 位范围时保留准确 ID 集合，nominalAmount 为 null、issue=query.total_overflow，不伪造截断或零。缺失必要分类/标签名称使关键词是否匹配不能确定时，返回该笔的 unavailable 说明，不悄悄把它当“肯定不匹配”。

## 预览与确认

`LedgerBatchService(ledger).preview(space, ids:..., action:..., patch:...)` 只读，返回不可变 BillBatchPreview。重复 ID 去重，最多一千个输入；未知、删除、失权或冲突记录逐 ID 返回 issue。确认页只能看到裁剪后的 before/after、changedFields 和目标 ID；完整私人资金正文只保留在内部冻结写入计划中。

`confirm(space, preview)` 重新检查空间、epoch、恢复状态、权限缓存摘要，以及每笔修订和完整正文摘要。服务端修订未变但本机已经继续编辑，同样要求重新预览。未知选择不扩大成全部、选择过期不改为“重新查询后自动确认”。

当前任一预览失败使 canConfirm=false；调用者可明确排除失败项，再生成新的预览。确认的本地实体、队列和分录提示处在同一 SQLite 外层事务。末项失败时前项也回滚，BillBatchException.issues 定位原选择 ID；网络提交仍是现有同步的一项一事务，不能承诺服务端整批回滚。后续远端部分失败保留回执、依赖和用户意图，不用清空队列掩盖差异。

## 允许的批量修改

BillChange<T> 区分 unchanged、set、clear，所有字段默认 unchanged。表单没有金额或账户批改接口。

| BillBatchPatch 字段 | set / clear |
|---|---|
| categoryId | 设明确同账本分类 / 清空分类；收入、支出类型与归档引用规则照常检查 |
| note | 设完整备注 / 清空；未改不会改写原备注 |
| tagIds | 用明确列表替换 / 清空；不默认为追加，不猜同名跨账本标签 |
| excludeFromStatistics / excludeFromBudget | 独立设 true/false；clear 拒绝，避免混淆 false 与未选择 |
| time | 设 BillTimeEdit / 显式清除精确时刻而保留业务日期与时区 |
| removeAttachments | 默认 false；仅 update 时可 true，只把选择账单 attachment_ids 置空 |
| bookId | 选当前账本为不变；客户端不同账本当前仍返回 book_move_requires_server，服务端独立协议见下节 |

只读成员不能批改。对拥有编辑角色但资金链接被裁剪的记录，仅允许备注、分类、标签、图片引用和两个统计标志的严格 metadata 更新，显式发送 preserve_hidden_financial_links。日期/时间、复制或删除仍需完整资金授权。本机 raw metadata 更新和 ACK 不把“字段为 null”误解成“没有资金链接”：公开可见性从确认投影或原操作 baseDataJson 保留，不能因此解除隐藏字段限制。

移除图片引用不会调用原件删除，也不删其他账单对同一图片的引用；本机暂存元数据保留。服务端引用变更和 GC 继续走 P2 的授权/ready/引用事务。批量文件下载是另一个平台导出能力，当前批改不冒充已提供下载。

## 时间的明确变化

未修改 time 时，occurred_at 原字符串、完整微秒精度、business_date 与原 IANA 时区均保留。仅重复设置原日期而未修改时刻同样不重新解析，避免重复时刻从第二次出现跳回第一次。

`BillTimeEdit(date:..., time:..., clearTime:...)` 不提供时区覆盖：每笔保留自己的历史业务时区。只改日期且原有精确时刻时，保留原当地时分秒和微秒；原为日期型则保持 occurred_at=null。明确设置 time 时接受 HH:mm 或 HH:mm:ss.ffffff；HH:mm 明确表示秒为零。clearTime 与新 time 不能同时给出。

当地时刻用[金额时间契约](money-time.md)的固定 IANA 数据解析：缺失时刻向前至首个有效时刻，重复时刻取第一次；保存确定 UTC 与解析后的业务日期。若跳过整天，业务日期跟随实际有效时刻，确认预览展示结果。不会把历史日期静默转换成设备本地日期。

## 复制与关联删除

复制使用确认时冻结的新 UUID，保留当前授权完整 payload 和原有资金引用，原单不改；确认页仍只展示公开投影。支出原单的入账退款/报销关系不属于其 payload，因此不跟随复制。退款、报销和余额调整自身涉及重新分配或新目标，当前明确拒绝 copy.requires_explicit_financial_flow，等待对应明确流程，不能隐式重复关联或猜新的调整金额。

单独删除有有效关联回款的原单拒绝；显式同时选择回款及原单时，预览先处理回款，再处理原单。未选择的关联不会自动清空或删除。双方资金引用都须完整授权。任一撤销使已知账户余额溢出时，预览拒绝，直接删除也在本地事务中拒绝。最终关联和余额仍由服务端重新验证。

## 验证与边界

真实 SQLite 固定集合和事务测试位于 `test/ledger/query_filter_test.dart`、`query_batch_test.dart`、`query_fixtures.dart`。本轮新增 22 项与原账务 22 项合并 44/44 通过，目标 analyze 无问题。覆盖组合 ID 集、分币种原币额、2^53 精度、溢出/缺证、默认不变、逐字段修改、修订/权限/恢复上下文、末项失败回滚、资金隐藏、明确关联删除、微秒和 DST、图片引用隔离及 raw ACK 后权限保持。

尚无本包真实 Android/HTTP 批改界面回执；跨账本客户端接入和批量图片文件导出另行验收，不把本数据层验收等同于 P3-02 全部完成。

## 跨账本原子移动

服务端独立分支、闭合 Operation.move、同 UUID 与精确分录保持、双账本当前编辑权、附件 ready 副本、失权回执和快照约束统一在[跨账本原子移动 v1](book-move-v1.md)维护，实现在 `server/src/flowtrace_server/sync/book_move.py`。不得在前端用删除再新建替代移动。

服务端真实 PostgreSQL、附件 HTTP 与原子回滚验证不代替客户端 ACK/pull 双序和旧待传冲突验收。客户端当前保护仍为 book_move_requires_server；完成这些门槛后再接入批量确认页面。不同报表币、共享专属账户与退款/报销关系闭包仍有明确拒绝分支，不默默丢失资金或关联。
