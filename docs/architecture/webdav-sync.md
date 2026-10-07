# WebDAV 同步设计

本文说明当前代码中的同步范围、协调、合并和兼容边界。WebDAV 是选定业务数据的跨设备同步，不是 App 沙盒备份，也不同于从论坛拉取收藏的同步流程。

数据存储与身份规则见[持久化、作品身份与迁移](persistence-and-identity.md)，账号切换见[账号与应用生命周期](account-lifecycle.md)，图片和离线文件见[下载、缓存与封面存储](downloads-and-storage.md)。

## 1. 同步范围与远端文件

当前有 8 个数据集，由 [`WebDAVSyncContent`](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVSyncModels.swift)定义。每个数据集独立选择、读取、合并和提交，不存在一个包含全部数据的总备份文件。

客户端在用户填写的基础 URL 下追加 `YamiboX/`。除应用设置外，其余 7 个参与者通过漫画身份装饰器写入 `manga-identity-v1/` 子目录。

| 数据集 ID | 当前远端相对路径（相对 `YamiboX/`） | 实际内容 | 当前 payload 版本 |
| --- | --- | --- | --- |
| `favoriteLibrary` | `manga-identity-v1/yamibox-favorite-library-v1.json` | 本地收藏条目、分类、合集、标签、论坛收藏映射及删除记录 | 2 |
| `likeLibrary` | `manga-identity-v1/yamibox-like-library-v1.json` | 文本摘录、图片喜欢的定位与来源元数据、样式、笔记、删除记录 | 2 |
| `bookmarkLibrary` | `manga-identity-v1/yamibox-bookmark-library-v1.json` | 书签位置、作品身份和删除记录 | 2 |
| `readingProgress` | `manga-identity-v1/yamibox-reading-progress-v1.json` | 普通帖子、小说和漫画的阅读位置与删除记录 | 3 |
| `contentCovers` | `manga-identity-v1/yamibox-content-covers-v1.json` | 封面 URL、来源页、动态/手动选择、强制文字封面和删除记录 | 2 |
| `appSettings` | `yamibox-app-settings-v1.json` | 导航配置、启动页兼容字段、网页导航栏设置 | 1 |
| `mangaDirectories` | `manga-identity-v1/yamibox-manga-directories-v1.json` | 智能漫画目录、章节、内容来源谱系和删除记录 | 1 |
| `browsingHistory` | `manga-identity-v1/yamibox-browsing-history-v1.json` | 访问来源、作品、标题、板块、作者、访问时间和删除记录 | 1 |

文件名中的 `v1` 不等于 payload 的当前 `version`，不能据此推断解码规则。漫画身份命名空间也是独立的格式边界。

### 应用设置不是完整设置备份

[`WebDAVSyncedAppSettings`](../../Sources/YamiboXCore/Settings/Application/AppSettingsWebDAVParticipant.swift)只导出 `system.homePage`、`system.navigation` 和 `webBrowser`。当前 `webBrowser` 仅包含 `showsNavigationBar`。接收端优先应用导航配置；旧数据没有 `navigation` 时，只有对应标签页仍存在，才把 `homePage` 转成启动标签页。

阅读器字体与排版、主题、外设绑定、WebDAV 配置和密码等不在这个数据集中。修改不同步的设置不会改变其同步指纹。

### 图片与下载不传文件

- 封面同步的是 [`ContentCover`](../../Sources/YamiboXCore/Library/Data/ContentCoverStore.swift)行，不包含设备上保留的图片字节。接收设备根据 URL 和来源信息重新加载；来源失效或无权限时，同步元数据不保证图片可见。
- 图片喜欢同步 `LikeItem` 的 `sourceImageURL` 等元数据，不上传 `LikeImageStore` 中的图片。另一设备需要重新获取源图片。
- 离线下载文件、下载队列、正文缓存、HTTP 缓存、草稿、账号 Cookie 和凭据均不属于这 8 个数据集。同步成功不能作为这些数据已备份的依据。

## 2. 模块边界与参与者注册

同步引擎由 [`WebDAVSyncService`](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVSyncService.swift)协调，传输由 [`WebDAVClient`](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVClient.swift)负责。业务模块各自实现 [`WebDAVSyncParticipant`](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVSyncParticipant.swift)，拥有 payload 解码、存储事务、合并和本地指纹规则。引擎只读取协调元数据，不统一解释业务记录。

参与者契约包括：

- 稳定 `datasetID`、远端文件名、所需子目录及可选旧格式文件名。
- `inspectRemote`：解码并返回 `updatedAt`、可选账号 UID 与 `syncRevision`；解码失败必须向外传播。
- `mergeAndExportSnapshot`：合并远端与当前本地状态，将结果持久化，返回可上传数据与对应指纹。
- `applyRemoteSnapshot`：在保留业务删除决策的前提下应用远端，返回本次事务的指纹和 `requiresUpload`。
- `readLocalFingerprint`：读取真正参与同步的本地子集；`localFingerprintDependencies` 表达跨数据集影响。

[`YamiboAppContext.webDAVDatasets`](../../Sources/YamiboXCore/App/YamiboAppContext.swift)通过 `AppWebDAVDataset` 把参与者、store 的 `changeID` 和 `changes()` 成对登记。[运行时装配](../../Sources/YamiboXCore/App/YamiboAppContext+Runtime.swift)与服务参与者数组都从同一注册表投影，避免“能手动上传但自动同步观察不到变化”的两份清单。

新增同步业务时，应先在业务模块实现 payload 与存储规则，再补齐同一注册项、内容选项与本地变更源。不得只在引擎中加入一个文件名或在 UI 中监听零散字段。

## 3. 一轮同步如何运行

### 协调与账号边界

同一个 `WebDAVSyncSettingsStore` 持有共享的 [`WebDAVSyncCoordinator`](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVSyncCoordinator.swift)。即使 UI 或生命周期创建多个服务实例，运行任务仍排队执行。仅用 service actor 无法跨网络悬挂点串行化所有实例，因此协调器持有任务队列、取消函数和 epoch。

修改 URL、用户名或密码时，`saveConnection` 先取消并等待旧任务结束，再发布新设置。账号切换与数据重置通过 [`AccountTransitionWorkflow`](../../Sources/YamiboXCore/Account/Application/AccountTransitionWorkflow.swift)使用同一个屏障。任务在网络、迁移、存储和回执更新边界检查运行 token，旧 epoch 的任务不能继续按新连接记账。

同步需要已登录会话、非空 Cookie 和可用论坛账号 UID。WebDAV 用户名只是服务器认证信息，不能代替论坛 UID。

远端文件的 envelope 使用 `accountUID`（论坛账号 UID）做保护：新格式的 7 个身份装饰参与者与应用设置均写入该字段。非空远端 UID 与本地不同则抛出 `accountMismatch`。旧文件缺少或留空该字段时仍兼容，不等于已验证账号一致。

**远端路径没有按论坛 UID 分文件夹。** 多个论坛账号共用同一基础 URL 时，会碰到同一组文件；账号检查是内容保护，不是自动建立各账号备份空间。当前检查也不以论坛基础 URL 作为第二个身份维度。

设置页只对“上传”的账号不一致提供明确确认；“下载”始终拒绝异账号。确认上传允许业务参与者按原合并规则吸收已有远端内容后提交，并非无条件覆盖或清空远端。相关交互见 [`WebDAVSyncSettingsViewModel`](../../Sources/YamiboXUI/Features/Settings/WebDAVSync/WebDAVSyncSettingsView.swift)。

### 手动与自动方向

- 手动上传读取选中的远端文件，检查账号，再逐个参与者合并并条件提交。所有选中项都参与，不受 dirty 标记限制。
- 手动下载读取选中的远端文件并应用。缺少某个数据集不清空本地；全部不存在则报告 `notFound`。业务数据通常合并而不是替换，应用设置例外。
- 两种手动入口均先运行格式迁移。因此“下载”不是在所有情况下都只读远端：初次进入身份新格式时可能导入旧文件并上传新命名空间。
- 自动同步要求自动开关开启、连接已配置、已登录且 Cookie 非空；关闭或未登录时不发起远端请求。

所有当前参与者都只在 dirty 时自动上传。漫画身份装饰的 7 类允许未跟踪内容初始化上传；应用设置不因首次没有指纹基线就默认覆盖已有远端设置。

自动协调按数据集比较远端与本地进度。当双方有 revision 时使用 revision，否则回退 `updatedAt`。远端领先且本地干净时应用远端；有本地修改的数据集合并后上传。未上传的干净数据集仍会吸收尚未应用的远端文件，不因其他本地数据较新就忽略它们。

### 生命周期与频率

[`AppContinuityWorkflow`](../../Sources/YamiboXCore/App/AppContinuityWorkflow.swift)将本地变更合并到约 2 秒的静默窗口；频繁阅读进度变更触发的自动轮次，在最近检查后的 5 分钟内只标记 dirty，跳过网络。前台激活和进入后台的收尾检查绕过此间隔，但 15 秒内没有待上传数据的干净生命周期检查会合并。

这些是前台/后台检查点，不是每 5 分钟必然执行的常驻定时器。后台保护仍受系统给定的执行时间限制。自动失败保留待处理候选，等待下次变更或生命周期检查，不建立持续重试循环。

## 4. 传输、缓存与条件提交

客户端使用 HTTP Basic 认证，发送 JSON 数据；配置检查只判断 URL 可解析且用户名非空，不强制 HTTPS。实际使用应选择 HTTPS，避免把 Basic 凭据和业务内容经明文网络传输。当前 payload 没有应用层端到端加密，服务器可以读取同步的收藏、摘录、笔记和访问记录，应只使用可信存储服务。

读取每个选中数据集的 GET 可并发；只有 HTTP 404 被解释为“没有这个文件”。401/403、其他异常状态、空响应、损坏 JSON 或不支持版本均使本轮失败，不能降级为空数据。

协调器只缓存具有强 ETag 的远端正文，总上限 16 MiB，且缓存不跨连接、账号回执范围或重置边界。后续 GET 使用 `If-None-Match`；304 只复用配对的缓存正文。304 返回不同 ETag 时重新完整读取。请求失败不把缓存当作离线同步成功。

上传前用 MKCOL 建立 `YamiboX/` 与参与者子目录；目录已存在返回 405 可接受。提交条件是：

| 远端状态 | PUT 条件 | 行为 |
| --- | --- | --- |
| 不存在 | `If-None-Match: *` | 只允许首次创建 |
| 存在且有强 ETag | `If-Match: <etag>` | 只提交到本轮读取的版本 |
| 存在但无强 ETag或只有弱 ETag | 不提交 | 报告 `unsafeConditionalWrite` |
| 返回 412 | 重新 GET、校验账号、重新合并 | 首次加最多 3 次重试，仍冲突则失败 |

强 ETag 本身不证明服务器遵守条件请求。每个连接在协调器缓存有效期间首次上传，会创建唯一 `.yamibox-sync-probe-<UUID>.json` 临时资源，验证首次创建保护、错误/旧 ETag 拒绝和正确 ETag 更新，然后删除探针。验证失败禁止提交业务文件；探针清理失败会记录日志，不会伪装验证成功。

PUT 前清除该文件的正文缓存，因为失败或取消的请求仍可能已经到达服务端。重试必须读回远端，而不是沿用旧缓存或只重发旧导出结果。

**不存在跨 8 个数据集的原子事务。** 各业务合并在自己的存储事务中完成，上传逐文件提交并逐文件更新成功回执。后面的文件失败时，前面的本地合并和远端写入不会回滚；`lastSyncedAt` 也可能因前面文件成功而更新。不能仅看这个时间断言整轮全部成功。

## 5. 指纹、revision 与回执范围

同步设置里的回执是可丢弃的协调状态，业务数据仍存放在各自 store 中。

| 字段 | 含义 |
| --- | --- |
| `dirtyDatasetIDs` | 需要上传的候选，不等于已上传 |
| `lastSyncedFingerprintByDatasetID` | 成功上传/应用那份本地快照的指纹，不是最近一次看到变化的指纹 |
| `lastAppliedRemoteUpdatedAtByDatasetID` | 已吸收远端的时间基线 |
| `localRevisionByDatasetID` | 本设备最近生成的上传 revision |
| `lastAppliedRemoteRevisionByDatasetID` | 已吸收的远端 revision，下次不重复应用 |
| `receiptScope` | 基础 URL、WebDAV 用户名和论坛账号 UID组成的范围 |
| `contentSelectionRevision` | 内容选择变更代次，防止运行中的旧选择错误清除新 dirty 状态 |

[`SyncContentFingerprint`](../../Sources/YamiboXCore/Persistence/SyncContentFingerprint.swift)用键排序、Unix 秒时间编码的 JSON 计算 SHA-256；应用设置使用键排序 JSON 的 Base64。身份装饰参与者还把身份注册表纳入指纹。不要把 envelope 的 `updatedAt` 或 `syncRevision` 纳入业务指纹，否则每轮导出本身就会制造新变化。

导出或应用返回的是与当时存储事务对应的指纹。记账前引擎再次读取本地指纹；若期间产生新修改，或 `requiresUpload` 表示合并结果不同于远端，继续保留 dirty，而不是覆盖掉迟到的本地编辑。

上传 revision 在本设备已生成值、已吸收值、本次远端值的最大值上加一，并由引擎写入顶层 `syncRevision`。revision 比较只用于协调方向与“是否已吸收”；业务条目的冲突仍遵守各自时间/内容规则，不是所有字段都改成 Lamport 时钟。旧文件无 revision 时继续按时间比较，上传时间至少略晚于已吸收远端时间。

URL、用户名或密码改变会清空远端回执；账号 UID 改变会在下一轮 `prepareReceiptScope` 清空并建立新范围。本地业务内容不因此自动清空或转换成另一套按账号分库的数据。

关闭某个数据集不删除远端文件。重新开启时提升选择代次，标记 dirty 并移除相应指纹与已应用基线，让后续重新协调。已在进行的轮次保留自己的选择快照，并在写回时核对代次。

## 6. 合并与删除语义

多数数据集不是“最后一份文件覆盖一切”。删除历史独立于活动记录保存，设备即使从未见过被删内容，也能保留裸 tombstone，防止旧副本复活它。

[`SyncDeletionState`](../../Sources/YamiboXCore/Sync/Domain/SyncDeletionState.swift)用 `tombstones[id]` 记录单项删除、`clearedAt` 记录整体清理。两端删除时间取较新值；记录修改时间不晚于相应删除时间时被过滤。不得用仅同步活动行或 `clearAll()` 代替业务上的 `clearAllForSync()`；前者可丢掉同步删除记录，后者表达可传播的用户清理意图。

### 各数据集的冲突粒度

- **收藏库**：条目的位置、标签、展示名、论坛映射按各字段时钟分别取较新值，不简单求集合并集。分类、合集和标签按实体更新时间选择，删除的 UUID 不复用；归属已不存在分类的合集也会移除。内容派生的收藏条目 ID 可被重新收藏，`updatedAt >= deletedAt` 时允许存活并移除过期 tombstone，这是与其他数据集不同的等时刻规则。见[收藏参与者与合并器](../../Sources/YamiboXCore/Library/Application/FavoriteLibraryWebDAVParticipant.swift)。
- **喜欢**：同 ID 按 `updatedAt` 选择，等时刻保留本地，补足缺失章节标题；样式、笔记属于条目内容而非独立字段时钟。活动内容与裸删除记录分别输出，图片字节不输出。旧设备删掉未知字段后，新设备可能凭等版本本地副本保住字段，但没有本地副本时无法凭空恢复。见[喜欢参与者](../../Sources/YamiboXCore/Like/Application/LikeLibraryWebDAVParticipant.swift)。
- **书签**：按 ID 选择较新记录并应用软删除；跨设备独立建立的同作品同位置书签再去重，保留创建最早者，等时刻按 ID 决定，其余转成删除记录。见[书签参与者](../../Sources/YamiboXCore/Bookmark/Application/BookmarkLibraryWebDAVParticipant.swift)。
- **阅读进度**：同内容目标记录按 `updatedAt` 选择，等时刻保留本地，不比较百分比大小。漫画进度要求明确 `chapterThreadID`；不能凭章名猜出章节来源。见[阅读进度参与者](../../Sources/YamiboXCore/Reader/Shared/Progress/ReadingProgressWebDAVParticipant.swift)。
- **封面**：整行按 `updatedAt` 选择，保留相同图片 URL 已知的来源页信息；不能把来源页从另一幅图片或手动选择挪到自动选择。用户强制文字封面、动态开关也随行同步。见[封面参与者](../../Sources/YamiboXCore/Library/Application/ContentCoverWebDAVParticipant.swift)。
- **漫画目录**：同 ID 优先较新 `modifiedAt`，等时刻用内容指纹确定结果。当两份内容谱系尚未包含彼此时合并章节与 `contentIdentityIDs` 并推进修改时间；已包含双方来源后恢复普通较新整份目录语义，保留用户主动移除章节的决策。见[漫画目录参与者](../../Sources/YamiboXCore/Reader/Manga/Application/MangaDirectoryWebDAVParticipant.swift)。
- **浏览历史**：同步访问记录，不传由本地阅读模式推导的页码等展示字段。以来源帖子为 ID，按 `lastVisitTime` 选择；等时间用稳定指纹决定，过滤来源/作品删除后最多保留 2,000 条。该规则由冻结的 [`BrowsingHistorySyncMergeV1`](../../Sources/YamiboXCore/History/Domain/BrowsingHistorySyncMergeV1.swift)持有。见[历史参与者](../../Sources/YamiboXCore/History/Application/BrowsingHistoryWebDAVParticipant.swift)。
- **应用设置**：同步子集是快照。上传输出本地子集，下载将远端子集应用到现有设置；不会把两份导航配置逐字段合并，不影响不同步字段。

喜欢与书签的 [`SyncSoftDeletionRules`](../../Sources/YamiboXCore/Persistence/SyncSoftDeletionRules.swift)在 `deletedAt >= updatedAt` 时保留删除，更晚的新内容可存活。不要套用收藏条目的等时刻生存规则。

### 内容开关与本地删除

漫画目录和浏览历史有特别边界：关闭对应同步选项时，后续删除不新增远端同步 tombstone。历史仍保存本地删除记录以阻止旧的迟到访问写回。其他带删除记录的业务保留删除意图，待重新开启同步后参与合并。该区别由 `deletionNotice(for:)` 向用户说明，不能统一描述成“关闭后所有删除以后都会同步”。

清理、重新访问/收藏与异步刷新互相竞争时，应使用业务 store 的当前写入接口，让 canonical 身份与删除检查在存储事务中再次执行。界面隐藏某项不等于同步删除已落库。

## 7. 漫画身份与旧格式迁移

[`MangaIdentityWebDAVParticipant`](../../Sources/YamiboXCore/Sync/WebDAV/MangaIdentityWebDAVParticipant.swift)装饰 7 个业务参与者，增加顶层 `mangaIdentities` 和 `accountUID`，把身份注册表与业务指纹组合。它不替代各业务合并器。

每份新格式文件自带名称别名、旧身份映射、重定向、当前标题及标题时钟。即使用户只同步书签或摘录而不同步目录，目标身份仍能传输。目录变更是装饰参与者的指纹依赖，不能只上传目录自身而漏掉相关身份引用。

接收时先合并身份注册表，再用业务模块提供的 typed normalizer 规范化内容目标和删除键。当前写入不从显示名随意制造目录身份；进度、历史中遗留的歧义目标需要章节来源证据。无法安全解析的旧目标会失败并保持可重试，不能把同名不同作品强行合并。

[`MangaIdentityWebDAVMigration`](../../Sources/YamiboXCore/Sync/WebDAV/MangaIdentityWebDAVMigration.swift)在普通同步之前执行一次性导入：

1. 对当前选中的新文件与待导入的旧根目录文件做预检查，校验格式和账号，再修改本地身份或远端资源。
2. 旧文件只读取，不回写。将旧内容吸收入本地，再通过正常条件提交写入 `manga-identity-v1/` 新文件。
3. 基础 URL、用户名、论坛 UID、数据集和格式共同决定导入 scope。只有新文件条件上传成功后才写入 `completedMangaIdentityImports`；失败不提前标记完成。
4. `mangaIdentityBaselineScopeByDatasetID` 单独维护新格式基线，旧格式回执或另一账号/位置的历史不能压住首次新格式导出。

已完成的 scope 不反复重读旧文件。因此升级后的新旧设备分属不同文件位置，不存在自动双向回写旧格式的桥接保证。

无身份注册表的 payload 使用 [`MangaIdentityLegacyJSONV1`](../../Sources/YamiboXCore/Sync/WebDAV/MangaIdentityLegacyJSONV1.swift)兼容规则，只改结构化身份字段，不替换标题、URL、摘录或章节 TID中的任意字符串。删除名称先在旧键范围过滤；`legacy-pending:`、`legacy-name:`、`legacy-resolved:` 区分未决、旧名保护与确认删除，避免改名误删存活目录。

本地数据库的历史身份迁移与 WebDAV 导入不是同一个入口。冻结的历史格式、迁移编码和历史合并规则不能随运行时代码重构而悄悄修改；需要行为变化时新增版本化规则，详见[持久化、作品身份与迁移](persistence-and-identity.md)。

### 当前解码兼容范围

| 数据集 | 当前接收的 payload 版本 |
| --- | --- |
| 收藏库 | 2 |
| 喜欢、书签 | 1、2；旧版可缺省删除字段，当前版要求该字段 |
| 阅读进度 | 2、3；版本 2 没有当前删除状态 |
| 封面 | 1、2；版本 1 没有当前删除状态 |
| 应用设置、漫画目录、浏览历史 | 1 |

当前 envelope 的 `syncRevision` 可缺省，以兼容引入 revision 之前的文件。缺少必需字段与不支持版本依然失败，不能用默认空集合吞掉远端损坏内容。

## 8. 凭据与失败反馈

[`WebDAVSyncSettingsStore`](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVSyncSettingsStore.swift)将非秘密设置与回执写入 UserDefaults JSON；密码只在内存中填充，当前编码不输出 `password`。持久化保存的是非秘密 Keychain 引用。

[`KeychainWebDAVCredentialPersistence`](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVSyncCredentialStore.swift)使用独立于论坛账号的 service，Local 与普通环境分别命名；设置 `AfterFirstUnlockThisDeviceOnly` 且不启用 Keychain 同步。因此另一设备需要自行配置 WebDAV 凭据。

旧 UserDefaults 明文密码只在 Keychain 写入和设置重写都成功后迁移。读写失败时保留可重试的旧记录，不将设置页暂时显示为空的密码解释成删除唯一凭据。替换凭据先写新引用，再写设置，旧引用删除失败记录待清理意图，下次读取重试。

手动同步在设置页显示成功或具体失败详情，包括认证、账号不一致、文件缺失、不支持版本、条件写入能力不足、冲突和传输错误。自动同步只记录非取消错误并返回跳过，不阻塞应用主界面。用户取消或账号/连接切换引起的取消不应显示为网络故障。

排查时先区分连接错误、服务器条件请求能力、远端格式问题和业务合并问题。不要通过删除 tombstone、清空 revision 回执、无条件 PUT 或绕过账号检查来掩盖失败。

## 9. 维护与验证

修改参与者或协议时，按[核心流程回归清单](../tests/regression-checklist.md)核对以下风险场景：

- 首次启用、只选单一数据集、关闭后修改/删除再开启，以及应用设置首次吸收远端。
- 两端并发修改、等时间冲突、同位置重复书签、删除后旧副本回流和更晚重新添加。
- 远端 404、空数据、损坏 JSON、不支持版本、401/403、弱/缺失 ETag和 412 重试耗尽。
- 自动同步的本地变化节流、前后台检查、途中新增本地编辑和中途切换连接/账号。
- 旧格式仅导入一次、导入失败可重试、歧义漫画身份、重命名与删除并发，以及新旧客户端格式边界。
- 多文件部分成功后失败，确认失败反馈与各数据集回执真实一致。

以上是维护验证目标，不表示这些场景已自动测试或本次文档编写已连接服务器验收。开发验证只使用本地测试 App 与隔离的本地 WebDAV 测试环境，不使用用户配置的远端备份或生产论坛。
