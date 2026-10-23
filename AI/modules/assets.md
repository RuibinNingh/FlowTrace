# 个人资产与估值

职责：读取本机私人账户精确余额、计算资产估值、维护账户元数据与已确认私人分组；正式账户写入复用账务服务。
入口：`apps/flowtrace/lib/domain/assets/`、`lib/data/assets/`、`lib/features/assets/`；币种页面为`lib/features/currencies/currencies_page.dart`。
不变量：金额使用BigInt/Money；隐藏不等于排除净资产；配置请求按身份冻结且迟到回执不回退缓存，估值不改余额或历史汇率。
必跑测试：Flutter工程内 `flutter --no-version-check test --no-pub test/assets`、`dart analyze lib/domain/assets lib/data/assets lib/features/assets lib/features/currencies test/assets`；共享账务变更另核对账务/领域目标。
相关材料：[资产契约](../../contracts/assets-v1.md)、[本地账务](ledger-data.md)、[金额时间](../../contracts/money-time.md)、[账务规则](../../contracts/ledger-rules.md)、[P4任务](../plans/flowtrace/tasks.md#p4-01-资产信用卡债务与多币种)、[工作区能力与缺口](workspace.md)。

## 当前实现

2026-10-23资产总览/账户明细/信用卡账期/趋势消费同一持久本机金额隐私与精确千分位；隐藏时数值曲线卸载而非保留tooltip，眼睛切换跨controller重开仍生效。AccountEditor保留精确raw输入，本次显示在全局隐私重新开启时撤回。Entry/Assets22目标及后补展示组34目标通过（含期初9007199254740993保存），不改账户历史或估值规则；真实普通Windows/Web全旅程另待执行。

`AssetPosition`只接收调用方已授权的账户ID、可用或缺失的Money余额、计入净资产和隐藏标记。纯计算器不授予访问权限，不从原始公开账单猜私人资金链接，不创建网络连接。

`valueAssetPositions(positions, currency, asOfDate, rates, valuationPolicy)`按最终本位币精度计算正资产、负债绝对额、净额，以及借入/借出子集；借入/借出不重复叠加到净资产。`AssetValuationRate`含直接币对、普通十进制汇率、实际生效日和来源。默认`exact_date`只采估值当日报价；显式`latest_on_or_before`才用当日或之前最新报价，并保留实际报价日供界面标示。不反向或跨币种三角推算；零余额无需汇率。重复最新报价、无可用汇率、未知余额、非法币种精度或溢出时返回有限错误码，全部总额为空，也不提供可被误当总览的部分换算集合。原币Money保持原值。

隐藏账户仍参与总额；只有明确的includeInNetAssets=false排除。`AssetRepository`以同一`readSnapshot`读取LedgerView和配置，只取自己user scope的账户；不把共享账户混入私人总览。当前余额使用已有生产账务投影，不从公开账单反推账户关联，不改余额列。偏好与汇率缓存修订不一致时不拼出外币合计。该计算器处理当前余额估值，不能当作资产趋势或信用卡应还账单；授权账户明细/历史与账期通过独立生产读取服务实现，见下文。

AssetsPage已接净资产/资产/负债/借入/借出、金额隐藏、隐藏和归档账户筛选，以及分组/币种配置入口；隐藏与归档仍按账户include开关参与总额。`AccountEditor`包含七种账户、新账户期初日期、银行/服务商、卡后四位、图标/备注/排序/分组、独立信用额度和可部分填写的出账/还款规则。新账户切换币种时清空金额，编辑保留期初定义；余额变动通过明确调账，账户不直接改当前余额。银行11/服务商39来自共享静态fixture并有精确对照测试，币种165及精度由共享core目录提供。新页面10个widget目标分批通过，独立Chrome已完成实际开户/资金/估值与授权读取旅程；c974候选的即时退出表单/公开Tab输入与重开退出已通过；仍不能据此宣称P4及全部平台交付。

## 私人配置与请求保存

`AssetConfigStore.requireConfirmedGroup(space, groupId)`供LedgerRepository在整体写事务中核对组：必须是同instance/user/epoch/client的active状态、完整REST确认列表包含的组，而且没有本机待处理删除请求。删除分组在入队与执行前均检查当前账户和旧未发送账户意图，避免仍被引用的组消失。

组/币种偏好/汇率使用独立缓存section和服务端统一用户配置revision。缓存前缀`assets.config.v1.${space.id}.`，冻结请求前缀`assets.outbox.v1.${space.id}.`，其后包含epoch/client；不创建第七种同步实体。响应按闭合模型校验，低于任何已知配置revision的迟到回复不覆盖缓存。

`AssetConfigRepository`先核对中央权限/恢复状态，再以原始bodyJson请求；网络发送前持久化operation_id/path/method/base_revision和完整信封。超时重开仍以原字节重试，409保留冲突、禁止自动重基；只有明确放弃才可另建意图，旧冻结正文仍保留。epoch变化经现有SyncStore先备份并进入recovery_required；两个前缀所有旧epoch记录纳入备份的`asset_configuration`，不会自动转到新epoch重放。配置列表默认只展示本机已确认快照，联网刷新是明确操作。

## 证据边界

S37–S41/S53已定位到保留的原研究截图/XML：资产总览含净资产/资产/负债/借入/借出，类型含资金/信用卡/充值/投资/债务，银行选择支持搜索，信用卡表单含负数欠款、额度、出账/还款日及计入总资产，操作菜单含分组及已隐藏账户。它们只证明观察到的界面；真实开户后明细、账期结算、免息及债务核销仍不能由截图反推。生产规则以FlowTrace契约标注的设计默认实施。

2026-10-21实际执行`flutter.bat --no-version-check test --no-pub test/assets/asset_totals_test.dart -r expanded`，12/12通过（4.80秒）；覆盖隐藏/排除、原币不改、负值精确舍入、缺余额/汇率、未来/逆向报价、重复日期、超过2^53与64位边界、默认精确日期/显式较早报价、零外币、借入借出，以及8个共享黄金场景57个固定资产状态。`dart.bat analyze lib/domain/assets test/assets`无问题。该目标不等同于P4全流程验收；客户端没有运行ADB或个人Edge。

其后执行`flutter.bat --no-version-check test --no-pub test/assets/asset_config_test.dart test/assets/asset_totals_test.dart -r expanded`，最终25/25通过（配置13+合计12）；首跑24通过/1失败是测试将现有恢复状态误写为resync_required，按生产既有recovery_required与实际合并备份key修正后重跑。验证含冻结重开同字节、旧回执不回退、冲突输入保留、删除/引用互斥、迟到身份拒写、epoch先完整备份、独立section同一版本序列及静态目录对照。该轮owned生产目录`dart analyze lib/domain/assets lib/data/assets lib/features/assets lib/features/currencies`无问题；当时尚未开展的真实页面主路径现已有下文Chrome结果。

再执行`flutter.bat --no-version-check test --no-pub test/assets/asset_repository_test.dart test/assets/assets_page_test.dart -r expanded`，最终9/9通过（本机投影3+widget6）。两次8通过/1失败为新信用卡测试输入额度后的焦点自动滚动导致保存按钮未命中；取消输入焦点、滚至真实按钮后重跑通过，未绕过回调或删减账务断言。实际验证私有总览不含共享账户、隐藏/归档照常计入、偏好/汇率修订不一致不拼合计、旧账单reporting不充当估值报价；界面金额隐藏、新卡负期初与明确日期/独立额度、旧账户期初锁定；未登录保存分组/报价不关闭原表单，偏好草稿不复位，也不提示创建成功。实际Chrome与最终Android验收仍未由这组widget代替。

窄屏实际命令`flutter.bat --no-version-check test --no-pub test/assets/assets_page_test.dart --plain-name 'narrow large text' -r expanded`，最终2/2通过。首跑1通过/1失败证实账户图标下拉在390×844、1.8倍文字时横溢98px；加isExpanded和受约束的文本后，在相同尺寸/字号通过。币种菜单通过实际滚动选中COP，核对金额被清空，未绕过选择回调。当时owned目标分批为配置13+合计12+本机投影3+widget8共36项，并无声称这36已一次合并或P4完整通过。

2026-10-22实际执行`flutter.bat --no-version-check test --no-pub test/assets/assets_page_test.dart --plain-name 'overlay removes' -r expanded`，2/2通过。配置删除确认和资产资金动作选账本弹层与页面同样监听身份；`app.setServerAddress`通知后旧分组名/账本名/删除控件即时移除。其后账户常用币种改为常用优先、原币及其余支持币种仍保留；银行搜索和详情/趋势真实入口已落且窄分析无问题；增强widget其后已纳入完整客户端504通过/5默认live跳过，真实入口另有下文Chrome结果，未将旧结果自动算到新入口。

## 服务端实际基线

P4候选源码已提供assets/currencies闭合配置与授权读取，OpenAPI41路径/112schema/47操作；0006五个私人配置表，不增加同步实体种类、不回填旧不可变JSON。current与as_of分开，历史需期初日期证据，私人entries按授权裁剪账本正文；信用卡以明确日历/FIFO债批重建，不拿当前总欠款替代本期应还。

架构实际回执：Windows/Python3.12/PostgreSQL18.6专用资产库完整411/411（74.30秒）、随后RR授权竞态2/2与Ruff clean；独立非editable候选wheel140192bytes、96包资源，SHA256`473a0a4289e6635f8e9047dba24910ea8131109fd87f21551a1ff2c5d2345e1c`。`tests/e2e/assets/server_smoke.py`在18085真实HTTP36检查通过，含配置回放/引用组删除拒绝、原币10000/目标1250冻结0.125及估值8→9不改历史FX、明细/历史/信用卡与正常墓碑清理。回执`outputs/validation/P4/assets-wheel-http-receipt.json`确认专用线程停止、合成活跃会话0，18080仍377。客户端真实HTTP和P4Chrome在此回执时尚未执行；不能把服务端结果算作页面/Android/Linux通过。

后续真实Flutter客户端生产服务HTTP联测已1/1通过（约6秒），回执`outputs/validation/P4/assets-client-http-receipt.json`。首次清理在账单删除ACK与public/private墓碑均空正文时暴露本机余额不可用；主代理修复确认来源证明后，两条先失败回归及独立证明目标通过，再以原固定金额重跑联测。独立SQL核对统一配置revision11、唯一回执、四单私人分录与附件引用清零、账户余额恢复、合成会话0，候选线程随后停止。完整客户端500通过/5默认live跳过、完整分析无问题。此HTTP结果与后续真实Chrome结果分别记录，不当作Android验收。

2026-10-22独立headed Chrome155已实际执行24唯一阶段（sync按计划两次），使用全新合成账号/独立profile/18085+18185。03a1普通main完成真实登录与本机sync、新信用卡-80/独立额度500/招商银行、已确认分组/排序2/隐藏、金额隐私、信用卡还款50、借入100/借出75/收回25/偿还40，以及100CNY→12.50EUR/冻结0.125、独立手续费0.25。八项同步命令均applied且实际drawer0待处理；现金860/EUR12.50/手续费99.75逐行核对，估值8→9的净值719.75→732.25，负债690。账户明细1000→860/6分录、总欠150/本期应还0、缺opening_date历史不可用与重开持久化均在真实UI核对。

保留原偏好确认句和报价8刷新句ARIA失败：实际HTTP200/视觉正确，不重复配置写入；独立只读恢复核对固定金额。ae7964字体候选只读复验中文/最终金额/窄屏和消息ARIA通过；正常关闭重开后同profile实际升级且本机数据保留。退出204且视觉正确、重开保持退出，但即时新表单语义仍缺失，严格logout失败不改为通过。390×844正常字号通过；CDP请求1.8而html实际16px，未声称Web有效大字通过。详细命令、产物和失败分列见[浏览器记录](../../tests/e2e/client-web/P4_ASSETS.md)，最终Android/Linux与完整P6仍未执行。

即时退出修复候选随后完成整工程503通过/5默认live跳过（27秒）、完整分析无问题（3.3秒）。4897普通main已实际复验：fresh已退出表单的公开输入/Tab、真实登录一次与重开保持退出通过，但logout204后的即时表单语义仍缺失，严格logout再次失败。未以新增widget或构建替代该失败，也未重写已经确认的资金或配置；这是保留的4897失败历史；后续c974复验与正常清理结果如下。

随后稳定登录Card候选`build/web-p4-auth-card`完成整工程504通过/5默认live跳过、完整分析无问题；实际SHA256为`c974c847b3dceb1ef138ae2fcd536a9937c968dfe69e09efe3ed5859fbe26a61`。同一专用profile正常worker切换后，fresh表单公开输入/Tab、真实登录、logout204后的即时用户名/密码/登录ARIA与公开输入/Tab，以及重开保持退出均通过；最终语义结构35节点/2editor。主代理实际查看安全截图并接收，旧ae/4897失败完整保留；此次未重复金融或配置写入，不代表完整P6或全平台通过。

本Web run已按原固定wheel正常清理：六资金单、八账户、分类/账本共16个正常墓碑，逐账户期初恢复，entries/附件引用/活跃会话均0，空分组/报价及默认偏好已核对，18085受控进程退出0。另核验18185自有静态launcher/listener命令与父链后关闭，端口无监听、owned Chrome0，原profile/storage/journal保留；18080/18181/55432继续保留。回执为`outputs/validation/P4/web-assets-cleanup-receipt.json`和`web-assets-browser-close-receipt.json`。

## 服务器明细、历史与信用卡读取

`AssetReadRepository`位于`lib/data/assets/asset_read_repository.dart`，以同一捕获的SyncLease读取三个闭合模型：`AssetAccountEntries`、`AssetHistory`和`AssetCreditCalendar`。账户必须已在当前空间确认、属于查询scope；读前刷新权限，写缓存时在整体事务内重新核对instance/user/epoch/client、权限集合、scope和撤权nonce。金额、修订及曲线标签保留十进制字符串/BigInt，不经浮点。分录页严格核对请求的日期、offset/limit与精确应有条数；完整期间的期初、分录合计和期末也须相等。

`AssetAccountPage(app, space, accountId)`从账户列表进入，区分本机原币余额与服务器期间期初/期末，支持日期范围和分页。原账本失权的私人分录只展示金额、业务日与分录成分；模型拒绝同时带回原账本、账单、备注、分类、标签或附件，页面也不从私人金融影子重建正文。只有当前本机仍有同账本账单正文时才提供打开账单的入口。

`AssetHistoryPage(app, space, scopeId?)`提供逐日精确净资产、资产/负债和借入/借出。曲线只把有界坐标比例交给绘图，点选展示原始精确Money；缺证据日断开曲线并显示原因，不连成零。该历史是用当前有效账务重构业务日余额，更正旧账会重算，不表示当时系统已知的审计快照。

`CreditCalendarPage(app, space, accountId)`展示服务器已同步总欠款、溢缴、可用额度、超额及期初未归属账期欠款；各账期分别标明期间消费、出账时应还、服务器已同步剩余应还、出账/还款日及所配日历的免息日数。资料不足保持null与原因，不能拿当前总欠款替代本期应还。这些FIFO与日期结果来自服务端，尚无独立离线完整重算器。本机待同步记录不计入服务器快照，页面明确标注这一边界。

受控读取缓存前缀为`assets.read.v1.${space.id}.`，其后绑定epoch/client、scope和查询摘要；上限128个查询、合计4 MiB。仅在本地scope游标、配置revision、完整权限集合、epoch/client及nonce均与缓存一致，且无未确认账务/配置命令时，才作为“已确认缓存”显示；证据不足要求联网刷新。网络结果可以高于本机游标，但只标“服务器已确认”，不冒充本机当前余额。

任一scope撤权由[同步存储](client-sync.md)在同一事务删除本空间全部受控读缓存，并递增`assets.read.invalidate.v1.${space.id}`的BigInt字符串。请求发送前捕获nonce，接受响应时再次比较，先撤权再授权也不能让旧响应写回。恢复先将缓存纳入完整备份的`asset_read_cache`；重建的新epoch/client不自动读取旧绑定。`AssetReadView`持续监听数据库与会话；切空间、撤权或证据改变先清旧内容。监听流错误或结束时同样清空、使迟到请求失效并禁用刷新，要求重新打开页面。

2026-10-22最终实际运行`flutter.bat --no-version-check test --no-pub test/assets/asset_read_repository_test.dart test/assets/asset_read_page_test.dart -r expanded`，**15/15通过**（数据10、页面5，测试约4秒）；上述新读层、三页、共用View及测试窄分析无问题。覆盖闭合/脱敏/身份拒绝、确切分页、scope/config回退、先撤后授权nonce、pending禁用离线缓存、真实恢复备份、超过2^53曲线和空缺；页面覆盖仅数据库撤权无App通知清备注、390×844/1.8倍文字的趋势与卡片、切空间隐藏、迟到GET拒绝，以及真实关闭Native SQLite后监听结束清掉已渲染曲线/金额。真实关闭验证了onDone分支，未声称单独注入onError也已实测。

保留首轮失败回执：固定UTC确认时间位于真实时钟约8小时以后，生产未来缓存检查正确拒绝；fixture改为真实确认时钟，业务日期仍固定。其后FakeAsync测试的销毁计时器及一次runAsync内连续撤权/重授权阻塞，通过测试体内finally卸载、分开真实事务并有界泵送数据库事件修正；未吞布局异常、放宽权限或移除未来时间校验。首轮、定位及最终日志分别保存在忽略的`outputs/validation/P4/client-asset-read-page-*.log`，最终为`client-asset-read-15-final.log`和`client-asset-read-final-analyze.log`。

另有`asset_account_review_test.dart`独立审阅6/6通过：账本撤权后本人分录仍锁定账户期初定义、JPY零位到KWD三位单次HALF_UP与冻结汇率、转入/独立手续费账户的归档和启用日期、hidden金融元数据，以及同epoch或更换epoch后新client恢复不得自动重放旧配置命令。该6项与最终15项分别有回执，不替代主代理合并全客户端测试、真实HTTP或P4浏览器主路径。剩余Android与Linux验证仍按[工作区说明](workspace.md)保留。
