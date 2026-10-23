# 同步协议 v1

状态：协议基线已接入服务端与客户端，当前验证及保留边界见[服务端同步模块](../AI/modules/sync.md)与[客户端同步模块](../AI/modules/client-sync.md)。业务实体的金额和规则以 [账务契约](ledger-rules.md) 为准。服务端同步内部实现是 FlowTrace 设计，不是钱迹服务端事实。

大批跨页原子读取使用独立协商的[group-sync-v1](group-sync-v1.md)。旧增量命中当前可见多chunk publication时返回既有`resync_required`，由旧完整snapshot一次安装；单可见commit和无关旧物化页保持原wire/hash。

## 请求与幂等

`POST /api/v1/sync/push` 输入 `{protocol_version:1, client_id, sync_epoch, operations:[...]}`。每项固定字段：`operation_id`（UUID）、`scope_id`（UUID）、`entity_type`、`entity_id`（UUID）、`action`（create/update/delete）、`base_revision`（create 为 "0"）、`depends_on`（同批或已确认 operation UUID，可为空）、`payload`。实体类型先支持 book/account/category/tag/bill/budget，后续扩展须服务端能力声明。

P3 增加可选 `move`，仅同 UUID 的 bill/update 使用，完整闭合结构与当前限制见[跨账本原子移动](book-move-v1.md)。缺省或显式 null 均按普通操作解释，但仍保留不同原始正文摘要。服务端 `bill-move-v1` 声明不代表客户端移动界面已开放。

P4-02的`receipt-tracking-v1`补充定义expense可选严格布尔`reimbursement_tracking`及BillPublic外层`source_summary`，见[退款报销](refund-reimbursement-v1.md)。服务端字段/聚合已实施，但关联维护整包及客户端仍待对齐，当前不声明该能力；旧服务没有该能力时客户端不得发送新追踪字段。缺失追踪仅在显示语义解释false，不回填旧实体、shadow、已冻结请求或已物化页。更新同一expense时省略须保留旧字段或旧缺失；非expense显式携带true/false/null均拒绝。原始输入缺省/显式值继续参与不同正文哈希，不先注入默认值。

新生成的expense投影可包含与源revision绑定的R/E/剩余/结清原因；旧投影缺失summary表示细分未知，不视为零，可信旧remaining仍可使用。新快照页可生成新投影，旧已物化pull/snapshot页和其SHA保持原字节，不为补默认或summary重算。源聚合随回款新增/修改/删除在同commit更新。未来`receipt-restructure-v1`与追踪能力分开；未实现时不声明、不导出空路由，通用push仍逐operation提交。

每项是独立事务；多实体转账在一个 bill 命令内部原子完成。批次按提交顺序响应，不暗示整个批次原子性。依赖失败返回 `dependency_failed`。成功：`{operation_id,status:"applied",entity_id,revision,commit_id,scope_revisions}`；重试同一成功操作返回相同正式回执，只有传输层 `replayed:true` 可变化。冲突返回 `status:"rejected",error`；仅当前仍有权限时包含授权当前投影。

幂等唯一键 `(user_id, client_id, operation_id)`。服务端验证 schema 后计算正文哈希；未知字段拒绝。P0 OpenAPI 的六类实体 payload 为闭合对象，create/update 均提交完整领域字段（update 不是随意 JSON patch），delete 的 payload 必须为空对象。可选字段省略与显式 null 是不同正文；哈希基于验证后的原始输入，不注入业务默认值；领域层在哈希之后解释缺省。哈希输入含 protocol_version、sync_epoch 和整个 operation，排除 access token/追踪 ID。v1 使用严格 JSON 规范化：对象键只允许 ASCII 协议字段名，按字节排序；UTF-8，无多余空白；字符串不转义非 ASCII，拒绝非法 Unicode；数组保持顺序；所有账务/修订/汇率用字符串；仅小型控制字段允许 integer（非 bool，范围 0..2^31-1）；不允许 float/NaN/重复键。不声称完整实现 RFC8785，其数值及 Unicode 排序更广。SHA256 小写 hex 保存于回执。

先鉴权、epoch/有效窗口和当前权限检查，再查回执，避免失权后借重放读取旧正文。相同键同哈希复用；不同哈希 `idempotency_mismatch`（409）。同键并发通过唯一约束及事务等待重读，不能重复应用。业务更改、分录、修订、变化和回执同事务。确定性拒绝可记录有限拒绝元数据，但不得误记为已提交账务；权限变化后的重试重新鉴权。

同一实体 outbox 串行。一旦首次发送，ID 与正文不可修改；后续本地修改新建操作，待自己的前序回执才固定 base_revision。请求超时不能另生成 ID 重试。已确认影子、本地未传投影、outbox 分开保存；旧回执或 pull 不能覆盖较新的用户输入。

### 已有正式回执的只读核对

`POST /api/v1/sync/receipts/lookup` 接受恰好一项操作的原始冻结 `PushRequest`，用原始省略/null语义计算哈希。它只读取当前用户、同一client、同一epoch已有的回执，不执行命令、不产生回执/分录/变化，也不创建或续期SyncClient。成功返回标准 `PushResponse` 单个原Applied，只有 `replayed:true`；不返回当前实体或财务正文。

会话、epoch和设备有效期必须仍有效，并在一致事务内按原回执所需scope重新检查当前写权限；viewer降级或撤权拒绝，不能沿用旧权限。缺失回执为404 `receipt_not_found`，原回执为拒绝则409 `receipt_not_applied`，正文不同为409 `idempotency_mismatch`；失效设备为410 `resync_required`。这些情况都不能退回push重发补证。旧回执只证明原操作的commit及scope向量，仍须等待来源scope的正式pull checkpoint；实体revision不与scope revision比较。

本接口不声明整个`receipt-tracking-v1`或`receipt-restructure-v1`已实现。未升级服务返回404时客户端保留待核对状态，不把接口缺失解释为允许重新记账。

## 冲突、权限与删除

create 仅当 UUID 未被使用；update/delete 要求 base_revision 匹配。`revision_conflict` 不能按客户端时间自动覆盖；保留基准/本地/服务器三份供显式处理。改/删冲突不自动复活；另存需新 UUID 并重新校验引用。关联删除、资产权限以领域契约为准。

`GET /api/v1/sync/entities/{entity_type}/{entity_id}?scope_id=...` 返回当前允许投影与可编辑时的完整正文。软删除实体仅在实际 scope 仍与请求一致、当前主体仍有该域读权时返回最小墓碑：event.deleted=true、event.data=null、editable_payload=null，不返回旧 payload。移到另一账本后，旧 scope 的当前读取仍是404；无权请求目标域返回403，不能靠来源墓碑获得目标内容。

客户端冲突读取先刷新当前权限，再以最高授权 public 影子的 scope 请求当前版本。403/404后只进行一次权限刷新及增量重新定位，只有不同的合法确认位置才重试；不能依据旧命令猜测目标、自动回写来源或重基冻结正文。最高私人 finance 影子不作为公共账单当前版本。

`GET /sync/scopes` 返回用户控制通道版本、当前 scope_id/role/permission_version 及撤销通知，不能泄漏失权账本的内容。每个 push/pull 页/快照/附件都重新校验。成员撤销与业务写在同一 scope 锁下序列化；用户禁用/会话撤销也在写事务结束前校验并协调锁，不能只在请求开始时验证。

墓碑参与变化列表且保留 90 天默认窗口。回执最小键+哈希保留至少设备允许窗口；超期 client_id 先冻结写入并要求重建，不能因清理回执使旧操作重新入账。恢复/协议切换的 epoch 变化拒绝旧写入。删除与当前权限拒绝不返回私有正文。

## 提交顺序与拉取

每个权限域一行 `sync_scopes`，修订使用 PostgreSQL BIGINT、传输为字符串。在事务中按 scope UUID 排序 `SELECT ... FOR UPDATE`，同时锁涉及账户，验证权限/修订，更新实体与该域计数，写不可变 change 投影，持锁至提交。禁止直接使用裸 sequence 或时间戳高水位。

例如 A 取得 scope 修订 41 未提交，B 也写该 scope：B 必须等待；读者只看到已提交 40。A 提交后 B 获得 42。A 回滚后 B 可获得 41。读者无机会从 42 越过迟交的 41。多个域按稳定顺序加锁，死锁/序列化失败整项有限重试，仍使用相同操作 ID。

`POST /sync/pull`：`{sync_epoch, cursors:{scope_id:"revision"}, limit:100, page_token:null}`。首请求从一致数据库快照取得所有授权域高水位向量，创建绑定用户/客户端/权限版本、15 分钟过期的服务器拉取会话。后续 token 只引用该会话及位置，不能让客户端自报高水位。会话选择变更所依据的快照向量固定；changes 为不可变内容，分页不依赖跨 HTTP 保持数据库事务。

响应 `{sync_epoch,commits:[{commit_id,events:[{scope_id,scope_revision,event_index,entity_type,entity_id,revision,deleted,data}]}],next_page_token,checkpoint}`。事件按每域 `(scope_revision,event_index)` 排序；跨域同一 commit 合组，仅投影当前授权部分，组不能分页拆开。单组最大 200 事件，超过限额的批量操作拆为独立用户可见事务；组跨页阈值时可少返回而不能漏掉。跨域总序以服务端 pull 会话生成的有向先后顺序固定，稳定 commit tie-break，不要求用 UUID 代表全局提交顺序。客户端整组事务应用，同页原子持久化；最终页才推进本轮正式 cursors。页重试按 commit/event ID 去重。

同一一致快照看见事务的全部已提交域变化；快照高水位不允许把半组筛出。变化范围/成员权限每页复核，权限变更令会话失效，要求刷新 scopes 重开拉取。若裁剪后只剩授权部分，只应用该部分，不等待不可见私人账户。

## 快照与恢复

首次/过期游标：`POST /sync/snapshots` 提交固定生成任务；一致快照中物化授权实体、基准游标、实例/epoch、权限版本与哈希清单，产物默认 15 分钟可下载。`GET /sync/snapshots/{id}` 返回 pending/ready/failed/expired 和 ready 时的 manifest；`POST /sync/snapshots/{id}/pages` 带 client_id/page_token，绑定创建者、设备与权限版本。manifest 包含 snapshot_id、epoch、checkpoint、permission_versions 及连续从 0 开始的 page_index/item_count/sha256 列表。页哈希是该页 items 数组规范化 JSON 的 SHA256，manifest 哈希为整个 manifest 同样规范化后的 SHA256；客户端逐页与总清单核对，确保无缺页/重页。读取每页重新鉴权；超时或权限变化拒绝。快照完成验证后再替换缓存并追赶增量。

普通 `cursor_expired` 先保留 outbox、冲突草稿、未传附件；恢复旧备份的 `epoch_changed` 则必须先保全**完整本地快照**，包括服务器曾确认、已经离开 outbox 的恢复点之后账单。用户比较稳定 UUID 和修订，选择受控恢复，不自动全部覆盖或重放。重建期间原空间只读，新缓存在独立暂存空间校验后原子切换；网络中断保留旧空间。客户端换账号/服务器使用独立分区，未发队列绝不跨身份发送。

参考：[PostgreSQL 行锁与事务](https://www.postgresql.org/docs/current/explicit-locking.html)、[RFC8785 规范化背景](https://www.rfc-editor.org/rfc/rfc8785)。夹具在 [fixtures/sync](fixtures/sync/README.md)。
