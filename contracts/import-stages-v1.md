# 大文件导入暂存协议 v1

2026-10-23普通main已挂17项路由并声明`import-stages-v1`，依赖同时协商的`group-sync-v1`；实际OpenAPI72路径/176schema/79操作。新隔离库main HTTP相关首包86通过、1新测试错误预期；空正文实际422与合法GET未登录401分别确认后，该单项复跑1通过。客户端schema5完整1009通过/6专用live默认跳过，真实TCP/普通浏览器旅程另验；旧服务和旧产物不因此更新。普通导入50行、导出1000项和旧同步commit限制保持。

业务入口为`/api/v1/data-tools/import-stages`。客户端先保存完整原件、固定stage UUID、原创建正文和账号绑定，再请求创建；任何任务回执只表示真实任务元数据，不表示金融发布完成。正式账务以服务端事务及[整组同步](group-sync-v1.md)安装结果为准。

## 输入与容量

- 原件非空且最多50MiB，连续分片每片最多512KiB、最多100片。分片使用PUT、`application/octet-stream`及`X-Chunk-SHA256`，query携带当前stage_version；每片和整体均核实际SHA256及长度。
- 每人最多8个未实际释放的源、200MiB预留。过期时间本身不归还配额；只有实际删除暂存字节后才释放。已发布金融记录不因源TTL到期重新开放导入。
- 原件最多200000行，需求清单最多200000个唯一原引用，名称最多2000个Unicode字符。源物理行号可大于记录数，不能将空行或多行备注后的真实行号误限为20万。
- 普通JSON请求和响应仍受1MiB上限约束。分片不放大全局请求限额；名称映射是一个有界JSON正文，分页读取需求清单不会解除其写入上限。50MiB/20万行与1MiB映射是独立限制，不承诺任意20万种不同资源都能放入映射，也没有20万行性能结论。
- JSON拒绝额外字段、重复键、NaN、浮点金额、过深结构及NUL。金额沿用字符串整数、币种精度和领域契约，不能经浮点转换。

## 动作与身份

所有动作均核当前真实API用途会话、本人、client及当前服务epoch；普通状态、上传、分页、映射和金融请求还核原origin绑定。每次版本变化使旧预览和旧分页失效，不把当前GET结果替换成旧请求正文。

| 路径与方法 | 当前行为 |
|---|---|
| POST根路径 | 必填固定stage_id；同v1、相同规范化创建正文和原绑定精确找回，不重复预留或创建批次 |
| PUT `/{id}/chunks/{index}` | 连续片序，相同片真实字节/hash重试幂等，异正文拒绝 |
| POST `/{id}/seal` | 固定版本、总长度/SHA，完整核对后仅排同一解析任务 |
| GET `/{id}` | 真实状态、版本、计数、任务ID、requirements及mapping摘要，无原件或金融正文 |
| GET `/{id}/jobs` | 当前origin/版本下读取最多4个真实任务摘要：action、job UUID/版本、status、attempt、安全error_code、available_at、lease_until，不返回payload/result |
| PUT `/{id}/mapping` | 当前版本CAS，成功版本加1、旧派生/预览失效、原件保持，并排重新解析 |
| POST `/{id}/preview` | 固定版本的领域预览任务，完成后提供preview_hash；不是写凭证 |
| GET `/{id}/rows` | 固定版本、最多100行及明确continuation；错误保真实原行，不静默截断 |
| GET `/{id}/requirements` | 固定版本完整原引用清单的有界页，绑定整体SHA；不重扫原件 |
| GET `/{id}/source-books` | 从当前持久合法book行分页提供原source_id/name/currency/timezone和原position，总count明确；不含账单金额/备注，不重扫原件 |
| POST `/{id}/apply` | 当前版本、batch_id及preview_hash共同确认，沿固定任务找回；发布全批与任务成功同事务 |
| POST `/{id}/undo` | 固定stage/version/batch，重新检查当前写权、item修订/hash和新增引用，全批反向发布 |
| GET `/{id}/reauthorization` | 本人新会话可只读核stage/batch/version/format/bytes/source SHA/mapping SHA/status/source_released/expired；不续期client、不写绑定或任务，不授金融写权 |
| POST `/{id}/reauthorize` | 用户明确确认当前版本及新client/epoch，真正当前权限复核后绑定新会话并推进版本；已发布只续撤销，原apply保持 |
| POST `/{id}/cancel` | 原origin和当前版本下明确取消，真实删除暂存字节；已进入金融处理拒绝 |
| POST `/{id}/discard` | 本人明确放弃未导入源，精确版本/batch/client/epoch/source SHA，允许旧origin失效或源TTL过期；保守拒绝applying和任何正式Batch/Publication，不改变origin绑定 |
| POST `/{id}/source-release` | 本人当前绑定下显式释放已发布原件，固定request/batch/version/client/epoch/source SHA，实际删除暂存派生并追加不可变审计；正式账务保持 |

source-books的position是原记录序号，可以稀疏，不是CSV/XLSX物理source_line，也不能套普通rows的连续页计数。它只是本人选择图片目的源账本的材料，正式预览仍核实际引用与映射冲突。

任务摘要独立于StageStatus及冻结ACK。排队apply时stage可能仍为ready，不能据此忽略已经失败的真实任务；失败的同任务重发请求只找回原任务，不自动重排。任务按实际stage持久UUID、owner/kind/epoch及闭合原payload/hash核对，版本可早于重新授权后的当前stage版本。读取摘要不续期client或创建新任务；安全error_code不等于原始异常文字。

## 映射与图片

Qianji文件创建时至少明确目标scope、时区和币种/精度，原资源名称由完整requirements逐项选择。原生文件内定义与外部引用分开：外部scope/resource UUID仅为待选择的来源，不代表服务器授权。

`mapping_hash`等于完整默认值展开后的StageMapping之规范JSON SHA256，Unicode键按码点排序，UTF8且不转义中文；两端共同黄金位于`server/tests/data_tools/fixtures/stage_mapping_golden.json`。它只用于期望映射状态核对，不是金融授权或回执。

图片必须由本人选择原件并经过现有本人user-scope附件上传，禁止主动抓取外部URL。原生图片须匹配manifest的真实hash/size/media。原图ID经`resource_mapping`映射到实际上传ID，`attachment_transfers`以实际上传ID为key、明确的目的源账本为value；Qianji图片名则经`template_mapping.image_urls`映射上传ID并同样声明transfer。不能用随意生成的UUID或最后一条预览行猜目标。

## 丢回复、重新授权与本机保留

创建、分片、映射和金融命令先持久冻结正文。映射回复丢失，只在远端恰为N+1且规范化mapping_hash等于原期望值时核对期望状态；不接受任意更高版本，不重复发送已成功的旧PUT。

重新授权预检只证明本人可读该来源。即使N+1和hash相同，也不能据此认为当前会话赢得重新绑定；真正POST后还须普通严格origin GET成功、版本精确匹配，才在同一SQLite事务保存真实确认和新绑定。原source/create/origin历史及冻结命令不改。丢映射回复后的预检证明保留为独立metadata，不伪造缺字段StageStatus或金融ACK。

discard已实际cancelled且来源/派生为空时，允许当前版本或当前版本减1的同来源请求返回真实期望状态，不再推进版本；这不是金融回执重放，也不建立新origin。客户端只能在用户明确确认后采纳终态并释放本机副本。处理中但任务失败且无正式发布的模糊状态需要独立reconcile，不能猜测安全后清理。

源释放回执保存第一次真实JSON；重放只允许`replayed`差异，旧缺省deleted_requirement_rows只在typed比较时扩零，不能修改原回执。服务端删除不自动删除本机原件；本机显式删除也不删除独立恢复备份的BLOB副本。

## 金融可见性与验证边界

parse只写暂存，preview为rollback-only领域检查；正式apply/undo全批账务、ImportBatch/Items、所有Publication/Chunks及任务成功共用一个服务端事务。客户端收页只写独立暂存，完整unit复核后一次SQLite安装；原outbox和草稿保持，不顺带push。

正式stage刷新要求完成一次在该次调用中新建的group pull，旧固定快照不代替导入后的刷新。最多先完成两份旧pull，整个调用仍合计最多64步/128页；未完成保进度并报告pending。pull后重新GET真实stage相位/hash；其他设备撤销或转undoing时不能沿旧GET显示导入成功。

当前后端分项、真实备份恢复和客户端分项证据分别见[数据工具模块](../AI/modules/data-tools.md)与[实施分册](../AI/plans/flowtrace/large-import-implementation.md)。普通main已接能力与完整映射页面，真实跨端图片/大文件旅程及最终三端产物仍按[当前进度](../AI/plans/flowtrace/progress.md)闭合，不能由本文或纯DTO测试推算完成。
