# Flutter 客户端

> **速查**
> - 职责：维护 Android/Web/Windows 共用工程、账号与设备会话、安全传输、资料空间切换、草稿和主题；同步算法由独立模块维护。
> - 入口：`apps/flowtrace/lib/main.dart`、`lib/app/`、`lib/features/identity/`、`lib/core/network/`、`lib/core/security/`；本地库为`lib/data/local/`。
> - 不变量：不同服务器实例/用户的库记录与outbox隔离；业务投影和待传命令同事务；金额/修订不经浮点；本地草稿不伪报正式入账或服务端同步。
> - 必跑测试：工程内 `flutter analyze --no-pub`、`flutter test --no-pub`；变更平台层时补对应原生/浏览器验证，命令及本轮真实状态见下文。
> - 相关：[计划恢复](../plans/flowtrace/progress.md)、[平台预研](../plans/flowtrace/platform-validation.md)、[客户端同步](client-sync.md)、[UI映射](../../contracts/ui-map.md)、[测试分层](../../tests/README.md)。

## 当前行为

2026-10-24随后按用户“生产部署啊”完成实际上线：生产Web已新构建0.1.1+2，普通main/正式profile并seal完整41文件；前包Windows/APK原字节复用，发布为正式域名HTTPS下载，两个包实取hash相符。Web和原生现都内置正式地址，已存手动设置/资料保持；后台1447709不改。生产IAB实际渲染未登录空草稿主页，未登录或写金融数据；具体发布、首次权限故障回退及修复证据见[部署记录](../logs/2026-10-24_client-production-deployment.md)。以下原生重建包“不更新生产”仅是当时边界。

2026-10-24新原生交付`0.1.1+2`来源`158ebc2`：无已存地址时内置`https://home.ruibin-ningh.top:18473`，不覆盖手动`active_server`或迁移旧资料空间。Windows production Release与Android ARM64 Debug均由普通main重建，214项输入构建前后不变；41项定向测试、两文件范围分析、Windows隔离schema5真实启动和APK版本/签名/内置地址核验通过。APK沿用`.dev`包名和原Debug证书，versionCode升至2；Windows未签名，没有Android设备/完整桌面UI验收。本包不更新生产Web/后端，以下“未重建”是前包快照，最新以[本包记录](../logs/2026-10-24_native-client-rebuild.md)为准。

2026-10-24当前生产Web已更新钱迹完整导入入口、文件交接及错误原因/行字段/请求ID；后端opt-in字段兼容旧Windows/APK。1015项通过/8专用live默认跳过，变更范围9项静态分析无问题；一个未接收的回款历史测试编译错误排除在本次集成之外，详情集中见[工作区缺口](workspace.md#当前缺口)。同版Web真实浏览器以合成105条完成文件选择→完整预览/确认→同步→重开105条且0待传。Windows/APK未重建，安卓测试取消；原文件Linux隔离验证与生产状态见[任务记录](../logs/2026-10-24_qianji-export-import-fix.md)。以下M1/schema快照不是当前Web版本。

2026-10-24 M1冻结[Alpha候选](../plans/flowtrace/alpha-candidates.md)：Windows/Web复用相同业务来源的旧schema3普通包，Android为较早schema3普通debug APK，不新编三端，也不声称三端功能完全一致。APK实际0.1.0+1/com.flowtrace.flowtrace.dev、ARM64/min24/target36，Android Debug签名及v2验证通过，与保留普通包/历史安装/stamp同hash，当前未ADB。下面schema5/1009等为各自源码快照证据，不能自动归给这些候选；新后端组合联调留M2。

2026-10-23大文件真实TCP新增1/1（19秒）：生产AppController/StageStore/Commands、SQLite、Identity/附件上传与普通main/Worker，204条/101支出、614400B两片与两publication chunk，分片和apply成功回复各丢一次后两次离线磁盘重开，同正文/同批找回并fresh group一次安装。支出12625、余额9007199254728368及77B图hash准确，预览无金融写/no push/原outbox草稿保持；退出后PG active session0，owned API-worker已关闭。此目标仅把Windows目录通道指向fixture沙箱，非原生runner目录lease/secure vault/普通UI/容量性能验收；同批续接清源undo和Chrome另验。回执`outputs/validation/P5/stage-http/c4624915cf5c4d3ea0b729498cb6ccfe/`。

当前schema5完整客户端**1009通过/6专用live默认跳过（59秒）**，完整静态分析No issues（8.1秒）；日志`client-full-schema5-stage1.log`与`client-analyze-schema5-stage1.log`。普通大文件页接完整资源草稿、图片校验/真实上传、作业摘要、明确preview/apply/undo/续接及源释放。相关122/122（10秒）包含五条页面旅程与实际SQLite删除回滚；Dart图片映射另经Python生产planner反核4/4。这些不代替真实TCP/Chrome金融旅程。schema5原件/恢复29、能力44、相位42、续接39是此前分次快照，下面908属于schema4历史；当前新普通Web构建中，尚非最终交付。存储边界见[客户端同步](client-sync.md)，页面见[专项](../../tests/e2e/client-web/STAGE-IMPORT.md)。

2026-10-23schema4新增跨页group独立暂存三表，协调器与普通SyncEngine按真实能力接入，data/sync/identity223/223及窄分析通过；真实HTTP丢页/离线SQLite重开、owner/viewer各201账单原子安装专项1/1通过。该快照完整908通过/6专用live默认跳过，分析clean；旧完整871/5默认skip与Web/Windows候选更早，schema5新完整回归待后续。详见[客户端同步](client-sync.md)与[实施分册](../plans/flowtrace/group-sync-implementation.md)。

2026-10-23普通设置菜单已接[数据迁移页](data-tools.md)，跨设备undo、迟到ACK单向CAS、仅pull撤权清缓存、完整恢复备份与秒开记账已合入。冻结普通入口完整871通过/5专用live默认跳过（66秒），全分析无问题13.4秒。普通Web6f72构建75.3秒并封装39资源，167源文件构建前后摘要一致；正常迁移/原图/导出/undo/离线与跨设备撤销刷新已有真实Chrome分项，最终汇总与其余旅程继续。普通Windows本机测试候选0.1.0+1构建75.3秒、新目录已启动，原生UI因Windows锁屏暂停等待本人解锁。均未当最终产物。

显式本机测试profile`FLOWTRACE_LOCAL_TEST=true`允许回环/私有局域网HTTP，设置页标明测试构建，公网HTTP仍拒绝；未传标志的原生Release保持HTTPS要求。Android系统网络策略单独生效，不由Dart标志修改。最终交付记录实际profile、变体及签名，见[交付分册](../plans/flowtrace/delivery-local-test.md)。

Web壳后补可收起提示，普通新a3d9构建56.2秒/完整39资源，Dart main SHA与6f72相同。地址保存→账号字段/Tab的即时和延时新profile分项通过，最后全关Chrome后的offline冷启同release完整39；账号widget整文件5/5通过。原迁移profile的ARIA失败仍保留且未找到稳定重现，不宣称已修；深profile的CacheStorage失败与短路径成功证据见[专项记录](../../tests/e2e/client-web/ACCOUNT-ADDRESS.md)。此新Web分项不扩大为普通Windows/完整P6验收。

此前共享设置/保护根接线806/5skip、迟到锁/设置保存7与偏好CAS25为历史分项，均已由上述871快照覆盖；完整真实保护旅程仍待验，见[偏好与保护](preferences.md)。`authorizedDownload`支持GET或POST筛选JSON，在授权/刷新之前冻结正文，身份/epoch/client租约及响应大小仍复核。

2026-10-22非安卓P5–P7新增：[Web更新保护](web.md)接入普通根应用/完整记账与未登录文本草稿，SQLite执行器闸门覆盖直接/批次/原始事务写者，schema仍3；只读快照仍可读、不可夹带写。Windows正式SQLite/附件改用原生已持租约的数据根，不回退无锁打开；真实两版本QA与边界见[Windows模块](windows.md)，不是普通main完整桌面验收。正式依赖新增纯Dart cryptography2.9.0供后续本机保护，pub get仅变更这一项；保护页面尚在实施。

已建立 Flutter Android/Web/Windows 工程，名称“流迹 FlowTrace”，SDK 为 Flutter3.38.3 / Dart3.10.1。当前提供本地草稿、服务器地址与资料空间切换、深浅/系统主题、健康连接检查、邀请码注册/登录、账号与设备会话。`/sync`接入主动同步与恢复页面，算法与验收见[客户端同步](client-sync.md)。P3 已接入真实本地账本、资金账户、收入/支出/转账和统计/日历/预算界面，P4已接账户/信用卡/债务/币种及资金动作，本地核心、独立读取和主要Web业务已分项通过，c974候选即时退出表单已在真实Chrome复验通过；细节和各自验收边界见[记账界面](entry.md)、[管理页面](management.md)及[报表模块](reporting.md)；本地保存和草稿不伪报服务端入账，钱迹全部页面及三端完整体验仍按后续工作包推进。

Android 正式applicationId为 `com.flowtrace.flowtrace`，本地debug使用 **`com.flowtrace.flowtrace.dev`**，独立于现有钱迹 `com.mutangtech.qianji`。仅debug允许HTTP以便本机/局域网隔离测试，正式构建默认HTTPS；不把调试签名当正式签名。NDK固定为当前已装28.2.13676358，`android.builder.sdkDownload=false`防止构建擅自安装SDK组件；许可证不自动接受。

## 本地数据库与边界

Native使用Drift/SQLite后台isolate，路径为应用application support下的 `flowtrace/flowtrace.sqlite`，不写安装目录。当前schema5含原有账务/同步/草稿/快照及三张group受控暂存表，另有大文件source/chunk/command与独立恢复chunk四表。schema1是隔离“仅设置”前驱，schema2是P1实体/outbox版本，schema3/4为此前同步/group基线；升级保留旧记录，不是钱迹数据库迁移。结构和生成权威见同步模块。

资料空间键为规范服务器地址、服务器实例标识、用户标识的稳定摘要。未登录时使用显式 provisional 空间，只允许本地草稿；确认服务器实例前不能创建正式同步队列。切服务器不把原空间的草稿/队列搬到新地址。地址禁止内嵌账号密码、query、fragment和公网明文HTTP；支持HTTPS及本机/局域网HTTP开发地址。

`LocalRepository.saveEntityAndQueue`在同SQLite事务写意图与outbox，失败完整回滚；`depends_on`为UUID或null，金额/修订不经浮点。P1的同实体未确认前拒绝连续编辑限制已由P2解除；当前通过前序串行、确认影子、冻结首发正文及显式冲突/恢复处理保全用户输入，细节集中在同步模块，不在本文复制第二套规则。

`AppDatabase.readSnapshot`在已有事务中复用一致快照，外部调用才新开读事务；`atomicWrite`持有一次完整业务写入，内部写辅助方法加入同一事务。任何内部写失败都会标记整笔事务必须回滚，即使调用者捕获了该异常；结束后的异步写入及未受管原始事务中的隐式加入均被拒绝。原始Drift `transaction`语义未覆盖，schema仍为3。该边界用于账务、同步、附件元数据、资料空间切换和诊断SQLite写入，Web附件字节的IndexedDB事务不受此API替换。

修复前在Chrome155/OPFS独立数据库最小嵌套事务中，内层写入完成而外层提交持续等待，预算保存与导出预览同样复现。修复后公开事务上下文版本独立Web probe4项及关闭重开4项通过，涵盖预算、并发观察、整批失败回滚和显式冲突重基；Native事务边界9项与冲突页6项合并15项通过，含原始requireNew嵌套失败仍保留外层写入。事务修复当时完整客户端381通过/3项live默认跳过，P3最终含移动界面完整411通过/4默认live跳过，完整分析无问题；P4新代码另验。普通main已真实验证预算创建/编辑/沿用、日历补记、重开报告和真实ZIP下载；事务专项与页面证据分别见[事务诊断](../../tests/e2e/client-web/TRANSACTIONS.md)和下文。

## 账号、安全存储与请求边界

原生使用锁定的flutter_secure_storage10.3.4，Android为系统KeyStore保护的RSA OAEP/AES-GCM存储，namespace为flowtrace.identity.v1，resetOnError=false；应用关闭系统自动备份，避免凭据与KeyStore错配。Windows实现已锁4.2.2，原生Windows安全存储仍待实际平台验收。安全存储失败会提示并停止保留登录，不降级到普通数据库。[维护者版本说明](https://pub.dev/packages/flutter_secure_storage/versions/10.3.4/changelog)。

access token只保留在内存；原生refresh以服务器地址/instance/user的DataSpace摘要分区存入系统安全库。普通SQLite仅保存client UUID与非凭据的当前账号元数据，不保存密码、access或refresh。Web不调用安全库保存令牌，使用服务端HttpOnly刷新Cookie、同源可读CSRF Cookie及内存access；写请求带CSRF，刷新使用Web Locks按服务器串行，避免本页并发和同源标签抢用同一旧Cookie。浏览器部署优先同站点API；不通过localStorage绕过跨站Cookie限制。

恢复登录前先确认server-info的instance；实例变化不向新部署发送旧refresh，原空间不被覆盖。网络未能确认身份时可保留已识别账号的离线空间，UI明确会话待验证；收到失效/撤销则清空内存授权并退出该可见账号。刷新回包丢失时不自动重用旧refresh；清除持久凭据失败时保持未登录并提供显式重试。离线退出只确认本机退出，服务器撤销未确认会明确提示，不宣称回收离线副本。

`sessionGeneration`在登录、退出、服务器切换时改变。`authorizedRequest`/`authorizedDownload`在发送前、刷新后和响应应用前核对generation及expectedSpaceId/expectedEpoch/expectedClientId；旧请求不能借新账号token发送。`bodyJson`原样UTF8发送，二进制`bodyBytes`入口复制冻结，三种正文互斥，401单飞刷新重试保持原正文。JSON响应上限1MiB、下载默认10MiB，错误响应另限64KiB，禁止携带凭据跟随重定向。

授权请求可通过`onRequestMetadata`向诊断模块提供固定类别、HTTP方法、合法request_id、状态与有界耗时；`diagnosticOperationId`只接受规范UUID，并与该响应编号关联。传输层不从正文提取operation_id，元数据不包含路径/query、正文、令牌、Cookie或任意响应文本。每个回调捕获原资料空间及generation，身份切换后的迟到记录直接丢弃；诊断回调失败或异步写盘不会阻断业务。未登录的server-info/login和当前直接HTTP健康检查未自动归属账号，不能按当前UI空间猜测记录。

`AppController.canSync`还要求身份不busy、实际打开的space等于身份space、且未切换空间。`rotateClientForRecovery`仅供用户明确确认后的恢复UI调用：保留业务数据与备份，撤销/清理旧凭据、换client UUID、要求重新登录；不会自动重放旧操作。

Web使用Drift WASM及明确的native/web条件导入，拒绝inMemory与unsafeIndexedDb模式，不用localStorage存交易。`web/sqlite3.wasm`和 `drift_worker.js` 来自锁定发布，来源、字节数/摘要见 `web/storage-assets.json`；WASM摘要与sqlite3发布包内哈希核对一致。应用壳离线缓存、跨版本更新、配额/多标签/清理恢复仍须P6完整验证；Web构建成功不等于完成离线PWA。

## 依赖与生成

`pubspec.lock`跟踪精确版本和传递依赖，直接依赖固定版本。首次尝试sqlite3 3.7.1时，传递record_use需要meta^1.19而Flutter固定1.17，pub解算失败；未使用override或升级SDK，已回到兼容组合：drift2.34.4、sqlite3 3.5.2、drift_dev2.34.0、build_runner2.15.0。timezone0.11.2由领域包用于真实IANA样本，数据随包提供。

Android的path_provider_android固定2.2.21，避免后续JNI版本要求未安装的android35。sqlite3首轮Android原生库下载超时，限制为授权真机arm64 ABI后重试成功；不是SDK许可错误。未更改包源码或SDK，也没有接受新许可证。

P3 选图接口新增直接依赖 `file_selector:1.1.0`，pub 解算成功并锁定兼容当前 SDK 的 Android0.5.2+6、Web0.9.5、Windows0.9.3+6 和 cross_file0.3.5+5；未升级 SDK 或覆盖包源码。版本选择依据[主包说明](https://pub.dev/packages/file_selector/changelog)、[Android版本要求](https://pub.dev/packages/file_selector_android/changelog)、[Web要求](https://pub.dev/packages/file_selector_web/changelog)及[Windows要求](https://pub.dev/packages/file_selector_windows/changelog)。包含新插件的 P3 原生集成包已成功编译和安装（首轮 Gradle61.9秒），确认当前 Gradle/Kotlin 组合可构建；系统选图主路径仍须独立实测，不以编译成功替代。

批量图片ZIP导出新增直接依赖`archive:4.0.7`，包要求Dart>=3.0<4.0，与当前3.10.1兼容。pub get成功，仅新增archive4.0.7及posix6.5.2，既有依赖版本未改。生产端使用可跨Web/native的`archive.dart`编码入口；[维护者说明](https://pub.dev/packages/archive/versions/4.0.7)与本机缓存pubspec已核对。该结果仅证明依赖可解算，ZIP内容、大小限制及各平台保存行为按导出模块另验。

当前Dart3.10的build_runner默认AOT因build hooks失败；用该包支持的JIT入口成功生成：

```powershell
flutter --no-version-check pub get
dart run build_runner build --force-jit
flutter --no-version-check analyze --no-pub
flutter --no-version-check test --no-pub
```

`lib/data/local/app_database.g.dart`是生成源码；不要手写修改。修改schema先更新声明和迁移、重新生成，再跑旧库/事务/重开测试。不要格式化或覆盖其他并行任务持有的money/domain目录。

## 本轮验证与恢复位置

P1已实测创建三平台工程、锁依赖、JIT生成；当时全套95/95通过（基础9项与领域86项），静态分析无问题。基础覆盖事务回滚、冻结请求、超过2^53的字符串、空间隔离、SQLite重开及v1→v2迁移；领域详情见[领域模块](ledger.md)。P2后新增的同步/附件测试计数由各模块和主任务最终合并回执维护，不把95当当前总数。

Android命令`flutter --no-version-check build apk --debug --no-pub --target-platform android-arm64`成功，ADB安装`com.flowtrace.flowtrace.dev`成功，`am start -W`冷启动Status ok，复查约3.4秒。设备追踪名`android-plt140-dev1`，PLT140/Android16/API36/arm64-v8a；自身PID错误筛选为空。未运行全局logcat清理或应用数据清除命令，未操作钱迹。集成测试只用于独立debug包，Flutter工具自身的测试安装生命周期不能当作保留用户应用数据的承诺。

真实设备集成 `flutter --no-version-check test integration_test/foundation_test.dart --no-pub`（实际指定上述授权设备）修复后**1/1通过**：从真实UI保存合成草稿，关闭数据库并以新连接重开，原记录仍在、outbox为空，再删除本轮新建草稿。首轮发现弹层pop完成早于退出动画，过早dispose文本控制器导致异常；已改为弹层自身State.dispose释放并重测。集成测试APK不是交付应用，验收后重新构建/安装常规main入口。

Web命令 `flutter --no-version-check build web --no-pub --pwa-strategy=none --no-web-resources-cdn`成功，资源随本地产物提供。真实Edge在127.0.0.1:18181、COOP/COEP隔离头下完成保存→刷新保留→切服务器空空间→切回保留；只使用合成草稿，验收后清理。`web/storage-assets.json`提供发布来源与摘要。该结果不证明P6离线壳、多标签/配额、安装或完整业务通过。

P2身份/传输与安全HTTP元数据单测34/34通过，覆盖单飞刷新、失效与回包丢失、vault读写删除失败、换服务器/同账号重登录期间的晚到请求、恢复换client保留草稿、原始JSON/二进制冻结重试、下载超限、诊断迟到丢弃与失败不阻断。元数据首轮测试发现响应头大小写导致关联ID缺失，已改为不区分大小写只读取X-Request-ID并重测通过。所持身份/网络/UI/集成目录静态分析无问题。

本轮串行合并`flutter --no-version-check test --no-pub`为178项通过、3项live测试跳过；默认命令未提供这三项所需隔离QA参数，真实附件HTTP、同步HTTP与数据库恢复各自有专项回执，不能将默认跳过写成该次通过。完整回归日志位于`outputs/validation/P2/flutter-test.log`。

P2接收时完整`flutter --no-version-check analyze --no-pub`无问题。随后诊断页同State切资料空间时立即清旧列表的目标回归1项通过；Android`integration_test/attachment_storage_test.dart`1项通过，实际应用支持目录原件与隔离SQLite关闭重开后读回，撤权物理清缓存而保留未传原件，具体规则见[附件模块](attachments.md)。

真实Android `integration_test/identity_test.dart` 1/1通过：从UI兑换合成邀请、真实安全vault保留refresh，新controller/数据库连接重开后旋转凭据并保留同账号草稿，普通设置无refresh，退出后vault清除。测试输入仅来自忽略文件，未在日志/截图回显密码或邀请码。Web实际完成邀请注册→刷新恢复→退出→刷新仍退出→再次登录→撤销当前会话；控制台无error/warn。会话切换时旧Semantics节点残留仍须补验；账号列表虽已按session/status重建，不能据视觉截图宣称语义树已修复。

真实Android `integration_test/sync_test.dart` **1/1通过**：同账号两套独立原生SQLite缓存与HTTP会话创建本轮合成账本/标签；页面分别选择服务器版本和保留本机修改，冲突清空，HTTP核对最终字段和revision=4。再显式构造本地需重建状态，进入恢复备份列表和原记录详情，确认未传输入、备份与outbox保留；这是本地恢复核对，不是服务端还原演练。合成服务端对象通过独立peer正常墓碑清理，两会话退出。

首轮同步UI测试已完成两次真实冲突，但测试默认英文Back定位不适配中文而失败；改用实际“返回”tooltip后，本轮构建19.6秒、安装72.5秒、测试约15秒通过。中间一次因并行修改中的共享源码语法失败未运行设备用例；修复后串行重跑。Drift多实例提示来自两个独立memory executor，未共享文件，不关闭该诊断。后续同工程Flutter生成/测试/构建须串行，避免Windows native_assets争用。

P2接收时，已使用`--target lib/main.dart --target-platform android-arm64`且不带QA编译参数重新构建；扫描APK全部ZIP成员未发现两组合成QA用户名、密码和邀请码字面量。常规debug包更新安装成功、冷启动COLD/Status ok（3910ms），自身PID错误筛选为空。实际查看的未登录首页截图为`outputs/validation/P2/android-main.png`，APK为`flowtrace-p2-main-debug-arm64.apk`。P3测试后的当前安装状态见下节，不把该历史收尾状态当作当前设备事实。

截图和构建回执存于忽略的`outputs/validation/P1/`、`P2/`；长期任务证据由主代理日志保存。Windows仅完成工程和工具链检查及原生SQLite VM测试，尚未构建/运行桌面产物。Linux部署/恢复不属于这些客户端测试，仍待环境。完整应用保护、浏览器多标签账号切换、完整离线壳与跨端业务验收仍有后续工作包。

## P3 账务主路径与后续平台验收

管理模块隔离 SQLite/widget 8项通过，第二轮原生构建前完整客户端静态分析无问题。`integration_test/ledger_test.dart` 在授权 PLT140 设备 **1/1通过**（构建19.4秒、安装36.8秒、设备用例约64秒），使用独立应用支持目录的文件库、合成账号和第二套 HTTP 会话。真实页面创建账本/两级分类/标签/两个账户，HTTP 阻断下录入支出/收入/转账；重开文件库和控制器后保留实体与操作 ID，再连接真实服务并由独立 peer 核对三笔账单、定义、标记及精确余额。

固定核对值：现金期初100000minor，实付支出30minor、优惠10minor/原价40minor；银行卡收入10000minor；现金转入银行卡5000minor、现金手续费100minor，只扣一次。最终现金94870minor、银行卡35000minor，首页支出130minor。支出单独设置“不计预算=true、不计统计=false”，第二会话仍一致。合成服务端对象通过普通墓碑清理，两会话退出；不使用用户账本或钱迹。

首轮构建安装成功（61.9秒/5.7秒），54秒设备用例停在收入分类定位，未执行新对象 push。测试 helper 对已可点控件仍调用 ensureVisible，触发 TabBarView 横向滚动；改为 hitTestable 优先并等待编辑器退出后重跑通过。保留两独立 executor 的 Drift 调试提示，不关闭诊断。

受控 HTTP 阻断不等于设备飞行模式，文件库和控制器重开不等于 OS 杀进程；系统图片选择器与 OS 终止恢复仍待专项。设备内 binding 截图成功生成，但本地 SDK 的 integration_test_device 在结束时卸载测试包，默认结果通道也未导出 reportData，PNG 随私有目录删除；尚无主路径图片，不把 P2 历史截图替代。该次集成结束dev包卸载，随后手机暂断；2026-10-22用户确认重连后已恢复ADB并安装独立合成fixture，选图/OS终止恢复正在执行，普通main恢复和完整旅程仍待最终步骤。日志与脱敏 JSON 回执在 `outputs/validation/P3/`。

统计/日历/预算新增 widget 6项与首页1项合并 **7/7通过**，两个测试文件目标静态分析无问题。真实隔离SQLite覆盖31号起始账期、统计/预算独立标记、超过2^53的预算新建/编辑/沿用、日历选日后实际补记、独立全屏图切空间与数据库撤权隐藏，以及390宽/1.8倍字体下柱线切换无布局异常。首轮图表布局异常已由界面实现修复后重测；测试fixture保留生产active同步状态要求，未放宽授权。浏览器后续使用独立Chrome测试实例，不再操作用户Edge；先前Edge结果仅是历史验收记录。

P3正常Web已通过独立Chrome的设置/登录/页面同步、精确报告/全屏折线、关键词搜索及日历选日。事务修复产物55.8秒，摘要`cabc652412d5d805591c947d12b53f6d0e76b11886fc01a5a01cff143bcfa8d2`；预算100.00→100.01、下期沿用100.01均通过。日历实际补记10月16日1.25后重开仍保留，报告收入100.00/支出14.75/结余85.25，预算使用25.00/剩余75.01；同步后重开首页0项待传/5笔本期流水，服务端独立scope核对也一致。

下载首轮因陈旧派生registrant未注册FileSelectorWeb失败，metadata/content均200，CDP定位到MethodChannel缺实现。保全旧产物后执行标准Flutter clean及offline pub get，锁文件SHA保持`90c726415a608d613b10bee8d92b16a3538be73821befaaf54766a988e4fbed9`，没有手改生成文件、SDK或保存实现。重新构建55.9秒，最终main.js摘要`a3a1c9eece0ffd8453592c219a1f4097958efda6afcbc42c9a98accb983b1c9a`，生成文件明确注册FileSelectorWeb，浏览器实际收到正文摘要核对一致。真实下载ZIP217字节，仅含序号名PNG77字节且原件SHA一致；新产物的重开报告/预算也复验通过。

UI退出实际204且视觉回到登录表单，关闭重开仍退出并有真实可用登录控件；同页退出后的Semantics漏掉可见表单控件仍按失败保留，未通过无障碍验收。合成账本已正常墓碑清理，专用Chrome全部关闭。具体脚本与回执见[Chrome页面验收](../../tests/e2e/client-web/README.md)，不标完整P6通过。

## P3 跨账本移动浏览器实测

移动入口接收时完整客户端411通过/4项live默认跳过，分析无问题；后续图片兼容修复selector/panel14项目标另列，不将其充作更新后的全量回归。普通main首轮41.6秒，在独立Chrome真实登录/页面同步、从搜索唯一选择账单、显式目标书/分类/标签、预览及准备原图、本机确认、再页面同步通过：源0/目标1、同UUID修订2、私人账户在确认前后及同步后均9875minor。目标时区不同，原业务日/Asia-Shanghai时区/微秒瞬时保留。

真实预览发现Flutter Web的encoded ImageDescriptor.width不支持；保持原fixture和已完成移动，未重复入账或换图。生产像素校验改用跨平台公共codec API，保留原始尺寸40MP、720解码宽、单帧/完整解码及PNG动画检查。修复后普通main46.1秒，main.js SHA256为`a55bfe7934a502b70a66b39fb8c1e83a729883a2811581bae80d2c0d00970ed0`，只重跑原账单verify全部通过，包括真实原图渲染。辅助HTTP核对目标clone新UUID、77原字节及SHA一致，源报表0/目标125、资金余额9875不变。

本轮仍严格保留即时退出Semantics失败；退出204/视觉与关闭重开退出分别通过。两个新测试账本和一个明确的私有账户已正常墓碑清理，专用Chrome关闭，无ADB/Edge。可复现脚本、历史失败与当前边界见[移动浏览器专项](../../tests/e2e/client-web/README.md#跨账本移动专项)；P6及剩余Android验收保留。

P4新模块入口为[资产](assets.md)与[币种](currencies.md)。私人REST配置/冻结队列及授权读缓存均复用schema3设置表并按space/epoch/client隔离，不把组扩为第七同步实体。恢复保留旧配置意图，scope撤权整空间清资产受控读缓存并递增nonce，迟到回包不得写回。账户/资金新目标、配置/估值及读层分项通过不代替整工程回归和真实浏览器；18181仍固定P3 a55bfe79产物，P4使用18185及独立构建目录，实际结果如下。

P4账户明细、资产趋势与信用卡账期读取已接独立授权读层；服务器快照与本机余额分别标明，离线只展示有完整版本证据的确认缓存。2026-10-22读数据10+页面5合并15/15通过，独立账户审阅6/6另列；监听流结束清屏、仅数据库撤权清备注、390宽/1.8倍字体及精确长金额已覆盖。具体实现、首轮fixture失败与限制集中在[资产读取](assets.md#服务器明细历史与信用卡读取)，本段不把这些目标计作新的全量/浏览器/真机结果。

2026-10-22资产P4-01本地候选完整客户端500通过、5项需显式配置的live默认跳过；完整analyze无问题。真实Flutter VM/文件SQLite与候选wheel资产联测1/1另行通过，正常删除余额缺陷已按[本地账务](ledger-data.md)修复。普通main独立`build/web-p4`构建45.2秒，main.js SHA256 `e14b234aad6a6deead2a8f2c21040cb41daab6b578a34b112fe045947b1eba81`；此首版公开输入失败及旧profile保留，后续候选结果如下。旧P3`build/web`及锁文件未变，无Android或Linux新结果。

Web语义树由FlowTraceApp根组件生命周期持有公共`ensureSemantics`句柄，在首帧起生成语义并于卸载释放；仅kIsWeb启用，原生不增加句柄。此修改针对真实Chrome中路由变化后可见输入框有光标、开放DOM却无任何编辑节点，公开keyboard.type/insertText均无文字的实际阻断；不修改身份请求、SDK或浏览器DOM。修改后完整客户端500通过/5默认live跳过、分析无问题；独立`build/web-p4-semantics`的公开输入与真实登录已通过，随后资产业务与同步通过。旧e14b失败产物保留，尚不声称完整P6或即时退出语义通过。

此候选40.4秒构建成功，main.js SHA256 `03a1c84dfb17657d87e0c14191f0634fac18cbe3e75596a9aa1e26a00f0036fe`。持续Web语义会增加DOM/语义计算，并使引擎启用accessibleNavigation；需在实际长列表、路由往返及含动作的SnackBar上核对，不声称无性能或动画影响。旧placeholder激活也有平台句柄，故这里只把首帧一致模式列作修复候选，不将未证实的框架内部原因写为定论。

为消除外部字体加载对首次中文显示的依赖，工程随包提供官方未修改Noto CJK SC与Roboto400/500，主题采用Noto回退，启动通过标准LicenseRegistry登记本地许可文本；来源、固定commit与摘要见[字体说明](../../apps/flowtrace/assets/fonts/README.md)。币种异步状态消息使用liveRegion。该轮完整500通过/5默认live跳过，最终Roboto/许可接入后资产及根壳目标73通过、完整分析无问题。普通main `build/web-p4-fonts`构建41.9秒，SHA `ae7964f21eddde4b5be7298cd5679ed43de2e317f3a364520f66b41e5bd3a7d1`。

真实Chrome沿同一专用profile正常worker更新到ae7964，阻远程字体域时本地Noto/Roboto均200，宽1280与窄390实看中文完整、最终净732.25；配置只读刷新确认文字进入ARIA。浏览器请求OS字体1.8但html仍16px，只认普通字号窄屏，另有widget实际1.8证据。ae当时即时退出真实204/视觉确认而表单ARIA缺失失败，新进程重开保持退出且表单恢复通过；该失败保留，后续修复结果如下，没有清storage、重开户或重复资金写入。回执与脚本见[资产Chrome专项](../../tests/e2e/client-web/P4_ASSETS.md)。

后续4897将确认框改为公开DialogRoute，等待完整overlay移除且页面mounted后再执行确认；Native验证时序正确，但实际即时表单仍失败，历史保留。安全DOM对照确认FORM仍可见但5子节点变0；慢cleanup测试进一步确证，busy结束移除前置进度条时，无key登录Card被替换、全局Form被迁移。现在登录Card使用稳定业务key，保持原Form/ListView key和根语义句柄；修后4项/identity38通过，最新完整客户端504通过/5默认live跳过、完整分析无问题。

该候选普通main `build/web-p4-auth-card`构建41.9秒、SHA `c974c847b3dceb1ef138ae2fcd536a9937c968dfe69e09efe3ed5859fbe26a61`。真实Chrome同profile正常worker激活后，公开表单输入/Tab、真实登录、退出204后即时用户名/密码/登录ARIA和再次公开输入/清空、关闭重开保持退出均通过。退出后35语义节点/2editor，真实Tab由text INPUT到password INPUT；root亲看公开probe图并核回执，金融/配置没有重写。该专项修复不代表完整P6无障碍、离线升级或全平台验收；P4-02后续新源不包含于这次504回归。

随后P4-02接入expense追踪的本地metadata合法性、presence保留与金融指纹排除，以及独立公开来源进度纯模型；无新UI/能力门控入口，不修改普通linkedsource增额规则或Reference。数据新29+原ledger114合并143通过，模型69通过，最终完整源码602通过/5默认live跳过（28秒）、完整分析无问题（4.9秒）。新模型正确处理旧显式null为未知、全退款不称已报销；在该602快照时权限/epoch/修订仍待接读取层证明；后续B结果见下段。当前固定Web仍c974前一504快照，602不代表已生成新的Web/Android产物。范围与后续切片见[退款报销模块](reimbursements.md)。

2026-10-22 B授权读取/完整ACK因果侧车及纯分配预览接入后，完整源码 **722通过/5需QA配置live默认跳过**（41秒），最终完整分析无问题（4秒）。包含ACK25、读取45、纯预览46及应用lease4新目标；分项不与全量累加。两条读取缺口经独立审阅先复现再修：未冻结后继操作不能用旧base缩小来源范围，数据库通知后禁止旧cut迟到发布。首分析只有新测试if缺大括号info，修格式后通过，测试语义未变。

`AppController.receiptReads`和`captureReceiptReadLease()`提供实际应用的offline读取桥：不发网络，绑定当前space/client、session/space generation及本地active epoch；在线身份已知新epoch则拒绝旧cut。身份变化、切服务器、dispose通知watch清空；离线最后确认身份不是当前服务器授权的替代，正式写入仍由服务器鉴权。纯预览绑定query/lease/read观察值，确认必须另在事务fresh read复核，不能当成写入凭证。普通Web仍c974，Android专用fixture正在真机验证，新回款UI尚未接入。

随后单笔确认适配42项接入`AppController.receiptCommands`，最终完整 **764通过/5默认live跳过（49秒）**、完整分析无问题（6.6秒）。`create`只保存一笔新到账，固定ID重复点击只能找回完全相同原create；fresh source/权限/预览金融一致性在本机同事务复核，失败回滚。commit返回窗口身份变更抑制迟到成功且保留已提交旧账，远端revision前进即使正文复原也不认旧create；两项先红后修并独立复核。业务范围与限制见[退款报销](reimbursements.md)。

Android本地专项已验证默认OEM系统picker选图/取消/10MiB+1拒绝，以及修复QA只读事务后第二attempt同APK无重装force-stop/COLD恢复，原数据库SHA完全不变；原第一次QA BEGIN IMMEDIATE失败保留。这不是新回款UI、服务端网络或完整P3/P4旅程。普通main已恢复并实际冷启，最终固定包/安装状态见[Android专项](../../tests/e2e/android/README.md)。
