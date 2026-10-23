# Web 地址保存与账号语义复核

职责：复核普通设置地址切换后的可编辑语义、键盘路径与壳提示。
入口：`account_address_transition.cjs`，固定普通构建与独立Chrome。
不变量：不输入真实凭据，不注入应用状态，不访问个人浏览器，不覆盖旧失败。
必跑验证：固定main SHA、普通页面保存、账号字段/Tab、壳当前状态及截图。
相关材料：[Web模块](../../../AI/modules/web.md)、[原迁移旅程](../import_restore/BROWSER.md)。

## 结果与边界

2026-10-23，原迁移旅程保存地址后账号表单肉眼可见但ARIA字段缺失的失败保留。root在同一普通6f72候选、新独立profile执行即时与5秒后打开路径，均见用户名/密码各一个且实际Tab到密码；没有Dart生产修复，因此不将“未再次重现”写成原缺口已解决。

Native widget新增真实Settings保存→提示仍可见→立即账号路由场景通过。首轮失败来自测试辅助断言沿用另一场景的login请求次数，调整该辅助参数后通过；不是生产语义红绿。浏览器首脚本严格文本定位撞上Flutter视觉/语义提示两节点的失败同样保留，后续定位首个可见提示，不改应用来配合脚本。

独立发现壳的在线降级提示遮挡设置鼠标目标，原45秒鼠标超时证据为`outputs/validation/P6/account-address-e7176177-f682-42bc-87c4-09e1b8d82c57/receipt.json`。壳现增加启动后的“收起提示”及窄屏限宽；启动前资源安全检查不允许收起。合成真实Chrome14（`33a663c1-8d81-4bc4-b918-8db310c160ca`）、seal10、worker5通过，含390宽、键盘收起、正常鼠标导航、离线状态不变。截图已人工查看。

新普通候选`apps/flowtrace/build/web-p6-feedback-20261023-a3d9`构建56.2秒、39资源，release为`9838ce467fd306bc8fca3a8b7d2d54be5422f6f81d09d8bfdcc210aee6ad9e9c`；main SHA仍`40db38642e86bf075386b14aa138b2e60488c6bf4925e758da079b8fe0eccac6`，Dart生产代码未变。167个lib/assets/web/pubspec输入摘要`053950eabd85106a39789cff2922d98a23ba06afb1a3708e361e4be299613a22`构建前后一致，旧bfb4/6f72保留。

新候选即时鼠标路径`e49c3640-43cf-4214-a7d3-a2b47897a208`通过：真实键盘收起提示→普通设置鼠标点击→保存→账号字段/Tab。较短profile的延时路径`b63ca50b-2eaf-4553-951f-3b7bd5a47b88`另通过，真实shell complete39。没有输入密码或发登录请求，此专项不代替原旅程的实际登录、迁移、原图与导出。

随后`8c0cc7a2-4645-4e95-a922-258375076927`通过即时普通鼠标/表单路径，再关闭整个所属Chrome，使用同profile且启动前offline冷开，普通首页可用、同release完整39，page errors空。Native账号widget整文件5/5（4秒）通过。自有18190静态宿主验证后按fixture/build/监听PID身份关闭，未留下服务或浏览器；不是最终常驻部署。

## CacheStorage 路径诊断

同候选/服务/资源，在较深UUID测试profile下39个资源均200且hash正确，但39次独立诊断Cache.put均报`InvalidAccessError: Entry already exists`；回执`cache-diagnostic-7563296e-d8d9-4ab5-a6c2-4468b37ce78e`。改用较短的`work/browser-cache-probes/UUID`新独立profile，同39资源put全成功且正常生产shell完整39，回执`cache-diagnostic-58db7b27-93ca-40a1-a30d-902a7cdcb4c6`。

诊断只写/删除自己独立的task cache，不修改生产壳cache、金融库或授权。证据支持本次Windows profile路径差异，不证明Chrome所有版本/路径的通用上限；没有降低hash、略过资源或改浏览器隐私设置。新专项profile改为较短ignored `work/browser-probes/UUID`，仍不连接用户Edge/Chrome。

## 运行

静态宿主沿用原受限fixture工具，只启动Web，不需要API或任何账号。脚本参数为构建绝对路径、main SHA、固定loopback来源、`immediate|settled`及`keyboard|mouse`；每次新UUID回执/profile，正常关闭自己的Chrome。

```powershell
$env:NODE_PATH = 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules'
& 'C:/Users/ruibi/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' tests/e2e/client-web/account_address_transition.cjs C:/Ruibin_Ningh/program/FlowTrace/apps/flowtrace/build/web-p6-feedback-20261023-a3d9 40db38642e86bf075386b14aa138b2e60488c6bf4925e758da079b8fe0eccac6 http://127.0.0.1:18190 settled mouse
```

所有回执在ignored `outputs/validation/P6/`。它们是独立分项，不能合并成原迁移旅程“无失败”，也不代表完整P6、Windows或Android验收。
