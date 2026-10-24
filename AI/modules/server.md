# Python 服务端

> - 职责：独立 Python 包、HTTP 身份/账本权限、PostgreSQL 迁移和安全诊断。
> - 入口：`server/src/flowtrace_server/main.py`、`server/README.md`、`server/migrations/`。
> - 不变量：不依赖 Flutter/容器；未实现路由不假成功；不回显凭据；启动不自动迁移；管理员没有私人账本隐式权限。
> - 必跑测试：服务端 `python -m pytest tests`（真实 PG 需本机隔离库）；构建 wheel 检查模板、静态资源和迁移。
> - 相关：[后台](admin.md)、[附件](attachments.md)、[诊断](diagnostics.md)、[报表](reporting.md)、[领域](ledger.md)、[API](../../contracts/api.md)、[权限](../../contracts/permissions.md)、[架构](../plans/flowtrace/architecture.md)、[工作区](workspace.md)。

## 当前入口

2026-10-24 Linux生产已独立安装本节M1 wheel：Python3.13.5/35项hash锁定依赖，36包依赖检查通过；原生PG17.11新本库真实迁移0001–0016/check通过，专用非root API/worker由systemd持续运行。HTTPS身份、图片、精确账务与重放、备份/隔离恢复、受控重启均已验，范围与页面限制见[生产部署](production-deployment.md)。以下M1“未部署”及其他运行包描述保留为各日期历史证据。

2026-10-24 M1仅补建现有源码的独立wheel（旧7包最高0006、均无本地部署入口）。新425738B/SHA47bad6e7…d3ba8，来源0926681，含0016与local_test_service；220源码成员逐字节一致、222 RECORD及Python编译通过。实际从wheel展开目录import，以开发venv依赖做6项ASGI live/static/admin-login/404检查通过；无真实DB/独立依赖安装/持久启动，不能称服务部署。冻结位置及客户端旧版边界见[候选清单](../plans/flowtrace/alpha-candidates.md)，M2/M3逐包验。

当前唯一head为`0016_backup_quarantine`：全新b75d库两次升降后原子登记，升级仍52表/metadata=[]、原9trigger/6function及identity/config保持。DDL只扩kind CHECK，遇隔离任务降级拒绝且不删任务；runtime现接隔离执行，facade21/后台-Worker11分次通过。完整jobs新005e库68通过/1图片默认skip、另新2a1图片1/1；旧恢复替身漏before_read的6失败修fixture后绿，未改宽生产。0015清单、0014源释放和0013保护保持，requirements168及非空恢复1为此前证据。旧QA不迁。

备份当前reader已持源共享lease、创建排他lease，可信新包任务证明与真实job/owner绑定hold接入入队/重试/Worker完成事务；相关124/124与实际pg_dump/Worker登记2/2为分次验证。旧包不自动登记，释放后不复活原hold；保护服务/零删除预览139通过。隔离执行/普通后台已接，Windows扩展路径修复实际红绿17、PG/HTTP27、路径别名24分次通过；同深度独立2890 Chrome入队5/完成3与真实CLI Worker通过。641c无receipt partial保留，旧包未移动，无purge。专用未领取取消PG25通过，root页面已接、HTTP/Chrome继续。

普通main现挂stage17操作并协商`import-stages-v1`，实际OpenAPI72路径/176schema/79操作，合同21/21。新1d246库stage/group/metadata/discard/CORS等相关首包86通过/1新测试错误预期（空body实际422）；补合法GET401后单项1通过，生产无更改。source释放/完整映射与schema5客户端已接，c462与新d1ba真实TCP native各1通过；两次followup分别因测试窥读改变attempt_count与实际group_unavailable失败，现场保留、未称完整续接撤销通过，普通8bb7 Chrome进行中。以下test-only/55路径等属于当时快照。

0010五张迁移暂存/发布表及0011两张[服务配置](configuration.md)表在本轮隔离库升级，均已做升降升与metadata核对；明确的本轮8d6b/0b7c保数据加法升级另有回执，不将旧库重当空库seed。配置现七runtime消费者，诊断POST/export/multiapp与相关158通过，保留/OCR/AI三项pending明确显示。provider端点和恢复target仅在OS配置、排除公开Settings/备份设置快照，不来自后台表单。

2026-10-23完整数据工具169/169、0skip含真实dump/verify/隔离恢复；四阶段Worker主专库62通过/1图片deselect和图片专库1通过/3非图deselect分次留证。stage源独立PublishedStageContext相关48、test-only HTTP18通过，源释放闭合前仍不挂main。组同步已挂普通main，协商group-sync-v1，生产客户端真实HTTP专项1/1通过；当前唯一OpenAPI55路径/151schema/62操作，合同21/21。稳定0013保留四保护表/六trigger/四function在新a938库升级metadata无diff、身份保持，实际PG/lease完整102/102通过；新164327空库另显式升0013后用于组同步联测，旧QA不迁。恢复backend6/Chrome4+无registry1/相关262及诊断158分项已验。以下前期证据不代表旧运行包或最终服务已更新。

2026-10-22非安卓P5新增[数据工具](data-tools.md)应用服务/实际HTTP路由和0007导入来源索引迁移，真实ASGI/PG目标通过；最新实际OpenAPI50路径/138schema/56操作，合同21通过。0008审计三索引已在独立admin库升级，完整后台仍实施中。所有build_engine事务新增维护fence，CLI排他窗口可一致备份数据库/设置/附件，显式TLS参数传递目标2项和真实维护PG3项再过。历史调整import-only入口不改变普通sync协议。依赖hash锁新增openpyxl/defusedxml与et-xmlfile，原依赖版本保留；旧开发服务未更新且当前18080无监听。

2026-10-22新增已有正式Applied的只读receipt lookup；服务端完整445项通过（含首批19个lookup真实PG/HTTP目标），后补来源secondary scope/会话撤权2项目标及增强18086真实socket1分别通过。查询不执行命令、不创建回执、不创建/续期设备，并检查当前原scope写权。实际OpenAPI42路径/114schema/48操作。没有新迁移、能力发布或运行服务升级，旧wheel未包含此接口；详细协议见[同步模块](sync.md)。

新独立`server/dist/receipt-lookup/` wheel已构建，142955字节/97资源逐字节一致，SHA256 `0c90bc30a313476cf22cd645f25de75ec4136699718a0ef5ce88b0e6be192f60`，包含lookup，尚未安装。旧receipts-schema/assets及运行18080包保持；构建不等于独立安装或Linux部署验收。

`flowtrace-server` 是独立 Python 包，支持 Python 3.12–3.13。生产/开发依赖锁含精确版本与 SHA256；wheel 包含 Jinja 页面、CSS 和迁移，安装不需 uv、Flutter、Node.js。

| 当前入口 | 实际行为 |
|---|---|
| `/health/live` | 进程可处理请求，与数据库状态分开 |
| `/health/ready` | 真实连接 PG、SELECT、检查迁移 head/部署元数据；失败为安全 503 |
| `/api/v1/server-info` | 持久 instance_id/sync_epoch，声明真实已挂载的身份/账本/同步/附件/诊断/报表与 bill-move-v1 服务端能力 |
| `/api/v1/auth/*` | 一次性邀请、密码登录、opaque access/refresh、轮换/复用检测、退出 |
| `/api/v1/users/me`、`/api/v1/sessions` | 本人身份与客户端会话列表/撤销 |
| `/api/v1/books*` | 私人/共享账本、成员邀请、owner/editor/viewer 授权/撤权 |
| `/admin/*` | 最小服务管理面板、独立 Cookie 与脱敏诊断导出 |
| `/api/v1/attachments*` | 声明、流式上传/完成和授权原图/缩略图，见附件模块 |
| `/api/v1/sync/*` | 真实 PG 事务、权限投影、回执、增量拉取和快照；新增已有Applied的只读核对，不重执行/续期设备，见 [同步模块](sync.md) |
| GET `/api/v1/books/{book_id}/report` | 当前成员权限下的一致快照精确期间/分类/日历/预算，见 [报表模块](reporting.md) |
| `/api/v1/assets/*`、`/api/v1/currencies/*` | P4候选：私有分组/配置回执、165币种/估值、授权资产余额/历史/分录/信用卡账期，见[资产契约](../../contracts/assets-v1.md) |

同步持久化与账单数据库投影已挂载，实际账单附件 create/update/delete 引用及客户端上传重试已联测。纯领域参考计算仍不能替代持久事务或授权服务。作业及完整 A01–A07 后台尚未交付，API 不启动 worker/周期记账器。

`contracts/openapi-p0.json` 留存候选；`contracts/openapi.json` 从真实路由导出，P4资产/币种及随后追踪/summary源码候选为41个路径、113个schema、47个唯一操作标识，业务响应闭合。当前18080运行的377 wheel仍为29/78/31，不能把源码导出当作已更新该服务。后台 HTML 不进入业务 schema。在 `server/` 执行 `python -m flowtrace_server.tools.export_openapi --output ../contracts/openapi.json`。

## 数据与事务

P4-02服务端当前仅实现expense追踪字段及最小来源聚合，完整语义/验证见[同步模块](sync.md)与[退款报销契约](../../contracts/refund-reimbursement-v1.md)。新字段可选严格bool、缺省保持原presence；summary只在expense外层并绑定源revision，不泄露foreign回款身份，旧物化页不注入默认。当前关联原单普通金额变更仍为原规则，Reference/client与方案A锁待后续，故不声明`receipt-tracking-v1`或未来复合能力。

2026-10-22专库`flowtrace_test_receipts_local`完整server425/425（66.21秒）通过，其中新增PG/ASGI目标12项；随后独占18086真实socket HTTP1项通过、已正常清理测试账单/会话并关闭监听。合同21/21、Ruff全server clean，新独立`dist/receipts-tracking/` wheel141389bytes/96资源逐字节对应源码，SHA256 `5ab8b4903348bd2cbe24e97447deb3bf717a2e100c688466bef87e8cdf14c28e`，仅构建未安装/升级服务。仍沿原0006无新增迁移，未动dev/assets旧运行数据；旧允许增额金额回归保留。回执`outputs/validation/P4/receipt-tracking-server-receipt.json`不代表客户端/Reference/UI或整个P4-02通过。

随后单独修正schema表达：`BillPublic.source_summary`使用本地Pydantic2.14.1的标准`SkipJsonSchema[None]`，仍允许旧缺失，显式null仍由原validator拒绝；唯一导出变化是该属性移除null branch，路径/113schema/47操作不变。新增断言先失败、修后合同21通过，33个真实模型结果/序列化摘要前后相同；没有重新执行425、PG或HTTP。该425基线属于元数据修正前、等效runtime证据，新窄回执`outputs/validation/P4/receipt-tracking-schema-receipt.json`分开记录。当前新构建`dist/receipts-schema/`为141467bytes/96资源，SHA256 `38c45977b2b4350b993994abe3bac6afd1a1557a66c7c5beefa70df00ca38d84`；旧5ab8包原字节保留，不能混用摘要。新包未安装/启动，迁移/能力/运行服务未变。

初始迁移创建 `server_state` 和随机部署实例/epoch，重复升级不重置。`0002_identity_books` 建立用户、管理角色、会话、刷新凭据、注册/共享邀请、账本、成员、scope、管理控制行和审计。CLI 显式迁移，API 仅处置连接池，不自动建表/迁移；不盲目 downgrade。`0003_sync_transactions` 回填旧账本 revision0，新增账本经共享 helper 同事务写首条实体/change；REST 过滤已删除账本，拒绝复活。`0004_attachments` 建立附件/ref/hold，`0005_attachment_tickets` 保留票据历史并支持显式续期；旧票据不能复活。模型发现入口为 `persistence/registry.py`，迁移链串行接入。

`auth.dependencies.get_session` 不自动提交，写用例显式 commit。业务写先按 `user → session` 加锁复查，再按稳定 UUID 锁 scope；成员变更锁账本/目标用户 scope，增加双方 permission_version，保留 inactive 成员。不得在 scope 后再获取用户锁。管理写按 `admin_control → 当前 user/session → 目标 user/session`，在锁内重读当前角色，不能信任登录时快照。

私人 user scope 仅归本人。共享账本不授予其他成员私人资产权限；管理员不绕过 `authorize_scope`。已移除成员不能复用已消费旧邀请复活权限，新邀请可明确重新授予。

P4候选迁移 `0006_assets_currencies` 只新增私有配置状态/组/偏好/估值/冻结回执五表，metadata共30表；已在 `flowtrace_test_assets_local` 升级，未迁移18080数据库。旧账户/账单JSON及不可变同步页不回填。组与账户引用修改共用本人scope锁，非空组拒删，共享账户group必须null；配置写入绑定user/client/instance/epoch/base revision，当前鉴权先于旧回执。币种目录冻结SIX 2026-09-17的165个数字精度单位，原15币种精度不变，不对N.A.单位猜精度。

## 配置与身份

前缀 `FLOWTRACE_`，可读取当前目录 `.env`，`.env.example` 不自动加载。数据库 URL 为 SecretStr，仅支持 `postgresql+psycopg`；未配置时 live 可用，依赖数据库的接口安全失败。主机/跨域来源明确白名单，不接受凭据来源 `*`。

密码为 Argon2id。随机 access/refresh、邀请、CSRF 仅存 SHA256 摘要；API access 15 分钟、刷新最长 30 天，串行轮换，旧 refresh 复用撤销整个会话。Web 刷新 token 只在 HttpOnly Cookie；Web 写须 Origin 与会话绑定 CSRF。原生为 Bearer。后台独立用途 Cookie，30 分钟空闲/8 小时绝对到期，生产 Secure/HttpOnly，业务/后台不能互换。

初始管理员/本机恢复经 `tools.bootstrap_admin`，无默认凭据或 HTTP 恢复入口。恢复依赖 OS/数据库权限，更新密码、启用账号、授予三种角色、撤销旧会话并审计。普通管理员不能禁用管理身份；服务所有者不能禁用最后可恢复管理员。

## 诊断与验证

HTTP 新建 request ID 并返回 `X-Request-ID`；结构化 stdout 只记白名单，不含 SQL 参数、query、body、令牌、账目或原始异常。安全错误模型同步导出 OpenAPI。JSON 写正文实际累计超过 1 MiB 在解析前拒绝；唯一二进制上传路由由附件流式累计 10 MiB，不使用通用 JSON 预读。诊断有界私有 JSONL/脱敏导出见诊断模块。

账本时区校验和领域均使用锁定 tzdata 资源，当前 Python 为 2026.5/IANA 2026e。后台先转 UTC 再格式化，含 +08 输入回归。Dart 时区库差异见领域模块，不声称所有历史规则一致。

2026-10-21 在 Windows/Python 3.12.13 和便携 PostgreSQL 18.6 隔离库完成P3最新全套377项（61.37秒），Ruff全clean，仅既有TestClient弃用告警。包含14项闭合移动输入、26项真实PG/HTTP移动及2项当前墓碑读取测试，覆盖双域授权、撤权回放、同UUID、历史调账/fee原分录、附件、GC、原子回滚和snapshot/pull。先前全回归373通过/2失败来自本测试合成deleting附件残留影响既有GC计数，补精确行收尾后完整重跑375通过；随后补墓碑读取达到377，未放宽GC断言。

最新独立生产wheel位于 `server/dist/move/`，84文件/117716bytes，以生产锁非editable安装在 `server/.wheel-move-venv/`，关键源码与包内资源逐字节核对。隔离18082实际HTTP15项通过，包括移动三域提交、原正文重放、原时刻/余额/私人分录保持、来源报表0/目标125、授权最小墓碑及匿名拒绝；合成实体正常墓碑、会话退出、临时线程关闭。上一375项候选包保存在 `dist/move375/`；旧335项/83文件wheel仍留在原 `dist/` 和 `.wheel-venv/`。

主代理随后将自持18080切换至上述377基线的非editable包，ready200、实际OpenAPI29/78/31、能力包含bill-move-v1；保持原backend-data、instance_id和sync_epoch，不执行新迁移。切换回执为 `outputs/validation/P3/backend-move-upgrade.json`。先前Chrome在335包上的验收保留为历史证据，不能当作新移动界面的浏览器结果。

独立 `tests/e2e/sync/book_move_harness.py` 使用同一固定wheel、专用18084与 `flowtrace_test_book_move_local`，Flutter VM生产移动服务真实HTTP **1/1通过**，随后独立SQL核对账单唯一UUID/revision2、唯一正式receipt、原-125分录和目标book、精确时间、图片refs及hash、准备后撤权的账单仍在来源revision1。实际用户本机库为四个独立磁盘SQLite及附件文件目录，两个会话属于同一移动账号；另有账本owner和来源-only viewer。最终本轮四会话均退出，18084停止监听；专库只保留合成夹具，不重置其他数据库。命令、失败夹具修正及边界见[真实联测](../../tests/e2e/sync/README.md)，脱敏回执为 `outputs/validation/P3/book-move-http-receipt.json`。该联测未改变18080，也不是移动页面、真实图片选择器、Android或Linux验收。

主代理先前真实浏览器验证后台登录/邀请兑换、禁用前后 API、重新启用不复活旧会话、单设备撤销、安全错误及退出；1280 桌面/390 移动根页面无横向溢出，表格容器内滚动，截图在 `outputs/validation/P2/`。

P4服务端当前完成完整411/411（74.30秒）及随后新增RR竞态2/2：旧snapshot在scope锁前遇已提交撤权会真实序列化重试，只回私有金额；持scope锁时用独立连接 `pg_blocking_pids` 证明撤权等待，提交后再读裁剪失权账本正文。首轮完整409通过/1失败是Windows从stdin启动pytest导致既有multiprocessing无法重开入口，改真实受控.py入口后全过；没有放宽断言。

P4独立候选wheel在 `server/dist/assets/`，140192bytes/96个包资源逐字节核对，SHA256 `473a0a4289e6635f8e9047dba24910ea8131109fd87f21551a1ff2c5d2345e1c`，按生产锁非editable安装于 `.wheel-assets-venv`。`tests/e2e/assets/server_smoke.py` 在专库/18085实际HTTP36检查通过，包括100CNY→12.50EUR冻结转账、估值8→9只改变估值总额、额度/期初carry、私人明细、历史、陌生scope403、冻结旧回执、引用组删除拒绝及正常墓碑清理。最终两合成会话退出、线程停止；回执 `outputs/validation/P4/assets-wheel-http-receipt.json`。这未更新18080，不等于客户端/浏览器/Android/Linux验收。

2026-10-22另以同一固定wheel、专库/18085及真实Flutter VM生产仓储完成资产HTTP **1/1（约6秒）**：原字节配置丢响应重试、组确认后同步、冻结跨币资金与估值隔离、私人typed读取、撤权清读取缓存/nonce/下载并保留本机意图、重新授权及正常墓碑清理。独立SQL确认配置revision11/唯一回执、分录及refs0、余额精确恢复，最后两测试会话0、线程停止。首轮暴露客户端ACK/已拉取删除墓碑识别缺陷，主代理修proof后保持原期望重跑通过；完整因果及命令见[资产联测](../../tests/e2e/assets/README.md)。回执为 `outputs/validation/P4/assets-client-http-receipt.json`，不是浏览器/手机或18080更新证据。

测试须显式 `FLOWTRACE_ENVIRONMENT=test`、`FLOWTRACE_TEST_DATABASE_URL`，且 loopback/`flowtrace_test_` 数据库名；不配置为 skip，不作 PG 通过。身份合成数据用外层事务/request savepoint 清理。当前 TestClient 对 httpx 有一条弃用告警。运行/发行命令见 [服务端 README](../../server/README.md)。未执行 Linux/systemd/Nginx，不能以 Windows 结果证明 Linux。完整后台/朋友试用仍按计划门槛。
