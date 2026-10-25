# Web 离线发布与更新保护

> - 职责：普通Flutter Web完整资源壳、离线启动、失败保旧版及多标签更新协调。
> - 入口：`apps/flowtrace/web/`、`tool/web_release/`、`lib/platform/web/`、`deployment/web/`。
> - 不变量：同一release完整hash校验后才可用；不缓存API/admin/凭据/账务DB；更新先保存完整草稿并排空写者，拒绝跨版本资源拼接。
> - 必跑测试：seal Python测试、worker Node生命周期测试、独立真实Chrome壳和普通Flutter主路径；Dart存储闸门及草稿widget目标。
> - 相关：[客户端](client.md)、[Web验收](../../tests/e2e/web/README.md)、[部署说明](../../deployment/web/README.md)、[计划](../plans/flowtrace/p5-p7-implementation.md)。

## 当前行为

2026-10-25工作区favicon及192/512普通、maskable图标已换成“流线 F”，manifest的主题/背景色和HTML theme-color统一为`#3593FD`。maskable每侧增加8%背景边距，亮色标记实测最远半径约0.365图宽，位于0.4安全圆内；本地真实IAB已查看16–64px和圆形/圆角裁切。源码和导出说明见[图标说明](../../apps/flowtrace/assets/branding/README.md)。本包没有运行Flutter构建或seal，也没有修改任何已冻结Web包/生产资源；以下仍是现行生产版本。

2026-10-24当前生产Web为0.1.1+2、来源`5f3e813`，release `271e839535a9f2c94f689cd45a3b54f8d156481e6dbb968d127569a64c29f8dd`；内置正式HTTPS地址，已有手动设置保持。普通main新构建45.6秒，seal39资源加manifest/worker共41文件，ZIP25,835,302B/SHA`a677510547fecd5ff2ddd1df4139c5a502ed97ef11ed43baf2efbe26bbfce1fe`。生产HTTPS逐项核对39资源、IAB实际渲染主页；观察到完整新版提示，点击回执超时但后续截图为正常主页且提示消失，不扩大为完整多标签/离线升级验收。旧fcdcda0和原105条合成浏览器证据保留；本包复用其业务验证与前包41定向，不重复1015整套。版本/切换/第一次权限回退/第二次修复见[生产模块](production-deployment.md)、[Linux手册](../../deployment/linux/README.md)和[部署记录](../logs/2026-10-24_client-production-deployment.md)。

构建后`seal_release.py`对新产物生成SHA256清单和版本，生产worker仅发布完整包/完成标记。安装校验失败保留旧完整包，已缓存资源损坏返回503，不从新网络版本补单个资源。首装有实际进度，离线准备失败提供明确仅联网路径；未把估算配额当成实际可写容量。

多标签`prepare/resume`协议要求所有当前应用同意后才激活。旧active worker持有25秒CacheStorage lease，重启仍阻止未准备的新标签启动；未知旧协议、任一保存失败/迟到标签/超时取消时恢复原应用。没有无条件skipWaiting。

普通FlowTraceApp注册JS bridge。EntryPage会取消350ms debounce、等待既有草稿队列并保存当前完整计算式/正文；未登录文本草稿也保存到稳定ID，取消更新后手动保存不重复创建。未登记编辑器/对话框、身份/同步/恢复忙碌或导航变化拒绝更新。SQLite执行器闸门覆盖直接SQL、批次和原始事务，等待已许可写者提交或回滚；新写者拒绝，只读快照仍可读且不允许夹带写入。resume幂等，取消后迟到prepare不再锁住旧应用。IndexedDB附件字节由页面busy和现有附件管线保护，不宣称SQLite闸门覆盖其底层事务。

## 已验与待验

2026-10-24 M1选择已有普通a3d9作为Alpha候选，保留新c5e8。两目录均经生产verified_web核39资源与manifest/worker共41文件及绑定全hash；a3d9冻结至outputs/releases/alpha/m1-20261024/Web，53,365,981B，未重建或制作ZIP。已有普通Chrome地址/冷启离线证据复用，不重跑相同旅程；其144个lib与Windows旧普通候选一致，不能据新schema5回归扩大能力。新wheel展开目录的ASGI静态index/JS/WASM及隔离头通过，非新浏览器/DB联调，见[候选清单](../plans/flowtrace/alpha-candidates.md)。

2026-10-23新普通schema5候选`web-stage-20261023-c5e8`构建59.5秒，seal39资源、release `e4d63f16e2ad6471fe3afb8b8f4b974d43cf93828e464172a09268f7650e821c`；main SHA256 `3431f09c812458c899d3ca259b6cddbee1186d37d030de9e4cd227bf1fee3101`。184项构建输入前后摘要同`aab12edc50d7243fb4103bb589ffbc5aa71873aae44a45f0d2cde7dfe57d2301`，普通lib/main.dart、显式本机测试profile且无QA参数。对应客户端全量1009/6默认live skip和分析通过，真实新Chrome stage旅程尚待，不借用下面旧壳/普通业务分项作此新候选验收。

2026-10-23首装降级提示原先会遮挡普通首页设置鼠标目标，已新增启动后的“收起提示”，启动前安全检查保持可见；窄屏限宽，收起不改变真实离线状态。新真实合成Chrome14、封装10、worker生命周期5通过，含390宽/键盘收起/正常鼠标导航。普通main新候选`web-p6-feedback-20261023-a3d9`构建56.2秒、39资源，release`9838ce467fd306bc8fca3a8b7d2d54be5422f6f81d09d8bfdcc210aee6ad9e9c`，main与6f72同SHA；167源快照`053950eabd85106a39789cff2922d98a23ba06afb1a3708e361e4be299613a22`前后一致，未覆盖旧产物。

普通地址保存后即时打开账号/表单/Tab在新Chrome分项通过，延时路径另有通过；原迁移profile的ARIA失败仍保留，未将未重现写成已修。深测试profile中39个资源均200/hash正确但Cache.put全部报InvalidAccessError，短独立profile同资源全部可写且真实shell完整39；属于本次路径差异诊断，未证明Chrome全版本的通用路径上限。新验收profile使用较短ignored路径，仍完全独立于用户浏览器。详见[地址转换记录](../../tests/e2e/client-web/ACCOUNT-ADDRESS.md)。

生产壳在合成页面的真实Chrome专项14项、Node生命周期5项、seal10项通过，含worker实际停止后持久锁仍有效和旧注册URL迁移。普通Flutter固定b8e5真实4项通过：双标签并发保存/离线刷新、未点保存的文字经真实屏障落盘再更新、整浏览器进程离线冷启四条各唯一。A/B包main同SHA，仅manifest描述变化；不是两个业务版本、正式账outbox/附件或随后新保护的验收。Dart屏障/原子事务/完整编辑器草稿20项、完整806/5默认live跳过与后补迟到状态7项目标分开记录，初次编译与只读快照问题已保留并修正。实际回执见验收入口。
