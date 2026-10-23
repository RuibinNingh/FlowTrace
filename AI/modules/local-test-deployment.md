# 本机独立测试部署

> - 职责：固定wheel/依赖/Web/PG输入的校验暂存、Windows当前用户独立测试实例管理及普通同源静态入口。
> - 入口：`deployment/local-test/windows/`、`server/src/flowtrace_server/tools/local_test_service.py`、`tests/e2e/local-test/`。
> - 不变量：准备不安装/自启；独立cluster和资料根；秘密不入静态包；只控制核实的自有进程；失败保留旧版本与资料。
> - 必跑测试：合成产物准备、静态白名单/MIME/headers/坏seal、临时进程身份拒绝；真实安装/启动/备份/任务注册另属最终部署验收。
> - 相关：[交付分册](../plans/flowtrace/delivery-local-test.md)、[部署说明](../../deployment/local-test/windows/README.md)、[服务端](server.md)、[Web](web.md)。

实现提供Prepare与显式Install/Start/Stop/Status/Backup/登录任务管理。当前只准备实现与合成/短程验证，未运行Install、真实持久实例、自启注册或整机重启。PG55432、旧18080及QA资料不由本工具复用。初次安装以当前用户ACL保护新Root，固定wheelhouse离线解析，新建SCRAM cluster/DB/身份，版本与数据分离；部分失败保留，不自动重置。

2026-10-24 M1已冻结可供后续使用的普通Web a3d9和新head0016 wheel；wheel展开目录与开发依赖下的6项ASGI入口/静态字节/响应头检查通过。该短程检查没有独立安装、连接真实DB、监听端口或注册服务；Install/Start/保持验收仍属于待用户决定的M3，详见[候选清单](../plans/flowtrace/alpha-candidates.md)。

新ASGI入口包装普通create_app，API/admin/health仍按原路由；精确白名单提供已seal Web，没有未知业务URL的index回退。启动验证所有资源和worker manifest，每次静态读取复核hash；COOP/COEP、no-store、nosniff及正确WASM/JS MIME避免离线壳混版与错误资源回退。秘密/备份/私有配置位于独立数据根，不进入静态目录。

进程管理核对PID、启动时间、exe、config/GUID；Windows venv redirector和其base-python子进程分别记录。正常停止合作退出，忙任务未退出则报错保留进程；不按名称杀其他Python/PostgreSQL。Supervisor及Python各运行模式持独占OS租约；登录自启任务只在最终动作注册为当前用户Interactive/Limited、隐藏窗口，无Windows密码或提升，移除前精确核对用户/等级/执行文件/目录/参数。编写脚本不等于已完成这些真实部署验证。

入口只用显式私有配置，不合并开发环境；连接限127.0.0.1、本实例GUID派生数据库/角色及独立端口，全部DSN查询参数拒绝。运行日志仅固定字段，每模式2MiB×4；未来新cluster配置PG collector、私有目录、24小时名称循环（每60分钟时间轮换、同名截断、size=0），并非字节硬上限。启动前只在确认所属PG已停、路径/配置可归属后安全截断固定bootstrap文件，拒绝硬链接及未知PID。普通逻辑Backup不会递归data：不包含运行日志、备份目录自身、私有配置及vault，秘密需另外安全保管或重新配置。

Prepare另在隔离Python进程核对ensurepip声明的内置wheel资源、ZIP/入口/metadata；缺资源明确拒绝，不改全局Python或创建venv，回执actual_venv_seeded始终false。本机Anaconda缺pip25.0.1被实际拒绝，managed3.13.5/pip25.1.1资源检查通过；真实seed由最终工具链安装另验。

2026-10-23已验准备分项：普通ASGI静态/业务路由、坏seal/变化拒绝、固定字段日志、真实跨进程租约与连接边界25项；合成Prepare/Status/保旧、源在校验后变化拒绝、临时PID与任务元数据9项；新增PG日志配置/引号路径和活/未知PID、硬链接、坏配置保旧1项。无实际PG/应用实例安装；Install、离线依赖解析、initdb/迁移/bootstrap、真实Start/Stop/Backup、实际时间轮换、任务注册和登录/重启仍待最终交付阶段。回执位于`outputs/validation/P5-local-deployment-*.log`，不能当成最终持久部署完成。
