# 大文件迁移普通页面验收

> - 职责：验证普通 Flutter 页面中的原件持久化、资源映射、真实作业状态、显式导入/撤销和受控释放。
> - 入口：`apps/flowtrace/lib/features/data_tools/stage_import_panel.dart`；协议与持久化位于 `apps/flowtrace/lib/data/data_tools/stage_import_*`。
> - 不变量：原件落盘先于 HTTP；资源清单完整 SHA 核对后才确认映射；作业摘要不等于金融结果；正式结果通过 fresh group pull 和随后状态复核取得。
> - 必跑测试：`apps/flowtrace/test/data_tools/`；真实页面必须使用普通 main、隔离服务、真实 worker 与新 UUID Chrome profile。
> - 相关：[数据工具](../../../AI/modules/data-tools.md)、[大批实施](../../../AI/plans/flowtrace/large-import-implementation.md)、[已有小批浏览器记录](../import_restore/BROWSER.md)。

## 当前实现与验证

2026-10-23，客户端数据工具同次 **122/122、10秒** 通过，`outputs/validation/P5/stage-ui-tests2.log`；窄静态检查 `stage-ui-analyze5.log` 无问题。包含原有小批流程、schema5暂存与恢复、分片续传、映射/显式续接、真实 SQLite 事务失败回滚、完整页面五条 widget 旅程。这些是客户端目标测试，尚不能当成真实普通 Flutter/HTTP/worker/Chrome 金融旅程通过。

随后主代理的 schema5 完整客户端回归 **1009通过、6项专用 live 默认跳过、59秒**，完整 analyze 无问题（8.1秒）；122已包含，不另相加。新的普通 Web 候选 `apps/flowtrace/build/web-stage-20261023-c5e8` 构建59.5秒，seal39资源，实际 main SHA `3431f09c812458c899d3ca259b6cddbee1186d37d030de9e4cd227bf1fee3101`，release `e4d63f16e2ad6471fe3afb8b8f4b974d43cf93828e464172a09268f7650e821c`。这是构建/封装结果，尚未作为浏览器通过。

生产图片共享黄金另由真实 Dart 四条输出，经 Python 正式 `open_stage_source → operations_for → target_ids → plan_transfers` 反核 **4/4**：原生原图→实际上传ID→同批来源账本，以及钱迹名称→上传ID→现有目标账本；重选时只移除没有剩余引用的旧 transfer。回执 `outputs/validation/P5/stage-image-dart/f2fc323a-476d-451d-91d2-38a2f25562e5-python-verified.json`。这是纯映射与生产 planner 联核，不代表真实网络上传或金融写入。

首轮 `stage-ui-tests1.log` 的118通过/2失败保留。失败来自测试在用户尚未回答确认对话框时调用 `pumpAndSettle`；页面在此期间刻意 busy，等待明确确认。夹具仅在开对话框步骤等待动画并断言真实对话框、目标按钮与更新屏障，确认后仍等待操作完成。未减弱网络/事务完成断言。首次静态错误和 `XFile.fromData` 合成路径问题也保留原日志，不回写历史通过数。

## 普通页面行为

在设置中的“数据迁移与导出”进入“大文件导入”。原有普通小批导入、导出和本人历史仍保留。钱迹原件需先选择目标账本；保存时只冻结最小模板方向，不从错误行猜资源名称。未协商 `import-stages-v1` 时可保留本机原件，任何服务器动作都关闭。

完整原件最多50MiB，每片不超过512KiB，实际 BLOB 持久化后才发创建/上传请求。重开继续使用原 stage ID、正文和 SHA；账号或 epoch 变化保留原输入，不隐式重新授权。源、分片、命令和独立恢复 BLOB 具有实际容量边界；释放真实活跃 BLOB 后才释放配额，恢复副本保持独立。

资源逐页最多100项。选择即时写本机草稿；重开从第一页重新计算完整清单 SHA，原选择保留。未到末页、未选完或原图所属账本尚未保存时不能确认映射。当前正式请求最多1MiB，草稿也受1MiB及每空间16MiB实际 JSON 字节限制；20万条清单的协议上限不表示20万映射能一次提交或已获性能验收。

图片必须本人选择并通过正式附件接口上传；若原件包含真实 manifest，会核字节 SHA、大小与格式。不抓原链接，不虚构上传 UUID。原生同批图片所属账本来自独立 `source-books` 元数据，和现有可用账本分列显示；此信息不授写权。临时修改图片所属账本期间阻止更新，必须完成上传保存或明确放弃该未保存选择。

“刷新任务状态”只读取真实 `jobs` 摘要。文件 `ready` 时，apply 作业仍可能排队、执行或失败；已有任务不会被客户端自动重排。“确认正式导入”和“撤销这次正式导入”都显示目标确认。收到作业 ID 后继续读真实 stage；仅在 fresh group pull 成功且随后状态/版本/映射/预览仍一致时显示资料已同步。全程不发 sync push，也不从作业结果伪写本地账务。

本人新会话先只读核原件来源，再明确续接；普通 GET 成功证明确实绑定当前 session/client，不能仅凭 probe 的新版本冒认绑定。已发布且已释放本机原件仍可显式续接与正式撤销，不要求重新上传。取消或过期的未发布暂存使用独立 owner discard，实际确认取消后才原子删除本机副本，原输入历史和旧 binding 保持。

## 真实浏览器下一步与证据要求

使用新 UUID 空测试库及受控合成账号，API/Web 选独立 loopback 端口，源文件和凭据仅放 ignored `work`。本轮 profile 使用 `C:/ft-chrome/st-8bb7c19397ba`，首次启动拒绝未经本轮owned marker登记的已有目录，保留所有旧profile。该策略延用本机短路径已验观察，不宣称Chrome通用路径上限。不连接个人浏览器、不使用 Edge、不改系统代理或下载工具；不迁移或清理历史 QA 库/原件/失败现场。

浏览器必须校验实际收到的普通 `main.dart.js` SHA，正常填写服务器地址和登录表单，通过可见控件、真实系统文件选择事件与手工状态刷新完成操作。读取数据库或 HTTP 的后验可以独立核对余额、正式批次、原图 SHA 和 publications，但不能代替任何 UI 步骤。不得注入 token、私有 Dart AppState、本地 SQLite 或下载产物以绕过用户路径。

计划顺序为：多片本机原件保存与重开 → 真上传/parse worker → 完整资源清单与图片选择 → 映射后重新解析 → preview worker → 逐行预览/显式 apply → worker 完成/真实 fresh group → 关闭重开核本地资料 → 显式 undo → worker/group → 服务器与本机原件分别受控释放。每阶段记录真实作业状态与安全字段；失败保留截图/语义/响应摘要，不跳过后继续报告整条通过。

普通 main 已接17个 stage 操作和对应能力，主代理已验证实际入口。真实浏览器专项尚未执行；之后将另录固定候选、独立服务、profile、worker 与具体成功/失败回执。

本轮新增 `stage_import_journey.cjs` 提供分阶段可见页面操作，命令参数依次为阶段、已seed私有fixture、固定构建目录、实际main SHA、`native`或`qianji`；没有seed证据、固定端口、私有目录边界或SHA不一致时拒绝启动。`serve_stage_web.py`只在127.0.0.1:18194服务同一sealed候选，必须显式传fixture/build/main SHA；它不会启动API、worker或浏览器。当前仅执行 Node语法检查和Python编译/Ruff，未启动服务或Chrome。fixture与TCP准备由独立 `tests/e2e/import_restore/stage_harness.py` 所属任务维护，浏览器来源不得与另一TCP金融链共用actor/namespace。
