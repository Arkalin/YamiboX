# Proposal

## Why

现有阅读器虽已按目录区分领域、流程、数据和界面，却仍与论坛、具体 Store 和应用模型共用两个聚合模块，目录约定不能强制限制依赖；只增设 ForumSource 而保留当前 Core 也会留下传递耦合。以完整阅读器为第一个受保护业务，同时独立验收论坛来源的编译与运行边界，在有限模块之间建立可失败的依赖准入和真正可替换的来源入口。

## What Changes

- 保留一个仓库和一个 Swift package，以 `YamiboXCore`、`YamiboXUI`、`YamiboXReader`、`YamiboXLibrary`、`YamiboXForum`、`YamiboXForumSource`、`YamiboXUserData` 七个源码 targets 加现有 App 为实施布局；数量来自职责划分，不以增加 target 为目标。
- 阅读器、收藏与论坛的业务流程、ViewModel 和 UI 分别归属 Reader、Library、Forum。现有 UI target 收窄为薄公共 UI；Core 收窄为真正跨模块的领域值、必要契约和少量基础能力。协议、适配器及 Domain／Application／Data 目录不各自占用 target。
- 先形成粗粒度的最终所有权，再分别验收 Reader 的完整边界与 ForumSource 的独立性。Reader 只依赖中立 Core 和公共 UI；Source 的项目依赖仅为中立 Core，不能经它获得阅读、书库、持久化、UI 或 App 实现。模块访问控制与依赖声明、import、重新导出及 API 检查共同提供约束，App 能编译不能替代任一独立验收。
- 论坛通信、认证协议、解析、来源模型和内容适配归属 ForumSource；保留 `Forum -> ForumSource` 的专用公开 API，同时向 Reader、Library 等消费者提供中立的内容、详情、目录发现、远端收藏、更新与资源能力。Library 不以改名后的论坛 DTO 或来源型默认工厂绕过边界。
- 数据库、文件、Store、迁移、持久队列与原子提交归属 UserData，用户数据 WebDAV 同步先作为其内部子系统。Source 显式接收环境、传输、凭据快照/有效性、安全验证、缓存字节、资源和诊断能力，移除全局环境与隐式数据库/缓存初始化；App 内适配只转换与连接，不另建 Adapter target，也不把非论坛网络访问集中到 Source。
- 将作品、章节、内容片段、资源、位置和数据源分页定义为来源中立的契约。阅读器不再理解 `tid`、板块、论坛页码、作者过滤和 HTML；这些解释与转换由论坛阅读适配层负责。
- 将设置、进度、历史、注解、封面、目录持久化和离线队列改为按阅读器实际需要提供的能力接口，不把每个 Store 原样复制成协议。
- 阅读器 ViewModel、加载／布局／导航／注解协调器和正文视图留在 Reader 内。论坛原帖、评论编辑器等界面归属 Forum，通过 App 的类型化宿主接口接入；App 负责最终装配和跨业务协调，不接收所有未归类的业务实现。
- 保留唯一正式数据源及现有产品行为。通过独立编译闭包与 Local App 中的最小内存装配验收 Source，再用中立替身验证小说、漫画、资源及 Library 的详情/发现/收藏/更新流程；不增加正式第二数据源、来源选择 UI 或插件系统。
- 保持既有数据库、账号 vault、设置、缓存、下载载荷/指纹、恢复路由与 WebDAV 格式兼容；来源语义与持久化兼容分别归属实现侧，保留跨业务事务、提交后通知、账号代次、下载停止等待和迟到结果保护，不改变设备共享数据的账号策略。
- Library 到 Source/UserData、Forum 到 UserData 仅允许在登记的迁移阶段暂存，必须在本变更交付前以能力替换、独立闭包、负向检查及行为证据完成退出。Reader、Core、公共 UI 不得借用这些例外，最终准入不保留过渡白名单。
- **BREAKING**：内部 Swift 模块归属、导入路径、来源公开工厂和消费方装配 API 将调整，仓库内调用方同步迁移；不承诺保留旧的宽依赖初始化器或重新导出全部旧 API。此处不是用户数据格式或产品交互的破坏性变更。

本期包含净化共享模块所必需的论坛数据、用户数据及非阅读 UI 归属调整，不能以保留旧 Core/UI 聚合实现换取少改文件。Library、Forum 的全部内部封装不是本期完整业务验收目标，但上述来源与存储实现依赖的退出属于本期交付条件，不能继续推给未定义的后续变更。不拆数据库，不新增独立 Sync target，不升级依赖，不借机重构全部非阅读业务。

### Relationship to Related Change

本次将已确认的 `decouple-forum-source` 方案吸收到本变更的既有两项 capability 中，保留原 Reader 内部封装与行为验收。共享的七模块搬迁、来源拆分与依赖退出统一按本变更实施一次；另一个变更保留为方案参考，不并行执行重复清单，也不自动勾选、删除或归档它的任务。本次修订不以该方案已经实施为前提。

## Capabilities

### New Capabilities

- `reader-module-boundaries`：以阅读器为首个完整保护对象，约束业务 UI、共享模块、宿主集成和公开 API，增加 Source 独立闭包及 Library/Forum 迁移依赖的强制退出准入。
- `reader-source-contracts`：通过来源中立的阅读与资源契约接入论坛和替换装配，明确 Source 双类出口、显式运行能力、非论坛消费者、缓存/下载/会话责任及历史数据兼容。

这两项新增的是开发期依赖准入和数据源接入契约，不是新增阅读器产品功能；现有阅读交互保持不变。当前项目尚无主规格，无需修改既有 capability。

### Modified Capabilities

无。

## Impact

- 构建与检查：`Package.swift`、App 的 Xcode package products 接线、`scripts/check-architecture.sh`、现有 CI 架构检查入口、`docs/architecture.md`，以及模块边界相关的项目指引。
- 当前 Core：阅读流程与契约、论坛网络／解析与阅读适配、Library 等业务、全部持久化与同步、设置／账号状态、图片数据加载和资源所有权，按新职责分配而非整目录照搬。
- 当前 UI 与 App：阅读器、收藏／历史／详情／下载管理、论坛／登录等业务界面；公共视觉与平台桥接；App 装配、设置聚合、导航及跨功能生命周期。来源/存储边界必须达标，但不宣称 Library/Forum 全部内部 API 已重新设计。
- 数据与行为：拆分 `ForumCacheStore`、`DownloadStore`/载荷文件、账号会话和图片管线中的混合责任，不借机改写历史迁移、存储键、载荷指纹或 WebDAV payload；仅在本地测试环境验证真实接线与替换入口。
- 验证授权：不新增单元测试、测试文件或测试 target。若实现期间确需新增，另行请求明确批准；临时独立编译针对 iOS Simulator SDK，运行验证只由签名 Local App 承载，不另装测试 App。

本轮仅更新既有五份规划文件，不修改应用代码，不启动实施。
