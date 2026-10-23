# 备份隔离独立Chrome验收

> - 职责：新合成备份的候选、零删除预览、当前密码确认、真实排队、独立CLI Worker与文件后验。
> - 入口：`quarantine_fixture.py`、`quarantine_serve.py`、`quarantine_acceptance.cjs`。
> - 不变量：仅新库/新包/新短profile；无覆盖、无purge；合成PGDMP不构成pg_restore证明；原管理session保持有效直至worker完成。
> - 必跑验证：静态编译/Ruff/Node语法；真实1280与390页面、键盘确认；原子移动后完整hash/receipt/control/audit/最近恢复点保持。
> - 相关：[隔离实现](../../../server/tests/backup_retention/QUARANTINE.md)、[清理分册](../../../AI/plans/flowtrace/backup-retention-controlled-cleanup.md)。

2026-10-23本轮新库`flowtrace_test_p5_admin_9469cda70890464c`显式从空库升稳定0016。夹具位于`outputs/validation/P5/admin/quarantine-641c2667e3254019844e41d63ad379c7/fixture.json`，凭据仅其指定的ignored私有文件。5个独特合成包中，2个旧候选、1个保留标记、1个未登记包、1个当前最近恢复点；仅登记4包、创建1个pin，准备会话已撤销。初始后验`postconditions-d2f0ceff6eaa44afab6da8a8d96eb921.json`证明5包hash/目录保持、无隔离、活跃会话0。

首新库`flowtrace_test_p5_admin_463a4bbc83914872`已保留：首次合成对象错误地命名为`objects/synthetic.bin`，正式验证器按64hex对象名规则拒绝`backup_manifest_path_invalid`，外层固定安全码为`backup_package_unavailable`。仅产生1个未登记合成包及3个合成账户，准备会话finally撤销；没有移动、删除或重置该库/文件。修正新脚本为实际对象SHA256.bin后，另建9469新库成功，未在463a重跑bootstrap。

静态Python编译/Ruff与Node语法检查通过。经主代理核对后，实际启动127.0.0.1:18096与本轮新`C:/ft-chrome/q-641c2667e325`；首次拒绝未经本轮owned marker绑定的已有目录。旧f38b包、所有恢复target及原有数据不参与。以下保留计划顺序，再单列实际失败边界。

执行顺序：`quarantine_serve.py --fixture`服务本轮固定fixture；`quarantine_acceptance.cjs enqueue`使用正常登录/表单，验证保护原因、显式2包preview、错误密码拒绝、新preview、390键盘密码/checkbox/按钮、真实pending行且无通用取消重试。该阶段正常关闭Chrome，刻意不登出原管理session。随后`quarantine_fixture.py worker --fixture --job-id`只允许本库唯一且精确匹配的pending隔离job，实际启动`python -m flowtrace_server.worker --once`，凭据只在子进程环境，记录自身PID并核真实完成。再运行浏览器`completed`阶段，核列表已完成/固定结果、两个控制行不可再选、recovery-only权限与service-only拒绝，最终正常登出。

`verify`分离核对来源2目录消失、目标2目录和效果receipt精确匹配、原字节逐SHA保持、3个保护包无变化、无覆盖、control版本1→3、job attempt1及独立enqueue/complete审计。验证只读，不伪造job完成、不修补receipt、不重置库。每次后验写新UUID文件，失败证据和所有包永久保留；最终是否0活跃会话及宿主退出另以实测记录。

## 第一轮实际结果：排队通过，整条失败

独立Chrome155.0.8059.85的`enqueue`阶段 **5/5** 通过，回执`browser-enqueue-20261022T201525260Z/receipt.json`：1280候选/确认范围、错误密码拒绝与无回显、新preview、390无横向文档溢出、键盘密码→checkbox→提交、正常CSRF提交、真实pending且无通用取消/重试。该阶段保留原管理session供worker，而不是登出后让执行器绕过原session。

实际CLI子进程PID53588运行`python -m flowtrace_server.worker --once`，真实job `d35f6af3-fd94-42d1-a166-0286c5f31ed2` attempt1失败，机器码`backup_package_unavailable`；进程退出不等于job成功，postcondition正确拒绝完成。intent `e8031ab6-7cb1-47c7-8c7f-f2a9ecd6ba54`保持：第一选中包a004cced已从来源移动到隔离target，缺receipt；第二包c2976e4d仍在来源，target/receipt不存在。两control均reserved v2，未改成quarantined，也没有重试、补receipt、删除或移回。

只读`windows-path-failure-readonly.json`记录：来源成员最长219字符，隔离目标最长274，receipt203。目标274字符对象的普通lstat失败，安全栈为`service.verify_backup:446 → private_files.regular_file:51 → pathlib.lstat/stat`，FileNotFoundError(errno2,winerror3)。同一受控对象用extended prefix仅只读核对40字节/原SHA一致；这不是执行绕过或修补receipt。根任务另在新pytest目录真实重现并修生产Windows I/O，原641c现场永久保留，不以短data root掩盖。

随后`failed`观察阶段 **1/1** 只证明真实失败行/固定错误码、1280/390页面、无取消重试、reserved不可再选和正常登出；`overall_quarantine_acceptance`仍明确failed，不能将观察通过写成完整隔离通过。回执`browser-failed-20261022T201736286Z/receipt.json`。已实际查看desktop确认、390键盘确认与失败列表截图。

`failed-run-preserved-postconditions.json`核5包所有原成员SHA均保持（第一包只读extended前缀），3个保护包和第二包未移动；active sessions0。`host-closed.json`记录先核exact fixture/CommandLine后仅停止监听PID25836，venv parent1248随后退出；18096监听0，ownhost/该profile Chrome进程均0。库、profile、全部包、缺receipt partial与旧失败保留。成功`completed`阶段尚未执行；后续须生产修复后另新UUID同深度fixture复跑。

## 第二轮实际结果：完整隔离主路径通过

2026-10-23（Asia/Shanghai），生产Windows受控I/O修复后，另建空库`flowtrace_test_p5_admin_6bc3f41e05d34ac3`至0016；新夹具为`outputs/validation/P5/admin/quarantine-2890b2d602254dc7a51955b3a945e67a/fixture.json`。服务资料根仍用原本相同深度的`work/flowtrace-dev/p5-restores/<UUID>`，没有通过缩短服务器路径规避274字符成员；只有Chrome采用独立短profile `C:/ft-chrome/q-2890b2d60225`。初始后验由主代理另行复核5包保持、无隔离、无活跃会话，获准后才启动18096服务。

同版独立Chrome实际`enqueue` **5/5**，回执`browser-enqueue-20261022T202247803Z/receipt.json`，包括错误密码拒绝后新建preview、390键盘显式确认与真实排队。实际CLI `python -m flowtrace_server.worker --once`使job `5ef999ac-1aaa-44ee-99ab-5458e000d1f4`在attempt1成功，固定结果`backup_quarantined`，intent `13ef3496-2476-445f-82d8-4ecab455c487`。随后普通页面`completed` **3/3**，回执`browser-completed-20261022T202308956Z/receipt.json`；真实完成行没有通用取消/重试，隔离后控制状态不可再次选择，recovery-only可读候选但配置403，service-only候选403且不泄露目标ID。两角色与owner均正常退出。

最终只读`postconditions-b025ef4529264f45abafbfc9bc7e6fb9.json`证明2来源目录消失、2隔离target及完整receipt精确匹配、5包所有原成员SHA保持、其余3保护包未变、无覆盖、control可用v1→预留v2→隔离v3，入队/完成审计各1、活跃会话0。Windows目标后验只对固定已移动target使用extended路径，仍执行原regular-file/link与全SHA验证；该只读适配不生成receipt、不重试效果。本人已查看1280完成页及390窄屏截图，主代理另行亲看验收。合成PGDMP只证明hash移动与控制闭环，不构成pg_restore、Linux运行或跨断电持久性证明。

`host-closed.json`记录核exact fixture/CommandLine后仅关闭监听PID23216，venv父33292自动退出；18096监听、ownhost及本轮profile Chrome进程均0，所有资料保留。第一轮641c缺receipt的partial/reserved现场、首463a命名失败包、旧f38b包与所有恢复target均未触碰。本轮没有purge、自动清理、提交、推送或持久部署。
