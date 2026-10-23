# M1 Alpha候选清单

> 状态：M1完成，候选已冻结；尚非最终发行。日期：2026-10-24，Asia/Shanghai。
> 来源：本地恢复提交`0926681058789da10ae75074bb236c43743dc853`；旧客户端按各自构建快照追溯，不冒称由该commit构建。
> 恢复入口：[里程碑](alpha-milestones.md)、[进度](progress.md)。后续M2须用户另行决定。

## 实际产物

统一冻结目录为`outputs/releases/alpha/m1-20261024/`，完整路径、源位置、SHA256和边界保存在其中`CANDIDATES.json`。冻结保留旧包，没有覆盖构建目录或私人数据。

| 候选 | 冻结产物 | 版本与本次验证 | 使用边界 |
|---|---|---|---|
| Windows | `FlowTrace-0.1.0+1-windows-x64.zip`，29,202,962B | 普通main、local-test、qa=false；ZIP CRC/安全集合、26文件逐hash通过，CRT三DLL签名有效 | 应用未签名；旧schema3；此前窗口/草稿ARIA/SQLite启动已验，完整原生UI因锁屏未验 |
| Web | `Web/`静态目录，41文件、53,365,981B | 复用a3d9，内置0.1.0+1；39业务资源加manifest/worker全部hash及绑定通过 | 需HTTP服务，M1未生成Web ZIP；既有普通Chrome地址/冷启离线已验，本包未重复浏览器旅程 |
| Android | `FlowTrace-0.1.0+1-android-arm64-debug.apk`，123,295,330B | `com.flowtrace.flowtrace.dev`，min24/target36；普通入口同hash历史回执/构建stamp交叉核对，APK v2签名通过 | Android Debug签名、debuggable/明文HTTP允许、ARM64；构建于2026-10-22，schema3，未恢复ADB/安装 |
| 后端 | `flowtrace_server-0.1.0-py3-none-any.whl`，425,738B | 现成wheel缺本地服务入口，唯一补建；head0016，220源码成员逐字节匹配，222 RECORD成员通过、Python编译通过 | wheel隔离展开目录用开发venv依赖执行6项入口smoke；尚非独立依赖安装、数据库联调或持久服务 |

Web release为`9838ce467fd306bc8fca3a8b7d2d54be5422f6f81d09d8bfdcc210aee6ad9e9c`，main SHA为`40db38642e86bf075386b14aa138b2e60488c6bf4925e758da079b8fe0eccac6`。Windows ZIP SHA为`17a7f6d95dd8b8bad1c3d6e0f4134f5fa29650cafe07e7bfd5e7c86e19988a63`，APK SHA为`8ebc81d5b5e13acd1a145691f6d7c114647ae4890d7dea08ae74769a943d2795`，wheel SHA为`47bad6e745f87c2fb90e5f6428484436ab94e89de5eb6b0166f1eadcbfdd3ba8`。

## 选择依据与兼容性

Windows bfb4与Web a3d9的167项输入中，全部144个lib文件、资源及pub文件逐hash一致，唯一差异是Web壳提示。选已具普通页面/离线证据的a3d9，保留较新c5e8，不为M1重建客户端。APK为普通入口的较早候选，静态审核161成员无QA入口/参数/测试UUID，签名与历史正常安装回执一致；功能不能声称与Windows/Web完全相同。

这批客户端均早于schema5暂存迁移/group增量；Web产物无group-sync-v1/import-stages-v1字面量，Windows旧源快照无group四文件。由来源证据推断它们不消费新group路径，但这不是三端对新wheel的实际协议联调证明。同步40001服务端问题仍保留，不在M1扩展修复；严重问题的处理条件与未验证事项集中在[工作区缺口](../../modules/workspace.md#当前缺口)。

后端补建只保存现有源码，不增加功能。展开wheel后从该目录实际import，`/health/live`、`/`、`/main.dart.js`、`/sqlite3.wasm`、`/admin/login`为200，未知文件404；静态字节hash、COOP/COEP通过。复用开发venv依赖，无真实DB连接，不能当作独立安装/启动或原生客户端已连接。

## 下一包的必要接收

M2只对所选组合做必要的安装/启动、登录、一次精确记账同步与重开保持检查，处理实际严重账务/安全/启动阻断，完成Web ZIP与安装说明；非阻断继续待办。不得直接据M1静态证据称Alpha已完整验收。M3负责独立持久服务，当前无固定在线地址。

本包只补建缺失wheel，未重编客户端、未完整回归、未设备操作或持久部署。两位子代理分别只审Windows和Android。接收时额度接口报告7天窗口已用1%、额外积分0；该比例为账户窗口，不是精确任务成本。

实际回执位于`outputs/validation/alpha/m1/`，包括windows/android审计、Web/旧wheel盘点、新wheel源码/RECORD/启动检查和冻结复制后验。[本包记录](../../logs/2026-10-24_alpha-candidates.md)仅在工作包完成时写入。
