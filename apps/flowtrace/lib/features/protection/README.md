# 本机应用保护

`ProtectionController` 只负责 Web/Windows 本机界面门禁；`supported:false` 不读取或改写保护设置。它不代替服务器登录/权限，也不加密 SQLite、附件或浏览器存储。Web同源脚本、有权访问浏览器资料的人以及本机系统用户仍可能读取缓存；未实现系统生物识别或 Windows 安全桌面解锁。

保护密码独立于服务器密码，长度8–128字符。每次设置使用32字节安全随机 salt，固定 PBKDF2-HMAC-SHA256 600,000次、256位派生值；仅保存版本/算法参数/salt/派生值和有界尝试计数/UTC退避时间。原生 `compute` 在工作 isolate 派生，Web由 `cryptography 2.9.0` 选择 Web Crypto，不在 URL、日志或普通设置中保存明文密码。失败5次起退避1秒，最多30秒，重开保持。

`LocalProtectionStore` 使用事务内 compare-and-set。验证期间若另一页面更改记录，迟到的解锁不能覆盖新保护设置。Web的 BroadcastChannel 只发送 `changed` 信号；其他标签先锁定/请求保存草稿，再重新读取。无法协调标签页时不能开启新保护，已有保护保持遮盖。

应用启动先读取配置，已开启时保持锁定；配置损坏/读取失败保留原值并遮盖，不自动关闭或清除账务。`lock()` 同步切换遮盖状态，然后调用可注入的 `beforeLock: Future<bool> Function()`；返回false或抛错时提示部分输入未落盘，仍保持锁定和原页面挂载。解锁、修改/关闭密码与生命周期改变使用 generation 防止迟到成功展示旧页面。

`AppProtectionGate` 放在 `MaterialApp.builder` 中包住整个 Navigator。锁定时 Offstage/ExcludeSemantics/禁用原焦点隐藏原页面，以独立 Overlay 提供解锁输入；解锁后恢复同一页面状态。inactive/hidden/paused/detached触发锁定。此实现是收到生命周期事件后的应用内遮盖，不保证清除系统或浏览器此前保存的任务缩略图，也没有启用原生屏幕捕获排除策略。

密码忘记时不提供清空数据库或免验证关闭按钮。应保留资料目录/浏览器资料并由维护者受控恢复；清除站点数据会丢失未同步内容。

测试：`flutter test --no-pub test/protection` 覆盖独立PBKDF2向量/真实生产工作量的UI计时、设置/改密/解锁/关闭、持久退避、损坏/存储失败、跨页CAS、迟到验证与后台切换、隐藏内容及完整未落盘输入恢复。测试替身仅用于控制故障时序，生产派生器另测。

参考：[cryptography API](https://pub.dev/documentation/cryptography/latest/cryptography/Pbkdf2-class.html)、[OWASP密码存储参数](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)。
