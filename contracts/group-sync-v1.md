# 跨页同步组 v1

状态：普通服务端和Flutter同步入口已按`group-sync-v1`协商接入；当前验证及容量边界见[实施分册](../AI/plans/flowtrace/group-sync-implementation.md)。这是FlowTrace协议设计；原`sync-v1`的请求、commit上限和不可变历史页保持。

## 入口与身份

客户端仅在真实`GET /api/v1/server-info`包含`group-sync-v1`时使用；空cursors同样走本协议。正式epoch恢复仍需原有备份、显式选择与快照恢复，不自动重放旧命令。

| 方法、路径，前缀`/api/v1/sync/group-pulls` | 输入与行为 |
|---|---|
| POST根路径 | `{protocol_version:1,request_id,client_id,sync_epoch,cursors}`，201固定pull状态 |
| GET根路径 | 当前本人最多2个未收集handle的安全元数据；不含scope、manifest或账务正文 |
| GET `/{pull_id}?client_id=...` | 当前授权下读取固定状态 |
| POST `/{pull_id}/steps` | `{client_id,step_token}`，有限规划/物化一步；原token精确重放 |
| POST `/{pull_id}/pages` | `{client_id,page_token}`，返回index、manifest或data页 |
| POST `/{pull_id}/discard` | `{client_id}`，实际回收暂存并保留不能复活的request墓碑 |

DTO闭合，UUID规范字符串、修订非负十进制字符串且不超过signed64。JSON拒重复键/非有限数，POST content-type为application/json，正文流上限1MiB；各完整规范wire另限512KiB。重复或未知query拒绝，响应no-store。实际字段及错误信封以[OpenAPI](openapi.json)为准。

status/step/page每次重核当前真实API会话、purpose、client、epoch、控制与权限版本、期限。Web仍须Origin/CSRF，后台Cookie不能作为账务主体。opaque token/group UUID不授予权限。discard及列表允许本人用当前真实API身份找回和清理旧origin/epoch缓存；客户端只认自己的持久request，不自动清其他设备的active pull。

## 固定范围、页链与摘要

创建前持久request UUID、完整原body和base cursors。相同原意图重放优先于新配额，异body拒绝；响应丢失可用安全列表精确匹配request/client/epoch找回。服务端固定当前授权target，规划命中publication任一chunk时纳入当前授权可见的全部chunk；内部publication ID、原chunk计数和私有hash不进入公开wire。不同pull可生成不同随机group ID。

planning/materializing仅提供安全progress_code和next_step_token。ready才返回manifest及其SHA256，绑定instance/user/client/epoch、control/permission版本、base/checkpoint和index页描述。页链顺序：全部index页，随后每个unit的全部manifest parts、全部data页。最后next_page_token为null；前一unit的最后data页可以指向下一unit。

摘要使用既有严格规范JSON，不注入旧投影缺省：

1. 页SHA256覆盖完整page对象去掉`page_sha256`和`next_page_token`。
2. unit manifest SHA256覆盖`{pull_id,...descriptor去掉manifest_sha256}`；descriptor绑定有序manifest parts、完整commit计数与end_cursors。
3. manifest part绑定完整commit SHA/count和每个data页描述；data以commit_index/event_offset拆片，保留原event_index，重组后验证完整commit。
4. ready manifest SHA256覆盖完整manifest。客户端验证所有层级、顺序、数量、token链、完整授权向量和实际事件最大修订与unit end的精确一致。

[完整合成golden](../server/tests/sync/groups/group-ready-golden.json)与[单页golden](../server/tests/sync/groups/group-data-golden.json)由两端共同消费。金额`9007199254740993`和原始字段缺失保持。

## 接收、安装与清理

收页只写schema4独立暂存，不写财务投影或正式游标。完整unit在fresh status/权限和身份核验后，以单个SQLite事务安装全部commit、pending overlay、prefix和唯一receipt，并实际回收该unit暂存；安装失败全部回滚，先前已完成unit保持。安装时重读并核完整链，不能用接收缓存替代。游标CAS拒绝被其他拉取改变的基线。

协调器持久handle、next token及接收位置；离线或重开可用相同request/token续传。每次前台最多64 steps/128 pages，未完成返回`group_pending`；仅回收旧缓存也返回pending，避免误报当前资料已同步。本协议本身不发送outbox；普通同步原有显式push仍按原顺序执行。

过期不假释放配额。discard实际删服务端pages/units并清私有seed/plan，保原意图墓碑，旧request返回410；客户端abandon实际删受控缓存，不改业务游标或原冻结队列。scope/epoch失效清受控缓存并保UUID-only清理标记，供当前身份后续真实回收。

## 防护值与兼容

初始防护：每页512KiB、data页200事件、单commit200事件、unit2000commit、scope1000、unit10000、总页8192（包括私有plan/step）、单session及同用户保留页512MiB、每用户最多2个未收集session。客户端配额计算规范wire与receipt字节，不代表整个SQLite物理文件上限。

每个step采用5秒协作预算及剩余SQL timeout，已完成小步可持久续作；不承诺OS调度/COMMIT硬实时，也不证明全部防护上限的金融性能。内部每chunk私有事件SHA/count与连续/总计数已核，冗余整批私有events_sha256未另行流式复算；公开投影层级摘要完整重算。

旧客户端的增量若命中当前可见多chunk publication，收到原`resync_required`并走完整原子snapshot；单可见commit和无关旧物化页保持原wire/hash。旧snapshot原容量边界保留，不保证旧客户端读取全部大文件。stage上传/大批迁移能力独立验收，不因组同步可用而自动宣告。
