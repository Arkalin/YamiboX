# 项目结构

`Package.swift` 定义两个模块：`YamiboXUI` 依赖 `YamiboXCore`，Core 不依赖 UI。
模块内部的功能目录用于组织代码，不是独立的编译边界。

运行 `bash scripts/check-architecture.sh` 可检查轻量导入约束，CI 在构建前执行同一检查：
Core 不导入 UI 模块及界面／系统交互框架，Domain/Application 不直接导入 GRDB、Kanna、Nuke，
UI 不直接导入 GRDB、Kanna。另外对小说 Application 调用喜欢 Store／解析器、喜欢 Application
依赖小说具体缓存 Store 添加定向符号检查。这些源码检查不是完整的 Swift 符号依赖图，
不替代同一 target 内跨功能依赖的代码审查。

## Core

- `App`：共享服务装配、应用生命周期与跨功能流程。
- `Account`、`Forum`、`Library`、`Reader` 等业务目录：按职责放入 `Domain`（模型与规则）、`Application`（流程与依赖契约）、`Data`（解析、仓储与存储）。小功能不必创建空层级。
- `Infrastructure`：网络、HTML、图片数据、日志与本地化等公共基础能力。
- `Forum/Data/ForumPageClient`：原生论坛页面的表单请求、附件响应、重定向准入和 WAF 重放规则；通过 `YamiboClient.performRequest` 使用公共认证与传输。公共客户端返回 `YamiboHTTPResponse`，不引用论坛表单、附件或页面策略；通用同源重定向保护仍由网络层执行。
- `Persistence`：数据库连接、迁移注册与通用持久化工具；业务 Store 和 Schema 仍由对应业务目录拥有。
- `Persistence/Identity`：共享身份注册、历史迁移和跨业务身份合并协调。各业务的 `*IdentityRemapping` 负责本业务的表；协调器传递同一个 `Database`，不另开事务、不吞掉错误。封面选择、缓存冲突和同步删除状态的处理仍由对应业务负责。
- `Forum/Data`：编辑器、用户空间、博客和帖子解析分别收拢到 `Composer`、`UserSpace`、`Blog` 和 `ForumThreadPage`。
- `Reader`：区分 `Novel`、`Manga` 和两者共用的 `Shared` 能力。

编辑器文档的纯文本解析规则随 `Forum/Domain` 中的文档模型放置。
外部 BBCode/HTML 通过 `Forum/Data/Composer/ForumComposerMarkupCodec` 转为编辑模型；Domain 不调用 Data 解析器。颜色、字号和内联样式规则属于 Domain，HTML 元素适配留在 Data。
阅读器页面投影、目录编辑草稿、收藏排序选项和缓存标识规则随 Domain 放置；下载能力契约不依赖 Application 中的实现。
阅读位置排序基础算法属于 `Reader/Shared/Domain`，段落标识解析属于 `Reader/Novel/Domain`；
Bookmark、Like 各自保留锚点适配，不互相引用对方的内部排序实现。

作品身份使用 `Reader/Shared/Domain/ReadingWorkKey`，Bookmark 与 Like 不再通过功能私有类型共享身份。
原 `LikeWorkKey` / `LikeWorkKind` 保留为源兼容别名；编码字段和枚举原始值不变，无需迁移已有数据。
收藏目标与共享作品身份之间的转换属于 Library 的领域适配。
阅读进度与浏览历史使用的 `FavoriteContentTarget` / `FavoriteContentTargetKind` 由
`Reader/Shared/Domain` 拥有；保留历史公开名称、标识和编码格式以兼容现有调用与数据，
不与收藏专用的 `FavoriteItemTarget` 或注解作品身份 `ReadingWorkKey` 合并。

各 WebDAV participant 通过 `mangaIdentityStrategy` 显式选择身份传输，并提供本数据集的指纹、
旧记录删除字段和规范化策略。公共装饰器只负责身份传输与合并顺序，不按数据集 ID 分支，
也不解码具体业务 payload。当前格式必须由 participant 提供类型化规范化器；历史和进度还以类型化引用提供章节证据，并在各自 payload 中写回解析结果。
未携带身份注册表的旧备份沿用冻结的 `MangaIdentityLegacyJSONV1` 兼容规则，不作为当前业务新增字段的扩展入口；历史数据库迁移保持冻结。
本地收藏文档、更新目标、作品引用使用各自的类型化适配器；共享层只处理身份解析和 `SyncDeletionState` 的删除键规则，不再遍历业务 JSON。
不含目录身份的收藏同步运行日志无需身份重映射。
同步删除时间取最新值的规则集中在 `SyncDeletionState.mergingTombstones`；各数据集保留自己的去重和元数据补全语义。
Like 与 Bookmark 的运行时合并共用 `SyncSoftDeletionRules` 收集软删除标记、比较更新时间并应用删除状态；
书签的位置去重、喜欢的章节信息补全仍由各自的 Merger 负责，历史迁移不引用新的运行时规则。
两类 payload 的版本检查和公共字段编解码复用 `WebDAVItemPayloadFields`，各自保留版本号、条目类型和合并语义。

漫画身份能力由专用 `MangaIdentitySyncParticipant` 契约声明，装饰器在 `YamiboAppContext` 中装配，
不由通用同步引擎识别业务类型。`WebDAVSyncService` 只接收已装配的 participant 和迁移策略；
远端目录由 participant 声明，旧身份格式的预检、导入与完成标记由 `MangaIdentityWebDAVMigration` 管理。
迁移复用引擎的账号校验、条件写入和同步收据，并在同一同步协调范围内运行；
原有命名空间、持久化标记和指纹编码保持兼容。

应用装配通过 `AppWebDAVDataset` 将同步 participant、Store 的 changeID 和变更流成对注册；
同步服务与应用级观察从同一列表派生，包括喜欢与书签。新增数据集必须同时提供变更源，
不再分别维护 participant 列表和监听列表。防抖、同步间隔、禁用数据集过滤及前后台同步策略不变。

浏览历史的 `BrowsingHistorySyncRecord` 和 `BrowsingHistorySyncMergeV1` 属于纯数据与合并规则，
SQL 放在 Data 层，WebDAV payload 仅负责传输封装。普通访问写入和数据库迁移不依赖 WebDAV payload。
`history.v3.webdav` 固定使用 V1 的合并规则与保留上限；未来变更需要增加规则版本，
不能让已发布迁移隐式使用新的运行时策略。内容指纹算法由通用 `SyncContentFingerprint` 提供。

浏览历史 workflow 通过 `BrowsingHistoryReconciling`、`BrowsingHistorySettingsReading` 和
`BrowsingHistoryProgressReading` 获取规范化提交、板块设置和进度快照，不依赖具体 Store。
正式 Store 在 Data 层适配这些窄契约；规范化提交仍在原事务内比较快照并复核删除状态，
冲突返回 false，存储失败抛错。时间线排序与保留上限由 Domain 的 `BrowsingHistoryTimelinePolicy` 提供。
`Sync/Domain/SyncDeletionState` 保存纯删除模型、快照与合并规则，GRDB 建表和读写放在
`Persistence/SyncDeletionState+Persistence`；已有编码、SQL 和历史迁移规则不变。

Core 保留系统能力的协议及业务数据，不承载系统通知和后台任务调度的具体实现。
例如 `FavoriteUpdateNotifying` 和 `DownloadQueueRunObserving` 定义调用契约，UI 提供平台实现。

`YamiboAppContext` 装配账号转换与数据重置，不直接执行这些流程。
`AccountTransitionWorkflow` 保持同步协调、停止任务、提交、清理和发布的顺序及失败语义；
`AppDataResetWorkflow` 在同一账号操作租约内顺序执行注册的 `AppDataResetStep`，失败即停止并传播原始错误。
新增重置参与者只需在装配处注册操作，不修改执行器，也不并发执行有序清理。

## UI

- `AppEntry`：窗口、导航、应用级 UI 状态与启动协调。
- `Features`：按功能组织页面、视图模型和私有组件。功能内部再按实际职责分组，不建立全局 `Views` 或 `ViewModels` 目录。
- `SharedUI/Components`：跨功能复用的组件，例如 `BookCoverThumbnail`、列表行和反馈视图。
- `SharedUI/Annotations`：Reader 与 Like 共用的笔记编辑器、注解样式、失败反馈、选择动作与分段导航状态；不依赖功能私有组件。阅读器注解面板和喜欢列表仍由各自功能拥有。
- `SharedUI/Theme`：主题、颜色与公共视觉样式。
- `SharedUI/Support`：公共展示状态、观察辅助与交互计算。
- `Platform`：系统框架适配与桥接，按 `WebKit`、`UIKit`、`Images`、`Photos`、`Notifications`、`BackgroundTasks` 分组。

公共 UI 不依赖功能私有组件。通用封面属于 `SharedUI`，收藏徽章和合集拼图仍属于 `Features/Favorites/Cards`。
UIKit 与 SwiftUI 更新回调的调度器属于 `Platform/UIKit`，不由阅读器功能拥有。
图片浏览器与漫画阅读器共用 `Platform/Photos/ImagePhotoSaver`，相册授权和保存不由漫画功能拥有。
漫画分页交互保留 `Model`、`Input`、`Rendering`、`Runtime` 分组；纯模型集中于 `Model`，避免继续嵌套单文件目录。

小说阅读器的 `NovelReaderPreparationCoordinator` 拥有初次展示阶段、准备任务、取消代次和布局请求版本。
`NovelReaderLoadingCoordinator` 拥有仓储、已准备的数据、阅读 workflow 和加载后的缓存／预取任务，
负责请求有效性、状态发布准入及访问历史记录；ViewModel 保留展示映射、导航和浮层状态。
关闭使准备与布局请求同时失效，强制刷新等待旧准备任务退出，避免旧结果覆盖新状态。
视口完成恢复后，仍由原有回调通知协调器进入可见阶段。

`NovelReaderRuntimeUpdateCoordinator` 拥有首次展示协调器，以及布局、外观、iPad 展示输入的
运行时更新决策、请求有效性与回滚。ViewModel 提供当前 workflow、状态发布与设置持久化回调，
不再持有外观应用代次。成功和失败结果都校验请求代次与 workflow 身份，关闭使待处理结果失效。
小说的滚动、分页和卷页视口共用 `NovelReaderImageInteraction` 的图片点击与长按命中规则；
各视口仍独立持有手势和回调调度器，不共享交互状态。

前后台收藏更新通过 `FavoriteUpdateMonitor.makeForLibrary` 统一装配依赖，保留各自的 Monitor 实例、
原有共享运行登记和不同的检查预算。设置页面的轻量装配不因此获得额外的漫画目录检查职责。
收藏的 `FavoriteCoverCoordinator` 独立拥有封面快照、读取代次、Store 观察和回填任务；
它与漫画详情页共用 Core 的 `MangaAutomaticCoverService`，统一首章图片解析与缺失封面补全规则。
封面读取失败不会当作缺失；提交时在事务中再次检查已有封面与强制文字封面，避免覆盖并发的用户选择。
`FavoriteBackgroundState` 拥有背景设置与图片的成对发布及过期读取过滤。
`FavoriteLibraryOrganizer` 提供分组输入并消费这些状态，不再管理上述异步任务的生命周期。

新增或调整功能时，优先通过显式参数传入服务依赖，而不是通过应用模型临时查找。
首页由 `RootTabView` 注入 Library、Account、Forum 依赖；阅读设置面板只接收阅读模型、设置依赖、外设控制器和强调色。
收藏入口也显式接收 Forum 依赖，不通过 `appModel.appContext` 查找服务；首页 ViewModel 只接收导航回调，由界面装配层执行应用导航并等待漫画打开完成。
跨功能导航装配目前仍使用 `YamiboAppModel`；这不代表所有功能目录已经成为独立的依赖隔离单元。
论坛页面只接收 `ForumDependencies`，不再携带详情页和阅读器的依赖。
首页、板块、搜索、表单页面及草稿使用 Core 的 `ForumPageContracts` 窄契约；
对应仓储工厂分别返回能力接口，页面不依赖具体仓储实现。
小说详情页的文档、帖子页和收藏工厂也返回能力接口；详情页契约由 Core 的 `NovelDetailContracts` 定义，
具体仓储在 Core 中遵循契约，ViewModel 统一通过 `NovelDetailDependencies` 获取服务，不保留额外的 provider 覆盖入口。
导航宿主接收 `ForumNavigationDependencies`，其中 `forum` 是页面服务，`destinations` 是独立的目的页装配包。
`ForumDestinationNavigator` 通过 `ForumNavigationActions` 获取账号代次和打开阅读器的能力，不持有应用模型；
需要应用级展示的目的页仍在宿主装配层显式接收应用模型，不从导航对象查找。
阅读会话的界面宿主显式接收导航依赖，嵌入式与全屏会话使用同一路径，
不在 `ReaderSessionView` 中通过 `appModel.appContext` 查找服务。应用模型在这里仅继续承担导航和展示协调。
“我的”入口显式接收 Forum 依赖和账号切换协调器，首页也显式接收账号切换协调器；登录弹窗只接收账号切换协调器和用于刷新账号快照的模型，不持有应用模型。手机设置与 iPad 侧栏沿用入口传入的协调器，不再从 `appModel.appContext` 查找服务。

身份合并继续由原有数据库写入或 schema migration 提供事务边界。历史迁移集中在 `MangaIdentitySchemaMigration` 中，保留旧 schema 的 SQL 与注册顺序；运行时重映射由各业务适配器执行，不把历史 SQL 分散复制到当前 Store。
`manga-identity.v1` 至 `v3` 仅使用 `MangaIdentityMigrationV1` 命名空间中的冻结规则、身份算法和持久化 DTO，
包括离线缓存冲突比较所需的 schema-1 页面解码器，不依赖当前业务模型或运行时重映射。
这些历史副本是有意保留的版本边界，不随运行时代码去重或升级；规则变化应注册新迁移。

`FavoriteUpdateStore` 的关键读取通过抛错区分失败与空数据；刷新失败保留最后有效快照。
收藏更新只有在结果提交与终态保存均成功后才发布完成；持久化失败进入失败状态并允许重试。
普通 Store 与下载存储共用 `StoreInvalidationBroadcaster` 的有界多播内核，
每个订阅者最多保留一个待处理的失效信号，业务接口分别保留 `changeID` 与 `Void`。
下载身份迁移提交后的失效通知通过 `DownloadStoreCore` 契约调用；替代实现或包装器必须实现该通知，不再依赖向具体 Store 转换。

第三方产品依赖与实际导入保持一致：Core 使用 GRDB、Kanna、Nuke，UI 直接依赖 Nuke，不引入未使用的 NukeUI。

收藏的远端仓储工厂只返回能力接口：同步、快捷操作和板块管理在使用方分别收窄，协议由 Core 定义，
具体仓储在 Data 层适配。封面解析沿用 `ThreadCoverPageResolving`；更新检查使用只读的
`ForumThreadPageFetching`，正式实现和替代实现都经过相同的页码、作者范围和顺序参数路径，不保留独立的 `pageFetcher` 覆盖入口。
收藏来源补全使用 `FavoriteLibraryStore.update` 在同一事务中修改最新文档；Store 不公开整库保存入口，
防止读取旧快照后覆盖并发的编辑、删除或同步结果。

阅读器设置与外设面板只接收 `SettingsStore`，论坛导航宿主由阅读会话显式传入 `ForumNavigationDependencies`，再向页面投影 `ForumDependencies`。
下载队列使用 `DownloadQueueDependencies`，小说和漫画不再为了下载面板携带账号依赖包；
历史页使用 `BrowsingHistoryDependencies`，由 Forum 或 Library 的入口依赖投影得到。
小说下载协调器只依赖 `DownloadQueueStoring` 读取队列和订阅变更，不要求漫画、图片或下载管理能力。
小说与漫画在各自的入队事务内完成规范化、下载完整性和已有任务检查，再共用 `enqueueNewWork` 创建队列记录并保存；提交成功后的通知仍由调用方负责。
小说阅读器从依赖包到 ViewModel、workflow 均使用 `NovelReadingPageRepository` 契约。
帖子、用户空间、消息、积分和博客的页面能力契约定义在 Core，`ForumDependencies` 的工厂返回对应能力协议；UI 不再声明 Repository 的协议遵循，正式装配与替代实现使用相同入口。
功能目录不通过 `appModel.appContext` 查找服务；通知响应的依赖也由 AppEntry 注入。

小说与漫画下载页共用 `ReaderDownloadSelectionSection` 的选择模式、单项选择和列表结构，以及 `ReaderDownloadStateBadge` 的状态展示；下载动作、业务状态与行内容仍由各自页面负责。

### 下载命名与升级边界

用户主动保存的离线内容使用 `Download` 命名。论坛页、projection、排版和临时图片等技术缓存仍使用原来的 Cache 名称、键格式和路径；共享的 `ReaderCacheKeyCodec` 与 `NovelReaderCacheIdentity` 不改名。

`downloads.v1.naming` 在冻结的漫画身份迁移之后执行，将下载专用表及索引从 `offline_cache_*` 改为 `download_*`，并迁移同级 `offline-cache` 目录至 `downloads`。历史迁移保留原 SQL 与旧路径；改名迁移保持外键检查开启，确保外键引用随表名更新。通常直接原子移动目录，避免复制大量文件；新旧目录并存时先复制核验，全部通过后才移除旧目录。同名异内容报错，启动页允许重试，不创建空库代替失败迁移。新目录继续排除备份。

设置兼容读取旧 `novelOfflineCache` 字段，成功解码后写为 `novelDownload`。旧系统下载会话仅用于取消和收尾，新任务使用 `download` 标识。升级保留已完成文件及队列记录，队列暂停，用户确认继续后恢复；不保留未完成单个文件的传输进度。

注解删除、笔记修改与书签操作由 `ReaderAnnotationService` 执行。删除喜欢先提交元数据，成功后才清理图片；
服务通过 `ReaderLikeMutating`、`ReaderBookmarkMutating` 和 `LikeImageWriting` 分离元数据与文件 I/O；
图片捕获只需要更窄的 `ImageLikeMetadataPersisting`，可独立替换关键失败边界而不为每个 Store 创建镜像协议。
图片捕获通过 `ImageLikeCaptureService` 共用保存流程，小说和漫画只提供各自的锚点匹配规则。
元数据写入失败时清理本次新增的图片文件，并保留原始错误。Like、Bookmark 的关键读取向上传递错误，
列表首次读取失败显示重试入口，刷新失败保留原有快照，`AnnotationOperationState` 仅负责展示失败信息。
漫画滑动和卷页视口各自持有 `MangaPagedImagePrefetchSession`，共享预取去重、加载器替换与停止规则，不共享会话状态。

图片喜欢在 `LikeStore` 的同一事务内按作品和图片锚点查重并写入；获取图片期间有其他请求先提交时，
捕获服务复用已有记录，只清理本次未被引用的图片文件。阅读进度读取通过抛错区分失败与无记录；
恢复失败中止打开，刷新失败保留已有快照，未准备好的小说阅读器退出时不保存默认位置。
小说注解由会话级 `NovelReaderAnnotationCoordinator` 管理计数、锚点、高亮、捕获和 Store 观察；
根视图仅转发视口事件并负责面板展示。分页 HTML 规则集中于 `ForumPageNavigationParser`，
收藏更新列表与通知共用 `FavoriteUpdateSummary.displayText` 的文案映射。
分页解析按模板保留板块／帖子与用户空间／博客的不同规则；后两者共用总页数提取及末页下限规则。
博客 URL 身份由 `YamiboForumURLIdentity` 统一解析，路由和列表共用 `blog-UID-BLOGID.html` 的字段顺序。
WebKit Cookie 的异步读取、设置和删除统一在 `Platform/WebKit` 桥接，浏览器、会话协调器和数据清理共用。

小说 workflow 只暴露当前与预取投影的值快照，不调用喜欢 Store 或喜欢解析器；注解协调器将快照
交给 Like 功能补全章节标题。喜欢列表通过 `NovelReaderProjectionReading` 读取本地缓存，
不依赖具体投影 Store。按段落身份查找章节标题属于小说投影的纯规则，由阅读运行时和喜欢解析共用。

小说的分页与滚动装配分别由独立的 `NovelReaderPagedContent`、`NovelReaderVerticalContent` 视图负责，
形成各自的观察边界；它们只接收视口所需的模型、布局和交互依赖，不携带应用服务包。
导航后的视口恢复与注解刷新由 `NovelReaderNavigationCoordinator.Presentation` 统一编排：
同步定位保持立即恢复，异步定位等待操作结束；搜索和注解定位失败时不执行后续展示效果。
漫画的可观察 `MangaReaderNavigationCoordinator` 完整持有导航历史、请求代次与线性阅读过期状态；
ViewModel 只转发可用性读取并提供位置恢复、预取等内容操作，不再通过 getter/setter 回调持有导航历史。
阅读器取消任务或重置历史时同时使未完成的导航请求失效。

离线缓存的队列列表、运行状态与管理快照通过抛错区分读取失败和空数据。
队列页在列表、运行状态都读取成功后才发布；管理页读取失败保留已有快照与选择，显示独立的重试入口，
子页不因读取失败退出。小说和漫画缓存面板保留上次队列计数，自动继续队列的决策也不能把失败当成空队列。
启动后的队列恢复由单个共享任务执行，成功才标记完成；失败允许下一次读取重试。

`NovelReadingResumeResolver` 是无 I/O 的位置策略，统一精确锚点、历史页码、入口默认值及作者的回退顺序。
详情、历史、收藏、显式模式切换和应用恢复共享该策略，各入口继续拥有标题、来源、预览与默认值语义。
从头阅读清除位置但保留作者范围；应用恢复仍允许原启动锚点作为历史记录缺失时的回退。

`MangaReaderLifecycleCoordinator` 拥有准备、章节跳转、相邻预取、目录与书签观察、注解刷新任务，
并管理会话状态、请求有效性和内容版本。被替换的任务取消后保留到退出，重试等待旧任务结束后才替换 workflow；
关闭会同时取消任务、通知既有功能模块停止，并使所有旧请求失效。导航历史仍由导航协调器拥有，
ViewModel 负责内容操作与展示映射。设置与阅读进度写入不作为可丢弃的展示任务取消。

漫画详情的收藏与封面仓储工厂返回消费方的能力协议，替代实现也通过
`MangaDetailDependencies` 注入，不在 ViewModel 上另设封面仓储覆盖入口。
详情与阅读器各自持有 `MangaDirectoryCommandTiming` 和计时任务，共享更新结果、失败冷却与到期规则；
按钮文案、可用性和搜索模式由 `MangaDirectoryPanelCommandState` 统一派生。
帖子 ID 的原始链接解析由 `YamiboForumURLIdentity` 拥有，路由和漫画解析器不依赖标题清洗器提取 URL 身份。
图片基础设施只转换自身流水线与传输错误，其他错误保持原类型并附加诊断，不按功能枚举错误类型。
漫画目录和共享帖子投影加载共用 `YamiboNetworkErrorPolicy` 的网络错误转换，收藏更新也使用其离线判定。
取消及非网络错误原样传播，转换后的错误保留诊断上下文；各业务仍决定提示、暂停和恢复行为。
空白字符串归一化统一使用 `Infrastructure/StringPresence` 的 `nilIfBlank`，Shared 不依赖漫画 Data 层的字符串扩展。
漫画章节窗口、目录操作和小说详情直接复用该规则，不在 ViewModel 或领域模型中维护同义副本。
论坛的收藏仓储工厂与漫画阅读器的封面页工厂分别返回 `ForumThreadFavoriteRemoteOperating`、
`ThreadCoverPageResolving`；帖子阅读器的依赖包装配和直接注入均委托同一初始化实现，保持按需创建仓储。
小说与漫画的章节评论工厂均返回 `ReaderChapterCommentsLoading`，漫画会话持有的仓储也使用该契约。
正式仓储在 Core 内遵循协议；初始评论、翻页与评分原因沿用既有 `ReaderChapterCommentsModule.Adapter`，
替代实现通过同一依赖包入口注入，不改变仓储创建时机、会话复用或取消规则。
Like、Bookmark 的普通写入共用 `StoreWriteTransaction` 的事务、成功通知与错误包装；
SQL、同步合并和条件通知仍由各 Store 决定，失败不发通知，也不重复包装已有持久化错误。

HTML 选择器的列表与后代切分共用顶层扫描器，只替换分隔条件。
TextKit 的视口采样与选区定位共用坐标到文档偏移的转换，各自保留最近文本回退和页范围裁剪。
小说富文本的两个入口共用正文／标题属性构造，保留各自的标题定位和内联样式语义。
离线缓存按任务或条目取消共用事务内查找、删除及图片清理流程，成功提交后才通知，失败沿用原错误包装。
漫画相对翻页的可用性与执行共用目标计划；跨章不可用时仍保留执行路径的边界反馈。

账号登录与签到的 HTML、表单字段及远端请求由 `Account/Data` 的远端仓储负责；
应用流程通过 `AccountRemoteContracts` 消费类型化结果，保留会话代次校验、Cookie 隔离、
WAF 恢复、签到验证等待和本地提交顺序。签到推广访问仍独立执行，且仅携带 WAF Cookie。
收藏更新引擎通过 `FavoriteUpdateStatePersisting` 与 `FavoriteUpdateLibraryAccessing` 访问存储；
收藏来源回填仍在 Store 的单次读改写事务内进行，不暴露整份文档的任意写入能力。
普通帖子与智能漫画的检查顺序、预算和终态提交规则保持不变，不引入新的策略注册框架。
小说缓存操作仅保留正在使用的离线队列适配器，仓储的公开缓存 API 保留兼容性。
漫画章节与位置跳转共用加载后的窗口提交；单页与双页缩放共用显示坐标下的边缘规则，
各自保留已加载目标查找、初始对齐及用户坐标转换语义。

漫画目录的批量读取、目录读取和变更观察分别由 `MangaDirectoryBatchReading`、
`MangaDirectoryReading`、`MangaDirectoryChangeObserving` 声明；完整持久化契约组合这些能力。
批量查询没有逐条回退实现，观察也没有空标识或静默流的默认实现，替代实现必须显式满足契约。
收藏同步与更新检查只接收批量读取能力，收藏组织器接收读取和观察能力；装配包保留完整契约，
不绑定具体漫画目录 Store。正式 Store 的分批 SQL、目录复用和提交后通知行为不变。

TextKit 分页索引与行裁剪共用纯行矩形计算，统一文档坐标转换、垂直容差与有限值检查；
两条路径仍分别决定遍历范围、空白过滤、终止条件和结果收集，不合并各自的遍历流程。

## App 入口与资源

`YamiboX` 保存 App 入口、应用资源和系统配置。启动层创建平台服务，并将其通过 Core 协议注入业务流程。
离线缓存后台协调器由启动层创建，同一实例用于后台任务注册与缓存队列生命周期通知。
不使用缓存队列的签到、环境准备入口可以不提供该观察者。

iOS 26 起，用户开始/继续下载通过 `BGContinuedProcessingTask` 申请持续运行；
系统提供实时活动，不使用自定义 ActivityKit Widget。请求使用 `.queue`，
等待授权或提交失败不阻塞原有传输。前台发起的持续运行不依赖环境的
`supportsBackgroundRelaunch`：本地测试 App 也可申请，但仍不支持无地址参数的冷启动。

Core 的 `DownloadRunID` 隔离逻辑下载轮次；进度、终态及系统取消回调都绑定该轮次。
平台协调器在 MainActor 上串行管理注册、待启动申请、系统任务与节流更新。
启动回调只附着到有效轮次，不能启动队列；暂停/失败/完成会取消待启动申请，
迟到回调直接结束。系统取消闭包捕获原 executor 与轮次，不查询当前账号的 executor。
用户命令串行执行；内部身份迁移和删除单项更换 worker generation，但保留逻辑轮次。

整个队列只产生一个系统活动，按下载项等权汇总；项内准备、传输、落盘分别占
5%、90%、5%，成功保存后才记为完成。运行中追加会更新分母，删除不增加完成数。
图片通过下载 delegate、附件通过原请求 delegate 的任务字节观察上报进度，
附件重试会解绑前一次观察。未知长度只展示接收字节，不推算百分比。
字节进度仅驻留内存，经有界 AsyncStream 汇总；系统普通更新最多每秒一次，
阶段变化与终态立即更新。强制结束进程后不保证持续运行，系统亦可随时到期暂停任务。

构建缓存不属于源码结构。当前没有测试 target，不保留空的测试宿主或测试支持目录；验证遵循根目录 `AGENTS.md`。
