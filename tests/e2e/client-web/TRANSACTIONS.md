# Web SQLite 事务诊断

此专项使用生产 AppDatabase、LedgerRepository、LocalRepository 和 SyncStore，运行于独立 Chrome profile 与唯一 `flowtrace-probe-UUID-mode` 数据库。它不打开 `flowtrace` 应用库、不登录、不读取账号、图片或个人浏览器资料，不访问18080。诊断静态服务仅绑定回环18184并发送与应用相同的COOP/COEP头。

## 已证实的失败和修复

Chrome155.0.8059.85 / Drift2.34.4锁版worker / SQLite WASM3.5.2、真实OPFS锁存储中，最小原始 `db.transaction` 嵌套不涉及账务或watch：内层写入、内层Future返回后，外层提交30秒未完成。预算保存、4个并发watch加预算保存也各停30秒，无pageerror。初始回执为忽略目录 `outputs/validation/P3/web-transaction-probe-886ab112-d8e6-4cf3-9cba-61f336a439eb.json`，保留原失败而不覆盖。该证据定位到锁定Web组合的原始嵌套事务边界，不断言未经证实的上游内部函数缺陷。

应用改用单个 `atomicWrite` 外层事务，内部帮助函数共享事务；读投影用 `readSnapshot` 复用既有快照。内部写失败使整次写入仅能回滚，即使调用者捕获异常。原始 Drift transaction 保持原语义和实现，没有修改worker、SDK、包缓存或数据库版本。

修复后的完整专项回执先为 `web-transaction-probe-fdec792f-b9cc-499a-a55d-0212424a0914.json`；随后改为只使用公开transaction回调上下文，重新编译4.75秒，最终回执 `web-transaction-probe-a75f50ee-153f-41f0-97e7-5975b16ab049.json` 再次4/4场景通过，四组各自关闭数据库后重新打开4/4通过，无pageerror：

| 场景 | 实际核对 |
| --- | --- |
| Repository预算保存 | 实体2、outbox1；已有原始事务中的读取能结束 |
| 4个并发Ledger.watch下保存 | 四条流均得到提交后的变化，实体2、outbox1 |
| 回滚及恢复后再保存 | 捕获inner失败仍无marker；有效支出+非法tag整批回滚到实体2/outbox0/hints0/余额20000；随后预算可正常保存 |
| SyncStore冲突替换 | nextPush冻结→reject→resolveWithNewCommand完成，旧operation discarded、冻结字节不变，冲突为空、新outbox1 |

所有重新打开均核对预算10000最小单位和一个待发送操作；只接受精确字符串金额。上述专项不替代正常main预算按钮、图片ZIP下载、Android或P6全量验收。

## 复现命令

先在仓库根目录创建 `work/flowtrace-dev/web-transaction-probe`，复制锁定的 `apps/flowtrace/web/sqlite3.wasm` 与 `drift_worker.js` 到该目录，写入仅含UTF-8 meta与 `probe.js` script标签的index.html。诊断编译输出与正常 `build/web` 分离：

```powershell
# 在 apps/flowtrace 下执行；Flutter pub/build/test 窗口须先协调。
& C:/Ruibin_Ningh/app/FlutterSDK/flutter/bin/dart.bat compile js --packages=.dart_tool/package_config.json tool/web_transaction_probe.dart -o ../../work/flowtrace-dev/web-transaction-probe/probe.js

# 回到仓库根目录，在独立受控进程中运行，结束后正常停止该进程。
& server/.venv/Scripts/python.exe tests/e2e/client-web/serve_probe.py

# 另一个终端运行；使用已安装Chrome，不下载浏览器。
$env:NODE_PATH = 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules'
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/client-web/transaction_probe.cjs
```

fixed模式任一场景失败、超时、重开失败或pageerror会返回非零。显式参数`baseline`保留原始嵌套事务诊断，其超时用于故障证据，不纳入修复通过数量。每次启动新UUID profile，finally关闭自身Chrome；没有连接用户Edge或已有Chrome。当前专项已经关闭自有Chrome和18184服务，未重启18080/18181，未调用ADB。
