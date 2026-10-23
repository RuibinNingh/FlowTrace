# 币种与手动估值

职责：维护私人本位币/常用币种/估值日期策略及手动汇率；只影响资产估值与新选择。
入口：`apps/flowtrace/lib/features/currencies/currencies_page.dart`、`lib/domain/assets/asset_config.dart`及`lib/data/assets/asset_config_repository.dart`。
不变量：不更改历史账单原币/目标金额与冻结FX；报价不自动联网、不反向或三角推导；缺报价不以零或部分合计代替。
必跑测试：Flutter工程内`flutter --no-version-check test --no-pub test/assets/asset_config_test.dart test/assets/asset_totals_test.dart`，以及对应页面widget/真实浏览器；共享币种精度需核对固定目录。
相关材料：[资产模块](assets.md)、[资产契约](../../contracts/assets-v1.md)、[金额时间](../../contracts/money-time.md)、[共享静态目录](../../contracts/fixtures/assets/catalogs.json)、[工作区能力与缺口](workspace.md)。

## 当前实现

币种页提供本位币、常用币种、默认`exact_date`和显式`latest_on_or_before`选择，静态目录使用core已冻结165币种及已知小数位。启用集合包含本位币，旧记录的未启用币种仍可读取。手动报价为不可变ID、明确直接币对、业务日期、十进制字符串和来源；修改需删除旧报价后创建新记录。所有金额/汇率解析复用Money/BigInt，没有浮点金额中间值。

REST缓存/队列与私人分组共享全用户配置revision，按instance/user/epoch/client隔离。更新前持久化冻结请求，超时/冲突保留原正文，重试不重基；旧回执不覆盖新缓存。配置页可读取本机快照、明确联网刷新与重试/放弃保留请求。偏好、汇率和组是三个完整section，刷新以有界重拉获取一致revision，不把某项较高版本误当其他section也已读取。

当前配置13+精确估值12共25项目标通过；其后本机投影3+页面widget6共9目标通过，含未登录保存报价仍保留原始18位小数输入和窗口、保存偏好失败不复位选择。静态分析无问题，详见资产模块实际命令回执。独立Chrome真实页面已保存latest策略、日期化EUR→CNY报价8、明确删除后新增9；实际净资产719.75→732.25，原币余额保持。原异步确认ARIA遗漏失败保留、只读恢复与字体候选消息ARIA通过另列，未为通过重复PUT/POST。资产历史/账期等授权读取已实现并有15项目标及真实UI结果，不将数据层或widget结果算作页面验收。没有操作手机或用户Edge，没有自动联网报价服务。

服务端165币种目录基于SIX2026-09-17官方数字minor units，来源和SHA随包保存，旧15币种精度未改变。0006配置使用统一用户revision与冻结回执。独立候选wheel/18085真实HTTP36检查已证明手动估值8→9只改资产估值，原100CNY→12.50EUR转账与0.125冻结FX保持；后续生产AssetConfigRepository参与的真实Flutter HTTP联测1/1通过，验证冻结请求/回执、组引用账户同步、估值与历史FX分离，正常清理与合成会话0。版本/完整411+RR2、客户端500/5默认live跳过及实际停止证据见资产模块。后续实际Chrome独立候选已验金额/偏好持久化，原18080仍保留；后续c974即时退出专项已通过，剩余平台验收仍单列，不声称全部P6或自动汇率服务通过。

其后4897候选整工程503通过/5默认live跳过、分析无问题；真实浏览器fresh表单/登录/重开退出通过，但即时退出表单语义失败，此历史保留。最终稳定Card候选c974完整504通过/5默认live跳过、分析无问题，同profile真实logout204后即时ARIA/公开Tab输入及重开退出均通过，未重复估值或偏好写入。原Web run已正常墓碑清理并恢复期初，分组/报价清空、偏好复原、活跃会话0；18085与自有18185均关闭、owned Chrome0，旧profile和mutation journal保留。详见[浏览器记录](../../tests/e2e/client-web/P4_ASSETS.md)及资产模块收尾回执；完整P6、Android/Linux仍待相应阶段。
