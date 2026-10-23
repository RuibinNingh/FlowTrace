# API v1 契约

状态：P0 设计契约，2026-10-21。实现端点以服务端生成的 [OpenAPI](openapi.json) 为准；本文件列出的后续端点不会因此自动可用。领域规则见 [金额时间](money-time.md)、[账务](ledger-rules.md)、[权限](permissions.md)。

## 通用约束

- JSON 使用 UTF-8，业务 UUID 使用规范小写格式。金额及修订为十进制字符串，不能用 JSON number。小型计数（页大小、币种精度）使用 integer。
- `/api/v1` 是业务版本；客户端同时声明 `protocol_version: 1`。`GET /api/v1/server-info` 返回部署实例 UUID、同步 epoch、最低协议和当前已实现能力，UI 不把未启用能力展示为已成功。
- `GET /health/live` 仅证明进程存活；`GET /health/ready` 实际查询数据库并检查迁移版本，失败为 503。响应不暴露 DSN、异常栈或密钥。
- 默认 JSON 正文上限 1 MiB，操作批次至多 100 项，列表默认 50、最大 200。附件限制独立定义。超限返回 413，不静默截断。
- 稳定列表分页使用不透明 cursor，绑定用户、筛选、版本与稳定 `(created_at,id)` 次序。不可用偏移分页充当同步游标。
- 服务端生成 request_id，返回 `X-Request-ID`。外部追踪值只接受有限字符/长度且不作为安全标识；内部日志不记录密码、令牌、Cookie、完整账单或图片。

统一错误：`{"error":{"code":"revision_conflict","message":"该记录已被修改","request_id":"...","details":{}}}`。403/404 不包含他人的对象正文；校验错误只含允许的字段名和固定错误码，不回显敏感 input。HTTP 状态映射：400 格式/操作依赖、401 会话失效、403 禁止、404 不可见对象、409 修订/ID/幂等冲突、410 过期游标、413 超限、422 领域规则、429 限流、503 服务不可用。

## 身份与管理

| 方法/路径 | 输入、结果及权限 |
|---|---|
| POST `/auth/register` | 一次性邀请令牌、用户名、密码、设备名；事务兑换邀请并建立个人身份，失败不消耗邀请 |
| POST `/auth/login` | 凭据、client_id、client_kind（native/web）；短期 opaque access token；原生返回 refresh，Web 写 HttpOnly Cookie |
| POST `/auth/refresh` | 原生 refresh 或 Web Cookie；旋转刷新凭据、复用检测；Web 必须 CSRF/Origin |
| POST `/auth/logout` | 撤销当前会话；Web 同样要求 CSRF |
| GET `/users/me`、GET `/sessions`、DELETE `/sessions/{id}` | 当前身份及本人设备，不能查看别人的会话 |
| `/admin/login`、`/admin/*` | 独立用途的管理 Cookie/Jinja2 页面，状态变更 CSRF+同源 Origin；管理角色每次确认 |

访问凭据 15 分钟，刷新最长 30 天；后台空闲 30 分钟且最长 8 小时。仅存安全哈希，密码 Argon2。HTTPS 部署 Secure/HttpOnly Cookie，原生长期凭据放系统安全存储。第一次管理员由本机 CLI 创建，无默认密码。普通管理员没有私人账目、原始备份下载或恢复权限；最后一个可恢复管理身份不能被普通流程禁用。

## 业务接口目录（逐包实现）

| 接口族 | 读取 | 写入及实施工作包 |
|---|---|---|
| books/members | 授权账本/成员 | 创建账本、邀请成员、角色与撤权；P2-01，事务获取权限域锁 |
| accounts/bills/categories/tags | 授权投影与筛选 | 所有同步实体写入统一走 `/sync/push` 的领域命令；P3/P4 |
| statistics/budgets/calendar | 业务日期、币种、统计标记筛选 | 预算修改走领域命令；P3-03 |
| sync | `/sync/scopes`、pull、snapshot | 下述同步协议；P2-02 |
| attachments | 授权元信息、内容 | 暂存、提交、关联；P2-03 |
| recurring/installments/savings | 计划、发生实例 | 计划命令和固定任务；P4 |
| imports/exports | 作业状态与授权下载 | 校验预览、确认与幂等作业；P5-02 |
| admin | 运维元数据与审计 | 白名单管理命令；P2-04/P5-04 |

客户端本地保存成功和服务器确认分开呈现。身份/成员/配置等在线管理动作拥有自身幂等键并经过相同权限服务；账务不得新增绕开回执的普通 CRUD 写入口。

P1 集成字段统一：转出/转入使用 `from_account_id`/`to_account_id`/`target_money`；历史折算使用 `reporting`；借贷账户类型为 `loan_receivable`/`loan_payable`。这些名称与共享领域夹具一致。P0 候选原先的 destination/report_conversion 名称在未发布路由前已校正，原始/实际 API 不各留一套别名。

P0 的 OpenAPI 为可审阅候选，包含基础与同步 schemas。P1-02 接收后把候选保存在 `openapi-p0.json` 作为差异基线；`openapi.json` 改为唯一由真实 FastAPI 路由/模型生成的实现契约。尚未实现接口保留在本文和 P0 候选，不用返回成功的空实现维持文档数量。后续每包生成并审阅差异，检查已实现端点不发生静默破坏。

参考：[OpenAPI 3.1](https://spec.openapis.org/oas/v3.1.0)。

## P5已挂载数据工具

`/api/v1/data-tools`当前提供八条真实路由：POST `imports/parse`（有界multipart file/format/options）、POST `imports/preview`、POST `imports/apply`、GET `imports/history`、GET `imports/{batch_id}/undo-preview`、POST `imports/{batch_id}/undo`、POST `exports/json`与`exports/xlsx`。它们检查当前普通API身份，Web写请求验证Origin/CSRF，响应no-store；不开放operator备份/恢复路径。

parse文件最大5MiB，精确POST multipart总正文最大5MiB+64KiB；其他普通写请求仍1MiB。返回闭合document、逐行错误和本次文件的mapping_requirements（账户/分类/标签/图片的有界原值与行号），原生导出信封另返回闭合attachment_sources（仅源ID/SHA256/大小/媒体类型），不抓URL。响应超过客户端1MiB JSON界限明确413，不静默截断。

导入调用真实领域writer和事务，batch UUID与稳定source IDs保护重试/去重；撤销预检当前完整write权限及后续修改/引用。本人操作历史仅保留不可变元数据权限，见[权限契约](permissions.md)。导出使用POST筛选正文，JSON与XLSX精确金额/当前授权/图片links或embedded；下载仍重新鉴权，不给公开地址。当前50行创建批次/1000实体导出与尚未接入的大批job是实现缺口，不代表完整迁移已完成。
