# group-sync-v1 服务与独立HTTP分项验证

> - 职责：新协议闭合DTO、授权投影/拓扑、有限步持久物化、分片与当前认证的HTTP边界。
> - 入口：[模型](../../../src/flowtrace_server/sync/group_models.py)、[DTO](../../../src/flowtrace_server/sync/group_schemas.py)、[服务](../../../src/flowtrace_server/sync/group_service.py)、[物化](../../../src/flowtrace_server/sync/group_materializer.py)、[独立路由](../../../src/flowtrace_server/sync/group_router.py)。
> - 不变量：不改旧v1物化页，不暴露内部UUID5 namespace，完整commit仍≤200事件；ready以前不提供领域数据。
> - 必跑：明确隔离PG环境下，从`server/`运行`.venv/Scripts/python.exe -m pytest tests/sync/groups -q`，并执行owned Ruff。
> - 相关：[组同步分册](../../../../AI/plans/flowtrace/group-sync-implementation.md)、[大批迁移分册](../../../../AI/plans/flowtrace/large-import-implementation.md)。

2026-10-23（Asia/Shanghai），纯/DDL首包33项是历史证据`outputs/validation/P5-group-primitives-hierarchy.log`。随后主代理注册三表并在新4206专库完成0012升降升/metadata无差异；本代理同次纯33+实际PG20共53/53、无skip，135.97秒，证据`outputs/validation/P5-group-service-final.log`。包含任意末chunk cursor闭包、原session/设备/epoch/撤权/TTL、实际并发step幂等、配额回滚、真正discard和request tombstone。50,001新增合成历史加原book事件由空cursors完成ready和完整页流，该目标本轮115.20秒；这是合成历史传输，不是50,001笔金融写入性能。

历史独立HTTP6目标使用另一个新cd62专库head0012；与纯33/PG19（该次明确deselect已验大bootstrap）合并58/58，23.10秒，owned Ruff通过，证据`outputs/validation/P5-group-http-final.log`。当时路由只在测试app显式include。覆盖create→step→status→完整层级页流、旧step精确重放、原始投影与大金额保持、真实api_web Origin/CSRF、严格JSON/query及流式1MiB界、创建响应丢失后换session+撤权仍可安全列本人handle/清理。随后主代理将group路由和真实`group-sync-v1`挂入main；HTTP fixture已删除重复include，改核普通main组入口401/真实cap存在，同时stage路由与stage/large-import能力仍不公开。mounted HTTP和真实TCP两端的新回执见下文；旧绿回执只代表原测试入口。客户端协调器、普通浏览器或Windows完整旅程证据由主代理在组同步分册维护。

主代理随后指出async路由内同步认证SQL可能阻塞event loop，create/steps/pages/discard现均顺序`await run_in_threadpool(authenticated_request, ...)`后再执行service，GET仍同步路由。HTTP fixture对真实认证增加“不得运行在event loop”的断言，修后6/6通过，4.93秒，回执`outputs/validation/P5-group-http-threadpool-final.log`；未重复大bootstrap。

正式main挂载后的6项HTTP已在新6a2e专库/head0013通过，最终3.85秒，`outputs/validation/P5-group-http-mounted-cleanup-final.log`。六个实际APIRoute直接核body_field，避免延迟IncludedRouter导致空循环。fixture仅清本测试新增用户的受控cache并SQL撤销测试session；本专库首轮自有残留也精确清理，12用户/领域行/instance/epoch保持，活跃会话及未collected handle均0。后验为`outputs/validation/P5-group-http-mounted-postconditions.json`；该fixture清理不冒充真实客户端正常退出。普通main组能力与stage仍未公开的差异已由HTTP证明；真实TCP/SQLite两端另外1/1见[联测](../../../../tests/e2e/sync/group-http/README.md)。

新表为`group_pull_sessions`、`group_pull_units`、`group_pull_pages`，保留真实origin session/purpose、原request_id+intent hash、base/target保留pin及有限步内部位置。规划每次仅小批metadata或一个完整commit的正文；按剩余时间设置SQL timeout，预留最后鉴权/提交时间。真实`pg_sleep(6)`在约4.25秒中断第二work，仅回滚其savepoint，第一work持久保留并能续作；不是对OS调度或COMMIT交付的硬实时保证。规范JSON字节预留不等于PostgreSQL物理文件大小上限。

过期数据仍占两槽及字节配额；`discard`实际删pages→units、清seed/private plan与保留pin，再留下原request/intent墓碑，重复旧request返回410。本人当前API认证可清旧origin/epoch/权限缓存；不据expiry假释放配额。根GET列表只返回最多2个未collected记录的`pull_id/request_id/client_id/sync_epoch/status/expires_at`；超2明确503，不静默截断，不返回scope、manifest或正文，不自动清他设备active会话。未来SyncChange GC须尊重全部未collected base/target范围，不能只保护代表行FK。

闭合wire使用`group-sync-v1`，独立protocol_version=1。Create不接受路径、URL、origin或预算；planning/materializing状态只提供固定code和step token，ready才提供可安装manifest。每个完整JSON envelope上限512KiB，各data页总事件≤200；单个大event不能截字段，安全拒绝。200条各2000字符astral备注的合法AccountData超过1MiB，纯及PG分项均通过多页event_offset重组，金额`9007199254740993`与缺失默认字段保持。该结果不是200条真实金融入账性能。

层级摘要采用既有严格canonical JSON与SHA256：

1. data、unit-manifest、index页均对完整page对象去掉`page_sha256`和`next_page_token`后计算hash；pull_id、group_id（适用时）、kind、页序及原始投影均在hash内。token依靠服务端查表和当前鉴权，不作为hash授权。
2. UnitDescriptor的manifest_sha256计算`{"pull_id":当前pull, ...UnitDescriptor去掉manifest_sha256}`，其中manifest_parts按顺序绑定每个元数据页。index页进一步绑定这些descriptor。
3. PullManifest绑定instance/user/client/epoch/control/permission/base/target及index页descriptor；ready状态的manifest_sha256为整个PullManifest hash。
4. descriptor.item_count在index指unit数量，在unit-manifest指commit/data-page描述符合计，在data指原始event数量。分片不能改原event_index；commit_index只对可见commit稠密编号。

[单页golden](group-data-golden.json)固定原始JSON及缺省语义；[完整层级golden](group-ready-golden.json)给客户端实现提供ready→index→unit manifest→data链。两份均为合成数据，无真实凭据。内部publication/stage UUID不进入wire；同一固定pull的opaque group_id可重放，另一pull可另生成。纯拓扑需要调用方已经证明所选历史prefix及publication闭包完整，它本身不能证明真实DB没有漏选。

私有publication先验证连续完整chunk顺序、每chunk完整私有事件SHA/count和总chunk/event计数；不重读整批复算冗余`events_sha256`，未声称已核此值。公开投影重新计算可见commit与全层级摘要，不复用私有count/hash。内部HMAC seed仅私有state保存，固定pull的token按domain/purpose生成；每次重放旧step前仍检查当前auth/权限/TTL。

当前防护初值为每页512KiB、每session及同用户留存合计512MiB、scope1000、unit10000、总页8192（包含私有plan/step）、单组最多2000 commits/400000 events、每用户保留2session、每步5秒协作预算；这不是全部上限的容量承诺。迁移、registry、普通主路由与最终capability由主代理统一接线；group已接入，stage仍需后续闭合。首轮UTC表示差异、测试随机scope次序假设及HTTP fixture错误的红回执保留，没有修改旧结果充作绿证据。
