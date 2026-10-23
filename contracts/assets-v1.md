# 资产、信用卡、债务与币种 v1

本契约承接 [金额与时间](money-time.md)、[账务规则](ledger-rules.md)、[权限](permissions.md) 和 [同步](sync-v1.md)。S37–S41/S53 仅证明钱迹 4.5.4 当时的页面、分类和开关，未证明还款、账期或估值算法。下列算法和 API 为流迹设计默认 N；完成范围以模块文档及实际测试为准，契约本身不是部署回执。

## 账户字段与兼容

账户仍为六类同步实体中的 `account`，资金写入仍经 `bill` 事务；界面不能直接改 `balance`。`kind` 为 `cash|bank|credit_card|loan_receivable|loan_payable|prepaid|investment`。新增两类按记账金额持有价值，不暗示已实现证券份额、实时行情或加密币任意精度。钱包、银行、预付卡、基金等细分由 `provider_id` 表达。

```json
{
  "name":"个人信用卡","kind":"credit_card",
  "opening":{"currency":"CNY","currency_scale":2,"amount_minor":"-10000"},
  "include_in_net_assets":true,"hidden":false,
  "group_id":null,"sort_order":0,"archived":false,"icon":"account","note":"",
  "provider_id":null,"bank_id":null,"card_last_four":null,"opening_date":"2026-10-01",
  "credit":{"limit":{"currency":"CNY","currency_scale":2,"amount_minor":"200000"},
    "statement_day":15,"statement_day_inclusive":true,
    "due_mode":"fixed_day","due_day":5,"due_days":null}
}
```

- 旧必填字段保持原名。新字段缺省依次为 `null,0,false,"account","",null,null,null,null,null`；解释当前实体时可补默认，不能重写已物化 change/snapshot 内容或哈希。旧客户端更新省略新字段时保留旧值；显式 `null` 按字段含义清空。
- 名称 1–80 字，`note` ≤2000，`icon` ≤64，目录 ID 为 `[a-z][a-z0-9_-]{0,63}`，`sort_order` 为 0…2147483647，尾号严格四个 ASCII 数字或 null。所有文本拒绝 NUL。银行/服务商来自随包只读目录；`bank_id=null/provider_id=null` 允许自定义账户名称。
- `group_id` 仅允许本人 user-scope 账户引用本人未删除组。book-scope 共享账户必须为 null，不复制、展示或引用私人组。组的创建必须先获 REST 确认，再 push 引用它的账户；组 ID 不得放入同步 `depends_on`。
- `opening_date` 是期初余额生效业务日，null 表示历史锚点未知。不得晚于该账户最早有效分录。未用账户改变期初/日期必须经账户修订确认；已有任何有效资金分录时禁止改期初金额、币种、精度、kind、opening_date（包括将 null 补为日期），返回 `account.definition_in_use`。余额修正使用可追踪的 `balance_adjustment`，禁止静默覆盖余额列；旧账户缺失历史锚点不会被猜测补齐。
- `archived` 禁止新增资金引用；已有相同账户引用的账单可继续保留/维护。`hidden` 只控制列表，不能改变余额或净资产；`include_in_net_assets` 决定是否进入汇总。归档不删除历史，也不自动排除汇总。
- `credit` 仅信用卡可非 null。额度非负且与账户币种/精度一致；额度和日期可独立设置。`statement_day`、`due_mode` 都可 null，日期未齐时日历不可用。`due_mode=fixed_day` 要求 `due_day` 1…31 且 `due_days=null`；`days_after` 要求 `due_days` 1…120 且 `due_day=null`；null 要求两个 due 字段均 null。`statement_day_inclusive` 缺省 true，延续既定 N；S41 关闭状态不证明实际 cut 算法。

## 原币资金与冻结汇率

十一类账单及符号不变。转账、信用卡还款、借入/借出/收回/归还本金不重复记收支；利息分别独立收入/支出，手续费分录与支出仅计一次。`cash|bank|prepaid|investment` 是普通资金账户；债权正数、债务负数；信用卡负数为欠款、正数为溢缴。

两账户账单沿用 `money` 和 `target_money`，新增可选金融事实：

```json
{"transfer_fx":{"rate":"0.125","rate_date":"2026-10-21","rate_source":"manual"}}
```

`transfer_fx` 只适用于既有六类两账户类型、原/目标币种不同且存在 `target_money` 的账单。按 `money` 主单位乘 rate，最终一次 HALF_UP 到目标精度，结果必须与 `target_money` 完全相同；100.00 CNY ×0.125 =12.50 EUR。rate 为既定普通十进制正数字符串（整数部分≤20位、值<10^20、小数≤18位），日期合法，来源 1–80 字。相同币种不提供该对象。

旧单没有该字段时保留两笔原币事实，汇率来源显示未知，不拿估值表补造历史来源。旧客户端 update 省略 `transfer_fx` 保留原值；提供或改变它必须按完整金融编辑权限重新验证，不能伪装 metadata。跨账本 move 的金融不变比较、`preserve_hidden_financial_links` 比较均包含它。旧单显式清空已有冻结率拒绝；修改两笔金额时必须同时给出新冻结率或保留旧率且校验一致。`reporting` 仍是账单→账本币种的另一项冻结事实，两者不互相替代。

## 私有配置 REST 的冻结命令

组、币种偏好和估值记录是私有配置表，不扩充同步六类实体。所有列表/结果为闭合模型并发送 `Cache-Control: private, no-store`。普通 API native/web 会话可访问本人；admin 会话无隐式访问，Web 写入仍验证 Origin 和会话 CSRF。`X-Request-ID` 使用现有真实请求元数据，不把正文或路径写入诊断。

所有修改带相同冻结信封，REST path/action 也属于内容哈希：

```json
{"operation_id":"10000000-0000-4000-8000-000000000001",
 "client_id":"10000000-0000-4000-8000-000000000002",
 "instance_id":"10000000-0000-4000-8000-000000000003",
 "sync_epoch":"10000000-0000-4000-8000-000000000004",
 "base_revision":"0"}
```

`client_id` 必须等于当前会话，instance/epoch 必须等于当前服务；冻结/过期同步设备不能绕过 rebuild 写配置。每用户所有组/偏好/估值共用单调 `revision`，初始 `0`。操作按用户 scope 锁串行；base 不等于当前版本返回 409 `asset_config_conflict`。同用户、client、operation、相同规范化原始字段（不注入默认）重放返回第一次已提交响应，鉴权和 instance/epoch 检查先于缓存。相同 operation 不同正文返回 `idempotency_conflict`，不新增版本。新请求成功递增一次全局 revision，行自身 `revision` 为此次版本。GET 不创建版本。

响应丢失时以原字节、原 ID 重试；收到旧 replay 结果不得覆盖客户端更高版本缓存。新意图由用户确认或配置队列明确重新取 base，不自动把失败旧意图重基。持久缓存/队列键必须含服务器 instance、user、epoch、client，备份包含它们；epoch 改变先备份，停止自动重放，重建后由用户核对。共享权限撤销只删除受控共享缓存，不能声称收回用户已导出的数据。

### 组、银行与服务商

| 方法与路径 | 输入（外加冻结信封） | 闭合响应 |
|---|---|---|
| GET `/api/v1/assets/groups` | 无 | `GroupList` |
| POST `/api/v1/assets/groups` | `group:{id,name,sort_order}` | `GroupMutation` |
| PATCH `/api/v1/assets/groups/{id}` | `group:{name,sort_order}` | `GroupMutation` |
| DELETE `/api/v1/assets/groups/{id}` | 仅信封 JSON body | `GroupMutation` |
| GET `/api/v1/assets/banks?q=...` | q≤80，空为全部 | `{version:1,banks:[{id,name}]}` |
| GET `/api/v1/assets/providers` | 无 | `{version:1,providers:[{id,name,kind}]}` |

`GroupList={instance_id,sync_epoch,revision,groups:[{id,name,sort_order,revision}]}`；`GroupMutation` 额外含 `operation_id`，返回提交时完整组列表（稳定排序 sort_order/id）。名称1–80；最多1000个存活组。空组持久；ID不复用。删仍被存活本人账户引用的组返回409 `asset_group_in_use`，保留所有数据；先显式改账户组再删除。猜他人组与未知组同404，不回显其存在。

### 币种与估值

| 方法与路径 | 输入（外加冻结信封） | 闭合响应 |
|---|---|---|
| GET `/api/v1/currencies/catalog` | 无 | `{version:1,catalog_date,source,currencies:[{code,name,scale}]}` |
| GET `/api/v1/currencies/preferences` | 无 | `PreferencesResponse` |
| PUT `/api/v1/currencies/preferences` | `preferences:{base_currency,enabled_codes,valuation_policy}` | 同上加 `operation_id` |
| GET `/api/v1/currencies/rates` | 无 | `RateList` |
| POST `/api/v1/currencies/rates` | `rate:{id,from_currency,to_currency,effective_date,rate,rate_source}` | 同上加 `operation_id` |
| DELETE `/api/v1/currencies/rates/{id}` | 仅信封 | 同上加 `operation_id` |

`PreferencesResponse={instance_id,sync_epoch,revision,preferences:{base_currency,enabled_codes,valuation_policy}}`。无配置默认 CNY、`["CNY"]`、`exact_date`；base 必须在去重 enabled_codes 中，均为已支持代码，最多200。偏好只影响展示/新增选择，不禁读或改写既有外币账单。

`RateList={instance_id,sync_epoch,revision,rates:[{id,from_currency,to_currency,effective_date,rate,rate_source,revision}]}`。每用户每有序币对/日最多一条存活记录，行值不可编辑；替换必须先删后用新 ID 添加，历史账单均不引用它。最大10000条存活记录；from≠to；来源1–80。`valuation_policy=exact_date|latest_on_or_before`，只取显式同向直接币对，不自动倒数、三角套算或未来率。后者响应必须显示真正 rate_date；不声称实时行情。当前不访问外部汇率服务。

币种目录冻结官方 ISO 4217 已有数字 minor unit 项（0…6）；`N.A.` 等没有金额精度的单位不猜两位，不能开户。目录日期和来源随包展示；历史已有精度不会随网络改变。银行/服务商目录取已观察名称作为可搜索选项，不保证覆盖所有机构，不声称银行授权。

## 授权资产读取

以下均 `GET`，只读、同一个 REPEATABLE READ 快照，并在返回前复核当前身份与 scope。默认只读本人 user scope；可显式 `scope_id=bookUUID` 读取有权共享的账户，不能把本人私资混入共享汇总。陌生/撤权 scope 拒绝，viewer 可读共享资产，服务管理员无额外权限。

| 路径 | 参数 | 输出 |
|---|---|---|
| `/api/v1/assets/overview` | `as_of` 必填；`balance_mode=current|as_of` 缺省current；`scope_id?`、`base_currency?`、`valuation_policy?` | 账户原币余额、按币种资产负债/借入借出、逐账户估值证明、总额或 unavailable |
| `/api/v1/assets/history` | `start_date,end_date_exclusive`（≤366天）；scope/base/policy可选 | 每日相同口径总额及不可用原因 |
| `/api/v1/assets/accounts/{id}/entries` | `start_date,end_date_exclusive`，`offset=0,limit=100`（≤200） | 账户原币、分录和安全账单详情、匹配笔数/分页、期初/期末余额或 unavailable |
| `/api/v1/assets/accounts/{id}/credit-calendar` | `start_date,end_date_exclusive`（≤366天） | 当前欠款/溢缴/额度/可用额/超额、账期与还款日/免息日数；应还证据不足显式不可用 |

所有读取信封含 `instance_id,sync_epoch,scope_id,scope_revision,config_revision`。账户行包含 `id,revision,payload,balance`，payload按默认解释但不污染同步不可变页。entries 不经公开搜索猜私人账户；按账户所属 scope 授权后直接读有效私有分录。账本仍授权时才能带该单 `bill_id,book_id,bill_type,note,category_id,tag_ids,attachment_ids`；账本失权后仅返回分录金额、业务日、component、`detail_available=false`，这些账本标识/备注/分类/标签/图片全为 null/空，不通过私人分录拼回共享正文。按所有有效账户分录稳定排序，所有整数以精确十进制字符串输出。

### 当前余额、历史与净资产

当前有效余额=期初+全部有效分录，已有余额列须与该重算相等才可信；不一致返回 `asset.balance_unavailable`，不静默补差。overview `balance_mode=current` 明确使用全量有效余额，`as_of` 在该模式仅指定估值日期，不能冒称其为过去余额；`balance_mode=as_of` 与 history 才重构历史。日期曲线为“以当前有效账务重构在指定业务日的余额”：仅计 business_date≤该日的分录，**不是当年当时系统已知数据的审计快照**，删除/更正旧单会重构历史。`opening_date` 缺失，或已存在早于 opening_date 的分录，则历史 unavailable；当前总余额仍可单独返回。早于有效 opening_date 视为尚未启用账户，不纳入该日汇总；不能把未知日期伪装零余额。最多5000账户/50000分录，超过界限明确 `asset.limit_exceeded`，不悄悄截断成完整曲线。

逐账户先按日期选汇率、精确转换到本位币，然后加总（每账户最终舍入一次）。仅 include=true 的账户进入 totals；hidden/archived 保留。正数计总资产，负数绝对值计总负债，net=assets−liabilities；债权 loan_receivable 正余额在总资产中，同时单列 lent；债务 loan_payable 负余额在总负债中，同时单列 borrowed，**单列不能再次叠加净资产**。同币种无需估值记录；任何被纳入的非零外币账户缺率/溢出或历史证据缺失，整份跨币总额 `available=false,totals=null`，保留原币余额、按币种分组和 issues，不返回假的部分 net。零余额无需汇率。历史汇率与账单 reporting/transfer_fx 分开，改估值记录不改原单/分录/收支。

### 信用卡账期、应还和免息

每月出账日/固定还款日钳制到该月最后一天。inclusive=true 的账期 `[上次出账次日,本次出账次日)`；false 为 `[上次出账日,本次出账日)`。固定还款日选择严格晚于出账日的最近一个日期（同月已过则下月）；days_after 加自然日，无节假日或银行宽限推断。`interest_free_days=due_date−消费业务日`，是所配日历差，不是利息减免承诺；账期负向分录逐项可定位。

当前 total_debt=max(−余额,0)，overpayment=max(余额,0)；limit已知时 available_credit=max(limit−total_debt+overpayment,0)，over_limit=max(total_debt−limit,0)。额度未知则这两项null。

账单“期间消费”“出账时应还”“当前剩余应还”分别命名。流迹 N 采用 `(business_date,bill UUID,component)` 稳定顺序的先进先出抵扣（随机 entry_id 不作时间顺序）：负向分录形成欠款批次，正向分录依次抵最老欠款，溢缴抵后续消费；截至期末的剩余欠款归属原消费期，不把还款计收入。期初负欠款作为 `opening_carry` 单列不假配某历史账期；已有期初日期时仅完整覆盖的账期可计算，应还总额含单列carry，缺期初日期时所有账期应还不可用，仍可返回日期边界和当前总欠款。不能把当前负余额冒充本期账单。费用负向分录属于真实业务日的消费批次。金融机构实际账单与利息须人工核对；合同不推断最小还款额、利息利率或逾期费。

## 验收与迁移

0006 只新增私有配置状态、组、偏好、估值、幂等回执表；旧账户/账单 JSON 不回填，旧同步页不改写。升级在隔离库验证，downgrade 不自动逆迁业务数据。P4 新服务不替换当前18080的已验377 wheel，待完整回执后由主代理协调发布。

至少验证：旧省略保留/共享组拒绝/非空组删除并发；配置响应丢失重放一次、改正文/改用户/client/instance/epoch拒绝；银行搜索/自定义账户；充值投资分录；冻结100CNY→12.50EUR和改估值后历史不变；大于2^53和负数HALF_UP、汇总溢出；缺率整总额不可用；多账本私人账户明细与账本撤权后正文不泄漏；共享viewer/陌生/后台拒越权；负债/额度/溢缴/超额；月底/闰年/出账日开关/还款日；历史锚点缺失与分录早于期初拒绝；旧金融事实的move/preserve-hidden保护。

## 一手资料

- [SIX ISO 4217 维护机构与货币代码清单](https://www.six-group.com/en/products-services/financial-information/market-reference-data/data-standards.html)：目录来源，数值精度以冻结数据为准。
- [PostgreSQL 18 事务隔离](https://www.postgresql.org/docs/18/transaction-iso.html)、[SET TRANSACTION](https://www.postgresql.org/docs/18/sql-set-transaction.html)：一致快照在首次 SQL 前设置，权限检查与读取在同事务。
- [SQLAlchemy 2.1 连接与隔离级别](https://docs.sqlalchemy.org/en/21/core/connections.html)：对应实际锁定的 2.1.5，在事务开始前设置隔离级别，沿用现有 run_transaction；不在已开启读事务中途更改。
- [PostgreSQL 18 数值类型](https://www.postgresql.org/docs/18/datatype-numeric.html)：估值率使用 NUMERIC(38,18)，金额/修订以 BIGINT 边界验证；应用先拒绝额外小数，不能依赖数据库静默舍入。

这些资料支持数据来源和事务技术，不证明钱迹的未观测账务行为。
