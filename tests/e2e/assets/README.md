# 资产与币种隔离联测

`server_smoke.py` 验证已安装生产wheel的真实HTTP，不替代Flutter客户端、浏览器或Android验收。固定18085与 `flowtrace_test_assets_local`，只接受loopback55432、owner `flowtrace_dev`、两URL一致的忽略环境文件 `work/flowtrace-dev/postgresql/server-assets.env`；禁止reset/drop，不改18080。端口被占时直接拒绝，不杀他人进程。

先显式构建、以生产锁安装wheel到 `server/.wheel-assets-venv`。脚本用 `-I -S` 并固定site-packages，拒绝editable且逐字节比对包资源；不通过当前源码冒充发行包。

```powershell
server/.wheel-assets-venv/Scripts/python.exe -I -S tests/e2e/assets/server_smoke.py
```

当前实际36个HTTP检查通过：ready/真实OpenAPI、静态目录、冻结组/估值回放、完整资金转账/原币/冻结率、估值独立、明细/历史/信用卡、陌生拒绝、非空组拒删及正常墓碑。最终合成会话退出，受控线程停止，脱敏结果为 `outputs/validation/P4/assets-wheel-http-receipt.json`；原始凭据不出进程、不存源码。脚本失败时同样撤销本轮合成会话并停止自己的线程，保留夹具供诊断。

Windows完整服务端测试用 `python -m pytest` 或真实文件的 `if __name__ == '__main__'` 入口；stdin中的pytest.main会使multiprocessing spawn无法恢复入口。411项完整回归及新增2项RR竞态的命令/环境见 [服务端模块](../../../AI/modules/server.md)。本目录不执行Linux、Docker、浏览器或手机操作。

## Flutter VM真实HTTP

在主代理授予独占Flutter窗口、冻结参与生产源后，从仓库根运行：

```powershell
server/.wheel-assets-venv/Scripts/python.exe -I -S tests/e2e/assets/client_harness.py
```

`client_harness.py`启动同一固定候选wheel的受控18085线程，为两个新合成账号创建隔离磁盘SQLite/附件目录，再运行 `apps/flowtrace/test/live/assets_http_test.dart`。它使用生产身份、配置冻结队列、同步、账务、附件与资产读取仓储；测试vault为内存夹具，不作为OS安全存储验收。账号、密码、访问凭据及本机库只在忽略目录中；默认完整客户端测试不设置环境变量时跳过此live目标。

2026-10-22重跑 **1/1通过（Flutter约6秒）**。真实链覆盖：已提交POST丢响应后原操作/原JSON字节重试且仅一回执；组获确认后账户同步且不把组写depends_on；100CNY→12.50EUR及独立0.25CNY手续费；18位手工估值8→9不改变原单两币金额和0.125冻结率；本人分录/历史/信用卡typed读取；共享撤权使读取缓存和受控下载删除、nonce递增，而原件/草稿/冻结配置意图保留。重新授权后正常删除四账单与账户，独立SQL确认余额恢复为100000/0/−10000、有效分录/附件refs均0、配置revision11及唯一回执。最终两合成会话活跃数0，18085受控线程停止。脱敏正式回执为 `outputs/validation/P4/assets-client-http-receipt.json`。

保留首轮真实失败：`work/flowtrace-assets/live/20261022-001431-ab5f7cf0/flutter.log`在正常删除后的余额断言失败。服务端和本机canonical已为精确期初余额，且公共/私人删除墓碑revision2均已拉取；客户端无法区分已拉取墓碑与只有ACK而缺正文，错误地继续显示余额不可用。主代理补删除确认proof及回归后，上述原金额期望不变重跑通过。初轮合成会话同样退出、服务关闭，没有用重建/额外pull绕过该缺陷。

这是真实Windows Flutter VM/文件SQLite/原件文件联测，尚不等于浏览器页面、Android或Linux验收。

## 独立Chrome夹具准备

`web_fixture.py`只管理新合成数据和自有API线程，不启动浏览器。默认 `check` 仅检查固定wheel和18085空闲；显式 `prepare` 从产品冻结的 `tests/e2e/client-web/p4_assets_scenario.json` 加载金额、账户、期望和占位日期。它使用Asia/Shanghai准备日，正常种子命令建立七账户、一个账本和支出分类，撤销种子会话；不会根据运行页面反推预期。非cleaned旧manifest拒绝覆盖，不reset/drop测试库。

```powershell
server/.wheel-assets-venv/Scripts/python.exe -I -S tests/e2e/assets/web_fixture.py check
# 以下两步分别等待主代理授权；prepare不启动服务，hold不再迁移。
server/.wheel-assets-venv/Scripts/python.exe -I -S tests/e2e/assets/web_fixture.py prepare
server/.wheel-assets-venv/Scripts/python.exe -I -S tests/e2e/assets/web_fixture.py hold
```

公开忽略manifest为 `outputs/validation/P4/web-assets-fixture.json`；仅合成用户名/密码存于其引用的 `work/flowtrace-dev/assets-ui/<run_id>/credentials.json`。`hold`核对用户/账本/instance/epoch及候选包，绑定18085且仅允许18185 Web来源；在同一私有目录创建 `stop.request` 后关闭自有线程。真正Chrome步骤由[页面验收脚本](../client-web/P4_ASSETS.md)和主代理协调，固定P3的18080/18181及用户浏览器不在操作范围。

2026-10-22已在主代理放行后完成全新Web种子准备：七账户/账本更新/支出分类共九个正常命令全applied，种子会话0；场景原文SHA随manifest保存，日期按上海22日解析，初始净80000、估值8为71975、估值9为73225均来自事先固定预期。随后独立hold ready200供Chrome验收，未复用native已墓碑夹具。准备与持服只证明环境就绪，浏览器结果另由实际阶段回执给出。

`web_cleanup.py`默认check只读取本run绑定；audit只读核对精确八账户/六资金单/一组/两条报价历史，拒绝未知对象。cleanup仅在主代理最终放行、完成logout-reopen回执且会话0之后，以`--confirm-run`指定精确run UUID执行正常业务墓碑。先删资金单并证明期初完全恢复，再删账户/分类、空组/报价/恢复默认偏好，最后删账本；不重写期初、不直接SQL删实体、不reset。已有清理尝试记录时拒绝盲重跑，要求查看实际收尾状态。

原本机18080的候选升级[准备方案](LOCAL_UPGRADE.md)单列了备份/隔离恢复、0005→0006、原目录/instance/epoch保持及回退边界；目前只准备，没有执行该切换。
