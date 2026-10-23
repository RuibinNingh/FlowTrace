# 附件契约 v1

状态：P0 设计，P2-03 实现。附件不处于公开静态目录；任何元数据、原图、缩略图、导出访问都重新检验用户/资源权限。

流程：`POST /api/v1/attachments/uploads` 声明 attachment_id、scope_id、sha256、size_bytes、media_type，返回短时上传 ID；`PUT /attachments/uploads/{id}/content` 二进制上传（首版整体重试，不宣称分片续传）；`POST /attachments/uploads/{id}/complete` 校验后完成。ID 和摘要相同可重复调用，内容不同返回 409。未完成附件不可作为已同步引用。账单写入与附件引用元数据在同一领域事务，附件内容完成不自动创建账单。

默认单文件 10 MiB，实际流式读取也限量（不能只信 Content-Length）；首版允许 JPEG/PNG/WebP，校验真实格式、解码像素上限 40MP。大小在 API 中是有限 integer。原名只是显示，服务器随机存储键、私有目录、拒绝越界/符号链接；下载 Content-Disposition 使用安全文件名，nosniff，Cache-Control private,no-store。不返回长效公开链接。

暂存上传 24 小时过期，已完成未引用文件 7 天宽限；清理只处理数据库确认为无引用且不在活跃上传/作业/备份中的对象。清理与新增引用必须锁同一附件元数据行：GC 在锁内复核后设置 deleting，引用事务只接受 ready，不能在 GC 复核后再引用待删内容；文件删除成功再标 deleted，崩溃按状态重试。备份持有快照使用引用或维护锁，不能与 GC 交错失去文件。客户端未传附件保留本地原件和摘要，错误重试不删除原图。账户切换、撤权及 epoch 恢复按同步契约隔离处理。

过期续传是 FlowTrace 设计默认，未声称还原钱迹算法：客户端显式重新声明相同 attachment_id、scope、摘要、大小和类型，服务器重新验证当前用户/会话与写权限；只有同一上传者且声明完全一致才可获得新上传 ID。旧上传票据保留历史并始终为 410，不得因更换账号或旧票据复用复活权限。deleting 状态拒绝续期；已回收 deleted 对象仅在无引用/持有时重新暂存。ready 对象续期不丢失 refs/hold，未引用宽限重新起算。新旧上传临时文件按票据隔离，流写入及落盘/完成均在锁内复核当前票据与到期时间；旧请求不能越过续期写入新上传。

客户端使用服务器地址/instance_id/user_id 对应的资料空间隔离元数据与字节键，并额外绑定 sync_epoch、scope 与 attachment_id；重试保持附件 ID 与冻结账单命令不变。Android/Windows 原件存应用支持目录，Web 存独立 IndexedDB，写入失败不退回仅内存后宣称保存。恢复待核对时可继续暂存原件，但禁止正式上传/关联。在线撤权后清理受控下载缓存并阻止读取；用户自己选入但未传的原件保留为撤权状态。这不能追回用户在撤权前已经独立导出的文件。

接口错误：401/403、413、415、422 hash_mismatch/image_dimensions、409 upload_mismatch、410 upload_expired。验证样本必须覆盖越权 ID、伪类型、超限流、断流、重复完成和附件/账单之间崩溃；不得把正文同步成功等同于附件已备份。
