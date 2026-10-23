# 普通 Web 数据迁移浏览器记录

职责：用普通客户端、合成文件和独立服务验证实际迁移路径，保留失败和恢复事实。
入口：本目录的 `prepare_browser_fixture.py`、`serve_browser_fixture.py`、`browser_journey.cjs`。
不变量：不使用个人浏览器/Edge，不注入应用状态或令牌，不在UI外创建金融实体，不重置数据库，不盲目重发已尝试的写入。
必跑验证：固定构建SHA、实际UI路径、独立只读账务/原件核对、真实下载解析、关浏览器后的离线冷启动。
相关材料：[服务端与客户端目标](README.md)、[数据工具模块](../../../AI/modules/data-tools.md)、[大批迁移分册](../../../AI/plans/flowtrace/large-import-implementation.md)。

## 本轮事实与恢复位置

2026-10-23使用普通 `web-p5-integrated-20261023-6f72`（`FLOWTRACE_LOCAL_TEST=true`，没有QA Dart入口），main SHA为 `40db38642e86bf075386b14aa138b2e60488c6bf4925e758da079b8fe0eccac6`。独立安装的Chrome155使用新的 `chrome-data-tools-7aaf19a612db45c89a4ab688ffaaf205` profile，没有连接用户Edge或个人Chrome会话。

独立服务为API18090/Web18190，新UUID库为 `flowtrace_test_p5_backup_source_0b7c361a11514669`。准备阶段仅创建合成测试用户和默认账本，六行迁移业务及原图通过普通页面导入。初始head0010；浏览器全部关闭后，自有测试库加法升级至0011，instance/epoch、预览零写入及原件再次核对，然后恢复同prepared批次。没有重置或重新seed。验证结束已正常退出账号、关闭此profile的Chrome，两个临时服务均停止；这不是最终持久测试部署。

主要回执位于 ignored `outputs/validation/P5/7aaf19a612db45c89a4ab688ffaaf205/`。`browser-functional-slices-summary.json`连接各次实际UI、下载及只读证据，结果明确为 `functional_slices_completed_with_recorded_accessibility_gap`，`all_attempts_green=false`，不把状态不同的历史运行合成“全程无失败”。准备文件、口令和后端附件在 ignored `work/p5/browser/`，profile在 ignored `work/flowtrace-dev/browser-profiles/`，不纳入版本。

## 已执行路径

- 原生JSON含新账本、本人私人现金账户、分类、标签、支出125分与退款25分，另有一张77byte PNG。UI文件选择→原图选择并上传→六行预览通过；独立读取证明preview没有batch/目标实体/分录/引用，图片仍本人私有孤儿。
- 关闭整个Chrome，offline冷开普通首页和完整sealed缓存通过。恢复联网后，在本机未完成迁移中继续原预览，二次确认后导入；初次preview与正式apply具有相同batch ID及请求SHA `1f7c170faaa889c7bfa348b0cf1c757fd2406604bb05e3d8f291ee7d63170bca`。正常同步回拉后的资产页及只读PG余额均为9900分；退款来源、month_start_day15/display_mode year/show_assets及原图SHA一致。
- 公开钱迹V10 CSV由UI选择目标账本和账户/分类/标签映射，再预览、关Chrome、恢复同请求确认。两笔同额125分的不同source ID分别保留，余额9650分；同文件再次导入为created0/duplicates2，余额不变。
- JSON及嵌原图Excel均通过实际浏览器下载。独立解析每份8实体，验证精确字符串金额、退款来源、两笔不同ID、授权相对图片链接和XLSX原件77bytes/SHA完全一致。实际文件/下载回执由 `verify_browser_downloads.py`核对。
- 操作历史中选择“新增2条”的CSV批次，UI预览和确认撤销。正式undo200，页面实际显示“迁移已撤销，本机账本已刷新。”，PG余额恢复9900；脚本最初误期望另一句成功文案，所以原运行仍记failed。修正文案后不重发undo，冷开只读页面/数据库确认通过，实际原成功截图和ARIA保留。
- 全关Chrome后offline冷开，资产余额99.00、搜索原含图支出、详情中的生产图片预览/真实`img`均通过。该3×2纯色图截图边界受子像素抗锯齿影响，未谎称截图与原PNG字节相等；另核对4个内部像素RGB，原图字节身份由实际XLSX下载与后端文件SHA证明。
- 原生首批账户经后续CSV创建/撤销触及revision，服务端正确拒绝其整批撤销。未回写revision或放松冲突规则。另通过同一普通UI导入新source/namespace、独立账本/账户/原图六行，证据在 `remote-case-6f3ebad3/`。
- 第二client独立HTTP模拟立即撤销这组新批次，和UI证据分开。首次模拟undo提交后，脚本误读history的`items`（实际`batches`）报KeyError；持久intent阻止重发，`--recover-only`只读正式undone元数据及原图退回user scope/hash。再次全关Chrome正常开DataTools，观察到精确batch_id历史GET200、当前私有原图metadata/hash重新授权、没有apply/undo重发；远端删掉的账本/账户从UI移除，第一组账户99.00仍保留。
- 正常UI退出→冷开重新输入凭据登录→完整缓存就绪→再正常UI退出通过。凭据不进入截图、ARIA或回执；测试用户名在已登录页面属于合成数据。

## 失败与未闭合项

已确认的客户端无障碍缺口是：保存服务器地址并立即打开账号页，表单肉眼可见但语义控件缺失；同地址冷开不再次configure时，用户名/密码/登录控件完整且实际登录通过。该转换路径尚未修复，截图与ARIA保留，不能称为全绿浏览器验收。

其他已保留的验收脚本/合成数据修正包括桌面常驻导航栏与虚拟列表定位、初始CSV时间误含秒（公开格式要求分钟）、撤销成功文案及HTTP历史字段名。旧文件、失败回执与只读恢复结果都保留，没有将失败记录覆盖成passed。API进程尾部日志保存为 `api-18090-session.log`，受工具输出预算截断，仅作辅助，不当完整请求审计流。

此轮没有验证Windows原生迁移、真实钱迹私人导出、Linux部署恢复、50行以上公开导入、1000实体以上公开导出、stage/worker/group的端到端原子迁移；这些完整目标保持未验收。

## 可续跑工具

本机新的测试轮可使用已有受限数据库创建器，输出只含新env路径，不打印口令；准备器拒绝非空库，不得对本轮已seed数据库再次调用：

```powershell
$fresh = server/.venv/Scripts/python.exe work/flowtrace-dev/prepare_p5_restore_database.py --purpose backup_source | ConvertFrom-Json
server/.venv/Scripts/python.exe tests/e2e/import_restore/prepare_browser_fixture.py --env-file $fresh.environment_file
```

`serve_browser_fixture.py api`只服务该manifest指向的UUID隔离库，`web`只服务构建目录内、mainSHA完全相符且含release seal的普通候选。`browser_journey.cjs`参数依次为阶段、fixture路径、构建绝对路径、可选的明确mainSHA；它只支持源码列出的固定UI阶段，每次单独启动/正常关闭自己的profile，阶段之间允许断网和全关浏览器。更新候选时必须显式提供新构建SHA，不沿用旧hash。

`verify_browser_state.py`只读核对独立PG和原图文件；`verify_browser_downloads.py`只解析真正下载的文件；`summarize_browser_journey.py`保留failed状态并校验冻结请求、实际undo、只读恢复和跨设备证据。`simulate_remote_undo.py`明确是外部第二client模拟，持久intent存在时默认拒绝再次写入；`--recover-only`没有undo POST。
