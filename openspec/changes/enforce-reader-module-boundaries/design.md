# Design

## Context

动机与范围见 `proposal.md`。本次修订替代此前按契约、阅读业务与阅读 UI 分层拆 target 的方案，采纳“业务模块拥有自己的 UI、共享模块保持薄”的结论。实施基线是当前工作树，不是仅有 HEAD；已有未提交的调整不能回退或覆盖。当前 manifest 仍只有 Core、UI 两个源码 target，新边界尚未实施。

已核对的约束如下，文件名表示当前归属，不表示整目录搬迁：

| 现状证据 | 对设计的约束 |
| --- | --- |
| 两类 ReaderDependencies 暴露具体 Store，漫画 ViewModel 还有图片流水线默认构造 | 迁移必须包含能力注入、默认值和工厂返回类型，不能只搬 View 或协议 |
| NovelReadingWorkflow 同时包含协议与具体 Repository 遵循 | 实现侧遵循必须离开共享契约，不能让 Core 反向依赖 Source |
| NovelPageRequest 以论坛页码请求，漫画投影快照包含 ForumThreadPage | 来源中立性是语义改造，不是给帖子 DTO 改名 |
| MangaDirectoryWorkflow 处理标签／板块／搜索，小说投影构建包含 HTML 回退 | 来源解释进入 ForumSource，纯内容定位与阅读策略留在 Reader |
| ForumCacheStore 同时管理论坛 DTO、缓存策略和数据库；OfflineCacheStore 编解码 ForumThreadPage | 必须拆分来源语义与存储执行，不能让 Source、UserData 互相导入 |
| AppSettings 聚合多个功能的持久化设置，原有解码有兼容回退规则 | 共享设置值与编辑状态分开；不能让 UserData 为解码而依赖业务 UI target |
| 阅读根视图接收 AppModel／论坛导航包，ReaderSession 持有多种模式的 ViewModel | 阅读内部状态留在 Reader，跨业务展示与模式交接迁到 App |
| YamiboAppContext 共享数据库、身份事务、变更通知、重置顺序和同步注册 | 改变装配位置，不拆数据库或破坏事务；不能以公开全部 Store 替代设计 |
| L10n 与论坛表情 JSON 使用 Bundle.module；现有 SharedUI 含业务展示 | 资源和组件按实际责任归属，不能按目录名称判定为公共能力 |
| 架构脚本只识别旧 Core/UI，Xcode 当前只显式接入 UI product | 新 targets、App products 和检查路径必须同步接线，不能依赖传递导入 |

现有架构检查是 import 与定向符号检查，不是完整 Swift 语义依赖分析。本轮资料评估和文档校验也不等于新模块已经通过编译或行为验证。

## Goals / Non-Goals

**Goals:**

- 完整保护小说／漫画阅读流程、ViewModel、UI 与会话状态，使 Reader 的依赖闭包不含来源、持久化、其他业务或 App 实现。
- 以有限数量的业务与基础设施模块形成稳定所有权，保留薄 Core 和薄公共 UI，不为每个协议或适配器新增 target。
- 当前论坛作为独立来源实现，使用现有文本／图片场景提炼契约，通过同一阅读入口证明可替换。
- 区分编译器访问控制、依赖准入、API 审阅和行为验证各自提供的保证，保持数据、错误、观察及生命周期语义。

**Non-Goals:**

- 不把 Reader 内部 Domain／Application／UI 目录或小说／漫画分别变成编译层，也不承诺这些内部目录由编译器隔离。
- 不在本变更中完成 Library、Forum 全部接口的严格收窄；它们先形成业务归属，过渡依赖必须显式登记。
- 不新增正式第二来源、任意电子书格式、插件发现／动态加载、来源选择界面或跨来源作品合并。
- 不拆数据库，不改已发布存储与同步格式，不新增独立 Sync、Contracts、Support 或 Adapter target，不引入新架构框架。
- 不借模块迁移重做非阅读功能或 UI，也不将所有剩余业务塞进 App 以获得表面上的薄模块。

## Decisions

### 1. 一个 package 中按业务与实现责任划分七个源码 targets

以下是目标依赖图；简写均指同名前缀的 YamiboX target。七是当前责任划分的结果，不是固定的架构指标。后续增加或合并模块必须有新的边界需求，不能只因多了一个协议或文件夹。

| Target | 所有权 | 目标直接项目依赖 |
| --- | --- | --- |
| YamiboXCore | 真正跨模块的领域值、身份／位置／资源契约、必要消费能力和少量基础能力 | 无 |
| YamiboXUI | 通用视觉、图片显示／缩放／相册展示辅助、显示相关平台桥接 | Core，仅在实际使用时 |
| YamiboXReader | 小说／漫画工作流、准备／加载／导航／注解／生命周期、ViewModel、阅读 UI 和视口 | Core、UI |
| YamiboXLibrary | 收藏、历史、喜欢／书签管理、内容详情、阅读首页、下载管理的流程和 UI | Core、UI |
| YamiboXForum | 论坛浏览、帖子、评论、发帖、消息、用户空间及论坛账号界面与流程 | Core、UI、ForumSource |
| YamiboXForumSource | 论坛网络、来源认证请求、HTML 解析、来源模型和阅读内容适配 | Core |
| YamiboXUserData | 数据库、文件、Store、持久化缓存、迁移、原子提交、观察流及用户数据同步 | Core |
| 现有 App target | 最终装配、顶层导航、窗口、跨功能交接与应用级生命周期 | 按实际使用直接依赖上述模块 |

```text
App --> Reader, Library, Forum, ForumSource, UserData, UI, Core

Reader      --> Core + UI
Library     --> Core + UI
Forum       --> Core + UI + ForumSource
UI          --> Core
ForumSource --> Core
UserData    --> Core

App-owned adapters connect ForumSource ports to UserData capabilities.
No Reader --> ForumSource/UserData/Library/Forum/App edge is allowed at acceptance.
```

Forum 可直接消费 ForumSource 的论坛专用公开 API，因为当前不要求把论坛业务也变成任意社区客户端。Reader 则必须来源中立。无需为了依赖图对称，将全部论坛 DTO 搬入 Core。

GRDB 归属 UserData，Kanna 归属 ForumSource；Nuke 按当前数据加载和显示用途归属 ForumSource／UI，不进入 Core 或 Reader，公开能力不泄漏第三方类型。不新增依赖或顺便升级版本。必要系统值与计算 API 按用途准入；Core 不含 SwiftUI／UIKit、具体网络或存储执行，不能将 Foundation 的可导入性解释为允许它拥有所有副作用。

业务根视图、App 需要的工厂及窄能力可以公开；ViewModel、内部协调器、数据库连接和迁移实现不因此整体改成 public。Xcode App 与 SwiftPM package 的 package access 身份不能假定相同，默认由明确的 public 入口装配；包内协作才按实际需要使用 package。App 的直接 imports 和 Xcode package products 必须对应，不通过 UI 整模块转导出其他业务。

**Alternatives considered:** 继续按技术层增加 Contracts／Support／ReaderUI 会超出希望保留的粒度；只拆 Reader 并保留聚合 Core/UI 又不能消除传递耦合。选择功能模块承载业务与 UI，少量共享及实现模块承接必要边界。

### 2. 粗粒度归属与严格业务验收是两个阶段

本变更实际建立上述七个源码 targets，并净化 Core/UI；不是只预留空 target。Reader 是第一条完整验收线。Library、Forum 的内部接口全面改造留给后续变更，不能据此宣称所有业务均已隔离。

本变更交付时，仅允许以下有范围的非阅读过渡依赖，实际未使用的依赖不得添加：

| 过渡依赖 | 当前允许用途 | 后续退出条件 |
| --- | --- | --- |
| Library -> UserData | 收藏、历史、注解及下载管理仍在使用的窄数据入口 | 改由消费能力注入；移除直接实现依赖 |
| Library -> ForumSource | 远端收藏、更新检查、详情发现仍需的论坛 API | 按 Library 实际消费能力隔离来源 |
| Forum -> UserData | 草稿、账号与论坛设置等现有持久化入口 | 模块自有窄接口由 App 注入实现 |

这些是允许清单上限，不是整模块内部 API 的访问授权。不得暴露 DatabasePool 或增设万能服务容器。实施记录必须列出每条实际过渡边的消费者、用途和移除条件；无实际用途则移除。后续边界收紧不以本变更任务复选框假装完成。

Reader、Core、UI 不得使用这些过渡边作为绕行通道。Source 与 UserData 最终不互相依赖；迁移中即使短暂保留 Source -> UserData，也必须在本变更交付前移除。不存在永久 LegacyCore、聚合转导出 target 或把完整业务临时藏入 App 的兜底方案。

在原模块中先整理必要接口和宿主动作，再执行协调的归属切换。净化 Core/UI 可能需要一次跨多个 target 的可构建切换批次；不承诺每移动一个文件就能独立构建，也不要求一个尚未完成的模块骨架立即通过最终图校验。迁移阶段的例外按具体依赖和清除任务登记；Reader 验收后其例外必须为零。

**Alternatives considered:** “旧 Core/UI 基本不动、Reader 完全隔离、不增加中间契约 target”三者不能同时满足。扩大必要的搬迁范围，但不扩大为非阅读业务的全面重构。

### 3. Core 按真实跨模块需求准入，局部协议留给消费方

Core 可以有 Reading、Library、Settings、Resources 等内部目录，但目录不是额外的编译边界。进入 Core 的声明必须有真实跨模块消费者和稳定语义，不能只因为多个文件使用、为了免去一次转换或未来可能复用而进入。

- 可共享的作品／章节／内容片段／位置／资源值、阅读设置切片和跨功能注解值进入 Core。
- Reader 的布局状态、视口、会话协调器及仅内部使用的接口留在 Reader。
- 论坛响应、解析模型、标签搜索规则和认证传输表达留在 ForumSource。
- 数据库记录、同步报文、迁移 DTO、具体 Store 和持久化编码留在 UserData。
- 来源专用缓存、认证提供者等接口由 ForumSource 定义，App 内桥接到 UserData；不为它们额外建 target，也不默认放进 Core。
- Library／Forum 私有模型和业务接口留在所属模块；跨功能展示只提取真正共享的值，不提取整个依赖包。

阅读能力覆盖内容与目录加载、设置切片与观察、位置恢复／提交、历史、喜欢／书签／笔记、封面、目录原子命令及缓存／队列操作。先复用现有窄契约，仅补实际缺口，不把每个 Store 的方法原样复制成协议。跨业务原子操作是一个命令，不暴露事务对象。读取失败与无记录、修改完成与变更通知分别表达。

共享设置的值类型由 Core 按功能归类，设置 UI、编辑状态和工作流归各业务；UserData 保存旧聚合设置 DTO 与兼容编解码，并向消费方提供切片。不得因为 AppSettings 包含多个设置就把设置页面、Store 或整个应用模型放入 Core，也不能让 UserData 反向导入 Reader 来解码设置。

协议参数、返回值、关联类型、默认实现与工厂不能带回具体来源或 Store。依赖包只允许少量命名的必要能力，不提供任意类型查询。真实观察流不能以空流／空标识默认实现代替；异步工厂保持按需创建和会话复用，不在根视图初始化时启动任务。

### 4. 来源中立落实到身份、内容、导航和资源

以下是语义约束，不预设通用插件协议或最终类型名称：

- **身份：**运行时引用包含稳定来源命名空间与来源内标识，作品、章节、内容片段及资源均可稳定引用。来源内标识对 Reader 不透明；不同来源的同值 ID 不相等。来源身份、账号授权作用域、入口来源和会话代次分开，本地与正式环境沿用既有数据隔离。
- **导航：**来源内容片段不同于排版后的显示页。来源提供不透明定位符、相邻引用、目录和必要进度信息；Reader 不通过 view 加减推导请求。显示序号不能被反向解释为论坛分页地址。
- **内容：**支持现有富文本、图片、标题、稳定锚点和内容范围。HTML 与帖子解释在 ForumSource，已解析内容的定位、窗口、恢复与布局在 Reader；不能将 ForumThreadPage 改名后放入 Core。
- **发现和过滤：**板块、作者过滤、智能漫画标签／搜索聚合由来源适配解释。Reader 可传递有限的不透明范围选择和显示标签，不解析 TID／FID／UID 或拼接查询。
- **资源：**统一入口支持本地字节和远端内容。实际提供者处理 URL、Cookie、Referer、离线路径、缓存作用域及取消。Reader/UI 不构造论坛图片请求，也不以来源 ID 替代授权隔离。
- **附加能力：**评论、评分、原文、来源范围选择等显式可选。缺失时不显示入口，执行失败时报告失败；登录、远端收藏和全站搜索不是核心阅读的必需方法。

NovelLaunchContext、MangaLaunchContext、旧进度与投影同时承载论坛语义和历史编码，不能原样成为新契约。来源转换属于 ForumSource，持久化兼容转换属于 UserData，跨模块组合由 App 内窄适配连接。ReaderModeLaunchResolver 的来源识别留在来源／宿主侧，纯恢复策略归 Reader。

**Alternatives considered:** 单纯替换客户端或重命名 threadID 无法移除论坛假设；照搬 Readium 的完整出版物模型则超出已知需求。用现有小说、漫画语义和固定内容替身确定最小接口。

### 5. 来源缓存策略与存储执行分开，适配器不独占 target

ForumSource 对自己的论坛 DTO、缓存键、编码版本、TTL 和来源账户分区语义负责。UserData 对实际字节、文件、索引、完整性元数据、事务与清理执行负责。来源模块定义窄缓存端口，App 内适配器连接 UserData 的受限存储能力。

```text
ForumSource -> source-owned cache port
App adapter -> ForumSource port + UserData storage facade
UserData    -> database/files
```

上图表示实现关系，不表示 ForumSource 导入 App。来源工厂由 App 注入端口实现；UserData 不导入 ForumSource 或其页面 DTO。桥接只做参数／结果转换和装配，不在 App 重新实现解析、缓存策略或数据库算法。

现有 ForumCacheStore 必须拆出语义包装与磁盘执行；OfflineCacheStore 保存的原始论坛页面改经带明确来源／格式元数据的字节载荷边界。UserData 仍检查长度、指纹和文件一致性，ForumSource 负责来源模型解码和内容身份验证；解析失败／损坏处理沿用原有可观察行为，不把任意底层读取错误改成缓存未命中。既有载荷字节与元数据编码不借此改版。

缓存端口必须保留过期读取选择、批量能力、取消、账号代次和正在进行的写入协调，不能退化成一个忽略生命周期的 get/set 字典。身份重映射导致的索引与文件更新仍由 UserData 的统一事务／协调器执行，不能由适配器分多次提交。

**Alternatives considered:** Source -> UserData 稳定 façade 是可行的迁移折中，但导入 UserData 后无法仅靠模块访问控制限制 Source 只使用缓存成员。最终选择小端口与 App 内适配，不增加 target，也不允许反向依赖。若接口实际变得过宽，应重新评估职责，而不是继续堆叠抽象。

### 6. UserData 负责本地一致性，Sync 暂为内部子系统

UserData 内按 Persistence、Cache、Identity、Sync 等目录组织。它持有共享数据库、Store 工厂、持久化观察、身份事务、账号／设置本地状态和用户数据复制规则；不持有阅读导航、论坛发现算法或业务页面。

当前 WebDAV 的合并、删除状态、数据集版本和迁移紧贴用户数据，因此先保留在 UserData，而不是机械拆出 Sync target。WebDAVClient 属于该同步子系统，不因使用网络而归入 ForumSource。以后出现独立同步消费者或明确需要编译隔离时再评估拆分；同一数据库事务本身既不要求也不禁止拆 target。

持久离线队列执行与文件提交归 UserData，经注入的来源中立内容／资源能力准备数据；来源特定页面加工在 ForumSource。下载管理与用户操作流程归 Library，Reader 只消费自己需要的查询和命令。身份变更前取消并等待执行器退出的语义必须保留，不能只发 cancel 后立即改写身份。

UserData 自己建立数据库及成对的数据集 participant／changeID／观察流，再通过窄工厂和能力包交给 App。App 连接来源、存储、账号变更与平台生命周期，不获取 DatabasePool 或全部内部 Store。账号远端认证在 ForumSource，登录／个人资料 UI 与业务在 Forum，本地凭据与会话状态在 UserData，跨模块切换／重置顺序由 App 协调；Reader 仅持有必要会话有效性能力。

### 7. 业务 UI、公共 UI 和 App 宿主按责任归属

| 现有区域 | 新归属 |
| --- | --- |
| 小说／漫画根视图、ViewModel、视口、目录选择、阅读设置、阅读注解和缓存面板 | Reader |
| 收藏／历史／喜欢／书签管理、内容详情、阅读首页、下载队列与缓存管理页面 | Library |
| 论坛页面、帖子阅读、评论筛选／编辑／评分、消息、用户空间、论坛登录与账号资料页面 | Forum |
| 图片／缩放／相册展示辅助、通用反馈、视觉原语和显示相关 UIKit 桥接 | UI；业务操作外壳留在功能模块 |
| 顶层标签页／窗口、跨业务 ReaderSession、恢复路由交接、全局设置聚合、关于和应用级数据管理／同步设置入口 | App |
| 后台任务／通知注册、AppIntent、应用重置及全局平台会话接线 | App；业务执行仍调用所属模块能力 |

现有 SharedUI 不是自动迁移白名单。含论坛模型、功能 ViewModel、AppModel、Store 或导航容器的组件必须回归业务，或先提取值／动作驱动的纯展示部分。公共图片实现可使用 Nuke，但不公开 Nuke 类型，也不负责论坛鉴权和全局账号状态。通用图片浏览外壳可复用，喜欢捕获、来源评论等业务动作仍由所属模块提供。

Reader 对外仅暴露根入口、必要启动值、有限宿主请求／结果及确有跨模块用途的组件。内部 ViewModel 和准备／加载／布局／导航／生命周期协调器保持 internal，而非统一升为 package。宿主动作不返回 ForumPageSession、外部 ViewModel、Any 服务箱或完整依赖包。Forum 提供自己的页面入口，App 根据 Reader 发出的有限请求展示它们；Reader 保留工具栏、摘要和读者侧状态，不变成空展示壳。

跨帖子／小说／漫画的模式切换、嵌入式到全屏和旧会话恢复回调准入由 App 宿主负责。Reader 自己管理内容准备、导航、取消和位置；其业务规则不能以“宿主回调”名义搬到 App。

保持 SwiftUI 状态身份、MainActor 约束、持续观察、请求代次和初次加载时机。初始设置快照不替代观察；必要持久化写入不是可随界面销毁丢弃的显示任务。阅读外设服务由 Reader 提供有限控制入口，App 只创建并复用一个实例／处理器栈，不为每个根视图重复创建监听。

### 8. 资源与已发布数据保持兼容

- 既有共享 L10n 入口与共享本地化资源留在净化后的 Core；业务独占资源由业务 target 持有，公共视觉资源由 UI 持有。无需为拆 target 一次性重划全部旧字符串键，但这不构成把以后所有资源放入 Core 的理由。
- 论坛表情 JSON 及其来源解释归 ForumSource，通过有限值 API 供 Forum 使用。资源和调用者一起迁移，明确每个 Bundle.module 的所有者，不复制资源来绕过依赖。
- 原数据库 schema、历史迁移、恢复路由、投影编码、缓存键、离线路径、WebDAV 数据集版本／指纹及删除状态保持不变。新运行时引用不会自动给旧键加来源前缀。
- 已发布 DTO 与键编码留在实现侧，当前论坛的来源及持久化适配形成稳定双向映射；目录别名、规范身份和锚点沿用旧规则。
- 正式存储仍只支持已发布的论坛数据；其他来源误入旧存储必须明确拒绝，不截掉命名空间后写入。固定内容验证使用独立临时服务，不宣称已设计第二来源的长期存储或同步格式。
- 目录身份合并仍在同一事务内更新进度、历史、喜欢、书签、封面、收藏、删除状态及离线缓存；失败全部回滚，成功提交后再通知。模块数量不会改变事务边界。
- 保留账号租约／代次、队列停启、同步数据集与观察源成对注册以及重置的有序失败传播。不能因 App 负责装配而将原有协调步骤随意并行化。

若必须改变已发布格式，暂停该部分并先修订设计与兼容方案，不把迁移藏在文件搬迁任务中。

### 9. 将边界、替换与行为作为不同验收证据

Swift 的 internal 隔离模块实现；package 不是指定 target 的友元权限。访问级别 import 约束 API 暴露，不承诺隐藏所有传递依赖。Core 内部各业务目录共享同一可见性范围，是限制 target 数量的明确取舍。

1. **依赖准入：**结构化读取 manifest JSON，核对目标图与第 2 节有限过渡边，覆盖第三方依赖和 App product 接线；拒绝未知源码 target。Core/UI 的传递闭包不能含具体数据、其他业务或 App。
2. **源码与 API：**统一架构入口覆盖所有新路径、带访问级别／条件编译的 import 及重新导出；保留已有定向规则。API 审阅检查参数、结果、关联类型、默认值、工厂和已知符号泄漏；文本扫描不是完整语义证明。
3. **编译器约束：**实现依赖采用合适的 internal import；在当前 Swift 6.2+ 工具链上验证 MemberImportVisibility 的启用和作用，不能只凭工具版本认为默认生效。不要混淆 public import 与整模块重新导出，不用不稳定隐藏导入技巧代替接口设计。
4. **负向证据：**临时副本或隔离编译探针分别注入非法 target 依赖、直接／传递绕行、条件导入、重新导出、内部 ViewModel 访问和论坛 DTO 泄漏；对应检查或编译必须失败。保留合法基线，不在用户工作树中制造再回退违规代码。
5. **替换证据：**只提供 Reader、Core、UI 及允许依赖的编译闭包，注入非论坛身份、非数字且不连续的定位符、多片段小说、至少两章漫画、本地图片和内存观察／进度服务。使用正式同一入口完成加载、导航、恢复与显示，不修改 Reader 适配替身，不调用论坛或构造正式 Store。
6. **实际 App：**用 YamiboX-Local 在可用 iOS 模拟器验证；交互使用签名构建，先读启动参数文档，每次启动显式使用现有本地论坛地址。覆盖阅读模式、目录恢复、预览、注解、离线队列、评论／评分／原文、外设、手机／iPad、跨模式切换和过期结果。
7. **兼容与阶段结论：**用现有本地数据样本验证读写、失败、身份事务和同步载荷往返。最终记录 Reader 已达标、Library／Forum 实际过渡边及未验证项，不把包能编译当作全部业务隔离完成。

临时编译探针和固定内容装配是隔离的开发验证程序，不新增单元测试、测试文件、测试 target 或正式第二来源入口。确需新增单元测试须另获批准。移除临时入口，不使用已移除的 UI 测试宿主，不以 swift test 替代本项目 Local 验证入口。现有检查通过且后续改动未影响它时复用证据，不反复扩大无关验证。

### 10. 外部依据与适用边界

2026-09-28 核对的第一手资料如下。它们用于校验选择，不代表 Apple 规定七个 targets，也不将其他项目的整个架构当作本项目模板。

- [Apple：本地 Swift packages](https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages)：支持同仓库模块化；不要求逐模块拆仓库。
- [Apple：Swift package 资源](https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package)：资源按 target 组织，Bundle.module 对应所属模块，支持第 8 节的资源核对。
- [Swift Access Control](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/)、[SE-0409](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md)、[SE-0444](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md)：分别说明模块／package 访问、import 的 API 暴露限制和成员导入可见性；不据此声称 manifest 自身就足以阻止全部越界。
- [Readium 模块配置](https://github.com/readium/swift-toolkit/blob/9595172fa951424edfbd858ba9a839eb348f465e/Package.swift)、[内容与位置模型](https://github.com/readium/swift-toolkit/blob/9595172fa951424edfbd858ba9a839eb348f465e/docs/Guides/Getting%20Started.md)：借鉴解析与呈现通过内容／位置／资源模型连接；不照搬其多格式体系，也不把其包含解析及平台依赖的 Shared 当作轻量 Core。
- [IceCubes TimelineView](https://github.com/Dimillian/IceCubesApp/blob/9efcb16e720f337a401cf61c8e300dd043368282/Packages/Timeline/Sources/Timeline/View/TimelineView.swift)、[ViewModel](https://github.com/Dimillian/IceCubesApp/blob/9efcb16e720f337a401cf61c8e300dd043368282/Packages/Timeline/Sources/Timeline/View/TimelineViewModel.swift)、[DesignSystem 配置](https://github.com/Dimillian/IceCubesApp/blob/9efcb16e720f337a401cf61c8e300dd043368282/Packages/DesignSystem/Package.swift)：支持功能模块包含 UI 与内部 ViewModel；其网络及 Env 耦合不满足本项目 Reader 的更严格目标，不照搬。
- [NetNewsWire 账户责任](https://github.com/Ranchero-Software/NetNewsWire/blob/b4361413fc1850110f9f42652f0f84e7a51e9d64/Technotes/Accounts.markdown)、[Account 配置](https://github.com/Ranchero-Software/NetNewsWire/blob/b4361413fc1850110f9f42652f0f84e7a51e9d64/Modules/Account/Package.swift)：刷新／同步语义靠近数据所有者，同时数据库和 CloudKitSync 可独立；支持先确认责任，不证明 Sync 必须合并或独立。

## Risks / Trade-offs

- [Core 再次膨胀] -> 每个迁入声明记录真实跨模块消费者；局部协议、来源 DTO 和持久化编码不进入 Core。
- [UserData 成为新聚合 Core] -> 只承接本地一致性、持久执行与用户数据同步，禁止阅读策略、来源解析和业务 UI。
- [契约名中立而语义仍是论坛] -> 用非数字、不连续定位符与本地资源走完整替换路径，来源查询留在适配器。
- [公共 UI 或 App 成为绕行通道] -> 检查共享模块的传递闭包、入口类型和业务所有权；App 只负责自身应用级功能与组合。
- [首轮搬迁范围大] -> 先在现有模块整理契约，再形成协调切换批次；承认必要的非阅读搬迁，不许以临时大 target 掩盖耦合。
- [过渡依赖永久化] -> 只允许列明的 Library／Forum 用途，记录实际消费者和退出条件；Reader 例外在首条边界验收时清零。
- [新模型改变旧身份或数据] -> 保留旧 DTO／键／编码，检查双向映射和已存数据往返；不支持来源明确拒绝。
- [拆接口损坏事务、观察或会话] -> 保留原子命令、提交后通知、失败区别、账号代次和取消后等待；专门验证延迟结果与重建行为。
- [为过编译批量公开实现] -> 仅公开根入口、窄能力与工厂，内部模型和数据库保持隐藏，配合负向编译证据。
- [重叠工作树已有大量调整] -> 按当前实际代码核对迁移，不清空工作树，不覆盖并发修改。

## Migration Plan

1. 核对所有权、公开 API、资源与兼容样本；在当前模块中准备来源中立契约、存储／来源实现侧遵循和有限宿主动作，清点必要的非阅读搬迁。
2. 以协调切换批次形成七个实际 targets：业务 UI 归业务模块，来源与用户数据各归实现模块，App 接管真正的装配／跨功能宿主；净化 Core/UI，明确 Library／Forum 过渡边。
3. 完成来源缓存端口、App 内桥接、离线载荷及身份兼容映射；保持 UserData 数据库、事务、同步和账号生命周期。Source／UserData 回边及 Reader 宽依赖不得留到交付。
4. 收紧 Reader 根入口与完整内部流程，连接持续观察、资源、外设和外部 Forum 页面；运行独立闭包、负向边界及固定来源验证，首先完成 Reader 验收。
5. 完成正式入口、平台与数据兼容集成验证，更新实际架构和验证记录，删除仅迁移使用的 Reader 通道；明确非阅读过渡状态后交付本变更。Library／Forum 后续严格边界另立变更，不在这里标记已完成。

每个可构建批次可以独立提交，但当前请求不授权提交或实施。阶段内任务的局部静态检查不能替代批次结束的 Local 构建；只完成文件移动或根视图抽取不算 Reader 达标。

由于不改变持久化协议，回退针对本变更的代码与装配，不需要回滚数据库；不能清空用户数据或重置整个工作树。若实际必须变更格式，先另行确定兼容与回退方案。
