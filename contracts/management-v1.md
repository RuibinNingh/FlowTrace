# 账本、分类与标签管理补充 v1

状态：P3-01 服务端规则，日期 2026-10-21。对应 F05、F06、F10；采用 FlowTrace 的明确默认，不把钱迹未实测的删除、归档和多人冲突语义写成事实。基础协议见[同步契约](sync-v1.md)，角色见[权限契约](permissions.md)。客户端页面、模板目录与批量本地事务由客户端分别实现和验收。

## 入口与权限

继续使用 `POST /api/v1/sync/push` 的 book/category/tag 命令，实体总数仍为六类。create/update/delete、幂等键、base_revision、整项事务和逐项回执不变。分组也使用 `entity_type=tag`，不新增 group 同步实体或另一套标签存储。

| 动作 | owner | editor | viewer |
|---|---|---|---|
| 同账本分类、标签、分组的新增/排序/编辑/归档/恢复 | 允许 | 允许 | 拒绝 |
| 修改账本名称、封面、模板标识、资产入口及核心设置 | 允许 | 拒绝 | 拒绝 |
| 读取当前授权配置 | 允许 | 允许 | 允许 |

新建账本使用本人 user scope，后续修改使用账本自身 scope。分组、分类、标签及其引用必须在同一账本；UUID 可猜到不代表有访问许可。`show_assets` 仅控制客户端入口显示，不授予或撤销私人账户权限，不改余额。

## 闭合模型

没有列出的字段继续拒绝。控制整数是 JSON integer，严格拒绝 bool 和 float；排序范围为 0 至 2147483647。名称沿用 1 至 80 字符；颜色为 `#` 加六位十六进制，保留调用者原有大小写。图标为最长 64 字符的客户端图标标识，服务器不把用户字符串当 HTML 或可执行代码。

### BookPayload

原有必需字段保留：name、currency、timezone、month_start_day。币种、IANA 时区和月起始日规则不变。

| 新字段 | 默认值 | 规则 |
|---|---|---|
| template | `"blank"` | 最长 64 字符的小写 ASCII slug；首字母 a–z，后续为字母/数字/下划线/短横线 |
| icon | `"book"` | 最长 64 字符 |
| cover_color | `"#2279D7"` | 六位十六进制颜色 |
| show_assets | `false` | 严格 bool；显示设置，不能代替账户授权 |
| display_mode | `"month"` | month/year/all，分别为按月、按年、全部；跨端显示偏好，不改业务日期、统计归属或余额 |

新元数据存 `SyncEntity.payload`，不另加 Book ORM 列或迁移。name、currency、timezone、month_start_day 继续原子同步到 Book 核心列，供身份/权限和现有 `/books` 概览使用。客户端获取完整显示设置以同步投影或授权实体读取为准，不能假定旧 `/books` 概览已经返回这些新增属性。

### CategoryPayload

必需字段保持 name、kind（income/expense）、parent_id（UUID 或 null）、icon、sort_order；新增 `archived:false`。支出和收入分类不能混为父子。parent_id 为 null 表示一级分类；其余必须指向同账本、同 kind、未删除的一级分类。

### TagPayload

必需字段保持 name、color，新增字段如下。

| 新字段 | 默认值 | 规则 |
|---|---|---|
| kind | `"tag"` | 只接受 tag/group |
| group_id | null | 同账本、未删除的 group；根标签可为 null |
| archived | false | 严格 bool |
| sort_order | 0 | 非负控制整数 |

group 必须为根节点，不能设置 group_id、嵌套分组或引用自己。旧 JSON 缺少 kind 时解释为 tag，不会因被其他标签引用而自动变成分组。

合成分组命令示例：

```json
{
  "operation_id": "a0000000-0000-4000-8000-000000000001",
  "scope_id": "b0000000-0000-4000-8000-000000000001",
  "entity_type": "tag",
  "entity_id": "c0000000-0000-4000-8000-000000000001",
  "action": "create",
  "base_revision": "0",
  "depends_on": null,
  "payload": {
    "name": "合成旅行组",
    "color": "#2279D7",
    "kind": "group",
    "group_id": null,
    "archived": false,
    "sort_order": 0
  }
}
```

后续普通标签可用该分组的 entity_id 作为 group_id。group ID 不能写入 bill.tag_ids；账单只引用普通 tag。

## 层级转换、归档和删除

分类允许二级升一级、无子节点的一级降为二级、二级移动到另一一级。禁止自环、三级结构、跨账本父节点和跨 kind 父节点。有子分类的一级不能直接变二级；有有效账单、预算或子分类引用时不能改变收入/支出 kind。

分类移动还会检查现有有效预算：若移动后某份预算同时选中该分类和新父分类，拒绝为 `category.budget_overlap`。用户先明确调整预算，再重试新的分类修改操作；服务器不偷偷删除或合并预算条目。

标签可显式移动到其他组或设 group_id=null。含任何未删除子标签的分组不能删除，也不能转成普通标签；归档子标签仍算子标签。先逐项迁出/删除子标签，再发新的分组删除命令。被有效账单引用的普通标签不能变成分组。

归档不是删除：旧账单、筛选、历史统计和同步投影保留原引用。有效归档状态为自身 archived，或所属父分类/分组已 archived。归档父节点不改写每个子节点的自身标志；恢复父节点只恢复原来未单独归档子项的可选择性。

新账单不能添加已有效归档的分类或标签，手续费分类也一样。编辑已有账单时，可以保留它原来已经引用的已归档项；删除该引用后，不能把它当新选择加回。现有预算也可保留原有已归档分类，新预算或新增加的分类预算项不能使用已归档分类。账务金额和原分录不因归档/排序而改变。

普通删除仍检查有效业务引用：被账单、预算或子节点使用的配置明确拒绝。存在业务记录的账本仍返回 book_not_empty，不能为删除账本而抹掉账务或他人私人分录。

sort_order 不要求唯一。客户端在相同父节点/分组内按 `(sort_order, entity_id)` 稳定排序，收入/支出分类分别排列；同步提交顺序不能当作显示顺序。跨账本移动不复用原配置 ID；应使用目标账本的新 UUID，并显式重建引用。

## 模板与仅复制设置

template 是选择模板的元数据标识，服务器不会仅凭该字符串自动读取别人的配置或复制流水。模板目录、预览和展开算法由客户端提供，展开后的普通命令仍逐项完整鉴权。

复制采用明确白名单：账本显示设置、分类、标签和分组配置。不得复制 bill、account、预算记录、余额、分录、回执、成员身份或附件引用。复制类别配置不等于移动原账单，也不隐含授予目标账本对源私人账户的访问权。

推荐次序：

1. 用新 UUID 创建目标 book，scope 使用本人 user scope；名称由用户明确选择。
2. 为所有待复制分类/分组/标签生成新 UUID；重映射 parent_id 和 group_id。
3. 先发一级分类和根分组，再发二级分类和组内标签；依赖项使用正式 operation_id。
4. 客户端把整组本地实体和 outbox 在一个 SQLite 事务保存，之后等待目标 book 正式 ACK 再发其子域命令。
5. 服务端逐项提交并返回结果；失败项及其依赖保留为可见待处理状态，已经成功的独立项不假装回滚。

单个 push 批次最多 100 项，不承诺跨项原子性。批量排序/新增/配置复制应展示逐项失败，不用清空整个本地队列掩盖部分成功。依赖失败使用 dependency_failed；重试保留被冻结的原操作正文，修改意图必须用新 operation_id。

## 兼容与不可变数据

当前旧实体 JSON 缺少新增字段时，在当前投影/新快照中解释并显式补齐默认值，不无故增加实体或 scope revision，不重写旧 change/page/receipt。已有 Book 的注册/REST 建账本 helper 继续保持同一初始化口径。

create 省略新增字段采用默认值；update 省略本补充新增字段时保留该实体当前值。这样旧 v1 客户端改名称/颜色不会把新版设置清空。显式提交值才修改该新增字段，例如 group_id=null 明确移出分组，archived=false 明确恢复。原来就要求完整提交的字段仍按完整 update 处理，这不是任意 JSON patch。

原始输入的省略、null 和显式默认值仍产生不同幂等摘要；兼容解释发生在摘要之后。新增字段不参与反向改写已冻结请求。

旧 pull/snapshot 物化页必须逐字义保留其原字段集合。对应 HTTP 响应使用 response_model_exclude_unset，避免 Pydantic 在旧 page.items 内注入新默认值而使既有 page_sha256/manifest 失配。新创建的当前投影先补齐默认，再物化和计算哈希。协议消费者应为旧配置缺失新增属性提供上述回退值。

## 主要拒绝码与验证

| 情况 | code |
|---|---|
| 分组不可作为账单标签 | tag.group_not_selectable |
| group_id 指向普通标签 | tag.invalid_group |
| 非空组删除或转型 | tag.group_not_empty |
| 已使用标签改变为分组 | tag.definition_in_use |
| 新引用已有效归档配置 | category.archived / tag.archived |
| 非法分类层级 | category.invalid_parent |
| 移动导致既有预算重叠 | category.budget_overlap |
| 已使用分类改变收支类型 | category.definition_in_use |

输入层的自环、嵌套组、非法 kind/控制数/未知字段返回统一 validation_error；失权及跨账本资源继续安全 403/404，不披露他人配置。测试入口为 `server/tests/sync/test_management.py`，覆盖真实 PostgreSQL 事务、角色、旧 JSON/默认、归档保留历史、独立批次结果及旧物化页 HTTP 哈希。客户端页面验收另记，不将服务端通过等同于完整 P3 已交付。
