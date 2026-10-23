# 附件存储与授权

> - 职责：图片声明/上传/完成、授权元数据与原图/缩略图、账单引用事务和保守回收。
> - 入口：`server/src/flowtrace_server/attachments/`、迁移 `0004/0005`、`tools/cleanup_attachments.py`；客户端 `lib/data/attachments/`、`features/attachments/`。
> - 不变量：无公开静态文件；scope 授权覆盖每条读取；只引用 ready；GC 与引用锁同 scope/附件；原图不进入诊断。
> - 必跑测试：服务端附件/图片测试（需真实隔离 PG）；客户端附件/诊断目标、`test/attachments/attachment_http_test.dart`（显式合成凭据）、原生集成及独立浏览器 harness。
> - 相关：[附件契约](../../contracts/attachments.md)、[权限](../../contracts/permissions.md)、[同步](../../contracts/sync-v1.md)、[诊断](diagnostics.md)、[服务端](server.md)。

## 当前服务端流程

新服务配置接入单文件上限与每上传者原图声明配额，硬上限仍10MiB。同用户行锁串行预留跨账本上传，pending/uploaded/ready/deleting均占配额，旧声明重放不重复计费；降低限制不打断旧合法声明，deleted重新声明按新限制预留。孤立ready保留期读取当前配置（默认7天），refs/hold复查和deleting→deleted流程保持；专项正在验证，见[配置模块](configuration.md)。

2026-10-23客户端补导入回执正反采纳：服务器当前GET的scope/hash/类型/大小须匹配正式回执，当前本机epoch/client与scope权限仍有效，才将ready本机原件复制到新scope派生key并原子更新queue/清旧upload票据。旧原图不删；逆采纳仅接受服务器已回本人scope的原件，可从已撤旧账本缓存恢复为本人ready。5个真实SQLite/文件目标通过，包含重开、后续ensureReady、undo、错误scope/权限/迟到身份拒绝；该专项不是完整系统选图或跨端旅程。整体接线见[数据工具](data-tools.md)。

P5导入新增显式私有孤儿采纳：本人user scope中已ready、无refs/hold的原上传可由同批import原子转到授权目标账本（含新book），清单带明确目标并废止旧票据。preview/失败全部回滚，原字节不改；undo仅在无后续引用/权限版本等变化时转回本人孤儿。下载仍按当前scope授权，没有公开URL或后台任意抓图，服务与实际PG证据见[数据工具](data-tools.md)。

`POST /api/v1/attachments/uploads` 声明 UUID、scope、SHA256、大小与类型，返回随机上传 UUID 和 24 小时期限；相同身份/声明可重放，不同内容为冲突。PUT `uploads/{id}/content` 实际流式累计，单文件最多 10 MiB、60 秒读取期限，不信任 Content-Length；首版整体重试，不提供分片续传。POST `uploads/{id}/complete` 重新核对原图摘要、大小、格式/解码和缩略图，再同事务标 ready 与正式审计；重复完成不重复审计。

过期后只有当前仍有写权限的原上传者显式重新声明完全相同内容才能续期；新上传 UUID 保留旧票据历史，旧 PUT/complete 始终 410。deleting 锁中拒绝复活；deleted 仅无 refs/hold 时重新暂存。ready 续期保留引用/持有，未引用宽限重新起算。票据临时文件隔离，写流、发布和 complete 均重验当前 ID/期限；这是 FlowTrace 默认，不是钱迹实测同步策略。

JPEG/PNG/WebP 必须匹配真实格式，完整解码，最多 40MP；静态图片为当前默认，动画返回 `image_animated`，不默选第一帧。每进程最多两个同时解码，容量满为安全 503。EXIF 方向用于尺寸/缩略图；原件保持字节和摘要，640px 内的 WebP 缩略图清除 EXIF/GPS、ICC、文本元数据。Pillow 固定 13.0.0，具体依赖与哈希见服务端锁文件。

元数据、`/{attachment_id}/content`、`/thumbnail` 每次重新验证活动身份及 scope，viewer 可读、写需 editor/owner；管理身份无隐式私人范围权限。上传写还限原上传者，Web 同样验证 Origin/会话 CSRF。下载只用生成的安全 UUID 文件名，nosniff、private/no-store、受限 CSP，不返回公开长效 URL。

文件位于 `FLOWTRACE_DATA_DIRECTORY/attachments/{staging,objects}`，不挂静态路由，内部存储键为随机 64 位十六进制。服务器不接受客户路径/原名作为存储键；普通文件检查拒绝符号链接、junction、硬链接和越界。新建使用排他创建、POSIX 0600/0700；Windows 仍依赖服务账号目录 ACL，不能把 chmod 当作等效 ACL。文件与 DB 无跨资源原子提交：崩溃后留下的已验证文件由 pending/uploaded 状态重试或回收；只有 ready 能被账单引用。

## 引用、回收与备份边界

权威 `attachment_refs` 将账单 SyncEntity 与附件关联；`reconcile_bill_attachments` 在既有 scope/账户锁之后按附件 UUID 排序锁定，验证所属范围、ready、旧引用一致，创建/删除引用和账单同事务提交，不自行 commit。跨范围附件在加行锁前拒绝。同步 payload 的 attachment_ids 是确认名单，不是第二套引用数据库。

未完成上传过期 24 小时；ready 无引用满 7 天才可回收。GC 按 scope→附件加锁复查 refs 与 holds，提交 deleting 后拒绝新增引用，删除私有文件成功才提交 deleted；进程中断保留 deleting 可重试。错误文件/链接或不可写时停止后续回收，不能扩大删除目录。CLI `python -m flowtrace_server.tools.cleanup_attachments --limit 100` 只处理数据库确认对象，需服务 OS/DB 权限。

`attachment_holds` 为未来作业/备份提供保守持有原语；必须在同 scope/附件锁内取得，显式释放，不自动到期。崩溃持有宁可保留文件，后续作业/管理员确认后释放。当前未实现真正备份作业，hold 原语不能作为附件已经备份的证据。

## 已验证与未完成

服务端 12 项真实 PG 验证覆盖声明/上传/完成重放、摘要、未完成/伪格式/过期与续期、私有与共享撤权三类读取、refs/hold/GC、deleting 崩溃恢复、正式审计失败回滚、诊断故障仍注册成功、管理员脱敏导出。并发用独立 PG 连接观测真实 scope 锁等待，引用提交后 GC 保留原图。实际同步 HTTP 测试还验证非 ready 拒绝、相同正文重试成功、refs 添加/移除/重关联/账单删除及跨 scope 拒绝。独立图片/路径/流式测试另覆盖三格式、断流/超限、元数据和链接。

客户端目标 12 项使用真实临时文件与 SQLite，覆盖重开、输入深复制、并发固定 ID、失败保原件/重试、不重复点击、迟到身份响应、恢复阻断上传、撤权清实际缓存及损坏元数据不能指向原件。实际 18080 双用户 HTTP 一项完成上传提交后丢响应→冻结账单保留 retry→重试只发生一次 PUT→ready 后账单引用→陌生用户拒绝→viewer 下载→撤权同步物理删缓存且保留未传原件→正常墓碑收尾。测试会话退出，使用合成数据。

Web 标准 Flutter test runner 在本机 SDK 的 host.dart.js 访问缺失 `#play`，未算通过、未改 SDK。独立 `dart compile js test/attachments/browser/byte_store_harness.dart` 使用同一生产 WebAttachmentBytes，在真实 Edge 完成四项 IndexedDB 持久化/重开/拒绝覆盖/删除；harness 不是 Flutter 完整 Web 应用离线验收。Android 16 真机 `integration_test/attachment_storage_test.dart` 一项通过：通过实际 openAttachmentBytes 应用支持目录和文件 SQLite 保存/关重开原件，撤权后实际删除受控缓存且保留用户原件，测试仅清自己的 UUID 键/隔离目录。图片选择/编辑面板在下节的 P3 接收中，Linux 部署/故障恢复仍需独立环境。参考 [Pillow Image](https://pillow.readthedocs.io/en/stable/reference/Image.html)、[ImageOps](https://pillow.readthedocs.io/en/stable/reference/ImageOps.html)。

## 客户端持久化与同步接点

`AttachmentRepository` 将原件字节写入后才提交队列元数据；Android/Windows 使用应用支持目录中的普通文件，Web 使用 IndexedDB strict 事务，均不在失败时回退内存并声称保存。10 MiB 和文件头检查在本地执行，完整解码/像素验证仍以服务器为准。用户原件键与受控下载键分开，包含资料空间、epoch、scope、附件 ID 和摘要；修改内容另建 ID。

队列键固定为 `attachments.v1.{space.id}.queue.{attachment_id}`，受控缓存键为 `attachments.v1.{space.id}.cache.{attachment_id}.{original|thumbnail}`。同步恢复保全队列元数据/用户原件，待恢复状态禁止上传/正式关联，仍可本机暂存。`AttachmentLease.capture(identity)` 绑定 generation/space/epoch/client，busy 或切换账号后停止传输，迟到响应不能标 ready。`AttachmentTransfer.ensureReady` 在账单 push 前上传/确认现有 ID，不改冻结命令；上传失败保留 retry。`AttachmentStatusTile` 显示待传/失败/可重试/已上传，没有“已备份”承诺。

`revokeScope(space,scope)` 标记本机原件 revoked，清理该范围下载缓存实际字节与元数据；删除失败保留元数据，供启动再扫已撤权集合重试。读取同样检查同步撤权/恢复状态，损坏缓存键不得删除本机原件。已离线导出的独立文件不能收回。`SyncEngine` 已接上传前置和撤权 hook，图片选择/预览入口另随编辑器实现。

## P3 编辑器附件面板

2026-10-22原授权PLT140的真实默认OEM系统picker专项通过：生产AttachmentPanel/ImageAttachmentSelector选入77字节3×2合成PNG，核原件SHA和完整草稿引用；真实取消及10MiB+1应用拒绝均不改变快照。长UUID名被OEM截断后，仅给相同字节建立短唯一别名并记录映射，没有猜选私人图片。系统首次协议由用户本人同意。QA只读事务修复后，同APK无重装force-stop/COLD恢复仍为同一原图/UUID/引用，原SQLite文件SHA不变；失败与修复回执分列，见[Android专项](../../tests/e2e/android/README.md)。这证明本机选择/持久化，未包含新HTTP上传下载或全部编辑器旅程。

`AttachmentPanel` 作为受控编辑器字段，接收 repository、space、epoch、scopeId、attachmentIds、onChanged、isCurrent；可选 transfer/lease 用于在线预览与显式重试，contextChanges 监听账号变化，onBusyChanged 使外壳在选择/草稿引用保存期间禁止正式入账。外壳需先完整保存草稿引用再完成 onChanged；移除只改变本笔 ID 列表，不删除用户原件。失败关联可直接重试同一已暂存 ID，不必再次选图。

`ImageAttachmentSelector` 使用官方 file_selector 1.1.0；当前锁定 Android 0.5.2+6、Web 0.9.5、Windows 0.9.3+6，不升级 Flutter/Dart。各平台过滤器只作选择提示，真实类型以文件头和解码为准；先查大小，再以 `end=min(length,10 MiB+1)` 有界 slice/逐块累计，读取前后长度一致才继续。Web XFile 的 slice 会一次转 arrayBuffer，不能先无限 openRead 再计数。PNG 尺寸/已知动画结构先检查，再用公共 `instantiateImageCodecWithSize` 回调取得原始宽高、验证最多40MP并限制后续解码宽720，再核对静态帧与实际解码；原件字节不改。Flutter3.38.3 Web 的 encoded ImageDescriptor.width/height 不支持，不能直接读取；SDK 的 Web size API 首先解码取得原始尺寸，因此不能将非PNG路径声称为分配像素前检查。

已有 7 项选择器与 7 项面板目标测试通过，覆盖真实文件、伪类型/损坏/动画/40MP、超限与虚报 provider、引用持久化、取消、移除保原件、关联失败同 ID 重试、busy 完成/取消/旧空间隔离，以及切账号迟到选择丢弃。预览直接订阅该资料空间的 SyncState：真实撤权、epoch/恢复变化或监听失败均清除已渲染字节；另订阅编辑器生命周期信号，外壳卸载后独立 Navigator 预览也清屏，不依赖 AppController 刷新。新增两项实际文件/SQLite widget 测试验证无 app 通知的 SyncStore.revokeScope 和 parent 卸载路径，完整面板 7 项重跑通过。

普通Web跨账本移动后的详情预览曾因上述ImageDescriptor.width不支持而失败，真实77字节PNG经Pillow解码与CRC核对正常；保留失败回执。兼容修复后选择器7项及面板7项合计14/14通过，固定普通main a55bfe79...970ed0的独立Chrome复验原已移动账单，目标原图实际渲染通过，未换图或重复移动。真实 Android选择器与编辑器主路径统一最后验收，Windows 原生在 P7，不能以 pub 解析通过代替平台构建。

官方依据：[file_selector](https://pub.dev/packages/file_selector)、[Flutter 插件说明](https://github.com/flutter/packages/blob/main/packages/file_selector/file_selector/README.md)、[Android 版本记录](https://pub.dev/packages/file_selector_android/changelog)、[Web 版本记录](https://pub.dev/packages/file_selector_web/changelog)。
