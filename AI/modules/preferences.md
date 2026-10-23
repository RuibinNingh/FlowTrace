# 本机显示设置与应用保护

> - 职责：本机/浏览器外观和功能入口偏好、Web/Windows应用内锁定与完整草稿保留。
> - 入口：`apps/flowtrace/lib/data/preferences/`、`features/settings/`、`features/protection/`、`app/app_controller.dart`、`app/flowtrace_app.dart`。
> - 不变量：只改变显示和入口，不改金融事实/历史payload；本机偏好不假称账号同步；保护不存明文口令，失败不清除账单或草稿。
> - 必跑测试：`test/preferences/`、`test/protection/`、根widget与`test/data/update_preparation_test.dart`；真实Web/Windows前后台/多标签和完整输入需另验。
> - 相关：[客户端](client.md)、[记账](entry.md)、[Web](web.md)、[Windows](windows.md)、[实施计划](../plans/flowtrace/p5-p7-implementation.md)。

## 当前接线

2026-10-23已接首页/统计/日历真实展示与桌面布局（14个widget目标），以及Entry/Assets含子页的精确千分位、统一配色、金额隐私和功能字段入口（22目标）。搜索/详情/移动/批量/预算及表单内“本次显示”重置相关34目标通过。既有/草稿非空字段不因开关关闭丢失，金额表单保持原精确表达式，只遮盖显示并允许本次显式查看；资产隐私切换为同一持久偏好，隐藏时数值曲线卸载。完整真实Web/Windows保护旅程仍待执行。

“秒开记账”只在启动时已启用、选中可写且未归档账本、保护已解锁并回到顶层页面后打开一次原记账编辑器；取消返回不重复打开，运行中启用开关不立即跳转，不自动保存账务或覆盖草稿。完整草稿、暂存迁移请求/正式回执与本机刷新标记均保留于恢复备份；旧身份记录只读，不自动重发。相关恢复/快捷入口/撤权等20目标通过。

AppController加载`app.preferences.v1`；旧`theme_mode`可读，更新新偏好与旧主题键在同一SQLite事务内，成功落盘才发布内存值。坏JSON不覆盖，显式恢复默认时保留原值备份。根应用提供AppPreferencesScope，主题和设置预览已实际消费同一配置；显示/主页卡片/功能入口的各业务页面消费仍在继续，不能把设置开关存在当成全部生效。

设置页区分本机显示偏好与会同步的账本币种/月起始日/分类设置。格式化用BigInt和字符串千分位/金额隐私，不经浮点；当前只有简中完整文案，系统解锁/震动等平台能力不以空开关伪造。跨标签旧偏好写入使用两键事务CAS，冲突只重读并明确要求重试，不覆盖另一窗口的新设置或已恢复的坏值备份。

Web与Windows根Navigator外包AppProtectionGate。已开启保护时启动先遮盖，生命周期inactive/hidden/paused/detached立即遮盖并请求登记的业务编辑器刷新完整草稿；子树保持挂载，即使落盘失败也保留内存输入。隐藏时排除焦点/语义；独立Overlay承载锁屏文本选择/输入。保护密码表单不属于业务草稿。

本机口令独立于服务器登录密码，8–128字符、随机32字节salt、PBKDF2-HMAC-SHA256 600000轮和32字节结果；通过cryptography2.9.0，Web用WebCrypto、Native compute避开UI阻塞。验证/改密使用持久记录CAS和generation，失败退避持久化；跨标签通知仅含changed，不发送口令/摘要，外部启用先强制遮盖再重读。锁屏是应用内保护，不宣称浏览器存储/整库加密、清历史缩略图或排除系统截图。

## 证据

当前冻结普通入口快照完整`flutter test --no-pub --dart-define=FLOWTRACE_LOCAL_TEST=true --reporter expanded`为871通过、5项专用live默认跳过（66秒），全工程分析无问题（13.4秒）；已包含上述后补目标。普通Web候选`web-p5-integrated-20261023-6f72`构建/封装完成，真实平台验收正在接续。下段保留旧快照证据。

本轮完整Flutter806通过/5需专用联测配置默认跳过、完整analyze clean（10.3秒），含22个偏好/保护/KDF/gate目标及根设置入口；此前21目标的编译/Overlay缺失失败保留。随后CAS新增3例使owned25目标通过/分析clean7.1秒，未冒称已纳入806快照。真实600000轮独立向量和UI ticker目标通过；原普通Web更新专项产物是保护接线之前的固定b8e5，不能用它声称新保护真实浏览器已验。更新保存期间迟到生命周期锁/设置写入的2目标先红后修，7项目标通过，后续状态见计划恢复入口。
