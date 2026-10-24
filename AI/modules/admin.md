# 服务端后台面板

> - 职责：独立管理身份、用户/邀请/会话、任务/执行器、受控备份与隔离恢复、服务配置及审计。
> - 入口：`server/src/flowtrace_server/admin/`、`tools/bootstrap_admin.py`、`/admin/login`；备份 facade 位于 `backups/administration.py`、`backups/rehearsal.py`。
> - 不变量：管理角色不授予私人账本读取；写操作须 CSRF/Origin/当前角色，敏感操作还须当前密码与固定目标确认；长I/O不持源DB管理写锁。
> - 必跑测试：隔离PG运行 `tests/admin`、`tests/backup_admin`、`tests/backup_rehearsal`、`tests/jobs`、`tests/configuration`、`tests/test_identity.py`、`tests/test_admin_rendering.py`；页面另做UUID独立Chrome主路径。
> - 相关：[服务端](server.md)、[任务与执行器](jobs.md)、[配置](configuration.md)、[权限](../../contracts/permissions.md)、[真实浏览器操作及回执](../../tests/e2e/admin/README.md)。

## 当前行为

2026-10-24生产在独立Linux发行中实际使用正式owner完成HTTPS后台HTML表单的CSRF登录、概况读取及退出，初始凭据仅root-only交接；未测试/更改其他用户私人账本。新域名浏览器控制连续超时，表单HTTP通过不等于本次布局/完整后台浏览器验收；见[生产部署](production-deployment.md)。

2026-10-23隔离Chrome已分次完成：新2890 fixture在与失败641c相同深度的Windows目录中，真实表单入队5项、独立CLI Worker后完成3项均通过，两个目标全hash/效果回执/controls v3及唯一完成审计一致，其他三个包未变，会话0且精确宿主/Chrome关闭。641c先前在274字符目标路径遇普通Path读取失败，原件已移动但无receipt；字节完整的partial和reserved v2全部保留。隔离文件层补Windows扩展路径后，实际先红后17项文件验证、另27项PG/HTTP及24项路径别名验证分次通过。合成PGDMP仅证明移动/hash，不是真实恢复。

专用“取消尚未领取的隔离”GET/POST现已接线到本人任务的独立确认页，closed表单/CSRF/当前恢复角色与密码；先精确metadata replay，再短预检commit、纯EX全包校验、fresh事务取消及解除本intent预留。只接受pending/attempt0/generation0/manual0且无任何JobAttempt或隔离目录的任务，通用retry/cancel仍拒绝；实际新HTTP/页面验证进行中。部分失败、已领取任务、reconcile、purge与网页恢复不因此开放。

2026-10-23新隔离确认GET/POST已接：从零删除报告进入固定preview UUID确认页，closed表单/当前密码/CSRF与完整canonical预览审计绑定。先同本人metadata重放，再readonly预检commit→纯EX/SH全hash→短fresh入队commit/finally；用户不提供路径或工具。转到现有队列筛选及精确UUID锚点，显示真实Worker完成状态，列表和服务均拒通用retry/cancel。新9c9c库实际11/11通过（11.23秒），含源字节不在入队时移动、Worker后实际target同hash、witness保持、唯一完成审计/精确POST找回及CSRF/Origin/密码/多余字段/选择SHA拒绝。首8/3中的一个为root重定向到不存在详情页，已修现有列表锚点；另两项为旧测试错误假设全局仅自己任务，改精确owner与角色过滤，旧回执保留。纯表单/模板31通过，真实Chrome与完整jobs回归另验。

2026-10-23备份读者补SH、创建补EX及当前control短gate，长归档/恢复不持DB事务；preview/submission源lease上下文显式finally关闭，来源先于target锁。reader/jobs/rehearsal/admin相关76/76及后续create/元数据14/14分次通过；真实任务引用/可信来源登记整合124/124、实际pg_dump/Worker登记2/2分次通过。旧无journal包沿原验证规则读取且不自动登记；任务hold释放后不复活，恢复意图永久保护。保护/零删除服务139为前一快照。详细证据见[读者记录](../../server/tests/backup_retention/READERS.md)与[任务引用](../../server/tests/backup_retention/JOB-REFERENCES.md)。

保留候选、显式登记、pin建立/释放与零删除预览七条后台路由已接，复用当前角色/密码/CSRF/固定UUID与CAS；最多20项选择/26表单字段。先预检commit，再纯I/O持SH全hash，再短事务fresh授权并commit/finally关闭；新POST认证/DB服务都在线程池，密码不回填。helper/四模板24/24、实际HTTP14/14及独立Chrome7/7分次通过；HTTP含20项multipart及另一连接NOWAIT，Chrome含桌面/窄屏/键盘/三角色、登记/pin20+1及显式两包报告。后验四合成包字节/目录不变、活跃会话0，宿主和Chrome已关闭。此fixture dump为合成hash材料，不是真实恢复证明；隔离是上述后续增量，purge尚未实现。

2026-10-23（Asia/Shanghai），A01–A04管理、任务和执行器页面已有真实PG/独立Chrome证据；A05原始备份导出服务、备份创建、固定目标隔离恢复及A06配置页面已接生产服务。各分项实际验收和仍未闭合的浏览器下载限制分别记录，页面可打开不表示全部P5或正式部署完成。统一缺口见[工作区说明](workspace.md)。

| 页面 | 实际能力 |
|---|---|
| 登录/退出及凭据 | 独立用途Cookie，无默认密码；修改凭据撤其他会话，本机bootstrap/recover撤旧会话并审计 |
| 服务概况 | DB可用性、用户/会话/邀请摘要、真实worker心跳和最近备份成功回执；历史成功不保证当前完整 |
| 用户与会话 | 字面搜索、活跃/附件声明占用摘要、启停、撤会话、当前密码重置；保护最后有效owner及可恢复管理身份 |
| 注册邀请 | 1–30天、单次、令牌仅展示一次、撤销；默认天数读取已生效配置 |
| 管理审计 | UTC、动作/操作者/时间筛选、快照分页、当前密码后最多5000行白名单NDJSON导出，无私人账单正文 |
| 任务/执行器 | 固定kind/status筛选、50项游标分页、fresh/stale心跳、当前密码/目标确认重试或取消；只advertise真实可用handler |
| 备份管理 | UUID清单、完整包声明字节/文件数（含manifest）、历史校验；恢复角色可重新全hash并受限下载、入队校验与创建 |
| 隔离恢复 | 仅OS登记的独立空测试DB/资料根/可信工具；当前密码预览/确认、单目标一次意图、真实worker恢复和独立完整核验、原任务状态 |
| 服务配置 | closed白名单、版本预览/CAS、同请求幂等、历史/新增版本回滚、密钥keep/replace/delete及固定provider连接检查 |

Jinja2模板、CSS与wheel同包，无外部CDN。深蓝导航、蓝色操作、浅灰画布与Flutter品牌衔接；桌面侧栏/移动导航、44px触点、焦点和reduced-motion有真实浏览器检查。窄屏导航/大表格在各自容器滚动，页面根不横向溢出。

## 权限与事务边界

当前角色分为server_owner、service_admin、recovery_admin。owner/service可管理服务与配置；recovery-only可登录portal并查看恢复任务、执行备份/隔离恢复，但不能因此修改服务配置或读取私人账本。owner没有recovery角色也拒绝原始包、创建和隔离恢复。角色变更撤目标后台会话，密码重置撤目标全部会话。最后owner与可恢复身份的保护独立执行。

POST核对Origin、CSRF表单与Cookie，并验证摘要绑定当前后台会话。生产Cookie使用Secure/HttpOnly/SameSite=Strict，空闲30分钟/绝对8小时；活动延长空闲但不越绝对上限。管理写按控制行→当前用户/会话→目标锁序重读当前权限。敏感操作须当前密码；密码/密钥/连接/目录不回显或入审计。时间先转UTC再显示，避免PG带时区值误标。

原始包导出显式分为只读当前权限/密码预检并commit、无源Session锁的线程池全hash/有界私有ZIP、短事务再次完整重认证+审计commit后打开descriptor流出；中途撤角色/会话会拒绝。包仅由固定backup UUID定位，不接受路径/URL；私有文件拒link/junction及异常硬链接，流结束清理本次临时档。

隔离恢复同样显式阶段：只读预检commit→纯I/O全hash及实际目标空检查→短事务当前权限/配置版本/来源纪元/登记绑定并授权预览commit→确认时纯I/O重新检查并持私有目标锁→短事务入队并commit后释放。目标仅OS闭集登记，实际探针再次核current_database测试前缀及实际loopback地址；表单不接DSN/目录/命令。每目标唯一occurrence，部分失败不清理/覆盖；verified私有receipt绑定目标、job、owner、preview及hash。旧worker失lease后新generation必须重新核完整DB同快照、文件、纪元/会话/frozen状态，才能复用已有恢复效果。重复确认只在当前重认证且同owner/preview/完整payload时找回原任务，不重做非空目标准备，不重新恢复。配置最终短事务持head FOR SHARE到调用方commit。

## 配置生效范围

public白名单仅10项，密钥引用仅ocr_api_key/ai_api_key UUID|null。明文仅经受控facade进入私有vault，Windows为当前用户DPAPI、Linux0600；不可变历史ref为显式回滚保留，删除当前字段不会物理删除历史密钥。无效引用显示“引用不可用，需重新提供”，不能仅凭非空ref声称可用。provider固定ID/endpoint由OS登记，HTML不接URL或secret UUID。

实际消费者已有注册开关、邀请默认天数、单文件限额、用户附件配额、孤立保留天数、worker轮询及诊断开关七项。备份保留、OCR和AI业务三项目前仅保存，UI分列待接；固定provider连接检查是独立真实探测。诊断OS硬关闭优先于DB开关，仅抑制私有辅助文件，不关stderr或正式audit；当前false导出503且旧文件保留，详情见[诊断](diagnostics.md)及[配置模块](configuration.md)。

## 验证与限制

既有A04合并70项/Chrome5组，A05导出相关108项/布局权限5组与独立HTTP包核验，A06配置合并217项/Chrome6组，创建合并235项/Chrome4组加另宿主无tool/完整包metadata1组均已有分项回执。原生Chrome ZIP下载历史仍为204/无事件，HTTP真实ZIP和NDJSON下载可用，不将这些替代原生ZIP浏览器通过，也未证明204来源。

本轮隔离恢复新增14项PG/HTML边界通过；初轮目标列表dict(Result)异常已修，失败XML保留。真实后端两目标6组通过，实际pg_restore一次、失source completion后generation2重新全核复用同receipt；另一目标被人为写入partial后普通/手工重试均拒覆盖且现场保留。另一个全新BDD目标由短UUID独立Chrome正常表单预览/确认→独立production Worker CLI一次→完成，Chrome4组首轮通过；独立后验再次全表同快照/对象hash、receipt绑定、新纪元、会话撤销/frozen、源配置5、一次enqueue及原任务replay通过。详见[e2e记录](../../tests/e2e/admin/README.md)。

当前仅本机loopback合成QA，旧QA库、恢复目标、partial、失败及历史快照都保留；未提交/推送或替换既有18080服务，Linux正式部署、受控清理及统一剩余验收按[计划进度](../plans/flowtrace/progress.md)推进。
