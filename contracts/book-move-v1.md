# 同 UUID 跨账本原子移动 v1

日期：2026-10-21（Asia/Shanghai）。本能力为 FlowTrace 明确默认，不声称还原钱迹同步算法。它扩展 [sync-v1](sync-v1.md) 的 bill/update；不会增加实体类型、变更账单 UUID 或用删除再新建替代移动。客户端开放门槛见文末。

## 显式操作

Operation 新增可选 `move`，缺省或 null 表示原有普通操作。非空时只允许 `entity_type=bill`、`action=update`、非零 base_revision、完整 BillPayload、`preserve_hidden_financial_links=false`；operation.scope_id 仍是来源，payload.book_id 明确是目标，与 move.target_scope_id 一致且不同于来源。原字段与原始 wire hash 语义不变：缺省和显式 null 仍是不同输入摘要。

move 字段的完整结构示例：

```json
{
  "target_scope_id": "10000000-0000-4000-8000-000000000001",
  "attachment_replacements": [
    {
      "source_id": "20000000-0000-4000-8000-000000000002",
      "target_id": "30000000-0000-4000-8000-000000000003"
    }
  ]
}
```

最多20对，source_id 和 target_id 各自去重且不同。无图片时 attachment_replacements 必须为 []。新客户端需先展示来源/目标、类别标签变化及克隆图片计划，再冻结完整操作；不能因服务器拒绝自动更换 UUID 或改成普通 update。

## 当前最小安全分支

- 两账本当前均须 owner/editor，viewer、失活成员和后台用途会话不能移动；所有私人资金引用必须属于当前用户本人。
- 两账本报表币种必须相同。money、type、account/from/to/target_money、reporting、优惠、目标余额、source、原业务日期/时区/精确 occurred_at 均保持原值；手续费资金定义不变。不能把目标账本当前时区套给历史账单。
- 来源账本专属共享账户不跨域携带，明确 `move_shared_account`；不能清空或换成另一个账户规避。原会计分录 ID、signed movement、币种、日期与余额保持，只改 LedgerEntry.book_id，尤其历史 balance_adjustment 不重算。
- refund/reimbursement 类型以及有任何有效退款/报销分配的费用源单当前拒绝 `move_has_allocations`；不以隐藏关联视作无关联。关系闭包迁移留给后续明确复合操作。
- 分类、标签和手续费分类只能显式指定目标账本有效 ID 或清空，不按同名猜映射，不继承来源账本 UUID。备注、主 flags 可在同一明确完整正文中调整；其他非迁移字段不偷偷丢失。
- 图片必须提前通过既有附件声明/上传/完成接口，准备目标 scope 内的新 ready 对象。mapping 精确覆盖来源附件，目标 payload.attachment_ids 必须按原顺序映射，不能少图、加图或无提示重排。每对检查 scope、ready、SHA256、大小和类型一致；原附件 scope/文件不修改，其他账单对源图的引用不变。

拒绝码包括 `move_target_mismatch`、`move_financial_fields_changed`、`move_private_finance_forbidden`、`move_shared_account`、`move_currency_mismatch`、`move_has_allocations`、`move_attachment_mapping`、`move_attachment_mismatch`，以及既有授权/修订/附件未 ready 错误。错误不返回另一用户的账户或关联单 UUID；已准备但最终未用的目标图片按现有孤儿宽限回收，不将准备成功当作移动完成。

## 事务与回执

1. 复查当前 user/session，按 UUID 排序锁来源/目标及相关本人私人 scope，再排序锁账户，最后对全部源/目标附件 UUID 合并排序加锁。scope 在加锁后重新发现，变化则整项重试；不在 scope 后反向取得目标用户锁。
2. 复验双方编辑权限、修订、完整资金所有权、不可变定义、目标分类/标签与图片映射。ref 的真实集合必须等于原 payload.attachment_ids，任何不一致整项拒绝。
3. 同一 PG 事务变更 SyncEntity.scope_id 与 payload.book_id、LedgerEntry.book_id、附件 refs 和孤儿时间，增加账单 revision。金额和账户 balance_minor 不变，不删除/重建账务分录。
4. 同一个 commit_id 发布：来源 scope 的该 bill tombstone、目标 scope 的完整 public 投影、本人私人 user scope 的最小 finance 投影；只有真实私人分录时才产生后一投影。被修改的两个账本 scope 各自增加修订，不把不同 scope 的修订号比较成全局时间。
5. 正式 SyncReceipt 与全部结果同事务提交。重放先锁住并重新鉴权 receipt.required_scope_ids，然后才读取缓存结果、核对原始 hash；移后实际实体已经在目标域不妨碍完全相同操作重放。失去任一原必需域权限后不能取得旧成功回执。变更任意正文但复用 operation_id 返回 idempotency_mismatch，不再次移动。

账户余额、源/目标统计、图片 refs、变化日志和回执必须同时成功或同时回滚。GC 使用同 scope→附件顺序，不得删除正在绑定的目标 ready 图片。失败的正式回执/审计写入不能被辅助诊断吞掉。

## 同 UUID 读取与客户端门槛

服务器当前实体只保存一个实际 scope；移动后完整 snapshot 只在目标 scope 列出该 public 账单，来源-only 成员不能从当前实体或快照取得目标正文。私人财务快照按本人最新 user-scope 变化，保持原分录金额但关联新 book_id。

增量 source tombstone 与 target public 具有同一个 entity UUID、同一个新 entity revision；各 scope 的 scope_revision 独立，目标变化可能先于来源墓碑到达。客户端必须按 scope 安装：旧来源墓碑不能删除已经安装的目标实体；来源先到时，随后相同 entity revision 的目标投影必须可以安装。只有来源权限的成员应移除该公共记录，不能读目标投影。

ACK 依据冻结 move 字段将实体写入目标 scope，不能用 operation.scope_id 把它写回来源。旧来源待传编辑必须隔离为明确冲突，不得清空后伪装成功；来源失权仍沿现有撤权清受控缓存策略。服务器 receipt replay、并发/越权、附件/分录回滚、完整 snapshot 与双方增量都需真实 PG 验证。

**客户端 ACK、pull 双序及 pending 冲突尚未实际验收前，不开放移动 UI。** 当前文档描述实施协议，服务器实现与测试结果由任务回执和同步模块更新；客户端现有 book_move_requires_server 保护在接入完成前保留。

## 服务端验证

2026-10-21 在 Windows/Python3.12/PostgreSQL18.6 的本机隔离库完成14项闭合输入、26项真实PG/HTTP移动及2项当前墓碑读取测试，连既有服务端全套377项通过，Ruff无问题。覆盖原分录 UUID/signed金额与10500历史调账余额保持、手续费三分录、不同用户反向移动、相同操作并发、源/目标任一失权后回执拒绝、附件GC双序与未ready同正文重试、正式回执数据库CHECK失败整事务回滚、唯一目标snapshot及来源-only增量无目标备注。

独立非editable生产wheel在隔离18082实际HTTP完成15项检查，明确验证移动后账户9875保持、本人privatefinance原-125、来源报表0/目标125、原正文重放、实际域最小删除墓碑和源404。合成实体按业务接口墓碑清理、会话退出、临时服务停止。该结果不包含客户端移动UI、真机、浏览器或Linux部署验收；当前运行服务的包版本由计划进度另行记录。
