# P4资产真实Chrome验收

职责：通过普通main真实可见控件验资产/信用卡/借贷/冻结FX/手动估值与授权读取；HTTP辅助结果另记。
入口：`p4_assets_qa.cjs`、`serve_p4.py`；P3既有脚本和`build/web`保留。
不变量：新UUID专用Chrome profile；不注入token/本地库/内部Flutter函数；业务创建不盲重试；不读取个人浏览器。
必跑检查：Node `--check p4_assets_qa.cjs`、Python `-m py_compile serve_p4.py`；普通main构建后才实际逐阶段执行。
相关材料：[资产模块](../../../AI/modules/assets.md)、[币种模块](../../../AI/modules/currencies.md)、[原浏览器证据](README.md)、[资产契约](../../../contracts/assets-v1.md)。

## 当前状态

最终候选为`build/web-p4-auth-card`，普通main SHA256 `c974c847b3dceb1ef138ae2fcd536a9937c968dfe69e09efe3ed5859fbe26a61`（41.9秒）；主代理完整客户端504通过/5默认live跳过、全分析无问题。沿同profile正常worker切换后，`logout-form-only`公开输入/Tab、真实登录、`logout`即时用户名/密码/登录ARIA与真实公开输入/Tab，以及`logout-reopen`全部通过，主代理实际查看安全图并接收。最终结构35语义节点/2editor，logout204；此轮金融/配置操作0。ae/4897原失败和e14b/profile历史仍保留，不扩展为完整P6/全平台通过。

本run已正常清理：固定候选wheel对六资金单、八账户及分类/账本共16对象正常墓碑，逐账户恢复opening，entries/refs/活跃会话0、空组/报价与默认偏好复原，18085受控退出0。自有18185核对精确命令/父链后停止，端口无监听、owned Chrome0；profile/storage/mutation journal保留，18080/18181/55432不变。回执`outputs/validation/P4/web-assets-cleanup-receipt.json`及`web-assets-browser-close-receipt.json`。以下按构建顺序保留业务通过与旧失败事实。

2026-10-22脚本已落，Node语法检查和Python编译检查通过。主代理全客户端500通过/5默认live跳过、完整分析无问题后，将普通main独立构建到web-p4；固定SHA256为`e14b234aad6a6deead2a8f2c21040cb41daab6b578a34b112fe045947b1eba81`。架构新Web种子7账户/9命令已确认、种子会话退出，当时18085候选受控hold（最终已按上述回执关闭）。18185实际HTTP200、main.js6257947bytes和COOP/COEP已核对，P3仍固定a55bfe79...970ed0。

当前实际结果：原定24个唯一阶段全部执行，sync按计划两次；定位重试、公开输入诊断与额外只读检查不计作“25项测试”。普通main03a1候选修复输入后完成真实登录、同步、两种宽度总览、分组、新信用卡、分组排序隐藏、金额隐私、六种资金动作、再次同步、日期化报价8→9、明细/账期/历史与重开。新卡-80后净720；转账100CNY→12.50EUR并从独立账户扣0.25；最终现金860/EUR12.50/手续费99.75，报价8净719.75、报价9净732.25，负债690。全部金额使用写入前冻结的期望，没有重复资金单或账户保存。

原严格失败分列：偏好PUT200后可见确认句未进入ARIA；报价8保存及精确行通过后，刷新状态句未进入ARIA；退出POST204且视觉正确，但同页新表单控件仍缺ARIA。偏好不重PUT，报价8不重POST；另存只读恢复receipt验证已持久化latest策略、精确报价/三个GET200及实际资产719.75。报价9实际732.25通过；新字体候选只读反馈检查已严格看到ARIA确认句。该版即时logout保持failed，logout-reopen通过，未把重开结果覆盖即时缺口；当时Tab因用户名控件未出现而没有执行，最终c974专项另记为通过。

最终只读字体候选为`build/web-p4-fonts`、SHA256`ae7964f21eddde4b5be7298cd5679ed43de2e317f3a364520f66b41e5bd3a7d1`。同profile第一次正常打开仍收到03a1，正常关闭再打开实际收到ae7964，本机金额/会话和零待传保持；仅证明此切换过程，不推定所有PWA升级路径。`font-verify`、`font-narrow`、`configuration-feedback`为额外三个只读检查点，均通过，未改原24阶段集合。阻断fonts.gstatic.com/fonts.googleapis.com时实际Noto/Roboto本地200，中文净/负/借完整，390×844金额/布局通过；CDP请求OS字级1.8但实际html font-size=16px，回执标记未证实生效，不能算Web有效1.8大字通过。真实widget1.8结果另列。Noto16MB正文无法由浏览器网络缓冲捕获，记录其200/路径，不伪填字节摘要；Roboto正文摘要已捕获。未宣称整PWA离线冷启动通过。

后续退出候选`build/web-p4-logout`实际SHA256`4897e5b9687515b057a5c6126f401bedfc6bcbaf875bf96bc044ac1e85c90f8e`，整工程503通过/5默认live跳过、分析无问题。沿同profile正常开关完成worker切换后，额外`logout-form-only`只读检查点通过：用户名/密码/登录真实ARIA、公开文字输入、Tab密码可编辑和清空均已核对，未提交该公开表单。随后仅真实登录一次、实际Tab密码与auth200通过；退出204及确认句通过，但同页控件仍缺ARIA，严格logout再次失败，未继续输入。logout-reopen通过、未自动恢复会话。已保留旧ae失败及新4897失败，不把widget确认overlay修补当作真实Web缺口已解除；没有重复资金/配置写入。这是4897失败历史；最终c974结果与受控服务收尾见本节开头。

主代理另授权一次固定4897纯诊断循环：fresh已退出表单先采结构，然后真实登录/退出，字段严格失败时采Tab前后结构，最后重开保持退出并关闭Chrome。所有值属性脱敏，aria-label仅固定控件白名单或other+长度，不读input.value/innerText/textContent/outerHTML，不改DOM或存储。fresh有31个语义子树节点、2个editor，FORM有5个直接孩子；失败时24个节点、0个editor，FORM仍display:block/visibility:visible且同尺寸，但孩子为0，Tab后不变，未见aria-owns悬空引用。此证据区分了FORM子节点缺失与仅被CSS隐藏，未据此声称已定位上游根因。安全结构文件为`web-assets-logout-form-only-semantics-fresh-signed-out.json`和`web-assets-logout-semantics-immediate-logout-failure.json`，该诊断对应4897；后续c974稳定Card后即时结构为35节点/2editor且真实输入通过。

以下e14b记录为保留的失败历史，当前已登录旅程不再停在该位置。

e14b真实独立Chrome155登录专项当时未通过：首失败为服务地址可访问label合并段落，按实际属性改严格后缀定位后地址已保存；随后登录页可见表单，但语义input有时disabled、有时完全缺失。12秒只读观察曾见启用，不能因此下结论永久identity.busy；实际30秒等候可访问控件仍超时。最初焦点检查仅找input，补查textarea后也未命中；主代理实际查看失败截图却已见用户名蓝框及光标，因此DOM查询失败不能证明生产不可输入。这些失败均发生在键入凭据之前。

随后按已查看1280×900空表单坐标执行实际键盘输入和登录点击，账号状态断言仍失败、受监视API HTTP事件为空。本轮同刻输入前截图未见先前的蓝框光标，可能在初始化尚未启用时发送了按键，不能据此判定生产登录失败。已输入后的表单不保存截图或值；先保留回执与输入前安全截图，再交主代理判断，不连续空转或声称已登录。原失败逐份保留，不绕过disabled、不注入应用/存储、不改金额断言。

按主代理要求，最后一轮`login --public-input-probe`先等待12秒（只作初始化延迟，不作成功证据），再点击同一用户名坐标、真实键入固定公开文本`focus_probe_01`并保存安全截图。实际查看只有蓝框与插入光标，没有测试文字，故未确认继续、未输入凭据。此证据不等同于生产根因已经定位；暂停后续24阶段验收，等主代理接诊，不把鼠标焦点外观当作可编辑值或登录通过。

最后一轮最小只读取证取消stdin确认，直接产出inspected并退出：物理点击后document.activeElement及开放shadow focus链只有`FLT-SEMANTICS role=button rect(8,8,40,40)`，document与开放shadowRoot的input/textarea/contenteditable共0个。`keyboard.type`后200ms及`keyboard.insertText`后200ms安全图均未见公开文本；两图已实际查看，HTTP/errors为空、自有Chrome正常关闭。截图为`web-assets-login-public-probe-type.png`和`web-assets-login-public-probe-insert.png`。没有在失败后继续输入凭据，也没有把inspected计为页面passed；生产修复由主代理接手。

`login --inspect-controls`只读列Settings标签；`login --inspect-login-controls`只在凭据输入前读取表单属性和遮框截图，回执状态为inspected，不算登录passed。`--reopen-current-address`比较已保存185直接初始化，仍不登录。默认真实登录按实际enabled节点有界等待；仅在主代理授权和同一已观察视口下才使用真实鼠标焦点，并单列Semantics失败。不得把HTTP登录或手工修改浏览器数据当作页面修复。

主代理完成全测试/分析并冻结全部生产源之后，才能构建普通`lib/main.dart`到`build/web-p4`。`serve_p4.py`只绑定127.0.0.1:18185，提供此目录并发送COOP/COEP与no-store；它不触发构建，不覆盖P3的`build/web`。

Web编辑控件最小证据由主代理修复后，独立`build/web-p4-semantics`实际SHA为`03a1c84dfb17657d87e0c14191f0634fac18cbe3e75596a9aa1e26a00f0036fe`。保留原e14b目录、旧profile和全部失败；候选公开type/insertText都实际显示focus_probe_01，再执行真实Cookie登录。旧profile当次由SW命中e14b只证明那次尚未切换，未据此宣称永久升级失败；主旅程使用新的UUID profile。静态服务和脚本只允许显式web-p4/web-p4-semantics/web-p4-fonts/web-p4-logout/web-p4-auth-card五个目录，同一18185只运行一个服务；每次核对实际浏览器正文SHA及COOP/COEP，候选等待生产真实语义控件，不注入DOM或调用内部Flutter函数。

静态场景为`p4_assets_scenario.json`。`server/.venv/Scripts/python.exe tests/e2e/client-web/verify_p4_assets_scenario.py`已实际通过：24个唯一阶段、sync执行两次所以25次运行；7预置账户、1个UI新卡、6资金单、10金额状态。独立checker只用整数/标准库，不导入生产账务、不访问网络/数据库。期初净资产800.00，新卡-80后720.00；借贷/还款本金不改净值；100CNY→12.50EUR+独立0.25费在无报价时合计不可用，手动8估值719.75、9估值732.25。信用卡总欠150.00而当前账期应还0.00；现金6分录1000.00→860.00；正常删六单恢复全部opening。所有结果在UI写入前固定，不能从页面读数反算期望。

场景特别保留一个include=true、零余额、opening_date=null账户，验证历史趋势仍显示缺少日期而非伪造零曲线。隐藏的是UI新信用卡，负债仍计合计；资金现金保持可选，避免Entry合理排除hidden新选择后自己堵住资金流程。seed.book_payload必须show_assets=true且Asia/Shanghai，不能依赖服务端默认false/其他时区。

```powershell
# 仅在主代理授予全局Flutter窗口后构建。
& 'C:/Ruibin_Ningh/app/FlutterSDK/flutter/bin/flutter.bat' --no-version-check build web --no-pub --release --output build/web-p4

# 项目根运行；候选API必须允许这个独立来源。
& server/.venv/Scripts/python.exe tests/e2e/client-web/serve_p4.py
$env:NODE_PATH = 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules'
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/client-web/p4_assets_qa.cjs login
```

## 合成fixture闭合边界

架构harness准备新的Web账号和对象，输出忽略文件`outputs/validation/P4/web-assets-fixture.json`。至少包含：

- purpose=`flowtrace-p4-assets-ui-synthetic`、state=`seeded`、run_id/instance_id/sync_epoch/user_id规范UUID，api_origin=`http://127.0.0.1:18085`。
- credentials_path只指向仓内`work/flowtrace-dev/`下的新合成账号JSON；支持单一{username,password}或由account_index选数组项。不得复用已清理live对象，不输出密码/令牌。
- names为固定合成书/账户/类别名，均带run marker；至少book/cash/eur/fee_account/credit/receivable/payable/expense_category、UI新建的ui_credit/ui_group。
- ids保留对应对象UUID供HTTP只读辅助核对；脚本不会据此注入账务。
- expected按阶段保存事先确定的真实可见金额/文字数组。除inspect/login/sync/logout外，无固定期望直接拒绝启动阶段，不能看到任意文字就算通过。
- inputs按阶段保存表单输入。account-create要求opening/limit/statement_day/due_day；group-create/account-metadata要求sort_order；fund阶段要求account_name_key/from_name_key/to_name_key/amount/note，fund-fx另有fee；rate阶段要求from_label/to_label/rate/date/source，rate-replace另有previous_row。

金额输入为十进制字符串，不能用JSON浮点表示金额。fund-fx固定真实输入100CNY→12.50EUR与0.125，独立手续费账户另选；估值报价改变后仍须在详情与HTTP辅助核对原资金金额/目标/FX均不变。日期已跨22日；默认exact_date的UI需当日报价，较早报价仅在明确latest_on_or_before时可用。

## 阶段与证据

| 阶段 | 实际页面操作与判定 |
|---|---|
| login | 设置独立地址，真实输入合成账号，Cookie/CSRF登录；不保存登录表单截图/DOM值 |
| sync | 真实“立即同步”，等待完成并记录受限applied回执 |
| inspect | 只读观察资产页及真实Semantics，供定位；不算金额验收 |
| overview / overview-narrow | 私人总览及固定余额/缺证据状态，1280×900或390×844截图 |
| group-create | 联网刷新完整配置、填写分组/排序、确认后可见 |
| account-create | 实际银行搜索选招商、新信用卡负期初/额度/日期保存到本机 |
| account-metadata | 已确认分组/排序/隐藏保存，菜单显示隐藏账户后核对 |
| money-privacy | 点击眼睛后可访问树也无固定余额，恢复显示后核对 |
| fund-repayment/borrow/lend/collect/repay/fx | 资产操作→明确账本→正式生产编辑器/计算器→本机保存，固定余额；sync另一步执行 |
| currency-preferences | 明确较早直接报价策略，保存后服务器确认 |
| rate-create / rate-replace | 日期/直接币对/来源与精确小数输入，旧报价先明确删除再新建 |
| read-details/credit/history | 实际进入授权页并点“刷新服务器资料”，核对响应确认与金额或不可用原因 |
| verify-reopen | 同一专用profile重开新Chrome进程，本机资料/会话/配置按固定期望保留 |
| logout / logout-reopen | UI撤销会话、即时字段ARIA/公开输入Tab及重开保持退出；旧ae/4897失败保留，c974严格复验通过 |

每阶段新启动/关闭本轮专用Chrome，profile由`web-assets-browser-session.json`绑定run/instance/epoch/user，拒绝其他目录和个人profile。主脚本只读取可访问控件/实际网络事件；没有HTTP准备、调用应用内部函数、改IndexedDB或跳过失败断言。

`web-assets-ui-mutations.json`在首次保存动作前记录started，页面观察完成后记completed。任何同名动作已经尝试过即拒绝重复，失败后必须先查看原ARIA/截图/网络标记和HTTP只读实际状态，再由主代理决定具体恢复方式；不能删日志后盲重新开户/转账。独立inspect和读取阶段可重复，旧失败收据/ARIA/失败截图先归档。

回执只含版本、产物SHA、视口、阶段、固定类别HTTP状态、规范UUID、精确金融字段与原字节摘要。不保存auth头/Cookie/完整请求响应/输入密码/trace；非登录ARIA对合成凭据逐值脱敏。真实截图要实际查看，记录布局与对比，不把脚本退出码当视觉验收。验收结束通过UI退出后正常关闭自己的context，服务与合成普通墓碑清理由主代理/架构harness统一安排，不关闭其他浏览器或整库删除。
