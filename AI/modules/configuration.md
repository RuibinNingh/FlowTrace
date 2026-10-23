# 服务配置与私有密钥

> - 职责：后台闭集配置的预览、版本CAS、精确重试、回滚与实际运行策略，以及私有密钥和固定服务连接检查。
> - 入口：`server/src/flowtrace_server/configuration/`、`admin/configuration_forms.py`及相关模板；迁移`0011_service_configuration`。
> - 不变量：后台service/owner当前角色与密码重认证；配置与审计同事务；秘密正文不入数据库/审计/页面；URL/命令/路径不来自管理表单。
> - 必跑测试：新隔离PostgreSQL下`server/tests/configuration/`，以及身份、附件、jobs回归；后台页面须独立真实Chrome验证。
> - 相关：[后台](admin.md)、[服务端](server.md)、[附件](attachments.md)、[作业](jobs.md)、[数据工具](data-tools.md)、[计划恢复](../plans/flowtrace/progress.md)。

## 当前行为

配置只接受十个公开字段和两个固定密钥引用。singleton保存当前版本/快照，revision保存不可变请求ID/摘要、操作者和快照；版本0为迁移冻结初始值。保存使用base版本CAS，同request须actor/正文/secret keep-delete-replace语义完全一致；回滚创建新版本，不覆盖历史。写按admin_control→当前用户/会话→singleton持锁，配置与审计由调用方同事务提交。只读/预览不赋予写权，recovery-only没有配置权。

已接入注册开关、默认邀请期限、附件单文件上限/每上传者配额、孤立附件保留天数、诊断开关和worker默认轮询间隔七项。配额将pending/uploaded/ready/deleting的声明原图字节全部计入，同用户跨scope声明受用户行锁串行保护；现有合法声明重放不重复预留，降低限制不破坏旧上传。deleted重新声明须按新限制预留。GC仍重新核对refs/holds后才清理。

备份保留策略和OCR/AI完整业务三项尚未接入，不能因配置已保存就声称生效。连接检查单独使用OS登记的`ocr_primary/ai_primary`，页面不能填写URL；未登记服务不能启用。探测只访问固定health/models路径、不跟随跳转、不使用环境代理/浏览器Cookie、不回传响应正文/端点，socket超时不宣称DNS硬中止。网络前结束只读事务，结束后复核当前会话、角色、密码及同一配置版本再审计。

## 密钥边界

页面只能提交keep/replace/delete及新值，不能提交引用UUID。替换由受信facade准备，绑定操作者/base/request/field；同意图跨实例互斥并精确复用引用，不同明文拒绝。配置只存固定字段的UUID/null，读视图另区分未配置、可用和引用文件不可用，不回显引用或原值。

Windows使用当前用户DPAPI及禁止UI标志，参考[微软接口契约](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)；POSIX使用服务私有0700/0600文件，未声称加密磁盘。单值1–4096字符，payload最多64KiB、封装最多128KiB，写前/读后均检查。Python字符串与bytes不保证全内存擦除。目录拒绝链接/越界；文件排他新建且不可变。

删除当前字段仅建立null新版本，历史引用保留供明确回滚；失败准备留下私有未发布文件，后续受控清理仍需重核全部历史引用，当前没有自动删除秘密目录。常规数据库/附件备份不含密钥文件，恢复后引用可能不可用，须在新环境单独提供。拥有服务账号/磁盘权限仍属信任边界。

## 验证与边界

0011只在本轮隔离库实际完成0010→0011→0010→0011，metadata diff为空、冻结默认一致、旧server_state不变；未迁移原开发库/旧QA。服务与表单53项目标通过；root另有vault/provider26及facade6项，后续统一回归单独记录。独立审查真实复现多字节封装不可读、URL空白与空query/fragment探测路径问题，均保留失败证据并补修/回归。

facade的真实第二连接在探测阶段可禁用账号或更新配置，最终拒绝成功且不留连接成功审计。后台页面、完整runtime专项及统一回归仍接续，不将DTO/构建成功当完整A06验收；当前无最终常驻部署。

2026-10-23接收：runtime9/9真实PG/HTTP/文件及两连接配额锁通过；root pre-UI相关153/153（30.91秒）；A06后UI相关217/217（62.85秒、无skip），独立headed Chrome6/6及后验通过，均按各自快照而不累加。真实UI覆盖预览无写、错密码、DPAPI替换/精确重发、固定loopback models连接、两标签CAS409、删除当前引用/历史同引用回滚/默认0形成新revision、recovery-only403和390窄屏/Tab。完整回执在后台验收目录，连接可达仍不等于OCR/AI记账流程已实现。

2026-10-23诊断真实配置POST false/true、export503/恢复200、OS硬关闭、正式audit和schema锁fail-closed通过；root多app私有目录/关一不影响另一及async offloop另2项。相关configuration全目录+策略/store/spawn+附件同次158/158（36.53秒），无skip。专用短连接每次读已提交开关且不借业务Session，详见[诊断模块](diagnostics.md)。
