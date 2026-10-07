# 持久化、作品身份与迁移

本页说明当前本地存储归属、业务身份和升级边界。持久化基础设施负责连接池、迁移注册与公共工具；业务 Store、表和合并规则由各功能拥有。不是每个功能目录都对应一个独立 Swift 模块。

## 存储归属

AppContext 打开并传入同一个 `DatabasePool`，数据库默认位于 `Library/Application Support/YamiboX/yamibox.sqlite`。测试或隔离装配可注入不同根目录和连接池，不应让业务 Store 自行猜测正式运行时的数据位置。

| 存储 | 拥有者与用途 | 维护边界 |
|---|---|---|
| GRDB 共享数据库 | 收藏文档、更新事件与同步日志、进度、历史、目录、喜欢、书签、草稿、下载及缓存索引 | 每个业务 Schema 注册自己的表和迁移；业务 Store 控制读写和删除语义 |
| UserDefaults | AppSettings、非秘密 WebDAV 设置/凭据引用、续读与 UI 状态等 | 设置字段修改优先使用 Store 的 `update`，不在 UI 直接改写整份 JSON |
| 账号 Keychain vault | 当前认证会话、当前资料、保存账号 | 原子文档由 AccountStore 维护；本地环境与生产环境 service 隔离 |
| WebDAV Keychain | WebDAV 密码 | 与论坛 vault 分离，偏好只保留引用；凭据读取失败不等于用户要求删除密码 |
| Application Support 文件 | 离线下载、封面图片、草稿附件、喜欢图片、自定义背景等 | 不由普通缓存淘汰；各 Store 管理引用、删除和失败收尾 |
| Library/Caches 文件 | 论坛页、阅读投影、普通图片及技术缓存 | 可重建、可被系统清理；持久业务不能把唯一数据放在这里 |

离线内容默认在 Application Support 的 `downloads` 下，并为该目录设置排除备份；其他用户资料与缓存的备份策略不能由此类推。封面索引与偏好在数据库，原图由 `ContentCoverImageStore` 持久保存，不属于普通图片缓存。详见 [下载、缓存与封面存储](downloads-and-storage.md)。

默认多数业务 Store 属于 App 安装级共享数据，不按论坛 UID 分库。草稿有明确的 `account_uid`；会话、账号缓存和远端同步有各自的账号作用域。不要仅因为 Store 被账号依赖包引用，就将其数据描述为“该账号私有”。相关转换见 [账号生命周期](account-lifecycle.md)。

## 读写、错误与通知

- 持久化读取应区分“不存在”与“无法读取”。例如 `FavoriteLibraryStore.load` 抛错表示失败，不能把它当作空收藏再覆盖写回。
- 收藏变更通过 `FavoriteLibraryStore.update` 在同一事务内读取最新文档、转换并保存，不提供先加载旧快照再整库保存的公开写入路径。
- 设置字段修改使用 `SettingsStore.update`，actor 内连续完成读取、修改与保存；整快照 `save` 只用于确实需要替换全部设置的场景。
- 事务成功后才发布失效通知。`StoreWriteTransaction` 提供公共写入边界与错误封装，SQL、去重和是否通知仍属于业务 Store。
- `changes()` 是每个订阅者独立的有界多播失效信号，消费者重新读取当前状态。`changeID` 标识 Store 实例，不是逐条变更日志、业务主键或数据版本。
- 数据库与文件系统不共享一个原子事务。文件导入、索引提交、引用回收与失败补偿必须按所属 Store 的顺序执行，不能声称一次删除能跨所有介质回滚。

草稿另外使用数据库 generation、revision 和删除墓碑：迟到保存必须检查代次和预期 revision，账号不匹配、已删除与并发冲突分别处理。不能靠内存 actor 状态替代持久化冲突检查，因为另一个 Store 实例也可能写入同一数据库。

### 数据库打开失败

`YamiboDatabase` 配置写锁等待、注册全部迁移，并关闭 schema 改变时自动擦库。一般打开或迁移失败应传播到启动错误与重试，不创建空库掩盖失败。

当前有一个明确例外：SQLite 返回 `SQLITE_CORRUPT` 或 `SQLITE_NOTADB` 时，将数据库及 WAL/SHM 旁文件移动为带时间戳的 `.corrupt-*` 文件，再创建新库。这可能损失新库中的原有本地记录，隔离文件用于诊断；它不是备份恢复，也不是任意持久化错误的统一处理方式。

## 三类业务引用不能混为一谈

| 类型 | 用途 | 当前身份 |
|---|---|---|
| `ReadingWorkKey` | 阅读注解、喜欢和书签共享作品身份 | `kind` 为 novel/manga，`id` 为帖子 ID 或漫画目录 ID；旧 `LikeWorkKey` / `LikeWorkKind` 是源兼容别名 |
| `FavoriteContentTarget` | 进度与浏览历史 | 普通帖、小说帖、目录级漫画 `mangaTitle`、单帖漫画 `mangaThread` |
| `FavoriteItemTarget` | 收藏条目 | 仅普通帖、小说帖、单帖漫画，不能构造目录级 `mangaTitle` 收藏 |

这些类型可以通过领域适配转换，但不应为了名字相近合并成一个万能枚举。`FavoriteContentTarget` 的历史公开名称和编码保留，并不表示由收藏功能拥有。

普通/小说帖使用 `thread:normal:<tid>`、`thread:novel:<tid>`；单帖漫画收藏与进度都使用 `manga-thread:<tid>` 以便精确匹配；目录级进度使用 `manga-title:<directory-id>`。展示标题不构成当前稳定身份，修改名称不应产生一条新进度或让旧书签失联。

智能漫画关闭时，恢复使用该帖自己的 `mangaThread` 进度，不应因一个目录的当前章节恰好同 tid，就恢复到目录级记录。作品引用、收藏入口、阅读位置和缓存键分别解决不同问题；缓存键格式也不是替代业务身份的扩展入口。

## 漫画身份注册与运行时合并

`MangaDirectoryID` 是持久化不透明身份，新目录使用 `manga-id:` 前缀的 UUID。只有旧格式导入器可以从旧名称生成确定性的 `manga-legacy:` 身份；不能在每次刷新、重命名或目录重建时按标题重新计算 ID。

共享注册表包含身份、名称/旧收藏别名和重定向。目录缓存清理保留注册表，使进度、喜欢、书签、封面和离线引用在目录暂时不存在时仍能解析。

旧引用解析优先使用章节 tid 与不透明身份证据。证据冲突或存在多个候选时保留未解析状态，不能强行绑定到当前同名目录。注册表快照只暴露能唯一解析的别名；有证据并不意味着仅凭标题就可以合并两个目录。

显式合并或远端身份批次导入经过以下边界：

1. `MangaDirectoryStore` 串行化身份变更，准备并暂停下载写入者。
2. `GRDBMangaDirectoryIdentityMigration` 在一个数据库写事务内合并目录/章节、维护身份重定向和标题元数据。
3. `MangaIdentityRemapping` 将同一个 `Database` 传给各业务适配器，规范化进度、历史、喜欢、书签、封面、收藏相关引用、删除状态与下载记录。
4. 任一适配器抛错使整个写事务回滚；协调器不开新连接或嵌套事务，不吞掉参与者错误。
5. 成功提交后完成下载身份变更并发布各业务失效通知；失败也释放准备状态，但不发布成功通知。

业务冲突处理仍由所属适配器决定，例如目标封面的保留、下载冲突选择、书签位置去重及删除状态的最新时间合并。公共协调层不遍历任意业务 JSON 来猜测所有字段。

身份快照的别名/重定向与目录的 `content_identity_ids_json` 也不同：后者记录已合并内容的来源，不能仅因重定向存在就认定对应章节内容已经合并。异步刷新在提交时重读规范身份和当前权威标题，避免用旧快照恢复合并前目录或撤销用户重命名。

## 历史迁移与旧格式兼容

迁移链的注册入口是 `YamiboDatabase.migrate`。各 `DatabaseSchemaModule` 拥有建表、演进和清理；跨业务漫画身份迁移在业务初始 Schema 之后执行，下载改名再接在冻结身份迁移之后。已发布 ID 和顺序是升级契约，不是可以随意整理的字符串列表。

必须保留以下版本边界：

- `manga-identity.v1`、`manga-identity.v2.content-provenance`、`manga-identity.v3.pending-tombstones` 使用 `MangaIdentityMigrationV1` 中冻结的身份算法、规则、SQL 和 DTO，不依赖当前业务模型或运行时 remapping。
- 冻结 schema-1 页面解码器用于历史下载内容冲突比较，不能替换为最新帖子页/阅读投影模型，也不能按“重复模型”删掉。
- 未携带身份注册表的旧 WebDAV JSON 使用冻结的 `MangaIdentityLegacyJSONV1`；当前 participant 提供类型化规范化器与章节证据，不把新增字段塞进旧通用兼容遍历器。
- `history.v3.webdav` 固定使用 V1 历史合并规则和保留上限。新的运行时策略不能隐式改变一次旧数据库升级的结果。
- `downloads.v1.naming` 保留对旧 `offline_cache_*` 表和 `offline-cache` 文件路径的引用；这些历史名称不是未完成的产品改名。

文件升级与设置兼容也需要成功边界：下载旧目录正常以同卷移动升级，新旧目录并存时先复制核验，冲突报错保留重试机会；设置仅在旧 JSON 完整解码成功后将 `novelOfflineCache` 写为 `novelDownload`。不能用解码失败后的默认设置覆盖唯一旧数据。

论坛账号旧偏好迁入 Keychain 后才清理源数据；WebDAV 明文旧密码也是安全写入成功后才从偏好移除。读不到秘密不能等同于秘密不存在。同步传输格式与合并顺序详见 [WebDAV 同步设计](webdav-sync.md)。

### 新迁移如何接入

- 本业务表变更在所属 Schema 中追加唯一迁移 ID；需要跨业务或在身份升级后执行的变更，在统一迁移入口中按依赖追加，不能提前修改冻结迁移期待的旧表结构。
- 新规则使用新版本规则/DTO 或新迁移，不编辑已发布迁移、旧身份哈希和旧编码枚举值。
- 新身份引用在业务侧提供类型化 remapping 与同步规范化，接入已有事务和提交后通知；新增数据集同时注册 participant 与变更源。
- 同步删除状态的键也要迁移，不仅修改当前可见记录，否则已删除的数据可能在下一次同步复活。
- 若迁移涉及文件，明确可重试状态、冲突和原文件保留策略；不要假设 SQLite 回滚能撤销已完成文件移动。

## 维护入口与验证

关键源码：

- [数据库与迁移注册](../../Sources/YamiboXCore/Persistence/YamiboDatabase.swift)、[Schema 契约](../../Sources/YamiboXCore/Persistence/DatabaseSchemaModule.swift)、[事务工具](../../Sources/YamiboXCore/Persistence/StoreWriteTransaction.swift)。
- [共享作品身份](../../Sources/YamiboXCore/Reader/Shared/Domain/ReadingWorkKey.swift)、[进度/历史引用](../../Sources/YamiboXCore/Reader/Shared/Domain/FavoriteContentTarget.swift)、[收藏引用](../../Sources/YamiboXCore/Library/Domain/FavoriteItemTarget.swift)。
- [漫画注册表](../../Sources/YamiboXCore/Persistence/Identity/MangaDirectoryIdentityDatabase.swift)、[运行时合并](../../Sources/YamiboXCore/Persistence/Identity/GRDBMangaDirectoryIdentityMigration.swift)、[业务 remapping 协调](../../Sources/YamiboXCore/Persistence/Identity/MangaIdentityRemapping.swift)、[冻结身份迁移](../../Sources/YamiboXCore/Persistence/Identity/MangaIdentitySchemaMigration.swift)。

持久化调整至少核对干净安装和支持的旧版本升级，关注重命名/合并后的进度与注解、清目录后保留引用、删除状态、下载文件、并发写入与失败重试。按 [核心流程回归清单](../tests/regression-checklist.md) 选择相关本地场景；阅读恢复规则见 [阅读器设计](readers.md)。

本页记录源码契约，不是数据库恢复、历史升级或同步兼容已经通过验证的证明。旧临时程序、已移除测试 target 和旧通过报告不能代替当前检查。
