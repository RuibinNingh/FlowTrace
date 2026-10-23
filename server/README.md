# 流迹 Python 服务端

当前提供进程/数据库就绪检查、邀请注册、设备会话与刷新轮换、私人/共享账本权限，以及独立的最小后台管理面板。以上路由都访问真实 PostgreSQL；真实同步持久化、附件引用、报表与同UUID跨账本服务端移动已接入。客户端上传/冻结账单重试及撤权清缓存已联测，移动界面还须独立验收ACK/pull双序；完整运维后台仍按后续工作包交付。

Python 支持范围见 `pyproject.toml`，依赖精确版本和哈希分别在 `requirements.lock` / `requirements-dev.lock`。服务端安装不需要 Flutter、Node.js 或 Docker。开发源文件在 `src/flowtrace_server/`；领域实现与 HTTP/数据库分离。

## 本地开发

在 `server` 目录，以 uv 创建 `.venv` 并按开发锁安装：

```powershell
uv venv .venv --python 3.12
uv pip sync requirements-dev.lock --python .venv/Scripts/python.exe --require-hashes
uv pip install --python .venv/Scripts/python.exe --no-deps --no-build-isolation -e .
.venv/Scripts/python.exe -m pytest tests
```

Linux 对应解释器路径为 `.venv/bin/python`；生产可直接使用标准库 `venv` 和 pip：先安装生产锁中依赖，再 `pip install --no-deps` 安装发行 wheel。构建发行包使用开发锁中已锁定的 build/hatchling：`python -m build --wheel --no-isolation`。wheel 包含管理模板和 Alembic 迁移；不能仅复制 Python 文件而漏掉资源。

环境变量以前缀 `FLOWTRACE_` 读取；`.env.example` 仅作模板，不会自动加载，替换示例凭据后才复制为本机 `.env`。数据库 URL 只接受 `postgresql+psycopg`，不使用 SQLite 替代服务端。没有配置数据库时进程可以提供 live 检查，但 ready/server-info 返回 503。

```text
python -m flowtrace_server.tools.migrate upgrade
python -m flowtrace_server.tools.migrate check
python -m uvicorn flowtrace_server.main:app --host 127.0.0.1 --port 18080 --no-access-log
```

迁移必须显式执行一次，不由 API 进程启动时自动执行。迁移身份与业务运行身份在部署时分别授予。初始迁移保存随机 instance_id/sync_epoch；重复 upgrade 不重新生成。数据降级入口被禁用；按已审阅恢复流程处理不兼容迁移。

## 接口与验证

| 实际端点 | 行为 |
|---|---|
| GET `/health/live` | 进程存活，独立于数据库 |
| GET `/health/ready` | 每次真实 SELECT、核对当前 Alembic heads、确认部署元数据；异常返回固定安全 503 |
| GET `/api/v1/server-info` | 从已迁移数据库读取实例/epoch，仅声明已实现能力 |
| POST `/api/v1/auth/register`、`login`、`refresh`、`logout` | 单次邀请、Argon2 密码、opaque access/refresh；刷新复用撤销整个会话 |
| GET `/api/v1/users/me`、GET/DELETE `/api/v1/sessions[/id]` | 当前身份及本人的客户端会话 |
| `/api/v1/books*` | 创建/列表、成员邀请/角色与撤权；owner/editor/viewer |
| GET `/api/v1/books/{book_id}/report` | 当前成员权限下，按 start_date/end_date_exclusive 汇总期间/分类/日历/预算；可选 budget_id |
| `/api/v1/assets/*`、`/api/v1/currencies/*` | 私人分组与冻结配置回执、币种/估值、授权余额/历史/分录/信用卡账期；详见[资产契约](../contracts/assets-v1.md) |
| `/admin/login`、`/admin/*` | 独立管理会话、概况、用户状态、注册邀请、会话撤销、密码修改和审计 |

统一错误不回显请求值、DSN 或异常正文；服务端生成 request ID，诊断只允许有限字段，不记录 query/body。JSON 写请求正文实际累计超过 1 MiB 即返回 413；二进制附件上传实际流式累计 10 MiB、60 秒期限，不经过 JSON 预读。管理/业务写操作在事务中复查会话和当前权限，不使用登录时角色快照。

同步实体当前读取可用于解决删除冲突：实际scope匹配且当前有读权的软删除返回最小deleted事件，data与editable_payload均为空，不返回旧正文。移动后旧scope仍404，失权域403；具体见[同步契约](../contracts/sync-v1.md)。

原生登录返回 access、refresh、csrf_token、session_id、user_id；Web 刷新 token 只写 HttpOnly Cookie，所有 Web 写请求必须包含允许的 Origin 和会话绑定的 `X-CSRF-Token`。Web 登录返回 CSRF，刷新不重新生成该字段。客户端必须串行刷新，旧 refresh 再次使用会撤销整个会话。生产 Cookie 使用 Secure；本机 HTTP 仅供隔离开发。独立 Flutter Web 来源通过 `FLOWTRACE_CORS_ORIGINS` 的 JSON 列表显式配置，例如 `http://127.0.0.1:18181`。

## 最小后台

迁移后，在有操作系统权限的终端执行以下命令，密码通过交互输入，无默认管理员密码：

```text
python -m flowtrace_server.tools.bootstrap_admin --username your_admin
```

仅能初始化一次，建立服务管理员/恢复管理员/服务所有者。后台与业务会话不能互换。禁用账号和撤销会话先展示对象供二次确认；修改密码要求原密码并撤销其他设备，保留当前后台会话。审计展示 UTC、操作者、动作和目标 UUID，不读取私人账单。

最后一个可恢复管理员受保护。本机恢复既有管理员可加 `--recover`；它依赖 OS/数据库权限，恢复启用和三个角色、更新密码、撤销全部旧会话并审计，没有 HTTP 恢复入口。自动化终端可用 `--password-env VARIABLE_NAME` 指定已存在的临时环境变量名，不将密码作为命令行参数。

普通服务管理员无私人账本、原始备份下载/恢复权限。当前面板供开发测试和自用；A01–A07 完整后台、限流、作业诊断和备份恢复留在后续阶段，不能据此开放朋友试用。详见 [后台模块](../AI/modules/admin.md)。

跨模块契约由真实路由导出，在仓库根目录使用开发环境解释器执行：

```text
python -m flowtrace_server.tools.export_openapi --output contracts/openapi.json
```

`contracts/openapi-p0.json` 保留设计候选，不能混入当前真实接口。P4资产/币种及追踪聚合源码候选导出41个路径、113个schema、47个唯一操作标识，业务响应使用闭合模型，错误文档与实际安全错误一致；后台HTML不进入业务OpenAPI。当前18080的377固定wheel仍是29/78/31，需显式协调迁移/安装才能改变运行版本。`bill-move-v1`说明服务端[显式移动协议](../contracts/book-move-v1.md)，客户端通过独立门槛后开放。路由或模型变更后须重新导出审阅。

P4-02当前只完成expense可选strict bool `reimbursement_tracking`与BillPublic外层来源聚合，详见[退款报销契约](../contracts/refund-reimbursement-v1.md)。旧update省略保留presence、非expense不携带；GET/push/pull/snapshot防止模型默认注入false/null，旧物化页不重写。关联原单严格金额锁、Reference及客户端仍待后续，因此`receipt-tracking-v1`/未来`receipt-restructure-v1`均不宣告。独立receipts测试库完整425通过（含新增12个PG/ASGI目标），随后18086真实socket1通过并正常清理/退出/关闭。`dist/receipts-tracking/`新wheel已核对96包资源，仅构建未安装或升级运行服务，无新迁移。

后续`source_summary`schema收窄为optional但nonnull，仅用Pydantic标准注解修正导出，不改变原runtime。旧5ab8 wheel保留；当前`dist/receipts-schema/`候选重建核对96资源，具体新SHA见服务端模块。33组前后模型/序列化结果相同、窄合同21通过，未为该元数据修正再次运行425/PG/HTTP，运行服务与capability仍未更新。

真实数据库测试仅在同时设置 `FLOWTRACE_ENVIRONMENT=test` 与 `FLOWTRACE_TEST_DATABASE_URL` 时运行，后者必须指向 loopback 且数据库名以 `flowtrace_test_` 开头。不配置时明确 skip，不能算 PostgreSQL 验证通过。测试会在该隔离库执行迁移，并在一个用例中临时改变迁移标识后恢复；禁止指向真实账务库。

身份测试使用外层事务和请求 savepoint 清理合成账号、邀请、会话。包含会话过期/轮换、CSRF、后台用途分离、撤权后旧邀请不能复活成员、管理员不能绕过私人 scope、最后管理员保护和本机恢复。后台时间总是先转换为 UTC，包含数据库返回 +08 时间的回归。

## 维护资料

现状与验证回执见 [服务端模块](../AI/modules/server.md)，规则见 [API](../contracts/api.md)、[账务](../contracts/ledger-rules.md)。[FastAPI 错误处理](https://fastapi.tiangolo.com/tutorial/handling-errors/)、[Lifespan](https://fastapi.tiangolo.com/advanced/events/)、[SQLAlchemy Engine](https://docs.sqlalchemy.org/en/21/core/engines.html)、[Alembic](https://alembic.sqlalchemy.org/en/latest/tutorial.html)、[Psycopg 安装](https://www.psycopg.org/psycopg3/docs/basic/install.html)、[uv 锁定环境](https://docs.astral.sh/uv/pip/compile/)为本轮核对过的一手依据。

P2 另核对 [FastAPI 密码哈希](https://fastapi.tiangolo.com/tutorial/security/oauth2-jwt/) 和 [Jinja 环境/filter](https://jinja.palletsprojects.com/en/stable/api/)。FlowTrace 的令牌是数据库可撤销的 opaque token，未采用文档示例的 JWT 方案。


## 附件与诊断

附件契约见 [附件模块](../AI/modules/attachments.md)。声明/二进制上传/完成独立于账单，只有 ready 才能同事务引用；私有路径不挂静态，原图与缩略图逐次授权。JPEG/PNG/WebP 真实格式/解码/40MP，当前静态图片默认；原件字节不变，缩略图移除元数据。24 小时票据过期后须由同用户显式重新声明完全相同内容续期，旧票据始终 410，deleting 锁中不复活；迁移链已到 `0005_attachment_tickets`。回收 CLI：`python -m flowtrace_server.tools.cleanup_attachments --limit 100`，只有数据库确认到期、无 refs/hold 的对象才进入 deleting→文件删除→deleted，可崩溃重试。

诊断规则见 [诊断模块](../AI/modules/diagnostics.md)。默认在数据目录的 diagnostics 私有子目录生成受控 JSONL，1 MiB/3 轮换/7 个 UTC 日/8 MiB 合计；后台审计页可下载最多 1 MiB 的再次投影脱敏版本。`FLOWTRACE_DIAGNOSTICS_ENABLED=false` 可关闭文件诊断，stdout 安全摘要保留；诊断失败不改变已经提交的业务结果，正式回执/审计仍必须事务持久。

运行数据目录不纳入源码。Windows 跨进程与真实 PG 检查不能代表 Linux/网络文件系统部署；真正备份作业、图片选择/编辑器真实平台路径与完整运维后台仍按各阶段验收。Windows 的多进程测试请用 `python -m pytest`，不要在 stdin 脚本中直接调用 pytest.main（spawn 无法重建 `<stdin>`）。

精确汇总的权限、来源证据、不可用状态、限额和实际验证见 [报表模块](../AI/modules/reporting.md) 与 [reporting-v1](../contracts/reporting-v1.md)。读取先固定 PostgreSQL REPEATABLE READ 快照，并复查当前 user/session/账本成员；不是公开或管理员绕过权限的统计入口。缺少可证明净额时明确 unavailable，不把转账本金、隐藏来源或缺失汇率当零。

P4新增迁移 `0006_assets_currencies` 为私有分组/偏好/估值/回执，旧同步JSON与物化页不回填。资产接口明确 current/as_of；未知期初日期无法证明过去余额，缺估值率无法证明跨币净值。估值记录与账单冻结reporting/transfer_fx独立，改估值不改原币事实。信用卡总欠款、出账金额、FIFO剩余应还分别命名，日期/历史缺失显示不可用，不推断银行利率或最小还款。独立包HTTP与完整回归事实见服务端模块。

固定候选wheel与专用18085另已通过真实Flutter VM资产HTTP1/1（2026-10-22），配置原字节重试、精确资金/估值隔离、typed私有读取、撤权缓存与正常墓碑均有独立SQL收尾。运行命令、初轮客户端删除proof缺陷和修后回执见[资产联测](../tests/e2e/assets/README.md)；服务最终关闭且测试会话0，未更换18080。
