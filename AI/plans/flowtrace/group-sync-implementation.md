# 跨页同步组实施与验收

> - 职责：将迁移发布的多个commit作为一个当前授权单元收取并原子安装，保持旧同步协议和原始字段语义。
> - 入口：先读[当前进度](progress.md)；服务端`sync/group_*`，客户端`data/sync/group_*`及schema4。
> - 不变量：公开ID随机且只属于固定pull；接收不写账务；一个unit同事务安装投影/游标/receipt；失效缓存真实清理后才释放配额。
> - 必跑测试：独立PG的`server/tests/sync/groups`与旧分页；客户端`test/data/group_*`及data/sync回归；最后需真实HTTP和普通浏览器旅程。
> - 相关：[大批迁移](large-import-implementation.md)、[服务端同步](../../modules/sync.md)、[客户端同步](../../modules/client-sync.md)、[交付](delivery-local-test.md)。

## 目标与当前状态

本分册承接用户已授权的非安卓P5–P7和最终Windows/Web/APK、本机持久测试服务。Git main无提交基线，保留原研究、QA与失败现场；不操作安卓设备。普通客户端协调器、真实能力协商与main六操作已接入，生产HTTP丢页/重开专项通过；stage大批页面和普通浏览器/Windows完整旅程仍需后续。

服务端0012三表在新4206库完成0011→0012→0011→0012及metadata无差异，instance/epoch/config保持。纯DTO/primitive33与真实PG20同次53/53、无skip（135.97秒），包含50,001新增合成历史及原book事件的初始空cursor→ready→完整页流，本轮该大目标115.20秒；不是50,001笔真实金融写入性能。真实deadline目标4.25秒：pg_sleep6被剩余SQL预算中断，只回滚当前work savepoint，已完成work提交并可续作。独立HTTP与纯/PG相关58/58，认证移出event loop后6/6分次通过；当前main已挂group六操作、真实cap已宣告，stage仍不挂。唯一OpenAPI55路径/151schema/62操作，合同21通过。当前整体稳定head为0013保留保护迁移，新组同步联测库明确升0013，旧4206/cd62保持0012。

客户端schema4新增group_pulls/pages/receipts，JIT代码生成41秒，补receipt字段后增量23秒。协议/存储/多unit/协调器34目标通过；普通SyncEngine接入后data/sync/identity223/223，新完整908通过/6专用live默认跳过（45秒），窄分析无问题，全分析执行中。含Python共同golden、大金额和raw缺省、单commit跨页、schema3升级/文件重开、两index/每unit两metadata part、首unit有后续token仍可安装、第二unit失败保持第一receipt、末写失败/迟到身份/坏页全组回滚。旧159是独立审阅修复前快照。

新专库`flowtrace_test_p5_jobs_164327289e8e48a6`及自持18093生产main完成真实TCP专项1/1（7秒）：201条每笔125分真实expense经HTTP stage→Worker parse/preview/apply形成三chunk publication；owner/viewer分别成功页丢失→SQLite关闭→离线重开→同session/client/request/token续传，正式cursor只在完整unit推进。各3receipt且publication恰一份，201账单/25125分支出一致，owner私有现金余额`9007199254715868`和PNG下载hash正确、viewer不见账户且图片403；原冻结待传行/完整草稿不变、push0。后验active_owned_sessions0、强制撤销0、无额外handle回收，宿主线程停止。回执`work/flowtrace-group/live/e7b80efcd11748268ef8839b0468bd48/public-receipt.json`，命令/准备与边界见[真实联测记录](../../../tests/e2e/sync/group-http/README.md)。stage此时仅harness显式include，不把它当主能力；未覆盖系统安全库/普通UI/Android/Linux。

## 固定协议与存储

`group-sync-v1`为独立protocol_version=1，正式前缀`/api/v1/sync/group-pulls`，wire见[契约](../../../contracts/group-sync-v1.md)。创建前持久request UUID及原base cursors；原意图恢复优先于新配额，相同request不会重建另一pull。首次初始化使用空cursors走新流，不无限回落旧50,000-event增量或200,000-item快照。

每步最多5秒协作预算；SQL按剩余预算设timeout，规划本身可持久续作，不在一次HTTP中加载40万金融event。初值为每页完整envelope512KiB且数据页200events、单commit仍200events、单unit最多2000commit、scope1000、unit10000、总页8192、单session/同用户留存页512MiB、同用户未收集session最多2。这些是防护值，未证明全部上限的性能。

三表保存origin、原意图、固定base/target及控制/权限版本、内部发现序和最终拓扑序、有限规划状态、私有plan/step帧、真实规范JSON字节预留。内部publication UUID5 namespace和chunk index/count/hash不发viewer；固定pull内随机opaque group_id，仅可见commit重新稠密排序及投影摘要。只有ready才发manifest。

页链顺序为全部index→unit0全部manifest parts→unit0全部data→unit1 manifest/data，末页next=null。各页index按本kind/本unit计数；前一unit最后data的next可以指向后一unit，不影响前一unit完整性。root manifest绑定index页摘要；index绑定unit descriptor与分部摘要；分部绑定完整commit摘要和数据页摘要；数据fragment保原event_index和offset。原始投影缺省不被解码器补入再重算hash。

内部HMAC seed仅用于可恢复opaque token且不进wire/日志；每次status/step/page仍核真实当前会话、purpose、client、epoch、控制与权限。规划若选中publication任一commit，闭包纳入当前可见全部chunk；每chunk验证实际私有事件SHA/count及连续顺序/总计数。冗余整批events_sha256未重新流式复算，不能声称已核；公开投影层级摘要另行完整计算。

## 客户端边界与审阅修复

创建意图、进度handle和分页token可持久恢复。所有页仅写受控暂存，完整unit后以一次atomicWrite复用既有applyPullPage：只保一个完整commit的事件buffer，全部投影/本机pending overlay、最终prefix、receipt与实际暂存回收同事务。安装前fresh授权manifest/权限与lease、当前cursor CAS；安装时重新读取和验证链，不采用接收阶段缓存替代。

接收阶段只缓存两个不可变manifest/unit/metadata，unit按index descriptor计数直接定位唯一页，避免每页反复扫描先前全部index/metadata。安装重核绕开缓存。配额指规范wire及receipt字节，SQLite页/索引物理开销另受磁盘错误处理；不宣称限制整个SQLite文件大小。

独立审阅真实复现自洽hash把end/checkpoint提到3、实际event最多2仍推进cursor，红回执保留。现安装合并各授权域previous或0与本unit实际event最大revision后精确核end，不能只核event<=end。另修完整暂存恰满时额外receipt无空间的停滞：同事务按已全核且实际删除的本unit页净额核配额，失败连释放一起回滚。

过期本身不释放真实缓存。服务端显式discard删pages/units并清seed/私有plan，保原request/intent tombstone，旧request410；本人当前API可清旧origin/epoch缓存，不要求先恢复旧权限。客户端abandon实际删受控页/receipt，留不能复活的request tombstone，原账务游标和用户输入不动。两槽只排除真实collected/done/abandoned，留存字节仍真实计入。新安全元数据列表解决创建响应丢失后找不到pull_id的问题，客户端只匹配自己的持久request，不自动删除其他设备active读会话。

## 旧客户端与下一步

旧sync-v1新增量若命中当前授权可见多chunk publication，返回既有resync_required，让旧客户端走完整snapshot后一次安装；不会把多个独立增量页当组原子。单可见commit保持原wire，未关联新publication的旧物化页保持原JSON/hash。新6项真实PG（含旧分页）通过7.91秒。旧snapshot仍有原容量边界，不以此声称旧客户端能接全部大文件。

全分析已无问题8.1秒，正式main HTTP六目标在另新6a2e库6/6、3.85秒，session/handle0后验通过（fixture SQL回收不冒充客户端logout）。当前整体head已推进0014 source-release，旧组同步两个专库保持原head。本分册前述0013/候选描述为形成各回执时的状态；全局恢复以progress为准。

下一项具体动作：接stage源生命周期/清源后undo/非空stage恢复和普通大批迁移页面，再做独立Chrome与Windows完整旅程。0014先在候选路径两次PG升降审核，之后原子发布并仅新c76库登记升级；不能并发半发布head。最终产物/持久部署保持在业务验收后。
