# FlowTrace 验证入口

当前已建立契约、页面与合成场景，并执行P1工程/领域、P2身份同步及P3/P4的分项验证。本文件描述入口和前置，不替代各模块的实际通过记录；进度及运行回执见 [计划进度](../AI/plans/flowtrace/progress.md) 和当前任务日志。

## 测试层与权威输入

| 层 | 入口 | 验证范围 |
|---|---|---|
| 证据/契约资产校验 | `contracts/fixtures/parity/`、`ledger/`、`api/`、`sync/`、[scenarios](../contracts/fixtures/scenarios/README.md) | JSON结构、编号/证据路径、预期值自洽；资产校验不等于应用运行 |
| Flutter单元/组件 | `apps/flowtrace/test/` | 精确金额、本地事务/迁移/outbox、显示与交互状态；native临时库/合成样本 |
| 服务端单元/集成 | `server/tests/` | 领域、权限、API、同步与作业；涉及锁/并发的测试必须使用真实隔离PostgreSQL |
| 跨端契约 | `tests/contracts/` | Dart/Python对同一金额/权限/同步夹具的实现结果；不通过重写期望迎合实现 |
| 用户端与后台E2E | `tests/e2e/`、`apps/flowtrace/integration_test/` | Android设备、用户Web/后台真实浏览器、Windows原生；J01–J12/E01–E20和平台恢复 |
| Linux安装/恢复 | `deployment/linux/`及独立实例 | 无Docker空环境、API/worker/后台/Web、迁移/备份/附件校验、升级回退 |

[金额时间](../contracts/money-time.md)、[账务](../contracts/ledger-rules.md)、[权限](../contracts/permissions.md)、[同步](../contracts/sync-v1.md)、[API](../contracts/api.md)、[附件](../contracts/attachments.md)、[作业](../contracts/jobs.md)是实现期望权威。S01–S56 是参照界面状态，不能直接当56个路由；映射见 [ui-map](../contracts/ui-map.md)。

P3页面验收使用[独立Chrome测试实例](e2e/client-web/README.md)，预算创建/修改/沿用、日历实际保存、重开报告、关键词搜索和真实图片ZIP下载/原字节校验已通过；合成账本清理与会话退出已完成。退出同页的语义控件遗漏仍按失败保留，关闭重开的退出状态另项通过，不标完整Web或无障碍通过。启动浏览器、HTTP准备和页面验收分别记录。

后续[P4资产专项](e2e/client-web/P4_ASSETS.md)的固定c974普通main已通过业务、字体/反馈和即时退出ARIA/公开Tab输入、重开及正常清理，原P3/ae/4897失败保留历史。其后[退款报销追踪部分](../AI/modules/reimbursements.md)新源码完整客户端602通过/5默认live跳过、完整分析无问题；服务端完整425（含12 PG/ASGI）及后续18086 socket1通过，schema窄修合同21/33组等效比较另列。602尚未构建新Web/Android产物；读取Repository、完整回款UI和typed复合未实施，不能据单元数称P4或P6完整通过。

## 隔离约定

- 使用合成用户 alice/bob/carol/operator/recovery；测试时生成独立凭据，不能复用用户真钱账本、现有钱迹账号或生产会话。
- API推荐127.0.0.1:18080；Web/后台浏览器、数据库/临时目录使用每轮独立端口或明确隔离标识。连接字符串与控制入口必须显式标记测试环境。
- Native SQLite测试用临时目录；Web用独立来源/浏览器资料空间；Android只使用FlowTrace专用测试包/设备；Windows升级在独立账号/数据目录演练。
- 重试、冲突、撤权、丢回包、两事务晚提交和worker失租用可控故障点/屏障验证。SQLite不能代替PostgreSQL行锁、隔离级别或提交顺序测试。
- 准备好的Web应用壳才能断网冷启动；数据库持久化成功不代表离线资源缓存已可靠。Windows构建成功不代表安装升级已通过。
- 运行证据保存在本地忽略目录 `outputs/validation/P阶段/`；提交可复现的测试与脱敏夹具，不提交原始账本、令牌、图片中的私人内容或主机秘密配置。

## 验证命令与前置

以下命令只有相应工程、依赖和环境实际存在时才可执行。某层缺环境，记录未运行与补验条件，其他独立测试继续。

```text
apps/flowtrace/:
  flutter --no-version-check analyze --no-pub
  flutter --no-version-check test --no-pub
  flutter --no-version-check build apk --debug --no-pub --target-platform android-arm64
  flutter --no-version-check build web --no-pub --pwa-strategy=none --no-web-resources-cdn
  flutter --no-version-check build windows --no-pub

server/，使用工程虚拟环境：
  python -m pytest tests

仓库根目录，使用server虚拟环境解释器：
  python -m pytest tests/contracts tests/e2e
```

Flutter依赖首次准备使用 `flutter --no-version-check pub get`，当前SDK的生成入口为 `dart run build_runner build --force-jit`。同一工程的生成、测试和构建串行执行，避免Windows原生资源争用；不要手改生成文件。

Android基础集成使用 `flutter --no-version-check test integration_test/foundation_test.dart --no-pub` 并通过 `-d` 指定当轮实际授权设备。`identity_test.dart`、`sync_test.dart`、`ledger_test.dart`还要求18080隔离服务和忽略目录中的合成QA参数，通过 `--dart-define-from-file` 注入；先配置该设备到本机18080的ADB反向转发。测试完成后使用不含QA参数的常规main构建替换测试APK。测试仅操作FlowTrace debug包，禁止使用钱迹真实账目。

当前 SDK 的 `flutter test` 设备清理会卸载集成包，应用私有文件随之删除。需要长期截图/回执时，应在卸载之前由受控宿主导出，或使用支持 onScreenshot 的官方驱动；只调用 binding.takeScreenshot 不证明图片已导出到工作区。Android OS 终止测试应采用手动安装的独立 fixture APK 与宿主分阶段控制，不能将 Flutter 测试连接被杀后报断线当作业务通过。具体下一项设计见[Android 平台验收](e2e/android/README.md)。

命令可执行不代表所有平台均已验收。设备回执必须包含可追踪设备标识/系统版本，浏览器包含引擎/版本/来源，Linux包含发行版/数据库版本及恢复目标。凭据与完整设备serial仅留在忽略的本地环境记录，文档使用脱敏追踪名。

## 当前环境结论与完成标准

当前使用Flutter3.38.3/Dart3.10.1；授权真机PLT140（Android16/API36，arm64-v8a）已有debug构建、安装、基础与身份集成结果。真实Edge已完成本地持久化和身份主路径；本机便携PostgreSQL18.6提供隔离数据库，不能用SQLite替代服务端并发验收。Windows仅确认C++链与原生SQLite测试，桌面构建/运行未完成；WSL/Linux仍缺环境，用户已同意先本地开发。完整回执和边界见 [platform-validation](../AI/plans/flowtrace/platform-validation.md)。

最新约束：用户2026-10-22确认手机重连，本轮独立fixture的真实选图/取消/超限及同APK无重装force-stop/COLD只读恢复已通过，普通main已恢复安装冷启；完整跨功能旅程仍待后续。首次OEM协议由本人同意，原QA只读失败保留。浏览器另起独立Chrome测试profile，不操作用户Edge；上述Edge结果为历史证据。

单元、编译、真实设备、浏览器、数据库并发和恢复分别报告。业务完成以具体场景的输入/输出、权限和账务结果为准；“能打开”“返回200”“命令存在”“夹具校验通过”均不能单独证明业务成功。每项结果记录 passed/failed/not_run/blocked，必要场景未运行时总体不能标为完整验收通过。
