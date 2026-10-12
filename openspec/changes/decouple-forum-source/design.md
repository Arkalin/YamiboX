# Design

## Context

动机和与 `enforce-reader-module-boundaries` 的关系见 [proposal.md](proposal.md)。本设计以当前两 target 代码为实施基线，不把旧变更的未勾选任务当成已经落地的能力。

| 已核对的现状 | 设计必须处理的后果 |
| --- | --- |
| `Package.swift` 仅有 Core/UI；Core 同时依赖 GRDB、Kanna、Nuke | 只增设 Source 而保留当前 Core，不能消除传递耦合 |
| `YamiboClient` 结合传输、凭据快照、代次校验与 WAF 恢复 | 不能只抽出一个 `request(URL)` 协议；安全检查与可重放策略必须保留 |
| `YamiboForumEnvironment.current` 读取 Bundle/启动参数，并混合站点规则、Keychain 与后台标识 | Source 接收环境值；启动解析与平台/存储命名归宿主 |
| `ForumCacheStore` 管理 DTO、TTL、账号代次，同时默认打开数据库 | 来源缓存语义与存储执行必须分开，不能保留默认 Store 构造 |
| 小说请求暴露 `threadID/view/authorID`，漫画快照携带 `ForumThreadPage` | 中立契约需要语义转换，不是给属性改名 |
| `MangaDirectoryWorkflow` 混合远端发现、冷却、本地编辑与身份提交 | 远端发现归 Source，本地阅读策略归 Reader，原子重映射归 UserData |
| 当前下载实现是 `DownloadStore`/`DownloadPayloadFiles`，仍解码论坛页并构建小说投影 | 不能沿用旧提案中的 `OfflineCacheStore` 名称假设问题已解决；活跃载荷、指纹和身份校验需要单独拆解 |
| `SessionState` 自身包含论坛 Cookie 名称与域规则 | 把 `SessionStoring` 原样搬入 Core 仍不是中立边界 |
| 图片管线持有会话、封面及离线 Store，并创建磁盘缓存；维护包装执行队列化清理 | 必须处理普通图片缓存的同步访问契约及物理维护，不能靠异步端口同步阻塞来桥接 |
| 网络传输/日志还被 WebDAV 和应用更新使用 | 不能把整个 Networking 目录迁入 Source |
| 架构脚本仅检查旧 Core/UI 的 imports 和部分符号 | 需要 target 图、闭包、负向证据与 API 审阅，现有脚本通过不证明新边界成立 |

规范性验收分别见 [模块边界规格](specs/forum-source-boundaries/spec.md) 与 [运行契约规格](specs/forum-source-runtime-contracts/spec.md)。以下名称除现有符号外均是拟议职责名，实施时遵循现有命名风格，不因此承诺新增通用框架。

## Goals / Non-Goals

**Goals:**

- 用实际编译图约束所有权，用窄能力表达运行连接；这两类关系不能互相冒充。
- 来源既能向 Forum 暴露必要专用 API，也能为 Reader/Library/UserData 实现不包含论坛假设的能力。
- 对账号代次、缓存清理、下载文件提交和身份事务定义明确的线性化边界，不把异步适配简化为方法转发。
- 从当前代码的小说、漫画、详情、收藏、更新和资源需求提炼最小契约，并保留已发布编码。

**Non-Goals:**

- 不追求 Source 与任何共享值都零依赖；依赖净化后的 Core 是明确接受的边界。
- 不增加 Contracts、Support、Adapter、Sync 或临时 Legacy product，不通过服务定位器隐藏实现依赖。
- 不重做 Reader 视口、交互或完整内部封装验收，不重新设计论坛、账号、设置页面。
- 不引入第二个正式来源、来源注册/插件框架、新存储格式、账号分库或依赖版本升级。

## Decisions

### 1. 七个真实 targets 与 App 组成唯一最终依赖图

| Target | 项目内直接依赖 | 责任 |
| --- | --- | --- |
| `YamiboXCore` | 无 | 中立值、必要跨模块能力、纯规则、共享 L10n |
| `YamiboXUI` | Core | 通用展示、图片解码/显示、显示相关平台桥接 |
| `YamiboXReader` | Core、UI | 小说/漫画准备、阅读策略、位置、目录编辑、阅读 UI |
| `YamiboXLibrary` | Core、UI | 书库、历史/注解管理、详情、收藏同步与更新工作流、下载管理 UI |
| `YamiboXForum` | Core、UI、ForumSource | 论坛浏览/编辑/消息/账号业务与专用 UI |
| `YamiboXForumSource` | Core | 论坛协议、来源模型、解析、远端能力、内容与资源适配 |
| `YamiboXUserData` | Core | 数据库、文件、账号 vault、设置兼容、Store、身份事务、队列与同步 |
| 现有 App target | 按使用直接依赖以上 products | 装配、窗口/顶层导航、跨模块生命周期与平台入口 |

以上为项目内依赖，不表示禁止必要系统库和现有第三方实现。GRDB 仅归 UserData，Kanna 仅归 Source；Nuke 按真实职责归 Source/UI/UserData：Source 使用请求管线，UI 使用解码展示，UserData 使用已有 `DataCache` 与维护包装执行物理缓存。第三方类型不进入 Core 或跨模块公开签名，版本继续以 manifest 为准。

UserData 使用 Nuke 是对旧提案“仅 Source/UI 使用 Nuke”的有依据细化：把持久缓存执行留在 Source 会破坏所有权，重写其缓存或用同步等待异步 Store 则增加行为变化和死锁风险。共享同一现有依赖不形成 Source 与 UserData 之间的模块边。

Core 不能留下 AppContext、具体网络/数据库执行、论坛 DTO、账号流程或阅读/书库工作流。公共 UI 不能留下功能 ViewModel、路由容器或来源资源签名。内部目录不是新编译层。

旧提案允许的 `Library -> Source`、`Library -> UserData` 和 `Forum -> UserData` 在本变更交付时全部退出；不为未使用的过渡边添加依赖。Xcode 显式链接 App 实际导入的 products，不能靠 UI 重新导出；App 可访问入口使用明确的 `public` API，不假定 App 与 package 共享 `package` 访问身份。

**Alternatives considered:** 只切 Source 会把当前 Core 变成隐形 Legacy；额外建立 Contracts/Adapters targets 会改变已选模块粒度。选择协调迁移必要实现，同时不扩大为每个业务的全面重写。

### 2. Source 提供双类出口，Core 只收真实共享语义

Source 的公开工厂接受显式运行输入，返回按用途划分的能力，不提供暴露所有内部对象的容器：

- 论坛专用出口：板块/帖子、搜索、登录/资料、消息、发帖/编辑、评论/评分、远端收藏等所需 API 与 DTO，供 Forum 使用。
- 中立出口：内容与目录加载、来源发现、详情资料、远端收藏读写、更新信息、下载材料、资源读取。按真实调用方拆小能力，不把全部功能放进一个万能 Source 协议。
- Source 内部：HTTP 请求构造、HTML/BBCode 解释、来源分页、来源模型编码、WAF/资源策略。除明确公开的 Forum 能力外保持 internal。

Core 放跨实现的 `SourceID`、作品/章节/内容片段引用、不透明位置/范围、内容块、资源引用、结果/错误和必要消费能力。Source 专用的环境、认证提供者和缓存端口定义在 Source；App 实现这些端口并接入 UserData。仅单一业务使用的协议留在该业务，由 App 桥接，不因“是协议”自动进入 Core。

论坛 DTO 不复制到 Core；既有 `ForumThreadPage`、`ThreadID`、`FormHash`、来源型启动包不成为中立签名的别名。契约的参数、返回值、关联类型、默认实现及工厂都审阅；不以 `Any`、任意字典或向下转换藏回来源实现。共享设置使用中立值切片，UserData 私有兼容 DTO 负责原聚合编码，编辑状态仍归各功能。

**Alternatives considered:** Forum 也完全中立会把所有论坛特性复制成另一层社区 API，超出用户确认的边界；直接给 Reader/Library 提供 Source 仓储则不能验证替换。双出口保留有意耦合，移除非论坛耦合。

### 3. 显式运行输入与副作用所有权

| 外部能力 | 契约位置与来源使用 | 实际实现/所有权 |
| --- | --- | --- |
| HTTP 传输 | Core 的中立传输值/能力；请求、响应、进度、取消、响应体限制与重定向准入 | App 的通用 Foundation 传输桥接，供 Source、WebDAV、更新复用 |
| 站点环境 | Source 的不可变配置，包含端点、站点身份、Cookie/URL 策略输入 | App 解析启动/构建配置并选择实例；存储路径和平台标识另行交给 UserData/平台桥接 |
| 凭据与有效性 | Source 窄凭据快照、校验与条件更新端口 | UserData 提供中立账号快照和受保护提交；App 转换，不交出整个账号 Store |
| 安全验证 | Source 的类型化挑战/结果端口，不持有网页对象 | Forum 承载交互，App/平台桥接 WebKit 生命周期及实际凭据提交 |
| 来源缓存 | Source 的原始字节、时间/索引、批量、清理与在途协调端口 | UserData 受限存储能力；App 只映射输入输出 |
| 封面/离线/普通资源字节 | Core 的资源值与字节能力；同步普通缓存另用窄缓存端口 | UserData 的现有文件与缓存执行 |
| 诊断与时间 | 中立脱敏事件端口；按需要注入时钟 | App 接日志能力，UserData 持久化/查询日志；时间缺省值仅允许无副作用纯取时 |

`YamiboClient` 保留来源请求流程，但不再创建全局会话或读取当前 App 环境。通用传输执行不实现论坛解析、认证/WAF 决策或存储策略；这些规则由 Source 以请求选项及重定向准入能力传入。保留现有逐尝试日志、响应体上限、流式字节进度、取消和 delegate 行为，不能退化为一次性 `data(for:)` 包装。

`NetworkLoggedTransport` 拆出通用执行与日志事件，`NetworkLogStore`/持久记录归 UserData。脱敏在事件离开传输/来源边界前完成，不把 Cookie、授权头或私密正文交给显示层。WebDAVClient 留在 UserData 同步内部，应用版本更新检查的业务编排归 App，均注入同一个中立传输实现，不经 ForumSource。同步所需的账号身份与授权检查由中立上下文保留，来源独立不等于允许未授权同步。

Source 创建不得访问数据库、磁盘路径、Keychain、`Bundle.main`、`ProcessInfo` 或全局 AppContext；本地 Docker URL 兼容和论坛 Cookie 识别规则可留在 Source，但使用实例配置。Local App 的参数验证、站点切换清理和禁止生产回退保持宿主责任，语法只在既有启动参数文档维护。

**Alternatives considered:** 将所有网络实现留在 Core 会破坏薄 Core；将所有网络迁入 Source 会迫使 WebDAV/更新反向依赖论坛。小型共用传输端口来自已有多消费者，而不是为未来来源预造网络框架。

### 4. 身份、内容、位置和宿主动作按语义切开

运行时引用至少区分稳定来源命名空间、来源内作品/章节/片段标识和不透明定位符。账号作用域与运行代次是独立上下文，不进入持久作品身份；本地/正式环境继续按已有隔离规则运行。本轮只实现既有来源的持久映射，不宣称支持任意来源写入旧数据库。

- `NovelPageRequest` 与 `NovelReadingWorkflow` 中的论坛页请求/`view + 1` 逻辑迁入 Source；Reader 使用来源提供的后续位置、章节引用与显示用进度，显示序号不是请求地址。
- 小说 HTML/帖子解释及来源相关投影构建归 Source；Reader 保留已解析文本/媒体的窗口、布局、恢复、阅读状态与交互策略。
- `MangaReaderProjectionSnapshot.sourcePage` 从消费边界移除；Source 返回中立媒体/章节内容，兼容原始载荷只通过专门的下载/缓存能力传递给存储，不送入阅读 UI。
- `MangaDirectoryWorkflow` 拆出标签、板块、作者范围、搜索聚合和远端冷却等来源发现；Reader 保留手工目录编辑与选择，UserData 执行最终身份命令。
- `YamiboThreadRouteResolver` 拆为 Source 解释 URL 与内容事实、Forum/App 依据设置决定帖子/小说/漫画展示；Source 不持有 `SettingsStore`。
- 评论、评分、原帖等用类型化可选宿主请求及结果连接 Forum。Reader/Library 不持有 Forum 页面会话或 ViewModel；不可用能力有显式状态，不用空实现冒充成功。

**Alternatives considered:** 把 `tid` 改叫 `contentID`、把论坛页包进 opaque 对象仍要求消费者理解相同规则；引入完整通用出版物模型又超出现有场景。选用现有小说/漫画能验证的最小中立表示。

### 5. 缓存语义在 Source，字节与索引执行在 UserData

`ForumCacheStore` 拆成 Source 的来源语义缓存和 UserData 的原始缓存存取；App 适配不决定 TTL、编码、账号清理范围或执行 SQL。来源保留现有 namespace/key、缓存 envelope 编码、有效期及容量规则，不借拆分统一改键或重建数据库。

缓存端口提供明确的命中值/未命中及可抛错误、允许过期读取、批量/删除、作用域有效性和清理等待。Source 解码并按既有调用点决定可再生缓存的记录后回源策略；原 `loggedGet` 的可用性降级不是低层端口吞掉一切错误的理由。取消、会话失效与真正持久化失败分别处理。

首页/板块保持既有 accountGeneration、在途写入登记、推进代次/等待/清理顺序。线程缓存、普通图片与设备共享资料按原策略处理，不声称全部缓存原本已按账号分区。新会话的有效结果与旧请求结果必须可区分，但不能用一次模块搬迁悄悄修改共享数据归属。

**Alternatives considered:** Source 直接导入一个“稳定 UserData façade”仍开放整个实现模块；只做 `get/set` 字典会丢失清理与写入竞态保护。保留最小但完整的生命周期端口。

### 6. 下载保存中立准备结果和不透明兼容载荷

Source 提供下载材料准备能力：中立目标身份、已解析内容/资源清单、现有格式的来源载荷字节、格式版本及来源内容判等信息。UserData 负责持久队列、读取恢复、文件命名、完整性、原子提交、取消与发布，不导入论坛页或 Reader 实现。持久执行器可通过 Core 能力调用 Source，但实例由 App 注入。

`DownloadPayloadFiles` 中小说正文投影与论坛页编码、`DownloadStore` 中活跃漫画来源页解码/内容身份校验移到 Source。UserData 仍检查文件长度、字节完整性、目标记录和任务版本。来源内容校验通过注入的纯同步 validator 返回中立事实；用于事务内身份重映射/冲突判断时不得调用网络、持久 Store、异步等待或产生新副作用。事务外准备的数据仍需在提交时校验当前记录，不能把原锁内判断提前后留下竞态。

保留两种不同的既有指纹语义：漫画按已保存来源载荷字节计算；小说按排除浏览/回复计数、formhash、管理动作等字段后的规范编码判等。不能将两者统一成新 JSON 排序或新内容摘要。原始载荷/投影的编码键、文件名、schema 与读取回退均保持兼容。

小说已下载页的自动刷新仍复用现有持久工作者并串行处理，不从新 Source 工厂另启队列。任务删除、替换、账号或目录身份改变时继续停止并等待，提交保留既有元数据/任务身份条件，防止迟到刷新恢复已删条目。跨目录、下载、历史、喜欢/书签的重映射仍由 UserData 同一事务协调，通知在提交成功后发布。

历史 `MangaIdentityMigrationV1+SourcePage` 的私有 schema-1 DTO 继续冻结在 UserData，只为旧格式迁移服务，不引用当前 Source 模型，不变成新公共论坛模型。活跃格式与冻结迁移副本的用途必须在代码边界中明确区分。

**Alternatives considered:** UserData 继续解码当前论坛模型会形成反向依赖；把整个下载 Store 移入 Source 会把用户数据和队列带进来源；只传 `Data` 又不足以保护身份。选择字节加明确元数据/校验能力，并保持真正的提交权在 UserData。

### 7. 图片管线保留请求语义，物理缓存移出来源

Source 保留 `YamiboImageLoadCoordinator` 的请求合并、冷却、安全验证以及 Cookie/Referer/UA 等签名规则，消费方只提交资源引用并接收字节/进度。内存请求身份继续包含 URL、来源页、凭据、UA 和代次，不能仅以 URL 合并不同授权请求。

`ContentCoverStore`、离线资源文件、普通图片 `DataCache` 及 `YamiboMaintainedImageDataCache` 的物理维护由 UserData 创建和管理。Source 的 Nuke `DataCaching` 包装通过 App 注入的窄同步字节缓存能力转发；接口保持现有线程安全的同步读取/写入入队语义，不用 semaphore 或主线程等待把异步 actor 强转同步。

UserData 保留现有后台 flush、清理队列/锁、removeAll 与维护窗口代次协调、失败后重试时机。Source 不构造缓存目录，App 不重写 eviction 算法。普通磁盘缓存现有 URL key 和设备共享离线数据不因请求内存身份扩展而改格式；二者的安全语义须分别验证。UI 使用 Nuke 解码/显示，但不读取凭据 Store 或推导论坛请求。

**Alternatives considered:** 为避免 UserData 使用 Nuke 而重写物理缓存增加无关风险；让 UI 创建完整论坛图片管线则把协议重新泄漏到公共展示。选用现有实现分层，版本不变。

### 8. 会话协议、持久状态与账号转换分别归属

Source 负责 Cookie 选择/域判定、远端登录/验证/退出、WAF Cookie 合并规则与来源账号识别。UserData 负责通用凭据字段、账号记录和正式 vault 的原子持久提交；历史 `SessionState` 编码以私有兼容 DTO 保留，读取旧 Cookie 字符串所需来源解释经纯能力注入，不在 UserData 重写论坛规则。

Source 只获得凭据快照、会话有效性检查和受条件保护的凭据更新能力，不获得保存账号列表、全量重置或设置操作。Core 中共享的是中立 HTTP 凭据/账号值与有效性标识，不是带论坛域逻辑的旧 `SessionState`。App 适配只映射这些值；Cookie 解析、合并和登录判断不能藏在适配器里。

请求发出前、关键网络/WAF await 后、发布与持久提交前保留有效性检查；更新凭据由 UserData 在同一受保护提交点检查预期代次，避免 `validate` 与 `save` 分离的检查后竞态。账号操作 lease、会话 generation、缓存 generation、下载任务身份和同步 epoch 各司其职，不能合并成单个布尔值。

账号/资料 UI 与业务入口归 Forum，跨模块 `AccountTransitionWorkflow` 与 AppContext 装配移至 App 的明确生命周期区域，不把普通账号业务全部迁入 App。顺序保留：保存草稿 → 开始身份转换 → 同步屏障 → 停止/等待账号、下载和网页活动 → 清理对应缓存 → 提交账号 → 基于实际会话清理/接入 → 发布/释放。候选登录继续使用隔离存储、ephemeral 传输和非持久 WebKit；退出保持本地提交后尽力远端退出。失败按既有阶段语义收尾，不假定全局回滚。

**Alternatives considered:** 直接注入现有 `SessionStoring` 最省签名改动，却仍暴露论坛语义及过大权限；只注入 Cookie 字符串又丢失域、期限、有效性与安全提交。使用快照加最小条件更新能力。

### 9. Library、Forum 和公共 UI 完成调用方迁移

`FavoriteRepository` 的远端抓取/增删属于 Source；本地收藏命令、合并/更新编排与显示属于 Library。Library 从 Core 能力获得中立远端条目、游标和更新信息，不接收 `FormHash` 或直接构造来源仓储。远端收藏令牌、翻页和来源错误转换由 Source 完成，不能由 App 代做。

Forum 继续使用专用公开 DTO/API，但草稿、账号和设置通过消费能力接入，移除具体 UserData imports。发帖/编辑的表单、BBCode/提交协议归 Source；编辑选择、历史、草稿状态和用户操作归 Forum，不能整目录照搬。Reader/Library 的来源型默认初始化器与 Store 默认值删除，由 App 按需装配，保持原会话复用和取消时机。

原 UI 的业务页面分别落入 Reader/Library/Forum；仅通用展示留 UI。顶层导航、跨功能阅读会话、全局设置聚合、关于、数据管理/同步设置及平台任务接线归 App；数据库、同步算法与阅读交互不随入口迁入 App。共享 L10n 仍归 Core，`ForumEmoticons.json` 与解析相关资源归 Source，图片/视觉资源按实际使用归属，避免同资源重复编译或错误使用 `Bundle.module`。

**Alternatives considered:** 先保留 Library 直连 Source 可以快速编译，但不能达到本变更的最终边界；把所有无法归类的页面留 UI 或 App 会重建聚合层。按现有责任迁移，不同时重做页面行为。

### 10. 兼容转换不等于升级存储格式

运行时中立引用到已有论坛持久键的映射有明确来源准入；未知来源返回不支持，不把任意 opaque ID 当成 TID。UserData 保留数据库列名、设置/vault 编码、同步 payload、迁移顺序、下载命名与身份冲突排序。Source 保留现有活跃来源载荷编码，App 仅连接转换能力。

实施前从 Local App 生成或复制同版本本地样本，记录数据库版本、关键记录身份、下载文件名/字节指纹、账号/设置和 WebDAV 载荷；不能读取生产账号来补样本。升级后除预期运行变动外，对比对应字段和完整性，不以“页面能打开”替代存储兼容证据。样本可再生缓存、旧迁移格式和受保护账号文档分别验证，敏感字段不写入报告。

**Alternatives considered:** 同时升级所有模型/文件格式会使边界迁移与数据迁移无法独立归因。保持已有格式并显式分离运行值与兼容编码。

### 11. 四类证据联合验收，不新增单元测试体系

| 验收层 | 证据 | 不能替代的其他证据 |
| --- | --- | --- |
| 编译图与准入 | 解析 manifest 输出，检查 targets、白名单/传递闭包、imports/定向泄漏、禁止重导出；注入负例得到非零结果 | 不证明全部语义 API 中立或运行正确 |
| 来源独立装配 | 仅 Core/Source 及允许第三方闭包的临时集成宿主，显式内存能力完成代表性协议读取，列出实际构建输入 | App 构建不能证明此闭包 |
| 消费者替换 | 不实例化或调用 Source 的中立内存来源，驱动阅读、详情、发现、收藏、更新与失败/取消/可选能力流程 | 静态禁止 import 不证明消费者没有论坛假设 |
| Local App 回归/兼容 | 签名有效的 Local App、本地论坛和旧数据；账号竞态、下载删除/刷新、资源与非论坛请求证据 | 替身成功不能证明真实接线与格式兼容 |

扩展 `scripts/check-architecture.sh` 而不是建立另一套冲突准入。manifest 用 `swift package dump-package` 的结构化 JSON 解析，不以正则猜 target 定义；源码检查继续准确声明自身范围，覆盖修饰/限定/重新导出形式及已知泄漏，不自称完整 Swift 语义分析。实际编译与人工公开签名审阅补足其不足。

负例在临时源码/manifest 副本注入：缺失/空 target、非法直接边、Core 中转边、禁止 import/重新导出、已知来源类型泄漏；检查定位与非零退出后丢弃副本，不污染工作树。复用现有 CI 的统一架构入口并更新必要路径，不删除既有质量门槛；CI 当前普通 scheme 的编译步骤不作为本地交互验证入口。

不新增 XCTest/Swift Testing 单元测试、测试文件或测试 target，不恢复 UI 测试 host，也不把原 `swift test` 当验证入口。允许构建闭包检查、临时集成宿主/内存装配验证和 Local App 交互；不得以“宿主”改名规避单元测试授权。若需要新增解析器/持久层单元用例，另行申请而不阻塞其余已授权验证。

独立闭包在临时目录针对 iOS Simulator SDK 做编译检查，不给产品 manifest 增加第八个 target。运行验证仅由现有签名 Local App 调用该最小装配入口，分别提供纯内存端口或中立来源替身，不另行安装/启动其他测试 App。记录“编译宿主未依赖哪些模块”与“Local App 此流程实际未实例化/调用哪些实现”两种证据，不把同一进程链接了其他 products 的运行记录声称为独立进程证据。

本地构建选可用 iOS 模拟器并使用 `YamiboX-Local`；安装交互保留签名。每次启动显式传入 `http://127.0.0.1:8088`，参数和导航目标参照 `docs/tests/launch-arguments.md`，不在新文档复制另一套参数。站点不可用先诊断本地环境，不改用生产；模拟器不支持的系统后台表现单列为未验证，不宣称通过或擅自改用真机。

**Alternatives considered:** 仅增加 import grep 和一次 App 构建成本低，但不能发现 Core 绕行、来源假设或丢失生命周期语义；重新建立完整测试体系则未经授权。使用分层且有边界的现有可行验证。

## Risks / Trade-offs

- [协调迁移范围大] → 在原 target 内先整理边界，再按一个明确批次切换七模块；不承诺每个文件移动都能独立编译，不交付永久过渡边。
- [Core 以“共享”名义再次膨胀] → 每项公开值/能力记录实际消费者；来源专用端口留 Source，纯局部业务协议留业务。
- [App 适配器吸收真实算法] → 审阅只允许接线、值转换和宿主生命周期；HTML、分页、来源缓存策略、SQL 和指纹算法有固定归属。
- [Swift 并发隔离在迁移时改变] → 保留 MainActor UI 入口、Sendable 约束、actor 边界和取消等待；不靠新增不安全注解压过编译错误。
- [载荷字节或身份变化造成离线失效] → 保持 codec/文件名/指纹与冻结迁移，验证旧本地样本；运行引用与持久键分开。
- [同步缓存桥接造成阻塞或清理竞态] → 复用现有 DataCache 同步能力与维护队列，不同步等待异步 actor；专门验证清空与维护交错。
- [会话校验与提交之间发生切换] → 凭据、任务/记录版本和缓存代次在各自最终提交点条件校验，不能仅在请求入口检查。
- [旧变更与本变更重复搬迁] → 实施前明确唯一协调批次；复用已落地部分但分别核对验收，不修改旧任务掩盖未完成工作。
- [本地论坛不具备部分生产专属能力] → 用本地协议材料或中立替身验证契约，明确列出产品未覆盖项；不接入生产绕过限制。

## Migration Plan

1. **锁定本地兼容基线与职责清单。** 依据上述现状生成当前调用/文件归属及公开入口清单；保存可再生的本地样本和关键并发操作基线，不把这一步拖成重新研究架构。
2. **在原编译布局中准备中立边界。** 提炼实际能力、位置/资源值及结果语义，拆出来源端口、纯 codec、存储字节/事务接口和受保护提交；既有路径仍是唯一运行路径。
3. **完成来源/存储/宿主分割后协调切 target。** 同一可构建批次移动 Source、UserData、Reader、Library、Forum、App 与残留 UI，更新 manifest/Xcode/资源和调用方。不把空壳 target 当完成，也不保留两套同时执行的队列或观察。
4. **清除全部过渡接线。** Library 远端能力、Forum 存储能力、公共 UI 资源能力全部由 App 注入；清除旧具体默认值、重导出和 Core 聚合实现。若旧变更已先完成模块切换，直接从其已验证归属补齐此步及缺失的端口，不重复移动。
5. **按四类证据验收。** 先图/独立闭包，再替换流程与 Local App；对新增失败定位回边界/生命周期，而不是放宽准入。已通过项不无故重复，未覆盖项留有明确证据与原因。
6. **同步架构事实与实施记录。** 更新架构、网络/路由、账号、下载、持久身份、资源相关文档；仅维护实际变更的说明，不改旧变更复选框或主规格来冒充归档。

切换前保持一个可构建恢复点，切换批次未完成不发布。回退通过还原本次代码/manifest/项目接线并重新构建完成，不用破坏性 Git 操作覆盖其他人的工作；本变更不引入 schema 升级，因此不依赖反向数据迁移。验证中破坏的本地样本可从保存副本恢复，不触碰生产或无关用户数据。确认旧数据兼容失败时先修复边界转换，不通过清空全部用户数据让验证变绿。
