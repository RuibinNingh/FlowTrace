# 流迹开发计划进度

> **当前执行与恢复（2026-10-24，Asia/Shanghai；内置服务器与原生重建包已交付）**
> - 用户要求以后内置`home.ruibin-ningh.top`并重建Windows/APK；本包默认完整地址为`https://home.ruibin-ningh.top:18473`，版本`0.1.1+2`。仅没有已存active_server时采用默认值，手动地址及旧资料空间保留；没有自动搬账或切换既有账号。
> - 代码恢复提交`158ebc2`，基线`57b6386`干净；普通main、未传QA/local-test define，Windows Release与Android ARM64 Debug串行构建，214项源码/资源/锁定输入前后不变。旧包保留，APK`.dev`/原Debug证书保持、versionCode2。
> - 验证：41项地址/身份/账号页定向通过、两文件分析No issues；Windows全新解压25运行文件/hash通过，隔离根实际启动schema5并注册默认正式地址，仅关测试进程；APK元数据、v2签名、161成员CRC、main入口/内置地址、私有值排除通过。没有Android/ADB或完整原生UI/旧库原地升级验收，不重复上包1015完整测试。
> - 产物：`outputs/releases/production/20261024-clients-0.1.1+2/`，含Windows ZIP、APK、manifest、hash及说明。来源、具体大小/摘要、实际命令见[本包记录](../../logs/2026-10-24_native-client-rebuild.md)。没有替换用户Desktop安装或生产服务/Web；本次无子代理、无推送。
> - 当前生产仍为上包后端1447709/Web fcdcda0，105条/3退款及脱敏日志证据保持。下一动作是用户关闭旧Windows程序后解压新包、覆盖安装新APK并用既有正式账号试用；安卓测试继续取消，后续包仍由用户决定。

## 上包钱迹修复接收快照

> **2026-10-24钱迹修复包已交付并更新生产**
> - 用户明确要求兼容实际导出、处理105条及退款、开启脱敏日志/具体错误，并在测试通过后更新生产。本包完成，不自动开启其他功能包；安卓测试继续取消，无推送。
> - 本地代码恢复提交：`fcdcda0`（适配/UI/诊断）、`fa91d84`（收支同名分类）、`1447709`（Python3.13私有日志分派）；开工基线`db77b7e`干净。当前文档与部署回执见[本包记录](../../logs/2026-10-24_qianji-export-import-fix.md) → [生产模块](../../modules/production-deployment.md) → [Linux手册](../../../deployment/linux/README.md)。
> - 实际原文件：全新Linux隔离库105条原子导入、3退款精确关联、全部金额/正式报表、10收支分型分类、重放不重复和撤销恢复基线均通过；账户空则不造资产分录。原件未改、未自动导入生产。
> - 页面：同版独立IAB以合成105条完成真实选文件、具体原因/错误码/请求ID、文件交接、整批预览/确认、同步及重开105条/0待传。普通50行限制保持，完整文件走既有stage。
> - 验证：阶段服务端175通过；分类84、最终诊断30为后续分次目标；客户端1015通过/8专用live默认跳过，变更范围分析无问题，未接收历史测试单文件被排除；契约21/113subtest。完整范围/失败与已知并发group等缺口集中见[workspace](../../modules/workspace.md#当前缺口)。
> - 生产：后端`/opt/flowtrace/releases/20261024-qianji-1447709`，Web`/www/wwwroot/flowtrace/releases/20261024-qianji-fcdcda0`，各自current已切换，head0016无DDL；API/worker active、正式域名HTTPS ready200。诊断OS/运行双开，实际错误请求ID可从后台安全导出，私有目录/文件0700/0600。两轮更新备份与旧版本保留。
> - 产物：`outputs/releases/production/20261024-qianji-1447709/`的wheel/锁/Web ZIP/manifest/hash；Web复用已验fcdcda0构建，Windows/APK继续原M1切面。临时QA服务/转发已关，测试库/原件/失败证据保留。
> - 下一动作：用户在正式Web更新后选择原XLSX，点“钱迹原始导出 / 超过50条完整导入”，完成资源映射，核对105条预览后确认。若出错，提供行/字段、错误码及请求/任务ID即可；不发送账单正文或口令。下一包由用户决定，当前额度在交付回复据接口报告。

## 首次生产接收快照（当前版本以上文为准）

> **2026-10-24初始生产Alpha部署；部分验收未完成**
> - 最新授权：用户已明确授权连接 `root@192.168.0.145` 读取服务器 wiki，并以 `home.ruibin-ningh.top` 生产部署。本轮安卓测试已取消，直接按 Alpha 最终部署交付；完整钱迹功能与长期 P0–P8 不因此完成。此前“不部署生产”“等待 M2”仅是历史状态。
> - 恢复入口：[生产任务记录](../../logs/2026-10-24_production-deployment.md) → [生产部署模块](../../modules/production-deployment.md) → [Linux 运行手册](../../../deployment/linux/README.md)。本包文档开始时 Git 为 `main`、`59e246f`，工作区干净；已存在本地恢复基线，不再是无提交仓库。
> - 服务已实际部署：Debian 13.5、原生 PostgreSQL 17.11，新 `flowtrace_prod`/`flowtrace_app`，独立 Python 3.13.5 venv 与35项锁定依赖；迁移 `0001`–`0016` 和 check 通过。`flowtrace-api`/`flowtrace-worker` systemd 已启用且 active，API 仅监听回环 `18210`。
> - 入口已接通：Nginx 在目标机 `18473` 提供 TLS，Windows 对 `home.ruibin-ningh.top` 的域名 curl 得到 ready 200；BT/UFW 与 OpenWrt 专用 TCP `18473` NAT 规则已保存。证书精确续期成功，到期日 `2027-01-22`；规则持久配置不等同于整机重启已验。
> - HTTPS API 已验：用户登录、78B PNG 上传/下载、account/bill 两项 push、相同正文重放及pull；余额9875、唯一分录-125、图片hash保持。脚本误传字段422已按契约修正，只复用原数据读取，未重复金融写入；合成账号已禁用，后台真实HTML表单登录/退出通过。
> - 产物与凭据：Web 复用 a3d9，Windows/APK 复用 [M1 候选](alpha-candidates.md)；正式 owner 凭据保存在目标机 root-only 私有文件，不入仓库。本包没有 Android 操作、没有 Git 推送；冻结 APK 的旧功能切面和测试签名限制保留。
> - 备份与运行：首份一致备份010b2d24已真实恢复到全新Linux测试库，内容摘要/余额/图片及epoch/撤销通过；API/worker受控重启后数据身份保持、HTTPS ready200。两个每日timer已启用，私有配置独立归档；不是整机重启或异机备份证明。
> - 三端产物及配套wheel/锁/hash/说明已统一到`outputs/releases/production/20261024-alpha-0926681/`，服务器项目文档/wiki入口已补齐，保存本地恢复提交、无推送。首次客户端使用需设置生产HTTPS地址。
> - 未验/下一动作：生产浏览器两次取页超时，已停止扩大调查；用户试用页面登录/同步后反馈。独立外网、整机重启、Windows完整UI仍待验，安卓测试取消。当前不自动开启新包或扩展功能，已知项集中见[workspace](../../modules/workspace.md#当前缺口)。
> - 额度模式保持：最多2个子代理，针对性验证优先，无新功能，复杂故障最多两轮有证据的定位与修复。本包完成后报告实际产物、验证、遗留和当前额度，再由用户决定下一包；额度接口不可用时明确未知，不沿用历史1%作为当前结果。

## 历史接收快照（不作当前恢复位置）

> **2026-10-24 M0/M1 接收快照**
> - 用户要求：额度受控Alpha，优先可测试Windows/Web/APK与独立本地测试服务；暂停非交付必需的新功能。完整功能计划保留，不再自动沿P4–P8扩展。
> - M0：已核Git原无提交基线，保存本地恢复点和交接；当前0个活跃子代理，本包未派发，未新增业务代码/构建/部署。现有运行资料和失败现场保留。
> - 现成验证：取消页面相关最后一包35通过/48.37秒为已有回执，本包未重跑；新增历史读取源码仍未验证，group40001窄修未完成，均转交接。详细阻断与待办集中在workspace。
> - M1完成：Windows普通local-test ZIP、Web a3d9与旧普通Android debug APK已冻结到outputs/releases/alpha/m1-20261024；只补建缺入口的head0016后端wheel。文件hash/来源和6项wheel入口smoke通过；实际三端/DB联调尚未做，不称最终Alpha。
> - 临时试用：用户明确要求先运行Web和临时账号，回环18200已启动并实际登录，M1 Web/新测试库/普通用户，IAB页保留。口令只在私有配置和本次交付，详见[记录](../../logs/2026-10-24_temporary-web.md)；不算完整M2/M3，未安装自启。
> - 下一项：M2必要的组合启动/同步/保持检查、阻断修复与Web ZIP/安装说明；**待用户决定是否进入，不自动启动**。候选细节见[清单](alpha-candidates.md)。
> - 额度：M1接收接口报告7天窗口已用1%、额外积分0；每包交付重新检查，不等同于包内token/费用。上限2个子代理，针对性验证优先，复杂故障两轮仍失败即交接。
> - 依据：[Alpha里程碑](alpha-milestones.md)、[本包记录](../../logs/2026-10-24_alpha-checkpoint.md)。仅本地提交，未推送/生产部署；三产物与持久服务尚未最终交付。

以下为2026-10-23的接收快照；其中“进行中/正在验”是当时状态，当前执行范围和恢复位置以上方生产包状态为准。

> **2026-10-23状态快照**
> - 用户范围：继续非安卓P5–P7；安卓专属/ADB/安装暂停。完成后交付普通Windows/Web/APK并部署独立本机持久测试服务，详见[交付分册](delivery-local-test.md)。未最终打包、Install、持久Start或任务注册，整体goal active。
> - 当前动作：普通stage17/完整映射页已接；c462及新d1ba native各1/1通过。c462 followup因测试peek改变attempt_count失败，已修只读peek；d1ba followup实际group_unavailable失败，金融undo已成功但新group创建遇PG40001，正在新库可控并发复现并窄修共享预算重试，原现场不重发undo。普通Chrome独立8bb7正验。后台同深度2890 Chrome入队5/完成3与真实CLI Worker通过，641c无receipt partial保留；未领取取消PG25已验、root独立页面已接，HTTP/Chrome继续，不加DDL。
> - 客户端：schema5全量快照1009通过/6专用live默认跳过（59秒），完整analyze clean（8.1秒）；相关122和图片两端反核4分次通过。新stage TCP实际1/1、19秒：204items/101expense/2publication chunks，614400B两片，chunk/apply成功回复各丢1、磁盘离线重开2、原apply正文/原件/outbox保持，余额9007199254728368、原图hash、no push。后验active session0/18094 API-worker已关。此为VM+沙箱Windows目录bridge，非普通UI/runner secure vault/容量性能；续接清源undo及Chrome另验。
> - 服务端：稳定head0016，52表/原9trigger/6function及identity/config保持，旧QA不迁。隔离handler与管理executable已接，完整jobs新005e库68通过/1图片专用默认skip（17.02秒），新2a1图片另1/1（1.94秒）；首旧恢复替身漏before_read的6失败保留，修fixture真实SH/gate/hold后通过。stage普通main相关86/1新夹具误期望后单项1为分次证据，实际API72/176/79与合同21通过。
> - 大迁移：当前requirements/源释放相关同次168/168、0skip（79.71秒）；源释放120与0014非空8表真实恢复1、0015非空9表真实恢复1为分次证据，均保旧包/库。完整名称派生清单有界分页/hash，mapping_hash同Python/Dart黄金供丢回复核对；正式金融Batch/Items/Publication保持。早前完整169、四阶段jobs62及图片1、PublishedStageContext48/HTTP18为历史独立分项。公共导入50/导出1000和旧sync限制不改。
> - 备份保护：保护/reader/任务引用/候选HTTP14/Chrome7为此前证据。quarantine641c首次Chrome入队5通过、Worker在274字符目标普通读取失败，字节完整/无receipt partial与两reserved v2保留；扩展路径修复实际先红后17文件、27 PG/HTTP、24路径别名分次通过。同深度新2890 Chrome入队5/完成3、真实CLI Worker/哈希/回执/controls v3和审计一致，余三包未变，精确host/Chrome已关。合成PGDMP非pg_restore。未领取专用取消新9add25通过，只无效果才解除本intent预留；已领取/partial/retry/reconcile/purge/网页恢复未开放。
> - 后台：恢复生产pg_restore backend6检查、Chrome4+无registry专项1、postconditions与相关262/262通过；三个目标和partial保留，宿主/Chrome已精确关闭。原生ZIP短新profile重试仍204/无download事件，HTTP归档证明分开。七项配置消费者已接，诊断真实POST/export/OSfalse/审计与多app/async目标后相关158/158通过；保留清理、OCR/AI三项pending。
> - Web：新普通schema5候选web-stage-20261023-c5e8构建59.5秒/seal39资源，release e4d63f…e821c，main3431f0…e3101，184源前后同aab12e…d2301；尚待新Chrome stage旅程，非最终包。旧a3d9、提示/地址/离线及原ARIA失败/profile差异证据保留，不扩大为新候选或完整P6验收。
> - Windows与部署准备：普通0.1.0+1候选尚非最终包；原生桌面等待已发出的本人解锁答复，未操作锁屏/安全输入。部署工具静态25+Windows准备11分开36项通过，未安装服务。Anaconda3.12缺ensurepip内置wheel的venv失败保留；固定uv Python3.13.5在新工具venv离线安装35锁定wheel、pip check和14运行库导入通过，未改全局环境。
> - 完整边界：P4回款历史/完整UI/严格来源/Reference/typed、周期分期及七储蓄计划尚未闭合；P6/P7完整业务/保护/更新/文件旅程继续。安卓设备暂停、Linux缺环境延后；独立Chrome，不用用户Edge/个人Chrome。Git main无提交基线，未提交/推送/生产部署。
> - 运行：PG55432保留原测试集群；18080无旧监听，迁移18090/Web18190与恢复18087/18088自有短程宿主验证后均关闭；保留QA库、vault、备份及所有失败现场。

## 长期分期状态（历史接收表）

| 切片 | 状态 | 验收依据 |
|---|---|---|
| 本轮计划制定 | 已完成 | [本轮任务记录](../../logs/2026-10-21_plan-flowtrace.md) |
| P0 证据补齐与契约，4 项 | 实施基线已验收，原应用动态补验保留 | [证据矩阵](evidence-matrix.md)、[平台检查](platform-validation.md)、[开发记录](../../logs/2026-10-21_develop-flowtrace.md) |
| P1 基础工程与 Linux 隔离演练，4 项 | P1-01/02/03 已验收；P1-04 环境待补 | 客户端95项+Android真机1项、Web真实持久化/分区；Python独立wheel/HTTP，领域各86项；Linux按用户要求延后 |
| P2 身份同步与后台最小管理，4 项 | 本地基线已验 | 客户端178通过/3项默认跳过且各有live专项结果；Android身份/冲突/附件各1项、专库真实回滚1项；普通main启动与客户端诊断页真实浏览器已验，Linux边界未验 |
| P3 Android 日常完整主路径，4 项 | 原记账真机与查询/统计/移动本地/Web分项已验；真实系统picker/OS恢复专项新通过，完整旅程待最终 | 合成图片77bytes/取消/10MiB+1拒绝，第二attempt同APK无重装COLD/query_only恢复、余额9875和原IDs/body/完整草稿/原件一致；不是完整P3/P4旅程 |
| P4 高级账务与完整功能，5 项 | P4-01本地/Web接收；P4-02 B授权/因果/纯预览/单笔确认接收，历史/UI/复合待后续 | server445+后补2/socket1、合同21、client764/5默认skip与分析通过；Android本地fixture专项、c974/504 Web保持。cap/严格来源/Reference/typed未闭合，整包/全平台未验 |
| P5 自动记账迁移个性化与后台全量，4 项 | 非安卓部分实施中；安卓专属延后 | 数据服务/真实PG恢复分项通过；客户端迁移、设置保护、全量后台未闭合 |
| P6 Web，3 项 | 实施中 | 离线壳真实Chrome专项通过；普通Flutter完整旅程、更新屏障及完整业务仍待验 |
| P7 Windows，3 项 | 实施中 | 原生QA两版本升级/数据保持与快照专项通过；普通main桌面/完整旅程仍待验 |
| P8 Linux 最终交付与全量验收，3 项 | 未开始 | 待干净 Linux 部署、恢复与完整验收 |

本表保留完整功能路线当时的接收位置；当前生产部署不等于 P8 全量验收完成。工作包定义与详细依赖以 [任务分册](tasks.md) 为准，表中的未来产物是验收要求，不是已获得的结果。

P4-02的[实施细化](p4-02-implementation.md)包含开工差异、A–F依赖及T01–T15；最新接收表已区分追踪/summary部分、纯模型和未实现B/C/D。字段/无标识聚合已实现验证，但整套方案A严格规则未闭合，`receipt-tracking-v1`仍不advertise，未来`receipt-restructure-v1`独立未实现。

## 历史验证与遗留边界

本轮文档结构、覆盖和本地链接检查通过，实际验证回执保存在任务记录；当前能力和已知环境缺口以 [工作区说明](../../modules/workspace.md) 为准，原应用证据边界以 [产品范围](product-scope.md) 为准。

截至上述历史快照已有P0基线、P1本地工程与P2身份同步等专项结果；P3分项测试不等同于完整应用业务验收。当时Linux部署恢复未执行，原因是用户暂无Linux测试环境；当前已获目标机生产授权并完成顶部列明的部署分项，恢复验证仍以当前生产任务记录为准。

## 下一步

本次原生0.1.1+2包已交付，内置正式服务器；从[本包记录](../../logs/2026-10-24_native-client-rebuild.md)恢复。用户正常关闭旧Windows版本后解压运行新包，APK沿用原签名可覆盖安装且不清数据；已有手动地址仍保持。安卓设备测试不恢复，生产/Web仍是上包版本；真实账本导入仍须映射/预览/确认，不自动开启新功能包。其他边界集中见workspace。

### 原全功能恢复顺序（历史，当前不执行）

本轮以[P5–P7分册](p5-p7-implementation.md)和顶部状态恢复：先完成客户端大文件映射草稿/完整清单确认、正式preview/apply/undo与source-release，再完成真实HTTP/普通页面和main能力发布。后台保护服务、全部读者及真实任务hold已验证，继续候选/零删除预览的实际页面，见[清理分册](backup-retention-controlled-cleanup.md)。Windows原生等本人解锁，部署工具保持Prepare阶段；最终新包和常驻服务按交付分册推进。以下P4完整高级前置仍保留。

原约定在开发与验收闭合后，按[交付分册](delivery-local-test.md)生成普通Windows/Web/APK并部署独立本机持久测试服务。当前已由 Alpha 优先和 Linux 生产授权替代本轮执行顺序；三产物来源、固定Web/API/后台入口、启动维护与持久化/恢复证据仍须如实交付。

1. 继续B授权实际回款历史与追踪列表查询；来源read/纯预览/单笔确认已纳入764完整回归，四处审阅缺口红绿证据保留。随后接C完整草稿和同币单源页面，再多源/FX。pure preview不是写凭证，确认仍fresh read/事务复核；旧raw/hash/冻结字节保持。
2. B读取通过后接C退款报销主路径；D严格来源规则及typed修订/原子重构按正式契约推进，旧增额测试精确期望迁到实际typed验证，补回款换来源/类型双源修订，cap未闭合不advertise。P3/P4固定产物及18080旧基线保留，升级仍需可恢复备份与验证。
3. 全团队Flutter pub/build/test串行，测试/构建时短冻结共享生产源。新0006只验专用assets库，不迁移/重置开发库或历史测试库；P4候选独立wheel验收前不替换18080的377包。
4. 手机已完成合成数据的系统picker/取消/超限与同APK OS恢复专项，普通main已恢复并冷启；完整资金/统计预算/回款等跨功能旅程仍待最终。后续Flutter继续串行。浏览器单独启动隔离Chrome，不使用用户Edge或个人浏览器会话。
5. 原应用V01–V10在各领域接收时保留证据边界；Linux部署恢复待有环境后实测。c974即时退出专项已修并通过，完整P6无障碍/离线/更新旅程仍待其阶段；提交、推送与生产部署尚未执行。

2026-10-21 用户已授权按计划开发。接续实施以本文件顶部状态和开发记录为准，规划阶段的“不创建工程”限制已结束；生产发布仍按具体授权执行。

## 计划变更

| 日期 | 变更 | 依据 |
|---|---|---|
| 2026-10-24 | 默认内置正式HTTPS服务器，重建Windows/APK为0.1.1+2，保留旧资料/手动地址；本地交付不替换生产Web/后端 | 用户“以后应用内置服务器就是home.ruibin-ningh.top的，重建windows和apk”；[本包记录](../../logs/2026-10-24_native-client-rebuild.md) |
| 2026-10-24 | 完成实际钱迹导出105条/3退款、分型分类、具体错误和脱敏日志，并在分项测试/真实Linux与浏览器验证后更新生产 | 用户明确修复及生产更新授权；[本包记录](../../logs/2026-10-24_qianji-export-import-fix.md)，保持额度受控单包及安卓取消边界 |
| 2026-10-21 | 确认多用户、Android → Web → Windows、Linux 原生部署并加入后台面板 | 用户本次与前轮确认 |
| 2026-10-21 | 由三个子代理实际撰写分册，规划 9 阶段、34 个工作包 | 用户要求计划本身委派子代理并详细说明任务 |
| 2026-10-21 | 开始 P0，实际委派三位子代理并按依赖推进开发 | 用户明确要求开始开发、委派执行、及时更新进度与日志 |
| 2026-10-21 | 剩余手机验收统一放最后，浏览器改为单独启动Chrome测试实例 | 用户暂时断开手机并要求不再使用其Edge |
| 2026-10-24 | 改为额度受控 Alpha，复用已验普通产物，最多2个子代理、针对性验证、复杂故障两轮上限，暂停非必需功能 | Alpha 用户要求；M0/M1 历史接收记录 |
| 2026-10-24 | 明确授权读取 `root@192.168.0.145` 的 wiki 并生产部署至 `home.ruibin-ningh.top`；取消本轮安卓测试，直接最终 Alpha 交付 | 用户最新生产授权；[当前任务记录](../../logs/2026-10-24_production-deployment.md)；不代表完整功能全部完成 |
