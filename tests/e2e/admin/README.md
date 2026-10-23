# 后台浏览器验收

2026-10-23最新备份保留页面：独立Chrome155、1280×900/390×844七项旅程通过，涵盖普通备份入口、保护原因、显式登记、密码错误空回填、pin创建/解除、20+1分页、仅两选包零删除报告、三管理角色、键盘/reduced-motion和根无横向溢出。真实HTTP另14项含20选multipart及hash阶段第二连接NOWAIT；helper/模板24为另一分次证据。详细步骤与边界见[保留页面](../../../server/tests/backup_retention/PAGES.md)。回执在`outputs/validation/P5/admin/retention-36ed99e2a9b94f79aaed420e790a24d0/browser-ca82ea4d-5f91-41e4-ae95-547c71b2fe05/receipt.json`，四截图人工视检通过。四个合成hash包/目录后验不变、活跃会话0；18092自有宿主及Chrome关闭，库和包保留。不是实际pg_restore、隔离/销毁或最终部署证明。以下按各自日期保留历史结果。

本轮在2026-10-21使用真实IAB访问隔离服务 `127.0.0.1:18080`，数据库为本机 `flowtrace_dev_local`，全部账号和数据为合成。后端权限/CSRF/改密码等自动回归位于 `server/tests/test_identity.py` 和管理模板测试；这里记录实际浏览器主路径，不宣称已有自动浏览器测试脚本。

| 路径 | 实际结果 |
|---|---|
| 管理员登录→概况→生成邀请 | 页面成功，真实用户/会话计数；生成的一次性邀请通过HTTP注册接口兑换，201，用户me为200 |
| 禁用合成账号 | 首次POST展示账号和影响，确认前API仍200；确认后页面显示已禁用，旧会话401 |
| 恢复合成账号 | 确认后可新登录200，原有撤销会话仍401 |
| 会话撤销 | 确认页展示账号和设备，确认后页面已撤销，实际API401 |
| 审计 | 能定位操作者、动作和目标；UTC显示已经针对PG的+08返回值修正并复核 |
| 普通账号进入后台 | 登录页显示固定错误，不获得管理页面 |
| 管理员退出→直接访问概况 | 回到登录页；最后退出测试会话 |
| 凭据表单 | 页面正常、三项字段与提示可见；密码变更的持久行为由真实PG集成测试验证，浏览器未提交修改 |
| 1280×800 / 390×844 | 概况、用户表、确认页和凭据表单已查看；根页面无水平溢出，长表格仅自身滚动；导航完整显示，控制台error/warn为空 |

本轮发现并修复UTC标签错误、审计缺操作者、凭据表单间距和移动导航裁切。模板先更新、旧服务尚未载入新filter时出现一次500，重启隔离服务后复核正常。

截图在本机忽略目录：`outputs/validation/P2/admin-desktop.jpg`、`admin-mobile-credentials.jpg`。记录不含密码、邀请令牌或私人账目。CSRF负向、会话到期、重用检测、最后管理员保护等以相应自动测试回执为准；P5的配置/任务/备份等全量管理功能尚未验收。

## P5管理基础与审计（2026-10-22）

新增真实浏览器脚本`management_acceptance.cjs`、受限合成初始化`prepare_management_fixture.py`和loopback测试宿主`serve_management.py`。测试仅接受`flowtrace_test_p5_admin_*`隔离数据库；本轮数据库是新建的`flowtrace_test_p5_admin_35cf020eb6c34bd1`，升级到0008（审计索引）。未替换任何旧18080资料、未清库，没有ADB或个人Edge/Chrome操作。

合成fixture为`3f498e6d-125d-48ca-b599-b5b9ca160110`，五个隔离账号与56条固定审计；凭据仅保存于新建的ignored私有文件，脚本程序读取，回执和ARIA替换凭据原值，截图遮罩输入框和用户列。浏览器使用全新UUID profile，并在每段结束关闭所属Chrome；临时18087不作为最终持久测试部署。

| 实际验收 | 证据与边界 |
|---|---|
| 键盘登录、概况与搜索 | 用户名Tab到密码；真实版本/数据库/附件声明大小；按合成账号搜索仅一行；Worker/最近备份明确“未接入状态源” |
| 重置密码 | 错误管理密码时原API仍200、新密码不回显；正确重置后原API401、新密码登录200，页面显示原会话撤销 |
| 角色与最后所有者 | 授予恢复角色并在表格回读；已有其他恢复账号时仍拒绝移除最后server_owner，角色勾选恢复当前事实 |
| 审计筛选/分页/导出 | action/actor/UTC范围筛选，50+6无重复分页；失败结果28条；当前密码后真实下载56行/16045bytes JSONL，固定字段且无凭据 |
| 权限边界 | recovery-only可登录portal但users403；service-only无角色按钮且直接roles403；服务管理角色的普通客户端token读别人私人book members403 |
| 窄屏、恢复说明与退出 | 390×844根无横向溢出，表格/导航自身滚动；CLI说明没有网页恢复执行表单；退出后直访overview返回登录 |

第一浏览器回执`outputs/validation/P5/admin/3f498e6d-125d-48ca-b599-b5b9ca160110/browser-112ae5b8-ad2c-4d3e-9286-4d4e3a8b6b06/receipt.json`前三段通过。审计下载也已取得，但脚本以HTML label精确匹配select失败；按实际ARIA改用`combobox`。用新UUID profile和显式`--resume-receipt`核对同fixture前三段证据后续跑，避免重复已提交的重置；第二回执`browser-8f27cb1a-6736-41ac-b56e-a939f83806e1/receipt.json`后三段通过。两段链合计六项，不声称某一轮六项全通过；旧失败回执/截图保留。

续跑下载SHA256为`ca96376465eec3e5a1728e83efd188d844aa9ac531965b51ad273f6ba35c7f0a`；`page_errors`为空，console只记录favicon404和故意拒绝的403/409类别，没有凭据/正文/URL。截图/ARIA在各自browser目录，独立检查过窄屏截图。

本轮首次浏览器命令及新增受限宿主的重开命令如下。初始服务实际由ignored等价helper `work/flowtrace-dev/serve_p5_admin.py`启动；重开受限宿主前须先停止已占用18087的本轮helper。该库已有持久QA证据，不再次bootstrap或重复首次重置测试；下一次全量单测使用另一个空`flowtrace_test_*`库。测试环境文件程序读取，不输出DSN/凭据。

```powershell
server/.venv/Scripts/python.exe tests/e2e/admin/serve_management.py --env-file work/flowtrace-dev/postgresql/server-p5-restore-35cf020eb6c34bd18ae80c1f092b2515.env --port 18087
$env:NODE_PATH = 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules'
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/admin/management_acceptance.cjs --fixture outputs/validation/P5/admin/3f498e6d-125d-48ca-b599-b5b9ca160110/fixture.json
```

PG/模板合并目标首轮40通过（新admin16与原identity/UTC模板），后补UTC极值filter1纳入坏filter6项专项通过，非零附件声明大小/有效会话/最近同步摘要1项通过。2026-10-23在另一新建空库`flowtrace_test_p5_admin_bee04a5f36024c12`重新合并为42/42通过（29.54秒），未复用已seed浏览器库。源码/新测试Ruff通过，现有Starlette TestClient发出httpx弃用warning，未改依赖。

A04–A06的最新分项与剩余范围见下节及[运维接口/验收](OPERATIONS.md)，尚未完成完整A01–A07；不会用上述管理基础验收替代它们。root保留共享迁移、作业/配置/备份业务与最终同源持久服务入口的集成责任。

## P5真实队列与备份校验（2026-10-23）

后台新增`/admin/jobs`固定kind/status/UUID游标分页、`/admin/workers`实际心跳、目标确认与当前密码后的重试/取消，以及两步备份UUID校验排队。当前唯一可执行类型是`backup_verify`，其他类型明确提示处理器未接入；service可查看运维元数据，校验和恢复类控制须当前recovery资格。任务列表不展示payload、文件路径或原始异常。概况接真实worker状态；60秒内联系不等同于常驻进程在线或任务完成，最近备份状态仍待对应服务。

沿既有Jinja品牌作Extension：深蓝导航`#192b45`、蓝色操作`#2279d7`、系统中文字体、44px操作目标、原surface/table/credential-form组件；不改变原表单和路由契约。设计校准为variance2/motion1/density7/asset1/brand10，桌面1280×900及窄屏390×844验证表格/导航自身滚动、根无横向溢出，支持键盘和reduced-motion。

`prepare_operations_fixture.py`在原35cf专库仅升级0009并保留全部账号/审计，使用真实`pg_dump`建立两个新UUID备份，其中一个随后同长度损坏最后一字节；新增52个明确无handler的合成export任务和一个过期心跳记录。`worker_once.py`用独立Python进程调用生产`Worker.run_once()`，不替换处理器或伪造成功结果。临时18087从旧ignored helper切换到受限`serve_management.py`，只停止核实属于本轮的旧PID。

真实Chrome155全五组通过，固定回执：`outputs/validation/P5/admin/3f498e6d-125d-48ca-b599-b5b9ca160110/operations-browser-ec9de55c-b98b-4973-ba39-c26cdc5481e7/receipt.json`。

| 路径 | 实际结果 |
|---|---|
| 正常备份校验 | 错管理密码403且密码清空；正确密码后UI pending→真实worker→succeeded，固定摘要含备份UUID/字节数 |
| 损坏与重试 | 同长度损坏产生`backup_file_hash_mismatch`；UI重试保留同job UUID，manual_retries=1/generation=2，再次真实失败 |
| 取消与未实现kind | UI取消后worker不领取；52个export仍pending，页面不提供未实现kind的重试，不回显合成私有payload |
| 分页与心跳 | 历史61任务分两页无重复（保留先前失败轮产生的真实校验任务）；真实新心跳与120秒过期fixture区分 |
| 权限/窄屏/退出 | service无校验入口/恢复任务控制；recovery看不到普通export任务且直接对象404；390根不溢出、键盘打开执行器页；退出后直访jobs回登录 |

前两轮`operations-browser-a5459006-6715-4e77-afa9-b66a1a626e4c`和`operations-browser-2c15ae7b-fc07-424b-a3f7-dc1bfbc340b5`均前四组已通过，最后console门禁发现UUID表单pattern在Chrome `/v`模式不合法。生产模板改为完整分段UUID正则后，新profile重新执行全五组通过；失败记录和已提交任务均保留。最终`page_errors=[]`，console只有favicon404与故意错误密码403，所属Chrome余0；截图和ARIA与回执同目录并已目视核对。

```powershell
server/.venv/Scripts/python.exe tests/e2e/admin/prepare_operations_fixture.py --env-file work/flowtrace-dev/postgresql/server-p5-restore-35cf020eb6c34bd18ae80c1f092b2515.env --fixture outputs/validation/P5/admin/3f498e6d-125d-48ca-b599-b5b9ca160110/fixture.json
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/admin/operations_acceptance.cjs --fixture outputs/validation/P5/admin/3f498e6d-125d-48ca-b599-b5b9ca160110/operations-c6c751cb-5db8-41ce-a6b8-0ee91ec9dd99.json
```

真实PG队列23目标覆盖双连接同occurrence、SKIP LOCKED竞争、generation/过期worker、effect内租约/owner/epoch/result失效回滚、owner锁持到outer commit、五次退避/重试/取消、当前权限与心跳投影，以及真实dump的worker成功/损坏/前后撤权/无handler/敏感payload。初轮13中两项先红，揭示终态赋值后的查询autoflush违反lease约束，root修复原子字段切换后通过。新增HTML权限/确认/重认证/幂等5目标后，最终admin23+identity19+模板5+jobs23合并**70/70通过，39.17秒**；JUnit：`outputs/validation/P5/admin/regression-e75c2ba3-920a-46f2-830e-33c75ec37430.xml`。测试目录使用包内helper导入，避免全量收集时conftest同名冲突；源码/新测试Ruff clean。

A04接收时，备份创建、隔离恢复、配置版本/连接检查/清理及其余业务kind的handler尚未实现。原始备份下载见A05节，后续配置接入见A06节；历史队列结果不等于完整A04–A06、P5或最终持久部署完成。新QA备份、任务、库、失败材料保留，未提交/推送/生产发布，无Flutter/ADB/个人浏览器操作。

## A05元数据、受限原始包与交付边界（2026-10-23）

新增`backups/administration.py`和`/admin/backups`、`/admin/backups/{UUID}/download`。元数据按UUID游标每页20项、目录最多10000项、每份清单最多5MiB；声明大小/清单可读与真实worker历史校验回执分别显示，历史成功不承诺文件此刻完整。原始包仅recovery角色可用，service和无recovery的owner均拒绝；不接受路径、URL、DSN或命令，POST闭集字段、CSRF和UUID目标确认。

下载显式分为只读当前会话/角色/密码预检并结束事务、不使用Session且无数据库锁的文件打包、短事务完整重认证与审计三个阶段，Session不并发跨线程使用。打包在线程池执行，避免阻塞ASGI事件循环；第二连接可在打包中撤权/撤会话，最终拒绝并清理文件。归档位于服务私有`admin-downloads`目录，保持已打开的descriptor到流出结束；完整hash校验后ZIP写入时再逐文件hash，只写固定UUID前缀的清单/dump/设置/图片闭集成员，拒绝链接/junction/hardlink，固定regular 0600条目和数量/字节限额。文件总量上限沿用1GiB，归档额外只允许有界清单与ZIP开销；120秒为逐文件/每1MiB读的协作式预算，不是OS硬杀保证。`verify_backup`仅新增可选trusted `check_budget`，默认调用保持原行为，改前已与data代理及root协调。

新`server/tests/backup_admin/`24项目标和原管理、队列、备份安全目标合并**108/108通过，48.60秒**；JUnit：`outputs/validation/P5/admin/backup-regression-acfaeda9-130f-495f-b650-cf3843f563be.xml`。包含真实PG动态权限/会话、目标/CSRF/密码/额外路径字段拒绝，真实文件链接/junction、初验后文件改变、字节/预算、部分生成器消费清理、历史成功后损坏不冒报完整，以及真实第二连接在打包中拿到admin_control/User锁撤权和并行health请求仍响应。唯一warning仍是原Starlette/httpx弃用；Ruff clean。最早一项测试错误为commit后访问已detach ORM对象，改为事务内保留UUID，未改变生产校验。

`prepare_backup_download_fixture.py`在35cf专库创建真实AttachmentStore的3×2合成PNG原件/缩略图，再通过真实`pg_dump`生成新备份：`d257c159-dff8-407d-aa66-8ce688073f1d`。新fixture `backup-download-4ff3900d-6b37-48a6-9836-3bff57817983.json`保存于原admin证据目录；新增一个无recovery的合成owner只供角色测试，凭据使用新ignored私有文件，原五个账号凭据不变。已有损坏备份保留，另建无manifest的UUID目录验证不可用状态。

**ZIP原生浏览器下载事件尚未通过，不把以下HTTP和页面结果称为完整下载验收。**最终独立headed Chrome页面权限/布局收据是`outputs/validation/P5/admin/3f498e6d-125d-48ca-b599-b5b9ca160110/backup-browser-16ca026d-3b43-49d4-a4b6-db2315bd7acc/receipt.json`，其`acceptance_scope`明确为access-only与分列HTTP：

| 已验证部分 | 实际结果 |
|---|---|
| 真实页面元数据 | 正常清单5文件、部分目录不可用、历史成功时间与当前完整性提示分开；创建/恢复标明服务未接入 |
| 拒绝状态 | 错密码403且输入清空；损坏文件409不带下载header；service与无recovery的owner均无入口且直接GET/POST拒绝；recovery-only可打开确认页但不能访问users |
| 页面与退出 | 1280×900和390×844截图已目视核对；根无横向溢出，导航/表格自身滚动；键盘从密码进入确认框，reduced-motion保持；退出后直访回登录 |
| 独立HTTP包校验 | owner诊断HTTP与recovery独立HTTP均取得98174bytes ZIP，SHA256 `e7114126747501d7968a3cfd4312fd71e9676b0a47964e660652d01abbe7bc10`；五成员全部大小/hash相符，两objects；从下载包取出的真实dump经`pg_restore --list`确认包含attachments表 |
| 私有临时与审计 | 服务私有临时归档余0；存在授权准备及拒绝审计。审计成功指已授权并准备响应，不证明客户端已接收；回执字段使用`authorized_preparations`。所属Chrome余0 |

失败证据没有覆盖：headed稳定路径的`backup-browser-c279cd0c-0e51-4ef9-a5b9-d419b3fd9c0b`记录UI真实POST、表单valid/checked、服务日志200，而Chrome网络为无内容204/HTTP1.0/`ERR_ABORTED`，无native download事件；错误密码的403来自HTTP1.1。同profile独立HTTP是正确application/zip/固定Disposition/Content-Length/hash，原审计NDJSON的真实浏览器下载事件正常。`0cd1236f-3bfb-4647-97f0-4de6da5ff2e7`唯一query与`13b09239-0f0e-441a-9032-764d59174e69`仅本轮Chrome直连均未解决；`219523c1-df83-4c3c-a9c8-741fd96e166e`headless同真实表单也未解决。生产form未加入nonce或其他下载workaround。

只读发现本机IDMan运行及WinINet代理启用，但未证实204来自哪一层；没有任何工具层审批或安全拒绝返回。参考[IDM官方单次下载说明](https://www.internetdownloadmanager.com/support/using_idm/starting.html)做过一次仅测试页Alt交叉，Chrome另存`download.htm`，严格文件名检查拒绝（`aebf5359-6529-4ca2-bd91-cfc7ce99270c`），没有把HTML当ZIP。未停止用户进程、修改IDM/系统代理/安全设置或操作个人浏览器；只按本轮精确ZIP名检查Downloads及Downloads/Compressed均不存在，没有枚举其他下载或宣称外部接管成功。所有失败profile/回执保留，停止组合试探，原生ZIP交付继续列为待验。

本轮最终页面验收命令（仅部分范围）和实际HTTP复核命令如下；正常下载全路径脚本默认仍严格等待download事件，当前环境会保留失败。

```powershell
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/admin/backup_download_acceptance.cjs --fixture outputs/validation/P5/admin/3f498e6d-125d-48ca-b599-b5b9ca160110/backup-download-4ff3900d-6b37-48a6-9836-3bff57817983.json --access-ui-only
server/.venv/Scripts/python.exe tests/e2e/admin/validate_backup_download.py --fixture outputs/validation/P5/admin/3f498e6d-125d-48ca-b599-b5b9ca160110/backup-download-4ff3900d-6b37-48a6-9836-3bff57817983.json --archive outputs/validation/P5/admin/3f498e6d-125d-48ca-b599-b5b9ca160110/backup-browser-219523c1-df83-4c3c-a9c8-741fd96e166e/diagnostic-http.zip
```

A05分项接收时源码SHA256：`backups/administration.py`为`97091b484fe3a6dbd26ed9294d828d4e94d4591884123c6311c4f3e8b2020a9e`，`admin/router.py`为`4195d428e0ba433013f960320a91cfdace2884be3b8c83315dcd68d2945e02d2`；这是该次历史快照，后续A06/创建有新改动。临时18087当时由受限宿主PID32852/session38489保留，不能当最终常驻部署。0009冻结窗口已释放；恢复依赖见[OPERATIONS](OPERATIONS.md)。

随后root注册`0010_import_staging`后，按已核对的受限宿主进程身份关闭上述PID，18087监听归零。35cf旧QA库仍保留0009及全部fixtures/备份/证据，未为下一阶段迁移或重置；A06使用另一个新隔离库/端口。上述运行PID仅记录此前验收宿主，不代表当前仍在线。

## A06配置版本、私有密钥与固定连接检查（2026-10-23）

配置存储新增singleton当前行和不可变revision表；0为迁移冻结的初始公开值、两密钥引用均null，保存从1开始。公开十字段与`ocr_api_key`/`ai_api_key`两引用闭集，数据库只存canonical UUID或null，不存密钥原值。存储写在当前密码认证后按admin_control→actor/session→head加锁，检查base版本及包含actor/public patch/密钥keep、replace或delete语义的request hash；同请求重放返回原版本，不重做写或成功审计。回滚创建新版本，0表示冻结初始设置；历史引用保留，回滚时重验密钥资料与提供方登记。调用者明确提交/回滚，服务不暗中回滚调用者其他写。

root接入0011迁移、Windows当前用户DPAPI/Linux私有文件vault、固定provider registry和runtime facade。准备的密钥引用绑定actor/base/request/field；同意图重试使用稳定私有资料，换明文拒绝冲突，HTML不接收引用UUID。页面显示not_configured/available/unavailable，失效资料明确“引用不可用，需重新提供”。`keep`不要求新值，`replace`须明确输入，`delete`只断开当前引用并保留历史，密码和新值在错误/预览后清空。原始数据库/附件备份不包含OS密钥资料，跨机恢复需要另行受控提供。

后台入口为`/admin/configuration`及`preview`、`history`、`rollback/{version}`、`providers`。service/owner动态角色可用，recovery-only无此权限。保存/回滚/连接检查均有当前密码、CSRF和目标版本/提供方确认；无任意URL/DSN/路径/命令。连接检查结束只读事务后执行固定端点网络，再短事务重认证、核同一配置版本并审计，不持数据库管理锁等待网络；固定状态码不带原始响应。连接可达不表示OCR/AI业务已实现。

当前六个字段已有实际消费者：邀请注册开关、邀请默认天数、单附件大小上限、用户附件配额、孤立保留天数和worker轮询间隔。诊断开关、备份保留天数、OCR与AI业务四项明确显示“可保存；运行行为尚未接入”。邀请表单从runtime读默认天数，POST省略days也采用当前配置。保留策略影响后续回收判断，保存设置本身不发起批量清理；受控清理计划尚未接入，无执行按钮。

新回归库`flowtrace_test_p5_admin_35f8593390044615`升0011后，schema/form/service自有**56/56，7.14秒**；JUnit `outputs/validation/P5/admin/configuration-service-0c54b326-72f7-4fa4-907b-73298f911638.xml`。其中真实第二连接拿锁超时55P03，winner提交后loser重读CAS409；覆盖旧Principal当前角色/失效session、当前密码、历史secret回滚、0默认、20+2分页、调用者rollback与pending写保留、跨actor请求冲突及SQL闭集/NULL目标约束。首轮约束测试因`text()`将JSON冒号识别为bind而失败（52/1），改参数化`CAST(:extra AS jsonb)`后通过，未改生产规则。新增HTML **6/6，4.79秒**，JUnit `configuration-http-66c53259-760d-4c9e-a9ec-0be428b71ceb.xml`，覆盖真实DPAPI替换/同请求重放、输入/权限、回滚、固定provider及9天邀请默认；root另有vault/provider/facade/runtime专项，不把这里的自有统计冒称全套。

浏览器使用另一个新库`flowtrace_test_p5_admin_8d6bdfd9405245be`，只一次bootstrap，fixture `15584352-15c2-43d0-a524-dda86db6e5dc`。所有账号与新密钥仅在ignored私有文件中；`serve_configuration.py`持有18087面板及18088固定loopback AI测试服务，provider端点由QA宿主的Settings登记，HTML没有端点输入。`configuration_acceptance.cjs`使用UUID新Chrome155 profile，完整**6/6首轮通过**：

| 实际普通操作 | 结果 |
|---|---|
| 公开预览 | 不要求当前密码或保存确认，不写revision；重新打开仍初始值 |
| 保存与连接 | 错密码403且输入清空；真实DPAPI密钥替换+公开设置保存为1，固定`/v1/models`实际200并审计 |
| 双标签与删除 | 两个真实页面基于1，先保存为2；旧页面提交409，不覆盖2；当前AI引用删除 |
| 历史回滚 | 目标1预览/确认后生成3，恢复同一历史密钥；目标0生成4，初始限制/注册开关恢复，历史密钥仍保留 |
| 当前角色 | service保存为5；recovery-only没有导航，直接GET403；没有额外私人账本权限 |
| 布局/键盘 | 1280×900及390×844截图已目视，根无横向溢出；密码Tab进入目标确认，reduced-motion；退出后Chrome关闭 |

回执为`outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/configuration-browser-9b115b55-d28b-42cc-80d0-9dac2f54cdce/receipt.json`，`page_errors=[]`，console只有favicon404及故意403。后验`configuration-postconditions-49ae8843-770e-4ba8-8f51-886ac832c322.json`在同目录，核最终head5/恰5revision、历史同一引用恢复、默认回滚后原DPAPI资料仍可读、service最后提交、真实固定provider调用恰1且授权成功，以及固定metadata审计无原值。此后验是服务状态交叉检查，浏览器操作证据仍以上述UI回执为准。

```powershell
server/.venv/Scripts/python.exe tests/e2e/admin/prepare_management_fixture.py --env-file work/flowtrace-dev/postgresql/server-p5-restore-8d6bdfd9405245be90583fc29b85ef95.env --migrate --configuration
server/.venv/Scripts/python.exe tests/e2e/admin/serve_configuration.py --fixture outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/fixture.json
$env:NODE_PATH='C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules'
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/admin/configuration_acceptance.cjs --fixture outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/fixture.json
server/.venv/Scripts/python.exe tests/e2e/admin/validate_configuration.py --fixture outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/fixture.json
```

初始化命令仅用于该次新空库，不得对持久fixture重跑bootstrap；完整浏览器脚本要求初始版本0，也不得把最终head5重置为0再伪装初次验收。35cf旧0009库未迁移/改写，35f859仅隔离回归，8d6b保留浏览器资料。A06这里接收的是配置/连接基础，受控清理、OCR/AI业务和完整后台的剩余任务仍按[OPERATIONS](OPERATIONS.md)推进；无Flutter/ADB/个人浏览器、提交、推送或最终持久部署操作。

接入UI后的合并回归为**217/217通过，62.85秒**，范围为admin、configuration、jobs、backup_admin、identity、模板和backup_safety；JUnit `outputs/validation/P5/admin/configuration-regression-a84f8d19-e2e1-4235-938d-c4591ef6140d.xml`。唯一warning仍是Starlette/httpx弃用，未跳过目标；该数仅覆盖实际列出的目录，不等于完整服务端或全部计划验收。实际命令：

```powershell
server/.venv/Scripts/python.exe work/flowtrace-dev/run_isolated_queue_tests.py work/flowtrace-dev/postgresql/server-p5-restore-35f859339004461590a30489f3c65104.env server/tests/admin server/tests/configuration server/tests/jobs server/tests/backup_admin server/tests/test_identity.py server/tests/test_admin_rendering.py server/tests/data_tools/test_backup_safety.py -q --junitxml=outputs/validation/P5/admin/configuration-regression-a84f8d19-e2e1-4235-938d-c4591ef6140d.xml
```

回归与文档交付后，已再次按脚本名及fixture UUID核对并关闭本轮QA PID16520，18087/18088监听归零，所属Chrome余0。8d6b库/head5、私有vault和全部fixture/回执保持，未转为最终常驻服务；后续创建功能需新Settings宿主接入，不重置本轮资料。

## 受控创建备份与真实执行器（2026-10-23）

root的`backup_create`真实handler/命令经专项实际PG/pg_dump验证后，接入`/admin/backups/create`。当前recovery角色单独确认服务实例UUID、expected epoch与包含全用户资料的范围，当前密码、CSRF及request UUID校验后排队；同请求返回同job/backup UUID且不重复成功排队审计。页面只说排队，终态以worker实际结果为准。仅当当前Settings登记的trusted pg_dump绝对路径存在时显示入口，所有jobs list/get/control调用显式传Settings；缺配置实例不advertise/claim该kind、不允许重试。工具不由HTML提交，service及无recovery的owner仍无创建权限。恢复执行入口继续不提供。

新增HTTP创建3项目标与原jobs HTML5项合并**8/8通过，5.52秒**，JUnit `outputs/validation/P5/admin/backup-create-http-81a76898-ee1e-4815-97e0-1b3427f89aa1.xml`。覆盖错目标/epoch/密码/CSRF、路径/命令额外字段拒绝、工具未配置、同请求一条job/audit及三类角色；这些HTML测试只验证注册/入队，没有把tool sentinel当真实执行。实际pg_dump证据来自下面的CLIworker和目录后验。

同8d6b/head5资料新添77-byte的3×2合成PNG和真实缩略图，仅fixture阶段发布附件，不预先创建备份；增加一个无recovery的合成owner，凭据另存ignored文件。creation fixture为`backup-creation-6540794c-7997-401d-9575-8827e65f0d38.json`，保存在15584352证据目录。新宿主`serve_configuration.py --backup-create`只启用工作区固定pg_dump，实际作业使用独立`worker_once.py --backup-create`调用production Worker。没有常驻worker或最终部署的主张。

第一浏览器`creation-browser-faea948e-3027-4f7f-9008-84beb9e5ce03`真实创建成功，但文件数检查失败：worker旧结果不含manifest而报4，列表完整目录为5。root统一create/verify result和create_backup receipt为包含清单的计数/字节，并调整结果上限；旧成功job6696a755/artifact e7960a56及失败回执均保留，未改历史结果。当前metadata也把实际manifest raw长度计入声明大小；新纯fixture测试核5成员及全部成员大小和。此大小为目录成员合计，不包括ZIP容器额外开销。

修复后新UUID Chrome完整**4/4通过**：`outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/creation-browser-d35eb9df-bfcd-41c7-bf1a-fd6ff56b599d/receipt.json`。

| 实际旅程 | 结果 |
|---|---|
| 所有者创建 | 错当前密码拒绝后，真实确认/排队/CLIworker完成；job c120e05e，backup `69f9e473-aaff-588d-b8ba-12d4bd79a94c` |
| 独立校验 | 上述产物再经独立UI `backup_verify`和CLIworker成功，备份页显示历史校验回执 |
| recovery-only创建 | 可创建第二个真实包，job5a508004，backup `5c8350dd-6617-5f10-855c-f72c645e9c3f`，配置页仍403 |
| 拒绝与布局 | service/无recovery owner无入口、直接GET403；390×844无根溢出，密码Tab到确认框，退出；截图已目视 |

后验`creation-postconditions-32b5402e-fae1-4585-aac1-bcf17e276e34.json`核两份真实dump均`pg_restore --list`含attachments表，5文件/2objects全部hash，77-byte原图一致，每个job入队audit恰1，source配置head5保持；所有者目录成员合计125281bytes，recovery目录126121bytes。原始ZIP浏览器下载未重试也未冒称通过，A05限制继续保留。

metadata字节窄改是在创建QA宿主启动之后落地，因此另重启无tool宿主并用新profile验收，不假称旧进程加载了新源。独立scoped **1/1** `creation-browser-ed48c8ab-db14-4207-9c00-574987093839/receipt.json`核实际列表5成员/完整字节与后验一致、无创建链接、直接入口503且无执行表单、jobs不advertise创建。与上面的完整4组分列；两轮均无page error，console仅favicon404/故意403或503，所属Chrome全部关闭。

```powershell
server/.venv/Scripts/python.exe tests/e2e/admin/prepare_creation_fixture.py --fixture outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/fixture.json
server/.venv/Scripts/python.exe tests/e2e/admin/serve_configuration.py --fixture outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/fixture.json --backup-create
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/admin/backup_creation_acceptance.cjs --fixture outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/backup-creation-6540794c-7997-401d-9575-8827e65f0d38.json
server/.venv/Scripts/python.exe tests/e2e/admin/validate_creation.py --fixture outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/backup-creation-6540794c-7997-401d-9575-8827e65f0d38.json --receipt outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/creation-browser-d35eb9df-bfcd-41c7-bf1a-fd6ff56b599d/receipt.json
```

只有首次添加合成数据时运行prepare，不重置head5或已有备份。后续恢复需要OS固定target登记、空目标预览/再验及verified私有receipt，见[OPERATIONS](OPERATIONS.md)；没有生产覆盖或页面自填DSN/路径。

创建UI与完整包口径修改后的合并回归为**235/235通过，58.99秒**（admin/configuration/jobs/backup_admin/identity/模板/backup_safety），JUnit `outputs/validation/P5/admin/creation-regression-f068f16e-d007-4711-b974-d566071cb559.xml`；唯一warning仍为原Starlette/httpx弃用，未跳过目标。Ruff与Node语法检查通过。创建4组宿主PID22452已关闭；无tool补验宿主PID38448完成后同样按脚本/fixture身份关闭，18087/18088及所属Chrome归零，8d6b原head5/备份/附件/资料/失败回执保留。


## 2026-10-23 固定目标隔离恢复：真实后端6组、Chrome4组与独立无登记1组

本轮生产模块 `backups/rehearsal.py` / `rehearsal_schemas.py`、`/admin/restores`、预览/确认/原任务状态页已接实际生产Worker。仅OS登记的UUID目标可选，网页不接DSN/目录/命令；创建空目标必须由本机受控测试环境另行准备，**不能给空恢复目标迁移或bootstrap**。源库仍为已有8d6b（schema0011、配置head5），旧35cf/35f859与A2dc/B979现场不变。

预览的当前密码/角色只读预检显式commit，再由线程池无源DB写锁全hash/实际探针空目标；最后短事务重认证、配置FOR SHARE/来源纪元/固定登记复核并commit授权。确认再次纯I/O全核，私有目标锁跨source入队commit。target UUID的单一occurrence永久保留；重复确认须当前密码、同owner/preview/完整payload，只找回原任务，不对已消耗目标重新准备或执行。

私有preview有300秒新操作期限，不含明文连接；receipt绑定job/owner/preview/target/备份及完整hash。完整恢复核验使用REPEATABLE READ READ ONLY目标快照，statement_timeout120s、lock_timeout5s，核所有表摘要、余额、精确附件树/逐文件hash、独立新纪元、全部会话撤销及旧客户端frozen。840秒及trusted worker预算是协作检查，原pg_restore有独立进程预算，不声称所有OS阻塞都能绝对硬杀在总期限内。partial没有verified receipt时拒覆盖并保留；source完成失败后generation2必须fresh完整复核，才能复用同效果。

- 边界/PG/HTML14项通过（5.67秒）：`outputs/validation/P5/admin/rehearsal-ui-boundaries-f4b581f4-3074-4e4a-8c07-218cd723ef84.xml`。首轮11通过3失败源于`dict(Result)`列表查询，修为`.all()`后复跑通过，首轮`rehearsal-ui-boundaries-29c44275-6934-473b-ad77-acab52d95a49.xml`保留。
- 独立真实后端6组：`15584352-15c2-43d0-a524-dda86db6e5dc/rehearsal-stages-1e65f4b4-6e38-4e15-a91d-5d0a1804aca4/receipt.json`。正常A2dc实际pg_restore恰一次，丢source completion后generation2全核同receipt成功；B979在入队后放本轮witness，普通与手工重试均拒非空，witness/空DB不变。两个目标永久保留。先前actualinet::text带`/32`导致只读探针失败，修`host(inet_server_addr())`及IPv4mappedloopback校验，`rehearsal-stages-444ad465-0435-4af2-ab45-e550b7b0c38d`失败不改写。
- 真Chrome4组首轮通过：`15584352-15c2-43d0-a524-dda86db6e5dc/rehearsal-browser-c9aaf877-1aa4-4df2-b73f-d66c384ac71e/receipt.json`。Chrome155.0.8059.85、headed、全新短profile `work/browser-probes/c9aaf877-1aa4-4df2-b73f-d66c384ac71e`，没有用户浏览器。普通表单错密码→预览且独立验证目标仍空/根absent→390px/Tab确认→生产独立CLI worker一次→实际完成；重复同预览错密码拒、正确找回同job；service与无recovery owner403，recovery-only可看状态而配置403。page_errors空，console仅预期403和favicon404；桌面/窄截图已目视，无根横溢。
- 第三个BDD真实目标数据库 `flowtrace_test_p5_restore_bdd1a35fdbdd4ef2`，UUID `e9d5a5c7-3c84-45be-ae54-58c596d2cc83`，job `05aeb13b-6cf0-4e09-b27c-e34b1a2b13e8`，preview `73718a2c-113c-45a0-819e-471c8052489c`。源备份`69f9e473-aaff-588d-b8ba-12d4bd79a94c`的77字节实际PNG及缩略图随真实DB/对象恢复；目标已消耗，禁止再次当空目标使用。
- 独立后验 `15584352-15c2-43d0-a524-dda86db6e5dc/rehearsal-browser-postconditions-53221460-8d42-475b-a15e-ef086787cbb2.json`：再次完整DB同快照/对象hash/私有receipt绑定、新纪元/全部撤会话/frozen通过，源配置head5不变，单intent、enqueue audit1、replay audit1、attempt1/generation1。

实际启动命令（fixture只引用ignored私有env/凭据，绝不输出其中DSN或密码）：

```powershell
server/.venv/Scripts/python.exe tests/e2e/admin/serve_configuration.py --fixture outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/fixture.json --backup-create --restore-fixture outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/rehearsal-browser-fixture-639defee-675c-4080-9afc-1ec6b67eee37.json
# 确认18087/18088属于本轮服务且ready，再运行浏览器；真实恢复目标现已消耗，不能重做该首次验收。
node tests/e2e/admin/rehearsal_acceptance.cjs --fixture outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/rehearsal-browser-fixture-639defee-675c-4080-9afc-1ec6b67eee37.json
server/.venv/Scripts/python.exe tests/e2e/admin/worker_once.py --env-file work/flowtrace-dev/postgresql/server-p5-restore-8d6bdfd9405245be90583fc29b85ef95.env --restore-fixture outputs/validation/P5/admin/15584352-15c2-43d0-a524-dda86db6e5dc/rehearsal-browser-fixture-639defee-675c-4080-9afc-1ec6b67eee37.json
```

`worker_once.py`是实际生产`Worker.run_once`的一次独立CLI调用，浏览器脚本在真正表单入队后调用它；不是HTTP客户端替代UI，也不伪造restore结果。`validate_rehearsal_browser.py --phase preview|final`只做独立只读核验。

恢复UI合并回归**262/262通过，71.70秒**，实际范围admin/backup_admin/backup_rehearsal/jobs/configuration/identity/rendering；没有包含旧回归的backup_safety，不能直接与235计数作差。JUnit `outputs/validation/P5/admin/restoration-regression-b0f4d0fe-1403-4d91-a24d-f4708e1ed9bb.xml`，唯一warning仍为Starlette/httpx弃用。实际命令：

```powershell
server/.venv/Scripts/python.exe work/flowtrace-dev/run_isolated_queue_tests.py work/flowtrace-dev/postgresql/server-p5-restore-35f859339004461590a30489f3c65104.env server/tests/admin server/tests/backup_admin server/tests/backup_rehearsal server/tests/jobs server/tests/configuration server/tests/test_admin_rendering.py server/tests/test_identity.py -q --junitxml=outputs/validation/P5/admin/restoration-regression-b0f4d0fe-1403-4d91-a24d-f4708e1ed9bb.xml
```

原生ZIP另按root授权仅一次短新profile交叉：`15584352-15c2-43d0-a524-dda86db6e5dc/backup-short-profile-59497bb7-6152-4a71-9f81-aeaa865a5c50/receipt.json`，真实recovery当前密码/目标勾选/普通UI POST，Chrome仍204、net::ERR_ABORTED、无download事件。未改个人浏览器/IDM/代理/系统设置，未遇工具审批拒绝，不归因路径、不标浏览器ZIP通过。已有HTTP真实ZIP与历史NDJSON成功仍分列。

未登记registry的另一个宿主/新短profile只读Chrome1项通过：`15584352-15c2-43d0-a524-dda86db6e5dc/rehearsal-browser-e67c8af4-636d-472a-abe5-2b4d0265540a/receipt.json`，明确无可执行表单，不与有registry4项混成同一轮。其首次`rehearsal-browser-068b6894-eb86-4b7a-8d9b-a74aafc2d6d3`因宿主启动尚未ready发生connection refused（没有登录/业务修改），保留后待端口ready用新profile重跑。


## 2026-10-23 诊断开关：七项生效、三项待接

新的诊断policy/独立只读MVCC探针已接入main/middleware、worker与受控CLI作用域；无context或OS硬关闭不收集私有文件，DB关闭/读取失败/探针忙在文件锁后fresh guard处拒写，不借业务Session、不装maintenance围栏。stderr和正式audit独立保留。后端真实配置POST false/true与export503/200、OSfalse无文件、多app及async线程池已验证，UI标签HTTP明确7已接/3待接。此前A06真实Chrome6组与六项消费者是当时快照，不改写为新回归。

- 标准模块策略/store/Windows spawn24项0.77秒：`diagnostic-policy-ffbb7f2a-bca2-4d3e-ad80-dce1958c0e6f.xml`。
- 新d4a5库39项12.33秒：`diagnostic-runtime-0947fad2-093d-40d6-b465-7486bfca7ee3.xml`，真实PG当前提交开关、行锁/maintenance/schema锁与附件。
- 完整真实POST/export/OSfalse专项5项5.46秒：`diagnostic-http-33937452-bf43-4f5b-95e3-e219a5c4a0c8.xml`，不以fake reader代替DB。
- 相关合并158项36.53秒（configuration含root ASGI两项、策略/store/spawn、附件）：`diagnostic-combined-c879116d-7d5c-422f-968d-a544bdfc73b9.xml`，无skip/仅原弃用warning，0011快照。

Windows spawn首轮误用无main guard的programmatic pytest.main runner导致递归PG执行，另有审计字段断言错误；97e51989失败保留，旧35f859 head0/true/revision0/users6只读快照保留，不再当空库。后续始终使用guarded env launcher经subprocess启动`python -m pytest`。158合并首命令误拼root文件路径无目标执行，a2e60c02无测试XML保留。所有测试均不重置旧QA/三恢复目标，未因诊断测试操作用户浏览器。

实际完整命令：

```powershell
server/.venv/Scripts/python.exe work/flowtrace-dev/run_isolated_pytest_module.py work/flowtrace-dev/postgresql/server-p5-restore-d4a5e7b6873a4fb5af7aaada5f43a8bb.env server/tests/configuration server/tests/test_diagnostic_policy.py server/tests/test_diagnostics.py server/tests/test_attachments.py -q --junitxml=outputs/validation/P5/admin/diagnostic-combined-c879116d-7d5c-422f-968d-a544bdfc73b9.xml
```

root后续0012发现窗口和其他业务回归独立记录；本轮不把158当全服务端完成。受控保留/隔离/销毁的下一依赖见[设计分册](../../../AI/plans/flowtrace/backup-retention-controlled-cleanup.md)，当前无清理实现。
