# Windows 本机测试部署工具

职责：核验并暂存固定交付输入，提供当前用户范围的独立本机测试实例管理；入口：`Prepare-FlowTraceLocalTest.ps1`、`Manage-FlowTraceLocalTest.ps1`；不变量：独立cluster/资料根、秘密不入静态包、停止前核对进程身份、坏输入不覆盖旧版本；必跑验证：`tests/e2e/local-test/`；相关：[最终交付要求](../../../AI/plans/flowtrace/delivery-local-test.md)。

当前为准备工具实现阶段。没有执行本工具的Install、真实实例Start、任务注册或持久部署；没有登录自启/整机重启验收。此前PG55432及18080和所有QA资料保持原状。Linux部署仍延后。

使用Windows PowerShell 7、已安装的Python3.12/3.13，以及明确来源的PostgreSQL完整发行目录（含bin/lib/share）。Python和PG路径必须保留可用。所有版本进入服务根的`versions/版本/`新目录；`data/`、`private/`、`postgresql/data/`与Web分离。工具不接受旧cluster作为输入，不覆盖既有实例的数据库。

Prepare用隔离Python预检ensurepip公开声明的pip版本：对应内置wheel须实际存在、ZIP校验完整、入口及METADATA版本一致；缺失或损坏返回`python_ensurepip_bundle_unavailable`，不修改全局Python或补装pip。回执`python_seed_preflight.actual_venv_seeded=false`明确这只是资源检查，并未实际创建/seed venv。2026-10-23本机Anaconda缺声明的pip25.0.1 wheel被实际拒绝；managed CPython3.13.5的pip25.1.1资源通过。最终Install仍需独立验证真实venv seed及离线依赖解析，不能把资源齐全当安装成功。

Prepare必需参数：Root、Version、Python/PythonSha256、ServerWheel/ServerWheelSha256、RequirementsLock/RequirementsLockSha256、WheelhouseZip/WheelhouseSha256、WebZip/WebSha256、PostgresDistribution、PostgresManifest/PostgresManifestSha256、HttpPort、DatabasePort。根目录必须全新或有同一当前用户的本工具ownership记录；版本目录必须不存在。端口需空闲且不同，18080与55432拒绝。默认只绑定127.0.0.1。

离线wheelhouse ZIP为平铺的`.whl`集合，每个wheel的SHA256须存在于生产requirements.lock。锁必须是精确版本及hash，不接受索引/远程URL/可编辑依赖。Prepare不安装依赖，也不宣称已验证依赖闭包；最终Install使用隔离pip、`--no-index --only-binary=:all: --require-hashes`完成真实离线解析。缺包失败保留准备目录，不自动联网补包。

PostgresManifest格式为`flowtrace-postgresql-distribution-v1`，files数组逐项记录相对path、bytes、sha256，必须覆盖整个PostgresDistribution，至少含`bin/initdb.exe`、`bin/pg_ctl.exe`、`bin/postgres.exe`、`bin/pg_dump.exe`。清单由最终交付者对已核实发行文件生成并提供独立SHA；不是对未知来源二进制的安全背书。

Web ZIP须包含已seal的`flowtrace-release.json`及worker，允许单一外层目录。每项资源hash/长度、worker嵌入manifest和额外文件均核对。ASGI入口只提供精确资源白名单与根index；默认Flutter hash URL不需要通配SPA回退。未知API/admin/health/业务路径保持404；静态文件每次读取重新核hash，变化返回503，不拼接其他版本。WASM/JS MIME、COOP/COEP、no-store、nosniff及根worker scope头由包装器提供；API/admin仍走普通create_app。

所有操作通过显式Action，Prepare本身不会调用这些动作：

| Action | 行为 |
|---|---|
| Install | 仅新实例：当前用户私有ACL、独立venv、严格离线依赖、全新SCRAM cluster/role/DB、显式迁移和本地后台身份；结束时停止PG，不注册任务 |
| Start | 启动隐藏Supervisor；独占文件租约防止双Supervisor；启动本实例PG/API/worker |
| Stop | 请求本实例合作退出；35秒未退出则保留状态报错，避免在忙任务中强杀；确认应用退出后仅停止所属cluster |
| Status | 返回本实例身份、进程核对与匹配instance/epoch的真实ready；未安装显示prepared，部分安装单独标明 |
| Backup | 停止自有API/worker后保留/启动自有PG，调用维护锁备份；完成或失败恢复此前运行状态，半成品保留 |
| RegisterLogonTask | 最终阶段才显式注册当前用户Interactive/Limited登录任务，无Windows密码、不提升 |
| UnregisterLogonTask | 核对当前用户及本实例任务动作后移除该任务，不清数据 |

`Manage-FlowTraceLocalTest.ps1`的必需参数为Action与Root，Install另需Version。可用`Get-Help ./deployment/local-test/windows/Prepare-FlowTraceLocalTest.ps1 -Full`查看完整命名参数。最终artifact版本/路径由交付记录确定，本文没有可直接冒用的开发库安装命令。

私有service.json含本实例随机数据库口令和初始应用后台口令，只保存在Root/private，不能加入版本ZIP、静态目录、诊断导出或聊天。继承的FLOWTRACE/PG/Python路径环境会在子进程中清理，准备Python也使用隔离模式。入口只读取显式配置；DSN必须为本实例GUID派生的数据库/角色、127.0.0.1及独立端口，拒绝全部连接查询参数，包含hostaddr/service/options。Windows进程以PID、创建时间、实际exe及config/GUID标识核对；终止测试使用固定OS句柄，PID复用或其他进程标识不符时拒绝。正常Stop使用合作退出文件，不按进程名批量结束进程。

Supervisor失败5次后退出，由最终注册的登录任务进行有限重启；状态文件只含固定故障码。各Python运行模式持独占OS文件租约，第二个同模式进程立即拒绝；运行日志仅保留时间、级别和固定事件，不记录异常正文或参数，每模式2MiB×4。普通API诊断沿用原有容量/轮换规则。

仅未来新cluster在initdb后写受管logging include：`logging_collector=on`、私有`data/postgresql-logs`、`log_filename=postgresql-%H.log`、`log_rotation_age=60`、`log_rotation_size=0`、`log_truncate_on_rotation=on`，时区Asia/Shanghai。按[PG18官方规则](https://www.postgresql.org/docs/18/runtime-config-logging.html)，这是24个小时名称的时间循环，size=0关闭大小轮换，并非字节硬上限；启动及同小时重启仍可能追加。实际24小时循环没有运行验证，最终部署需核对SHOW值并调用pg_rotate_logfile确认目录和内容。PG日志始终私有，不通过Web提供。

`pg_ctl -l`使用单独的`data/postgresql-bootstrap.log`。每次启动前，先核对Root/GUID、所属PG没有活进程、PID文件可归属、端口空闲和受管logging配置，再对固定bootstrap文件以不跟随reparse point的独占OS句柄打开；仅普通单链接文件可截断。不会截断活PG、未知PID、硬链接目标或更改后的配置，不清理其他collector日志。该措施防止bootstrap跨启动无限追加，不代表单次异常启动有字节硬上限。

Backup调用普通逻辑备份：只枚举数据库、数据库附件行对应的固定对象及公开settings.json。不会递归data，不包含data/service-logs、diagnostics、其他备份或本次临时输出，也不包含private/service.json及密钥vault。manifest只允许database.dump、settings.json、objects/固定hash对象，受原有1GiB/文件数量/manifest读取上限控制。恢复秘密需另外安全保管或重新配置；该动作不是整个服务目录的完整备份。此次只读核对了该范围，没有运行本机工具的真实Backup。

Prepare校验失败、离线安装失败或部分安装均不会删除原资料、覆盖已封装版本或自动恢复数据库。当前Install仅支持首次独立实例；后续升级须先准备新版本、受控停止、备份及审查迁移，再显式切换，不能假设旧二进制兼容新schema。没有自动降级或删除半成品逻辑。

2026-10-23准备专项已实际执行：普通ASGI资源/路由、固定字段日志、跨进程租约和11类连接边界25项通过；合成Prepare/Status、坏包保旧、校验后源变化、临时PID与任务元数据9项通过；PG日志配置输出、带单引号/空格路径、二次初始化/活PID/未知PID/坏配置/硬链接保旧1项通过；缺失ensurepip声明资源安全拒绝且不改Python/不建venv1项通过。测试中的PG文件和wheel均为不可安装的合成资料；仅短程锁/临时sleeper进程实际运行，不是持久服务。Install、离线pip解析、initdb/迁移/后台身份、真实Start/Stop/Backup、实际日志轮换、任务注册与登录/整机重启仍未执行，最终版本和wheelhouse确定后由交付阶段独立验收。
