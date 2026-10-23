# 精确报表投影

> - 职责：按当前账本权限读取一致快照，并对完整可见账单集进行精确期间、分类、日历与预算汇总。
> - 入口：`server/src/flowtrace_server/reports/`、`domain/reporting.py`；客户端`lib/domain/reporting/`、`data/ledger/ledger_reporting.dart`及`features/statistics/`、`calendar/`、`budgets/`。
> - 不变量：不授予权限、不查询汇率/时钟、不使用 double；缺少金额或归属证据不显示部分汇总冒充完整值。
> - 必跑测试：`python -m pytest server/tests/domain/test_reporting.py server/tests/test_reports.py`（HTTP 需隔离 PG）；Flutter工程内`test/domain/reporting_test.dart`、`test/entry/home_page_test.dart`、`statistics_page_test.dart`和`budget_preferences_test.dart`。
> - 相关：[投影契约](../../contracts/reporting-v1.md)、[账务](../../contracts/ledger-rules.md)、[金额时间](../../contracts/money-time.md)、[本地账务](ledger-data.md)、[同步](sync.md)。

`ReportBill` 独立于数据库与界面模型，接收规范公开 payload、可信当前 remaining、分配完整性及隐藏分配计数。`ReportQuery` 明确账本、币种/精度及左闭右开日期区间；monthAt/month_at 复用原始锚点月末截短。调用者提供完整历史，不能先按期间筛掉后来的退款/报销。分类父子映射需包含历史归档分类。

2026-10-23首页汇总、预算与趋势卡片均可独立开关，复用`LedgerReportingService`同一生产投影。首页/统计/日历/预算展示统一消费精确千分位、收支配色与金额隐私；隐藏时卸载数值图、分类占比/进度与金额tooltip，已展开的tooltip也随切换销毁。独立预算编辑器保持原十进制输入，可仅本次显式显示，每次重新开启隐私均重遮盖，金额控制器与保存规则不变。桌面宽度>=1100的首页使用分别滚动的流水/汇总双栏，窄屏1.8倍字号金额纵排；不另算金额或因设置变化生成outbox。

首页/统计/日历14个widget目标与后补显示消费集合34个widget目标分别通过，owned分析无问题；后者包含预算2个新增目标，核对打开中的编辑器切换隐私后实际保存合成`9007199254740992`最小单位、分类限额保持，以及生产预算投影的千分位/隐藏不改原命令。回执为`outputs/validation/P5-home-display-widget-tests-final.log`、`P5-display-consumers-widget-tests-final.log`及对应analyze日志；两个集合有交叠，不累加为新的完整工程总数。当前普通Web/Windows新包与真实浏览器的新设置/保护/完整旅程尚待验，旧候选Chrome结果不作为这些新行为的实际浏览器证据；安卓专属与ADB仍暂停，完整边界见[工作区说明](workspace.md)。

`build_report`/`buildReport` 只做纯计算。两端用 int/BigInt，最终金额字段检查64位范围并编码为字符串；缺少冻结 reporting 不猜汇率。转账/借贷本金不进收支，fee 独立一次；费用的主统计与预算标记分别处理。退款/报销按原单日期冲减，用原报表额累计比例舍入；超额退款仅显式收入分量按回款日期计收入。分类直接汇总与祖先 rollup 分开，避免把父子重复求和。

完整分配或可信公开剩余额才能证明源单净额；没有证据返回 unavailable，全部数值投影为 null，原因不含私人来源 ID。公开剩余额能证明净额但无法证明退款/报销各分量时，总额可用而拆分 null，带 `report.allocation_detail_unavailable`。本地金融修改/回款删除后的旧剩余额不能作为当前证据；接入方需隔离这种暂态。

预算明确绑定查询区间；总额/分类/混合大于/混合等于分支遵循契约。父子同时预算或总额小于分类和被拒绝，结果不部分发布。日历为业务日稀疏总额，账户净资产继续由账户投影负责。

最初Python与Dart算法目标各17项通过，Dart由执行代理在串行工具窗口代跑，目标analyze clean。直接消费黄金L01–L04、L08的41步/50期间期望与4种预算配置，不依赖ReferenceLedger生成期望。补充覆盖分类后代、跨期日历、隐藏剩余额、缺来源不泄漏ID、stale remaining、分类环、64位溢出、缺汇率、累计尾差、超过2^53的JSON金额及非法报销守恒。Dart另提供`ReportResult.unavailable(query, issues)`，以有限错误码隔离scope/sync/conflict/budget本地读取失败；未知或空原因规范为report.invalid_data，所有数值为空。该工厂的有限代码/去重/脱敏/空数值用例已在`test/domain/reporting_test.dart`落地，纯报表/安全工厂18项和接入21项曾合并39项通过，并已纳入后续完整客户端500通过/5默认live跳过，不再处于待回归状态。

`GET /api/v1/books/{book_id}/report` 已挂载真实授权读取，参数为 start_date/end_date_exclusive 与可选 budget_id，币种/精度取受控 Book。闭合响应携带 sync_epoch/scope_revision/permission_version 和 report；普通 api_native/api_web 的 owner/editor/viewer 可读，管理员角色无隐式范围权限，后台用途会话被拒绝。无缓存，也不以已有缓存代替新请求授权。

请求早期认证读取先 rollback，再在首次 SQL 前设置 REPEATABLE READ。锁顺序为当前 user/session→按 UUID 排序的当前 user control 与 book scope，查全部有效历史/归档分类，构造后再次复验活动身份与成员权限；锁持有至结果模型固化/事务结束。跨账本回款仅通过 SQL 聚合返回已授权源单的累计源币额，与 canonical public remaining 规则一致，不读取其回款 ID/正文/私人 finance 作为响应。完整预算区间自动匹配，重复配置明确 unavailable，显式 budget_id 仍校验 scope 和区间。

最初真实PostgreSQL报表目标15项全部通过，包含于当时服务端完整335项回归（48.79秒）。覆盖owner/viewer、陌生/后台身份拒绝、撤权与冻结Principal再查、归档子类父预算、私人跨账本回款只显示可证净额、实际sync命令逐步黄金和真正PG锁等待；另验证首次RR快照建立后、scope锁取得前撤权已提交时读取会重试并拒绝。黄金四预算模式以及实体/输入/输出限额也已验证。每请求最多50000实体/8 MiB输入/1 MiB输出/10秒生成预算，超限413且不返回部分数字；statement/lock超时沿用同步事务安全错误。后续服务端候选版本和完整回归见[服务端模块](server.md)，不把335当作当前全部服务端测试总数。

生产 wheel 独立安装后，经隔离18082真实HTTP创建125最小单位合成账单并读取准确报告，匿名同路径401；server-info声明reports-v1，OpenAPI包含29路径/76schema/31唯一操作标识，管理模板/CSS/迁移/报表资源齐全。合成账单/账本已正常墓碑、会话退出，该临时服务已停止，不以此替代现有18080联调服务重启或Linux验收。

## 客户端接入

`LedgerReportingService(LocalRepository).read/watch(space, query, {budgetId})`通过`AppDatabase.readSnapshot`一致读取entities/shadows/outbox/state/权限缓存，已有事务时复用快照。需要当前verified空间、活动sync状态和账本角色；本机新源单以可证完整性为基线，canonical remaining加尚未反映的本机分配差额。pull早于ACK不重复扣减；raw ACK无新canonical证据、冲突、旧隐藏分配的金融改动或权限不明时返回不可用。21项真实SQLite专项和纯报表/安全不可用工厂18项合计39项通过；账务与领域曾合并180/180，owned目录分析无问题。其后完整客户端500通过/5默认live跳过、完整分析无问题；没有把整测数当作新的39项目标复跑数。

首页hero与StatisticsPage均消费该适配。统计支持账本月份起始日、月/自然年/自定义半开期间、上期比较、明确按期间天数的日均支出、可见原始记录笔数、分类直接占比及原始流水筛选。每日图精确金额保留BigInt，只将有界绘图比例转double，长期间按月绘制；全屏图独立实时订阅并受空间/权限限制。分类原始流水入口是搜索，不将名义金额冒充统计净额。

日历支持收支/结余/收入/支出、周一或周日开始、区间内选日、原始流水和以所选业务日补记。预算页只对账本月期间维护，总额/分类/混合规则由同一投影校验；支持设置/编辑/删除和沿用上期金额及分类，保存到本机待同步。金额字符串精确解析，未授权只读；重复期间预算暂停汇总并允许有权者清理。预算编辑不自动创造结转金额。

上述界面已落可见首页/侧栏入口，相关目录分析无问题。统计6项+首页1项共7/7通过，覆盖31号账期/独立标记、超过2^53预算创建编辑沿用、日历选日实际入账、独立全屏图的空间切换与数据库撤权，以及390宽/1.8倍字体下柱图和折线图布局。首轮每日图日期换行导致2px溢出，修正有界轴标签和高度后重新通过；日历fixture平台目录I/O调整为显式隔离预热，不改生产守卫。当前周起始统一保存为本机/浏览器显示偏好，仅在尚无版本化设置时迁移旧资料空间键；旧记录保留，不覆盖已有新设置，也不改变业务日期或时区。

独立Chrome真实UI已核对31号账期、初始收入100.00/支出13.50/结余86.50、宽/窄屏全屏折线及日历15日原流水。原预算等待由应用事务边界修复；正常main新产物已通过预算100.00创建/100.01编辑/下期沿用，使用23.75，剩余先76.25再76.26。日历16日实际补记1.25后，重开统计支出14.75/结余85.25，预算使用25.00/剩余75.01，真实UI同步已过。原失败证据仍保留，页面结果与Native widget分列。手机2026-10-22已重连并恢复隔离ADB；新增统计预算完整真机路径仍按最终旅程执行。服务端不从参考领域内存对象取得生产事实。上述Chrome旅程使用335稳定wheel；scope清理后18080顺序升级为已验377项的独立move wheel，实际29路径/78schema/31唯一操作，原instance/epoch与backend-data不变，不随源码热更新。

2026-10-22最终稳定Card候选c974的整工程504通过/5默认live跳过、完整分析无问题，包含原纯报表/安全不可用工厂和界面回归；实际即时退出ARIA/公开Tab输入与重开退出专项通过，旧ae/4897失败保留。P4 Web run已正常清理、期初恢复及会话0，18085与自有18185均关闭。上述整测与退出专项不算新的报表Chrome或Android旅程，也不代表完整P6通过。

机制依据：[PostgreSQL JSON](https://www.postgresql.org/docs/current/functions-json.html)、[事务隔离](https://www.postgresql.org/docs/current/transaction-iso.html)、[SQLAlchemy 隔离级别](https://docs.sqlalchemy.org/en/20/core/connections.html#setting-transaction-isolation-levels-including-dbapi-autocommit)。
