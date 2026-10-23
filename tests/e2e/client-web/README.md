# P3 独立 Chrome 页面验收

使用本机已安装的 Chrome 和工作区打包的 Playwright；新建 `work/flowtrace-dev/browser-profiles/chrome-p3-UUID`。不连接用户现有浏览器、不使用个人 profile、不运行 Edge、不下载浏览器、不改系统默认。CUA 当前返回 `Browser is not available: chrome` 且库存为空，已按主代理批准改用本地代码 E2E。

## 当前真实结果

独立浏览器启动专项已通过：Playwright1.62.1 启动 Chrome155.0.8059.85，headed，初始恰有一个 about:blank；已按唯一 profile 路径核对实际进程并正常关闭。回执为忽略目录 `outputs/validation/P3/chrome-session.json`、`chrome-process.json`。这不是应用页面通过。

合成账本已通过 `prepare_fixture.py seed` 在18080创建；脚本重跑没有重复业务对象，另一轮合成账本通过精确 scope 快照与普通墓碑清理后，已新建当前浏览器验收账本。PNG上传ready及HTTP黄金报告已核对。

首份正常main构建44.9秒，摘要`523a8cdea8693de8fa9f8133b73675d82f3c648d9cccd67b5cc0434cb04e9f02`。真实UI验证地址设置、登录、同步、重开会话/SQLite/账本保留、31号区间收入100.00/支出13.50/结余86.50/4笔、全屏折线、图片关键词单条匹配及日历选日。其预算保存/导出预览等待失败已保留；[Web事务专项](TRANSACTIONS.md)定位应用嵌套事务并修复后，probe及关闭重开各4/4通过。

普通main修复产物55.8秒构建成功，摘要`cabc652412d5d805591c947d12b53f6d0e76b11886fc01a5a01cff143bcfa8d2`，各阶段核对浏览器实际收到的main.js正文摘要。预算创建100.00、编辑100.01、下期沿用100.01通过，使用/剩余保持23.75/76.25、23.75/76.26和2.00/98.01；日历实际补记10月16日1.25，重开后报告14.75/85.25、预算25.00/75.01，页面同步后首页0待传/5笔。

图片下载首轮失败时metadata/content均200，CDP仅在导出点击阶段捕获MethodChannel缺实现，实际派生registrant缺FileSelectorWeb。保全旧main及4份生成文件后执行标准Flutter clean和offline pub get，依赖锁摘要前后不变`90c726415a608d613b10bee8d92b16a3538be73821befaaf54766a988e4fbed9`，没有修改SDK、生成源或应用保存实现；新生成文件明确注册FileSelectorWeb。最终普通main55.9秒，摘要`a3a1c9eece0ffd8453592c219a1f4097958efda6afcbc42c9a98accb983b1c9a`，真实Chrome完成1笔/1图预览及下载。ZIP217字节、唯一`images/image_0001.png`77字节、SHA256`1f9f02b6b40dcfd3a8db1d36e64a04e9568f3a389fe721ee5de9f76dca615aa9`与原件一致。新产物重开报告/预算通过，相关截图已实际查看。

当前整体仍为**部分通过**：UI退出204、视觉正确，关闭重开仍退出且登录字段可用；但退出同页的Semantics遗漏可见表单控件，严格logout阶段仍失败，独立logout-reload通过，不把它改成假成功。已知异步语义问题和完整P6配额、多标签、离线壳/升级均保留。本旅程未另验搜索图片组合筛选或全部详情变化。手机断开，任何ADB/安装/真机验收继续留到最后。最终合成账本已按scope普通墓碑清理，所有自有Chrome关闭。

## 准备与隔离

凭据只读取 `work/flowtrace-dev/client-auth-qa.json` 的既有 Web 合成账号，不输出凭据、不自动新建账号。API固定回环 `http://127.0.0.1:18080`；原生临时准备会话最终退出，不替代后续真实Web Cookie/CSRF登录。仅访问当轮合成账本UUID及其中数据，清理前还核对用户、instance、epoch和账本名称。每项创建先保存固定operation ID及正文，失败后重跑原请求。

```powershell
& server/.venv/Scripts/python.exe tests/e2e/client-web/prepare_fixture.py seed

$env:NODE_PATH = 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules'
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/client-web/browser_smoke.cjs

# 仅复用本次新建的专用测试profile；各阶段均正常启动/关闭Chrome。
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/client-web/p3_browser_qa.cjs reports
```

合成运行ID、账本/分类/账单/附件UUID、完整固定正文及期望值保存在忽略的 `outputs/validation/P3/web-fixture.json`，不含密码或令牌。生成的是3×2静态PNG，图片只含合成像素。图片哈希不变；没有读取用户照片或钱迹。

## 页面主路径与固定期望

待全部入口与客户端测试稳定后，一次构建普通 `lib/main.dart` Web产物，不使用测试入口或编译QA凭据。静态服务固定18181并发送COOP/COEP；18080已允许该隔离来源。构建成功不能当页面验收。

| 页面动作 | 必须观察的结果 |
|---|---|
| 新Chrome profile打开18181，真实设置地址、填写合成账号登录 | 账号已连接，正常Cookie/CSRF流程；不通过注入token或改IndexedDB登录 |
| 页面点击同步、从账本列表选当轮 `FT浏览器-P3-` 账本 | 31号账期为2026-09-30至2026-10-30，4条本期原始流水；期前9月29日和下期10月31日不混入 |
| 打开统计及全屏，切柱/折线 | 收入100.00、支出13.50、结余86.50；切图不改变金额；截图与控制台没有布局异常 |
| 设置本期总预算100.00，再编辑100.01 | 使用23.75；剩余先76.25，再76.26。支出13.50与预算23.75不同，证明两个标记独立 |
| 下一期沿用上期，保存后回上期 | 下一期仍有10月31日2.00，沿用额度100.01但新预算ID；回上期数据不改 |
| 日历选10月15日、查看当天流水，再补记10月16日1.25 | 选日与新账业务日一致；预算使用变25.00，主支出变14.75；先保存到本机，再页面同步 |
| 搜索独特“合成图片-运行标记”，组合有图片筛选 | 仅一条3.25记录；详情图片正常，不返回期外/未选记录 |
| 长按该条选择，再点“导出图片”，检查预览并确认 | 1笔/1张；真实浏览器产生ZIP下载；解压只有生成序号名PNG，字节SHA256等于合成原件，ZIP不含账号/令牌 |
| 登录状态下刷新，再退出并刷新 | 本机数据和选中账本保留；退出后不展示已登录页面或旧账号内容。旧Semantics节点单列，不用视觉正确替代无障碍验收 |

以上为顺序场景；补记后的统计期望已经单列，不能拿初始黄金值断言修改后的状态。预算大于2^53的精确性另有widget/跨端领域回执，本浏览器旅程不声称已覆盖全部P6配额、多标签、离线壳或跨版本恢复。

## 证据、失败与清理

页面使用可见控件/语义角色定位；脚本不能通过HTTP或修改本地数据库代替用户动作。每个动作记录阶段和实测期望，失败即保留当前页面截图和安全错误类别，不能跳过失败断言续报整条通过。登录表单不导出DOM值/trace，不打印填入的凭据；截图避开账号密码输入。

`p3_browser_qa.cjs`读取已有专用profile回执并校验路径/命名前缀，提供inspect/reports/reports-narrow、budget-inspect/create/edit/copy、calendar/calendar-save、reports-after-entry、search-export、sync、logout及logout-reload阶段；search-export-debug仅供捕获被UI捕获的导出异常。每阶段重新打开同一专用profile并正常关闭。日期ActionChip为checkbox，指标合并为section语义group；预算inputValue须先真实点击聚焦才能反映Flutter控制器值，保留首轮未聚焦断言失败。长按使用1200ms实际鼠标按下，超过200ms引擎去抖加500ms框架阈值。退出后首页切换为草稿布局，logout-reload等待实际“登录”而非仅登录后存在的导航菜单；首轮定位错误也保留。没有注入本地数据或更改应用DOM绕过手势。

`serve_main.py`仅绑定127.0.0.1:18181，服务已构建的build/web并发送COOP/COEP和no-store；不触发构建。中断后原静态/API/PG进程均停止，新轮open-app连接拒绝已单记环境失败，没有业务写入；恢复相同原数据和instance/epoch后继续。

下载文件先保存到当轮 `outputs/validation/P3/` 路径，再用标准ZIP读取校验条目名、数量、原字节及摘要；只接收应用此次下载事件，不扫描用户下载目录。应用截图与浏览器版本、profile、固定产物哈希一起登记。验收结束通过UI退出本轮浏览器会话，再关闭专用context。

下载固定保存为`outputs/validation/P3/p3-browser-images.zip`后，运行`server/.venv/Scripts/python.exe tests/e2e/client-web/verify_download.py`核对唯一`images/image_0001.png`及原件摘要，不解压到文件系统。该核对必须在真实页面触发下载后执行，不能手工生成ZIP充作浏览器产物。

真实UI同步后还运行`prepare_fixture.py verify-ui`，只按该scope读取快照/报告，核对7条总账单、唯一1条1.25补记、两期预算各10001以及服务端金额与页面相同。其HTTP准备登录会话最终退出，不能将该辅助结果代替UI。最终回执为`web-browser-receipt.json`、`web-zip-receipt.json`和`web-ui-server-receipt.json`；各失败重跑前自动归档原收据/语义树/截图。当前manifest已cleaned且浏览器已退出，不能直接盲目重跑预算创建；新轮应保留原证据、准备新的run与专用profile并从真实登录开始。

```powershell
& server/.venv/Scripts/python.exe tests/e2e/client-web/prepare_fixture.py cleanup
```

清理只对固定合成账本做scope快照，先账单/预算/标签/子分类/父分类，最后账本；界面创建的预算与补记也在该scope内。仅正常墓碑，不宣称已立即物理回收附件。不同名称、用户或epoch直接停止；没有整库清空、系统目录递归删除或用户Chrome操作。

## 跨账本移动专项

`prepare_move_fixture.py`使用另外的`web-book-move-fixture.json`，只创建两本新owner账本、一个本人私有现金账户、来源支出125minor及PNG、来源分类/标签和明确的目标分类/标签。账户期初10000，支出后9875。来源时区Asia/Shanghai、目标时区America/New_York，金额均CNY；原账业务日2026-10-21及微秒瞬时`2026-10-21T05:06:07.123456Z`必须保持，expense不附加不适用的fee。

创建与清理命令均先保存固定operation_id及正文，再发送；中断后使用原ID重试。已实际连续两次seed通过，未新建重复对象。只按已知两个scope读取快照，私人账户仅按固定UUID直接读，不枚举账号的全部私人财务。每次准备/补充核对会话均在finally退出。

```powershell
& server/.venv/Scripts/python.exe tests/e2e/client-web/prepare_move_fixture.py seed

# 沿用原专用Chrome profile，普通main已构建后按顺序运行；不注入账号或本地数据。
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/client-web/p3_book_move_qa.cjs login
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/client-web/p3_book_move_qa.cjs sync-seed
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/client-web/p3_book_move_qa.cjs move
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/client-web/p3_book_move_qa.cjs sync-move
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/client-web/p3_book_move_qa.cjs verify
& server/.venv/Scripts/python.exe tests/e2e/client-web/prepare_move_fixture.py verify-ui
```

真实控件路径为：设置→登录账号→填写表单→页面同步；选择来源书→资金账户核对98.75→唯一备注搜索→长按单条→移动到账本→明确目标书/分类/标签→核对1单1图副本→准备原图→本机确认。此时源搜索为空、余额仍98.75，另一个阶段才点击同步；目标书核对1笔/分类/标签/原时间，点击真实图片预览。不能将HTTP准备或准备图片成功当作移动已提交。

`move`只确认本机，`sync-move`才记录浏览器实际发出的单条move marker及applied回执。只保存规范operation/entity/scope/附件UUID、请求字节摘要和受限结果字段，不保存完整请求/响应正文或认证头。`verify-ui`随后只读核对同UUID/修订、源0/目标125、原时刻与账户、目标图新UUID及实际原件字节；该辅助核对不能代替真实页面。

首份移动入口普通main41.6秒、摘要`dc484696b4f3242d05b0a1055c75cc9d66446805da6fa3d21d3eaaa489df2c9b`。登录、同步、明确映射、准备图片、本机余额保持、正式applied revision2、源0目标1及目标详情/标签/原时刻通过；补充HTTP下载77字节也完全一致。但目标图片预览无法解码，严格verify及verify-debug失败已归档。CDP定位`ImageDescriptor.width is not supported on web`，Pillow实际load和PNG三块CRC均正确，没有通过换图或重做移动绕过失败。

生产修复改用跨平台`ui.instantiateImageCodecWithSize`回调检查原始尺寸，保留40MP上限、720解码宽限制、单帧/完整解码与PNG动画检查；selector/panel14项目标通过。新普通main46.1秒，摘要`a55bfe7934a502b70a66b39fb8c1e83a729883a2811581bae80d2c0d00970ed0`，依赖锁不变。只对原已移动账单重跑verify：源0/目标1、目标分类/标签/历史时刻、98.75余额和真实图片渲染全部通过，实际截图已查看。只读HTTP核对同UUID/revision2、源0/目标125、目标clone新UUID且77原字节及hash不变也再次通过。

未登录首页直接登录的语义字段缺失另保留；真实登录采用正常设置路径，输入前先实际点击聚焦等待稳定后填写，不用坐标或DOM注入。登录阶段不保存表单截图、输入值或trace。`inspect`/`inspect-target`只读观察新页面及菜单，`verify-debug`只在图片预览点击前捕获异常class及静态栈行列并立即resume，不取局部scope、头或正文。

移动只能执行一次，`verify`可以只读复验；若本机确认或同步后失败，先检查回执与状态，不能盲目重跑move。本轮UI退出实际204/视觉已退出，严格logout阶段因即时Semantics漏字段仍失败保留，`logout-reload`真实重开保持退出通过。最终两个新账本及固定本人私有账户已普通墓碑清理，准备/核对/清理会话退出，自有Chrome进程0；本地profile保留合成测试证据，不宣称立即物理回收图片。综合回执`web-book-move-receipt.json`，逐阶段收据及辅助`web-book-move-server-receipt.json`均在忽略证据目录；全P6、无障碍和剩余手机验收未标完成。
