# 运行诊断与脱敏导出

> - 职责：按应用/请求隔离的受控辅助诊断、有界文件收集、多进程串行轮换/清理和独立字段投影导出。
> - 入口：`server/src/flowtrace_server/diagnostics/`、`/admin/diagnostics/export`；客户端 `data/diagnostics/`、`features/diagnostics/`、设置的本机诊断页。
> - 不变量：诊断非业务回执；不保存令牌/正文/原图；失败不改判已提交业务；正式回执/审计仍必须同事务持久。
> - 必跑测试：标准 `python -m pytest tests/test_diagnostic_policy.py tests/test_diagnostics.py tests/configuration/test_diagnostic_collection.py tests/test_attachments.py`；含Windows spawn时禁止无main guard的`pytest.main`包装器；页面另用独立浏览器。
> - 相关：[服务端](server.md)、[后台](admin.md)、[附件](attachments.md)、[日志设计依据](../../.agents/skills/repo-collaboration-logging/references/runtime-logging.md)。

## 当前记录与容量

2026-10-24生产已将OS硬开关与数据库运行开关同时开启，私有目录/文件0700/0600；实际HTTPS错误解析的请求ID与后台导出一致，敏感哨兵、文件名、密码和令牌均未进入导出。新增`import_parse_checked`记录固定格式、错误码、物理行/字段、数量、stage/request UUID；HTTP 200中的解析失败也记录，异步解析可能早于外层事务commit，不能当作金融提交回执。客户端数据工具纳入原有有界诊断环，界面显示具体安全原因和关联ID。

锁定FastAPI的惰性`_IncludedRouter`现在按注册路由递归展开，仅记录合法路由模板。Python3.13将标准Handler改为`with self.lock`，原先刻意无全局I/O锁的路由handler因此无法落私有文件；现显式实现`handle`的过滤/emit分派，保持每policy/store各自锁，避免慢探针阻塞其他应用。Windows定向30项及Linux3.13真实Uvicorn请求/私有导出通过，原轮换/容量规则不变；修复、第一次失败及生产回执见[本包记录](../logs/2026-10-24_qianji-export-import-fix.md)。下文保留原有分次测试范围。

2026-10-23新增`diagnostics/policy.py`：`build_diagnostic_policy(settings)`持每应用独立策略与惰性私有store，`bind_diagnostics(policy)`以ContextVar限定HTTP/worker/CLI作用域；无上下文时不收集私有文件。全局日志只持stderr与一个无目录的路由handler，不因第二个create_app替换第一个应用的文件目录。每个policy独立日志阈值和close，关闭一个不影响另一个；普通新thread默认无policy，AnyIO线程池复制上下文，其他线程须受信调用方显式copy_context。root已接应用/请求/worker/cleanup CLI作用域及async事件线程池；真实PG/HTTP后诊断字段已标effective，配置页面为七项已接、三项待接。

OS `diagnostics_enabled=False`为硬关闭，既不查DB也不建诊断目录。OS允许时，每次文件锁取得后的guard通过独立NullPool/autocommit固定head SELECT读取最新已提交开关；完整十键快照无效、DB不可达、读取超时、探针忙或缺配置均仅抑制私有记录。每policy最多一个非阻塞探针，忙就丢辅助记录，不排队占业务pool；探针不借业务Session、不装maintenance事务围栏、不取User/head行锁，默认只读，statement100ms/lock50ms/connect1s。连接/DNS的OS行为不宣称绝对墙钟硬截止。业务事务未提交的新值不作为已生效值。

stderr结构化运维输出继续按进程阈值运行，正式DB audit不经此开关。文件诊断是best-effort，关闭不会删除既有文件。后台导出同时核OS硬开关与当前策略，关闭/不可读时503，即使旧文件仍在。禁止在event里复用业务事务Session或等待其行锁后另连接读配置。

旧的 `flowtrace_server.diagnostics` 导入兼容，现为包。HTTP 日志包含服务端 request_id、固定事件、注册的路由模板、方法/状态/耗时；领域可显式带合法 UUID operation_id/entity_id/scope_id。事件/错误码受控、UUID 解析、数值有界、未知字段丢弃；不接受请求 URL/query、密码、token、Cookie、账单正文、图片、原始异常或任意自由文本。业务提交事件应在真实 commit 后输出，新提交与幂等重放分别处理；诊断不能反推正式提交结果。

默认 `FLOWTRACE_DIAGNOSTICS_ENABLED=true`，私有位置 `FLOWTRACE_DATA_DIRECTORY/diagnostics`。JSONL 单记录最多 2 KiB，单文件 1 MiB、3 份轮换、含当天 7 个 UTC 日期、受管合计 8 MiB；下一次写入执行清理，容量可使保留早于 7 天结束。超大记录保存合法的省略 JSON，不截断 JSON 字节。文件仅短期开句柄，线程锁和 portalocker 跨进程锁覆盖追加/轮换/清理，等待最多 2 秒。当前 portalocker 固定 4.4.1，所有参与进程必须使用同一锁约定。

只管理精确文件名、有效日期、单链接普通文件；不清理陌生文件、符号链接、junction、硬链接、配置或业务数据库。新建 POSIX 0600/0700；Windows 目录 ACL 仍由运行身份管理。未声明网络文件系统支持，Windows 多进程通过不替代 Linux 验证。

写/轮换/锁失败返回非关键失败信号，不抛回已提交业务；独立 stderr 固定提示按每进程 60 秒限流，不包含原记录/异常。不能把正式同步回执/管理审计套用这个策略：附件完成的正式审计写入失败有真实事务回滚检查。

## 导出

后台审计页提供“导出脱敏诊断”，仅当前管理会话/角色可访问。导出固定目录，没有路径参数，最多 1 MiB；每条原 JSON 再做白名单投影，拒绝/省略非法数据，超限输出明确 export_truncated。返回 JSONL、私有无缓存、nosniff、安全固定下载名，并同事务记录下载审计。不是原文件打包，也不声称把自由文本自动脱敏。原始 AI 请求/响应没有开启或保存功能。

管理员只能取得这些辅助元数据，不能通过导出读取私人账单/备份或其他文件。现有文件损坏、不可读或锁失败给安全错误，不返回原始路径。诊断关闭则导出 503；健康与业务写入不依赖诊断磁盘可写。

## 验证范围

本轮独立标准模块策略/原store24项通过（0.77秒），包含OS hard-off、严格bool/读取异常、文件锁后fresh guard、并行app/AnyIO上下文、普通thread无继承、单例handler/独立阈值/close、慢探针不持全局handler锁及单probe非阻塞限额；Windows spawn三进程目标实际执行。回执`outputs/validation/P5/admin/diagnostic-policy-ffbb7f2a-bca2-4d3e-ad80-dce1958c0e6f.xml`。

随后新d4a5隔离库标准`-m pytest`39项（12.33秒）覆盖24策略/store、3真实PG与12附件；PG真实committed false后下一条私有记录不增而正式配置audit仍在，重新true恢复；同调用方持head UPDATE及exclusive maintenance advisory时探针仍读已提交值不等行锁；schema ACCESS EXCLUSIVE时短budget failclosed且业务连接不受影响。`diagnostic-runtime-0947fad2-093d-40d6-b465-7486bfca7ee3.xml`通过。

完整配置POST/export专项5项（5.46秒）使用真实create_app且无dependency override：CSRF/当前密码提交false成功且尾部诊断不增、后续live200/export503/旧文件字节不变；提交true后live/export200恢复；第二OSfalse应用无诊断目录/export503，关闭它不影响第一应用。schema锁下live仍200。回执`diagnostic-http-33937452-bf43-4f5b-95e3-e219a5c4a0c8.xml`。root另有真实多app与async offloop两项，不能把线程池或Lambda单测代替DB/HTTP切换证据。

最终相关合并158/158（36.53秒、无skip）覆盖configuration整目录（含root两项）、策略/store/Windows spawn与附件，`outputs/validation/P5/admin/diagnostic-combined-c879116d-7d5c-422f-968d-a544bdfc73b9.xml`。唯一warning为原Starlette/httpx弃用；前一条错误测试文件路径命令无目标执行，`diagnostic-combined-a2e60c02-dd49-452a-bfa9-48d41d153a6c.xml`保留，不当通过。该回归在d4a5的0011快照执行，后续root新0012/其他模块单独核，不回填此历史范围。

首轮把spawn目标放进无main guard的programmatic pytest.main runner导致子进程重进并递归跑PG目标，另有审计断言字段错误，`diagnostic-runtime-97e51989-1f3f-4fb0-8648-968d1f48b36f.xml`失败保留。旧35f859只读核head0/true/revision0但users6，保留且不再当空库；spawn进程已自行结束，未按进程名杀。后续使用新隔离库和guarded env launcher的标准`-m pytest`子进程，不追溯改写失败或历史通过回执。

独立测试覆盖字段与再投影、轮换/保留/总量/完整 JSON、未知文件/链接保护、写失败节流、锁等待和 3 个 Windows spawn 进程的 60 条完整记录。真实 PG 测试覆盖管理员导出、未登录拒绝、令牌/密码不在包内、诊断失败仍业务成功，以及正式审计失败时原子回滚。

主代理真实浏览器下载路径已通过：合成管理员经审计页取得 2406 字节/12 行脱敏 JSONL，仅固定元数据；已退出后台。截图 `outputs/validation/P2/admin-diagnostics-export.jpg`。深层恶意输入证明来自独立测试；完整后台检索/角色筛选/保留配置与 Linux/systemd 日志管理属于 P5/P8。参考 [Portalocker](https://portalocker.readthedocs.io/en/latest/)。

## 客户端本机诊断

`ClientDiagnostics(LocalRepository).recordQuietly(space,event,...)` 只接受固定事件、有限错误码/类别/方法、规范 UUID operation_id/request_id/scope_id/entity_id，以及有界状态/耗时；写入错误返回 false，不向正式业务抛错。记录保存在该资料空间的 `diagnostics.v1.{space.id}.ring` appSettings，最多 100 条/32 KiB，超过时移除最旧记录。未知/嵌套自由文本不能进入投影；记录损坏只影响辅助诊断，不改业务回执。

`ApiClient` 的安全 metadata callback 提供实际 `X-Request-ID`、状态、耗时与固定路由类别，身份层捕获原资料空间/generation并丢弃迟到身份记录；同步操作将 UUID operation_id 传入关联。附件仅在实际暂存/上传/校验下载/撤权后记录相应元数据。API 不传原 URL/query、body、图片、token 或 header 集合。

本机诊断页显示真实记录或空态，刷新不生成虚构记录；用户主动点击“复制脱敏诊断”后，`exportJsonl` 再投影全部持久记录，最多 64 KiB，复制标准 JSONL。页面绑定资料空间，换账号清空旧列表。四项客户端存储测试覆盖真实 SQLite 重开、并发限额、恶意既有数据再投影、诊断失败不影响已存业务；widget 测试覆盖空态、真实记录、主动复制与切换资料空间，换账号清列表修复后已单独重跑一项通过。客户端诊断不等于服务器正式审计，不作为同步成功判据。

2026-10-21 新版普通 Flutter Web 在真实 Edge 完成设置→本机诊断→刷新→主动复制：3 条实际 HTTP 请求 UUID 记录，638 字节/4 行 JSONL，仅含白名单元数据；console error/warn 为空。最后确认退出并撤销本次合成 QA 会话，关闭测试标签。该结果与独立 IndexedDB harness 分开记录，详见 `outputs/validation/P2/attachment-client-receipt.json`。
