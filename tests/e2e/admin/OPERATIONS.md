# 后台应用服务与浏览器验收边界

状态：部分接入，2026-10-23（Asia/Shanghai）。A04真实Chrome5组、A05回归108与页面权限/布局5组及独立HTTP包已有分项证据；原始ZIP浏览器下载仍受不明204响应阻碍，未标通过。A06配置/连接headed Chrome6组及接UI后合并217项通过。后续备份创建已接真实worker，headed创建/独立校验4组、另一个无tool实例边界/完整包metadata1组及实际目录/hash/pg_restore后验通过，详见[README](README.md)。七个配置字段已有实际消费者，备份保留/OCR与AI业务三项仍只保存；固定目标隔离恢复已接生产worker（真实后端6组、Chrome4组及独立完整后验）；受控批量清理继续实施。`backup_create`仅在OS登记的trusted工具实际存在时advertise/claim；隔离恢复仅在OS登记可用的独立空测试目标/工具时advertise；没有假任务或清理按钮。

## 服务边界

面板持Cookie/CSRF、显示固定表单和回执；作业、备份、配置和清理服务持实际授权、状态与事务。下面是内部应用服务的语义需求，模块名由root集成确认；不接受任意Python、SQL、文件路径、命令行或未冻结字典作为面板输入。

| 服务能力 | 受控输入与真实输出 | 权限/不变量 |
|---|---|---|
| 概况状态 | 数据库版本、最近worker心跳/租约、最后成功备份、附件声明占用和实际存储状态 | 只有实际证据可显示正常；未配置/过期/失败分别显示 |
| 作业列表/详情 | 固定kind/status筛选、分页；job UUID、次数、创建/更新时间、固定错误码、允许动作 | 只显示运维元数据，私人账本正文/图片/凭据不出现在详情 |
| 创建/重试/停止 | 固定类型、目标UUID、幂等请求UUID；返回同一真实job receipt | 当前角色、允许状态及版本在服务内再验；租约fence阻止旧worker提交，重试复用业务幂等入口 |
| 备份列表/校验 | 服务登记的backup UUID、manifest状态/数量/大小/版本；校验作业receipt | service可看元数据；当前校验需recovery角色再次认证，不直接读文件路径 |
| 原始备份下载 | backup UUID、当前管理密码、明确目标确认；有界内容/固定文件名 | `reauthenticate_admin(..., capability='recovery')`，当前有效会话和角色，单独审计；owner没有recovery时也须拒绝 |
| 隔离恢复预览/提交 | backup UUID和预先登记的sandbox目标UUID；仅显示固定目标标签/UUID、换epoch/撤会话影响；返回真实作业receipt | 每次提交重新认证recovery/CSRF/目标；目标映射由受控服务读取，浏览器不能提交DSN、路径或生产替换开关；非空目标拒绝 |
| 配置查看/校验/保存/回滚 | 白名单类型字段、base版本、修改请求UUID；新版本/错误字段/上一个有效版本 | 服务内角色和版本CAS；无效配置不替换有效值，密码/密钥只回has_value，空输入保留原值，显式删除另确认 |
| 连接检查 | 固定配置/提供方ID、已校验候选；有界超时/固定结果码 | 不回显密钥或原始上游响应，不提供任意URL探针；网络目标规则由服务校验 |
| 孤立文件清理 | 先生成服务端plan UUID/计数/大小/保留条件，再带原plan和版本确认 | 执行时复核授权/引用/hold；页面不能自报可删除文件或要求删除任意路径 |

面板已有`require_portal`、`require_admin`、`require_recovery`及action-scoped `reauthenticate_admin`。recovery-only可进入portal/自助改密/退出，但不能借此获得邀请、用户、配置等service操作；所有者管理角色需owner资格和再次认证。管理角色不自动授予私人账本权限。

## 后续真实浏览器检查

1. 服务源接入后，用固定期望核对Worker/备份状态；停止实际worker或造成过期心跳后，页面显示相应事实，不以页面可打开代替状态验证。
2. 创建允许任务、观察pending→running→terminal；真实失败后重试/停止，在后端核同一业务唯一结果。测试过期版本/旧worker提交/不允许状态的拒绝。
3. 按服务真实能力创建备份；校验当前只允许recovery再次认证，recovery-only访问恢复区域；service和无recovery的owner尝试校验、原始下载/恢复均拒绝。
4. 错密码/错CSRF/错目标/角色撤销/会话失效/非空sandbox分别拒绝；成功只恢复到新隔离目标，核epoch、会话、账务复算和附件hash，保留失败现场。正式生产替换不属于网页动作。
5. 无效配置/旧base版本/占位密钥不覆盖有效配置；秘密字段在HTML、响应、日志与下载均无原值；连接失败显示固定原因且旧配置继续有效。
6. 清理预览后加入新引用/hold，旧plan不能误删；只清本轮隔离合成数据，保留所有先前验证材料。
7. 每个页面补1280/390布局与键盘、普通/recovery/service/owner边界、受控错误与审计回执；最后退出并关闭所属UUID Chrome/临时服务。完整A01–A07还需这些实际结果。

本轮18087是临时QA服务，服务数据/凭据与最终持久测试部署分开；最终同源Web/API/admin及产物交付由root统一实施。

## A06接口现状与剩余依赖

已实现`configuration/{models,schemas,service}.py`，root接注册/0011迁移、vault/providers/runtime/facade及六项实际消费者。后台使用`read_admin_configuration`、`save_admin_configuration`、`rollback_admin_configuration`和`check_admin_provider`。已实现边界见下表，清理和恢复条目仍是剩余依赖。

| 应用服务语义 | 建议返回/门禁 |
|---|---|
| 读取当前配置 | 已实现：当前版本、闭集公开值、secret presence和available/unavailable状态；六effective/四pending分别显示，动态service/owner权限，recovery-only拒绝 |
| 预览候选 | 已实现：base版本+闭集公开patch，无写、不要求密码或保存确认；不回显密码/新密钥，保存需重新输入 |
| 保存与回滚 | 已实现：当前密码、目标版本确认、admin_control→actor/session→head锁序、CAS/request hash replay；回滚新增版本，0为冻结初始设置；密钥keep/replace/delete明确，历史资料保留支持回滚 |
| 连接检查 | 已实现：固定ocr_primary/ai_primary部署登记，当前版本/密码预检后结束只读事务，无锁网络，再短事务重认证/版本复核/审计；固定结果码，无URL/DSN/路径或原始响应 |
| 孤立清理预览/执行 | 未实现：仍需plan UUID/候选数量/大小/配置版本/保留条件，执行fresh复核引用/hold；页面明确缺口，无执行按钮 |

`Settings`中的数据库连接、环境、数据目录、hosts/网络信任边界、provider端点及pg_dump/pg_restore工具继续由OS受控配置登记，不是网页任意字符串。当前六effective字段为邀请注册开关、默认邀请天数、附件单文件上限/用户配额、孤立保留天数和worker轮询；四pending字段明确只保存。保留策略影响下一次回收判断，保存本身不发起批量删除。密钥明文不入数据库revision或审计；Windows使用当前用户DPAPI，Linux为私有0600文件，不宣称Linux加密存储。删除当前引用不会物理删除历史密钥。

隔离恢复另需OS登记target UUID映射到新隔离DB/env及新目录；预览只回安全标签、空目标检查/版本与影响，提交再次认证并fresh核对空库/目录和preview版本。实际`restore_rehearsal` worker、固定工具登记及任务租约fence就绪前，页面保持无执行按钮；不提供生产替换开关或由浏览器提交连接/路径。

### 创建与隔离恢复的下一依赖

备份创建已接`enqueue_backup_creation(session, principal, settings, request_id, password)`。页面显示固定“当前服务恢复点”、包含数据库/公开设置/附件的范围及短维护窗口影响，再提交request UUID、expected epoch、当前密码和当前实例UUID确认；不接输出目录或工具参数。同request返回同job/backup UUID并只一条成功排队审计。任务完成后按真实artifact UUID在备份列表核对；未登记工具时无执行按钮，列表/重试也不将该kind冒报可执行。所有后台jobs调用显式传当前Settings，CLI worker按同一OS受控工具设置运行；一次CLI迭代不表示已有常驻worker。

恢复目标登记建议只由OS受控配置持有：`target_id UUID -> safe_label / isolated_env_reference / private_root / tool_ids`。预览返回`preview_id`、`target_id`、`backup_id`、`config_version`、目标epoch/空库与空目录fingerprint、manifest SHA、到期时间及撤会话影响，不回连接或文件系统路径。提交只接受这些固定UUID、预览版本、当前密码和目标确认；服务重读登记项，在目标锁内fresh复核空库/目录、backup hash、工具和预览版本后幂等排队。worker在租约fence和目标锁下执行真实恢复，再独立校验epoch/会话撤销、关系和对象hash后才能成功；失败保留隔离现场，不覆盖生产，也不能清掉非本轮资料后称“空目标”。目标/handler未就绪时页面继续明确缺口，无假成功按钮。


### 固定隔离目标操作

打开备份管理→隔离恢复演练，仅选择OS已登记目标UUID与备份UUID，当前密码生成300秒预览。预览会实际全hash并核DB/资料根为空，但不恢复。确认页再次当前密码与目标勾选后只排队，查看原任务直到实际worker核验完成。每个目标永久一次意图，部分失败资料保留，不能通过换预览、取消或手工重试覆盖非空目标。重复确认同一预览只找回原任务，仍需当前恢复角色/密码。

浏览器真实BDD目标已成功恢复；A2dc恢复、B979 partial和BDD均永久保留，不能再次迁移/seed/drop/reset。禁止将这些目标登记为可复用空环境。私有receipt/preview/锁仅在源资料根，原始包不含OS私有密钥，隔离环境须另行提供。管理身份仍无私人账务读取权。

当前root授权短profile原生ZIP交叉仍为204/无事件，未证明原因，无需用户操作个人浏览器或下载管理器。详见README的独立失败回执。最新262项合并回归不含backup_safety；恢复页面与独立浏览器结果按具体范围记录。


### 诊断开关实际生效

后台配置中“允许诊断记录”已接入私有文件收集，OS部署关闭时DB不能越过硬限制。关闭后保留旧文件、停止后续私有记录且诊断导出503；stderr和正式audit继续。所有作用域均须显式绑定policy，无context不会写私有文件；DB探针不可读/忙/超时只丢辅助记录。真实配置POST/export/OSfalse及多app/async/附件相关158项通过，详见[诊断模块](../../../AI/modules/diagnostics.md)。

备份受控清理仍只有[正式设计分册](../../../AI/plans/flowtrace/backup-retention-controlled-cleanup.md)，没有清理worker/按钮，也未对旧QA或三恢复目标执行rename/unlink。
