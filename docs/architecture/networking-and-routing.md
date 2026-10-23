# 论坛接入、认证与路由

本文描述当前代码中的论坛 HTTP 传输、页面解析和原生／网页导航边界。开发和交互验证仅使用 `YamiboX-Local` 与本地论坛；环境准备见[本地开发入门](../development/local-development.md)，参数以[测试 App 启动参数](../tests/launch-arguments.md)为准。

## 1. 接入方式与职责

App 的论坛接入主要是读取 Discuz HTML、提取页面模型，以及提交 Discuz 表单或操作链接；不能把本地测试站的开发插件接口当作 App 的统一 REST API。图片、附件和部分操作响应也不一定是 HTML。

```text
用户操作／业务 workflow
    -> 业务仓储：选择 URL、分页、缓存与操作语义
    -> YamiboClient / 图片 / 下载：请求构造与业务适配
    -> ForumRequestExecutor：会话准入、恢复与单次预算
    -> 受控单次传输适配器 / NetworkLoggedTransport
    -> HTTP 状态与响应体
    -> 业务解析器：HTML、表单、附件或操作结果
    -> Sendable 页面模型
    -> UI 展示／原生导航／网页回退
```

公共传输与论坛页面适配分开维护：

| 接口 | 输入与输出 | 负责的边界 |
| --- | --- | --- |
| `YamiboClient.fetchHTML` / `submitForm` | 路由或 URL、可选字段 → HTML 字符串 | 认证、传输、WAF 与基础 HTML 解码；不解析帖子或表单 |
| `YamiboClient.performRequest` | `URLRequest`、delegate、重放与响应体策略 → `YamiboHTTPResponse` | 返回原始数据与 HTTP 响应；调用方决定重定向准入、重放安全和业务分类 |
| `ForumPageClient.fetchDocument` | 论坛 URL、表单字段／文件、Referer → `ForumPageResponse` | 原生表单编码、重定向准入、附件分类和此类请求的 WAF 重放规则 |
| `ForumPageRepository` | 页面加载或表单操作 → `ForumPageLoadResult` | 操作确认、表单校验，输出页面、原生重定向或网页回退 |

Core 维护网络与页面语义，UI 维护 WebKit 和系统 URL 打开方式。UI 不直接依赖 Kanna；解析后的页面值才跨越模块边界。公共客户端不应反向依赖 `ForumForm`、附件模型或论坛页面策略。

源码入口：[公共客户端](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboClient.swift)、[论坛页面适配器](../../Sources/YamiboXCore/Forum/Data/ForumPageClient.swift)、[页面仓储](../../Sources/YamiboXCore/Forum/Data/ForumPageRepository.swift)。

## 2. 环境、凭据与 Cookie

### 环境选择

`YamiboForumEnvironment.launchConfiguration` 仅在模拟器构建且 Info.plist 声明 `localSimulator` 时解析启动 URL。缺失、重复、格式错误或生产域名参数返回配置错误，不默默切换至生产站。应用装配接受配置后才可访问 `current`。

本地环境按 **host、scheme、有效端口** 判断论坛同源；显式默认端口与隐式默认端口等价。生产环境的论坛 host 和站点子域判断具有不同范围，不能用 `isForumHost`、`isForumURL`、`isYamiboHost` 互相替代。论坛页面另要求 HTTP(S)、无 URL 用户名和密码；生产论坛页面还限制端口。

环境同时选择独立的账号 Keychain service 和后台下载标识。Local App 需要每次启动显式配置 URL，且不支持依赖无参数后台重新启动的工作流。这是开发环境边界，不是给普通 App 添加本地地址回退。

### Cookie 与请求凭据

`YamiboRequestCredentials` 是 Cookie 数组与 User-Agent 的值快照。`YamiboCookie` 保留 domain、path、Secure、HttpOnly、SameSite、过期时间和采集时间；同一 `domain|path|name` 采用较新采集值，随后稳定排序。

出站 Cookie 逐条检查有效期、域名、路径和 HTTPS 要求，按较长路径优先组合请求头。持久化 SameSite 属性不等于 `URLSession` 中实现了浏览器完整的 SameSite 行为。旧字符串 Cookie 转换会丢弃 WAF Cookie，避免把缺失过期信息的旧通行凭据恢复成长期会话。

显式论坛 Cookie 头只能发往所选精确 origin。系统 Cookie 匹配不包含端口，因此普通本地请求关闭自动 Cookie 处理；只有隔离登录流程的私有 ephemeral cookie jar，且请求仍属论坛 origin 时，才允许自动接收和携带 Cookie。生产默认 session 并非统一无 Cookie 存储，业务可显式传入 `handlesCookies: false`；受控论坛适配器在跨 origin 跳转前拒绝跟随。

两种“隔离”不要混淆：

- `isolatedLoginService` 有私有 Cookie jar，用于登录响应与后续请求间传递 `Set-Cookie`，不共享普通登录流程的 jar。
- `makeCookieIsolatedSession` 完全不读写 Cookie storage，仅依赖调用方筛选后的显式请求头。

账号身份的切换、持久化与清理见[账号与应用生命周期](account-lifecycle.md)。执行器必需的请求上下文在初次请求前、响应后和 WAF 恢复／重试后校验 generation。网络客户端额外的 `validateSession` 保留业务约束；仓储和 workflow 仍须按其写入契约防止迟到结果写入新账号。

源码入口：[环境规则](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboForumEnvironment.swift)、[Cookie 模型](../../Sources/YamiboXCore/Account/Domain/YamiboCookie.swift)、[网络凭据策略](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboNetworkPolicy.swift)、[session 配置](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboNetworkConfiguration.swift)。

## 3. URL、重定向与响应分类

### 重定向不是普通页面跳转

公共 session 的本地重定向保护拒绝由已配置论坛 origin 跳至其他 origin。它不等于 App 所有网络访问都被限制到论坛，外部 URL、图片和其他服务仍有自己的调用方策略。

`ForumPageClient` 的 delegate 进一步限制自动跟随：目标必须是论坛页面、使用环境的 base scheme、不触发操作确认，且新请求为 GET。被拒绝的 301／302／303／307／308 响应，若 `Location` 是无用户名密码的 HTTP(S) URL，则转换为 `continuationURL`，由界面显式提供继续入口，而不是偷偷加载。

Discuz 的 GET 链接也可能改写状态。`ForumWebPagePolicy.requiresConfirmationToLoad` 检查提交参数、`formhash`、重复操作参数及未知动作等；`ForumPageRepository.fetchPage` 默认拒绝未确认的此类请求。出现页面、预览或普通重试不能代替用户确认。增加动作类型时须同步检查路由、加载与重放规则，不能仅以 GET 判断只读。

### HTTP 与响应体

`YamiboHTTPResponse.decodeHTML` 要求 2xx；401 映射为 `notAuthenticated`，其他非 2xx 保留状态码。内容仅尝试 UTF-8 和 Foundation 的 `.unicode` 解码，不是完整字符集自动探测。无法解码与空白 HTML 分别为 `unreadableBody`、`emptyHTML`。

`ForumPageClient` 同时使用 MIME、`Content-Disposition`、路径扩展和最多 512 字节的正文前缀识别文件。HTML/XML 错误正文不能仅因附件 header 被当作下载成功；上传接口的数字或 JSON 文本也不自动成为文件。被识别的成功文件响应上限为 **50 MiB**，传输时设正文限制，解码后再次检查；该值不是所有下载模块共享的全局上限。文件进度按每次 URLSession task 计数，WAF 重试会重新观察，不能累计两次响应作为同一个文件。

表单及上传字段、必填项、token 与附件大小另由 Forum 仓储验证；详见[编辑器与草稿设计](forum-editor.md)。网络层看到 2xx 不表示发帖、收藏或其他动作已被服务端接受，最终须解析业务成功／失败结果。

源码入口：[页面准入与操作确认](../../Sources/YamiboXCore/Forum/Domain/ForumWebPagePolicy.swift)、[HTTP 解码](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboHTTPResponse.swift)。

## 4. WAF 恢复与重放

### 静默网关迁移清单

以下清单对应 `unify-silent-forum-waf-recovery` 的实现边界；行为是否已经验收，以[本轮记录](../tests/waf-recovery-regression.md)为准。Core 契约位于 `Infrastructure/Networking/ForumWAF`，仅依赖 Foundation 和既有 Core 值类型。

| 当前创建点／业务入口 | 目标职责及重放许可 | 必须保留的约束 |
| --- | --- | --- |
| `YamiboAppContext.makeClient` → HTML 仓储、论坛／帖子／小说／漫画目录、收藏与自动更新、用户空间、博客、评论与路由补全 | 必需执行器；审定读取 `.safeReadOnce`，动作 `.never` | 原请求身份、账号代次、原有取消策略、缓存写入边界 |
| `YamiboAppContext` 的消息检查与黑名单工厂 | 使用同一 scoped 执行器，不按 interactive 省略恢复 | 后台／非交互不展示 UI；动作不重发 |
| `YamiboClient.fetchHTML` / `submitForm` / `performRequest` | 只构造请求、解码 HTML；执行器统一检测与预算，默认 `.never` | GET 不等于只读；Referer、body、UA 不变 |
| `ForumPageClient`、`ForumPageRepository`、`ForumAttachmentDownloadProcessor` | 无需确认的 GET／附件读取允许一次；表单、上传、确认 GET 禁止重放 | 重定向准入、50 MiB 文件限制、响应分类、单 task 进度 |
| `YamiboAccountRemoteRepository` 与 `YamiboAccountService.isolatedLoginService` | 登录表单／profile 读取允许一次，登录提交禁止；候选与活跃 scope 分离 | 私有 Cookie jar、候选凭据不得写入当前账号 |
| `YamiboAccountRemoteRepository.signOut` | 退役 scope，`.never` | 本地切换完成后不得借用新账号或回写其 Cookie |
| `YamiboCheckInRemoteRepository` 与后台签到装配 | 页面／检查读取允许一次；签到与推广 `.never` | 推广只携带 WAF Cookie；后台 lease 优先 |
| `YamiboImagePipeline`、`YamiboProfileAvatarLoader`、`AccountDependencies` 及 Reader／下载默认图片工厂 | 必需执行器与 scoped 上下文；图片读取允许一次 | Nuke 合并、成功缓存键、预取取消；外部图片不触发论坛验证 |
| `YamiboImageDataPipeline` 的 `DataLoader` / `ImagePipeline` / `session.dataTask` | native-forum 流式单次尝试适配器，不自行 recover/replay | 128 KiB 隔离前缀、逐跳停止循环、正常增量进度 |
| `YamiboImageLoadCoordinator` → `YamiboUIImagePipeline`、通用图片、漫画分页／纵向视口 | 失败恢复 ticket 继承原 operation 和剩余预算 | revision 防遗漏；成功图片与阅读位置不变 |
| `DownloadImageAcquirer` → `DownloadBackgroundTransport` 的 `URLSession` / `downloadTask` | native-forum 下载单次尝试，pending 绑定 operation/scope/generation/attempt | 文件前缀与 metrics 判定先于成功交付；无可信 pending 的旧任务取消 |
| `YamiboNetworkConfiguration.makeSession` → `NetworkLoggedTransport.data` / `dataTask` | 原生单次尝试创建边界；论坛业务只能经执行器进入 | 明确 origin、逐跳凭据准入、原始 HTTP 结果与诊断 |
| `ForumWebView` 的 `WKWebViewConfiguration` / `WKWebView`、`ForumWebSessionSyncState` 与显式网页登录 | web-session 桥接可观察挑战和 scoped Cookie；仅安全导航允许一次 | 引擎内部资源不是原生逐请求拦截；WAF-only 更新不 reload 成功网页 |
| `WebKitSilentForumVerifier` 的 WebKit 创建点，前台／后台签到共同装配 | 统一 silent-verifier，无 presentation/fallback；旧独立后台恢复器已删除，验证流量不递归 | 非持久 WAF-only Cookie、默认 8 秒、取消清理；预热共享协调器 |
| `WebDAVClient`、`AppSourceLoader` → `NetworkLoggedTransport` | external-service，精确文件登记，不进入论坛恢复 | 不注入论坛 Cookie，不把 405／循环改成论坛挑战 |

`ForumSessionKey` 将精确 origin、scope、generation、Cookie storage 身份和 UA 纳入合并键。`ForumRequestContext` 保留原始凭据快照；提交闭包必须在同一存储事务内验证 generation 并合并 WAF Cookie，不得以先校验后无条件 save 代替。`ForumSilentVerifying` 仅返回 WAF Cookie；不可用平台显式使用 `UnavailableForumSilentVerifier`，不以可选依赖绕过检测。

`ForumWAFFailure` 的终态映射：`challenge`、`silentTimeout`、`runtimeUnavailable`、`interactionRequired`、`noUpdatedClearance`、`processTerminated`、`replayNotPermitted`、`replayExhausted` 显示内联加载失败或队列失败／暂停；`sessionInvalidated` 丢弃旧结果并结束等待。实际任务取消单独保持 `CancellationError`。任何一项都不得自动转为登录、浏览器、验证弹层或通用错误 alert；正常主动登录是独立能力。

### 当前执行流程

1. 所有原生论坛入口必须携带 `ForumRequestContext` 和非可选 `ForumRequestExecutor`；`YamiboClient` 仅构造请求和解码。`ForumRequestPolicy` 默认禁止重放，已审定读取才显式使用 `.safeReadOnce`。未识别的 GET、POST、上传、签到、退出与推广不会自动重发。
2. 受控适配器隔离 405 响应头／前 128 KiB 正文，以及连续两次相同 URL 自重定向证据。普通 403/405、单跳和非论坛来源不会发起验证。原生逐跳适配器在第二次自跳停止，另设 10 跳上限；不允许携带论坛凭据跨 origin。
3. `ForumWAFRecoveryCoordinator` actor 按 origin、scope、generation、Cookie storage ID、UA 合并 flight。迟到挑战先检查同上下文的新 clearance。单等待者取消不影响其他等待者，最后等待者离开取消执行与计时资源。
4. `WebKitSilentForumVerifier` 创建非持久、未挂载到任何界面的 WebKit，只种入 WAF Cookie，以原 UA 访问安全登录入口。默认上限 8 秒，后台剩余运行机会更短时优先结束。页面加载完成本身不表示成功，须获得相对原请求更新且仍有效超过 60 秒的 clearance。
5. 协调器仅以原子 generation 检查提交 WAF Cookie。UA 不同的上下文不读写另一 UA 的持久 clearance；其结果仅在兼容 key 的有界内存内复用。原账号 Cookie、Referer、body、UA 不被验证结果替换。
6. 原操作最多初始尝试加一次重放。重放仍受阻即 `replayExhausted`；不允许重放的操作在成功更新 clearance 后返回 `replayNotPermitted`，不会把验证成功当作业务成功。取消和会话失效不重放。
7. 前台、后台、阅读器、候选账号均没有自动 WAF sheet、alert、登录或浏览器回退。错误进入既有加载失败、内联状态或队列失败／暂停。用户主动登录是另一项能力。预热使用相同 actor，不拥有展示能力。

### 图片、下载与网页边界

Nuke 的原始数据缓存键保持不变，流式 loader 必须携带执行器发出的 attempt；缺失 attempt 的缓存请求只能失败，不能退回不受控网络 loader。405 字节不会进入成功缓存。图片失败注册表保留原 operation、单次预算和 lease；同会话新 clearance 只向有效、未重放的失败图发布一次 revision。通知先于 UI 失败时仍能消费，成功图、全局 epoch、阅读会话身份与阅读位置不因 WAF 变化重置。

下载适配器声明后台 URLSession 不具备逐跳否决能力。论坛下载改用受控 data 传输，保留进度、取消与 50 MiB 限制；仅无 Cookie、Authorization、Referer 的外部公开图片允许系统后台下载。后台 pending 保留 operation/scope/generation/attempt，完成文件与实际 metrics 在终态交付前汇合；无可信 pending 的重连任务取消，持久队列仍保留并等待用户继续。不能声称后台任务在不可观察的第二跳提前拦截。具体限制见[下载与存储](downloads-and-storage.md)。

`ForumWebWAFBridge` 接管用户已经打开的网页或登录页的**可观察**主框架挑战，保留一次导航恢复预算；验证器自身不经过该桥接，避免递归。WAF-only 同步只写通行 Cookie，不删除／重新种入认证 Cookie，也不 reload 成功网页；否则导航重放可能落在认证 Cookie 的删除与重写之间。普通 Cookie 同身份更新由 WebKit 原子替换，不先删除。

WebKit 内部子资源仍由所属 Cookie store 管理，不能宣称这是对每条内部资源的原生拦截。由于 Cookie 按域而非端口匹配，`ForumWebCookieBoundary` 在首个导航放行前安装内容规则：对可能携带论坛 Cookie 的根域及子域请求禁止 Cookie，仅为精确论坛 origin 放行。不同端口的图片／脚本可继续加载但不发送论坛凭据；其他站点自身 Cookie 不受此规则影响。显式登录、普通浏览器和隔离验证器共用此边界，编译规则失败则不放行请求。规则使用 WebKit 官方的 [`block-cookies` 与 `ignore-previous-rules`](https://webkit.org/blog/3476/content-blockers-first-look/) 语义，不依赖导航 delegate 观察子资源。普通浏览器使用非持久 jar，通过 scoped 会话同步；账号转换停止旧导航与恢复。

### 诊断与准入

`networking` 日志使用公开的随机 operation/scope/generation/flight ID 关联 attempt、challenge、join 和 terminal，不输出 Cookie、口令、挑战全文或可复用凭据。既有 HTTP 诊断继续由 `NetworkLogRecorder` 脱敏记录。

`bash scripts/check-architecture.sh` 按确切文件登记四个原生创建边界、两项外部服务以及网页／静默验证 WebKit 创建点。新增适配器须先说明用途、来源限制、能力、预算及生命周期，再添加精确文件登记；禁止用目录通配放开新网络入口。CI 沿用同一命令。扫描是文本准入而非完整 Swift 数据流证明，不能发现所有别名、动态调用或语义上的错误重放；仍需要代码审查和本地行为验收。负例必须留在临时源码副本，不进入正式源码或测试 target。

源码入口：[执行器](../../Sources/YamiboXCore/Infrastructure/Networking/ForumWAF/ForumRequestExecutor.swift)、[恢复协调器](../../Sources/YamiboXCore/Infrastructure/Networking/ForumWAF/ForumWAFRecoveryCoordinator.swift)、[平台验证器](../../Sources/YamiboXUI/Platform/WebKit/WebKitSilentForumVerifier.swift)、[验收记录](../tests/waf-recovery-regression.md)。

## 5. 原生 URL 路由与网页回退

### 页面路由和帖子分类分开

`ForumRouteResolver.resolve` 首先应用页面准入与操作确认，再识别首页、标签、板块、帖子、用户空间、消息、博客、编辑器、动作表单和公告；不支持或不应由论坛原生页面处理的 URL 返回 `.web`。登录页是认证浏览器入口，不当作普通原生论坛页面。

帖子路由进一步使用 `YamiboThreadRouteRequest` → `YamiboThreadRouteResolution`：

- 同一次导航携带 thread／board 身份、标题、目标帖子、初始页和意图；必要时请求 HTML 元数据补全身份。
- 显式 `.nativeThreadReader` 或单次 `.plainThread` 覆盖直接进入普通帖子阅读；单次小说／漫画覆盖只影响此次导航，不修改板块设置。
- 普通分类依次使用已配置板块类型、已知帖子类型和必要的元数据线索。已知但未配置的板块默认普通帖子，不凭标题擅自启用智能漫画。
- 漫画类型再根据板块的智能漫画开关选择详情入口 `.manga` 或单帖直读 `.mangaDirect`；单次漫画覆盖不会自动开启该开关。
- `findpost`／定位链接先解析实际 tid、页码与目标帖子；只有未过滤、正序、touch 模板且能包含目标帖的响应才作为普通阅读器预加载页。canonical URL 用于稳定身份，requested URL、初始页和目标帖仍须独立保留。

回退不应吞掉取消或离线错误。定位失败但仍有已知帖子身份时可保留目标继续路由；无法确定身份、认证受限或结构不支持时才按解析器规则回退。收藏后台导入不允许把认证失败交给网页，应传播错误中止同步。

### WebKit 接回原生页面

浏览器仅把主框架 GET 且已支持的页面交给原生路由，不拦截 POST 或子框架。交接前先读取 WebKit Cookie，并按当前会话代次提交至 `SessionStore`，避免原生页面的首个请求早于登录凭据落盘。

原生失败后的网页回退可暂时抑制同一 URL 再次转回原生，防止循环；用户主动点链接或认证变化可重新启用原生路由。不支持的论坛页请求完整桌面模板，而不是把 touch 模板的提示页当成完整功能。HTTP(S)／`about` 外的 scheme 交给系统打开；网页可打开站外内容，因此浏览器不是通用同源沙箱。

WebKit Cookie 异步读取、设置和删除统一通过 `Platform/WebKit` 桥接。正常浏览器和 WAF 验证器各有协调逻辑，账号变更时停止加载、取消同步任务并阻止旧代次回写；不要靠单次 `didFinish` 回调完成全部会话同步。

源码入口：[页面路由](../../Sources/YamiboXCore/Forum/Domain/ForumRouteResolver.swift)、[帖子路由](../../Sources/YamiboXCore/Routing/YamiboThreadRouteResolver.swift)、[浏览器导航策略](../../Sources/YamiboXUI/Features/Forum/Web/ForumBrowserView.swift)、[WebKit 导航与凭据交接](../../Sources/YamiboXUI/Features/Forum/Web/ForumWebView.swift)。

## 6. HTML 解析、分页与错误边界

`Infrastructure/HTML` 提供 Kanna DOM 适配、文本与 URL 提取、Discuz 页面可读性检查；业务 Data 层拥有页面选择器和结果模型。DOM 解析与访问在解析过程内完成，不把 Kanna 节点交给 UI 或跨并发任务共享。URL 身份提取应复用 `YamiboForumURLIdentity`，不能在不同解析器间不断复制博客、板块、帖子 ID 正则。

页面可读性检查会把 200 响应中的登录表单／提示识别为 `notAuthenticated`，把已知防灌水、无权限和不存在提示识别为 `floodControl`。后者是历史命名下的合并分类，不表示服务端一定发生请求频率限制。该检查依赖已知文案与结构，也不是任意 Discuz 模板的完整识别器。

**空列表与解析失败必须按页面结构区分：**

- 首页须包含有效板块，否则解析失败；搜索页的 `.threadlist_box` 存在而结果为空是合法无结果。
- 标签页使用桌面模板和专用 User-Agent，须先通过标题／列表容器结构检查；不存在的标签可以返回空页，关闭标签的消息页不能伪装为无结果。
- 分页解析保留模板区别：论坛模板取分页文本中的总数，用户空间／博客／标签兼容链接页码，并避免末页总数低于当前页。`nil` 分页不等于任意深链页都是单页数据；标签深链缺失分页时仓储回到第 1 页解析，不凭请求页号编造总页数。

默认请求传播取消；`.completeStartedRequest` 则让已开始的网络工作通过独立 task 完成。论坛首页、板块、部分用户空间与博客采用后者，以完成有效响应及相关存储；搜索和标签采用传播取消并在解析前检查。页面仍要用自己的请求身份防止过期结果替换新查询，缓存写入仍要遵守账号代次。

`LoadDiagnosticError` 为传输和解析失败附加请求／状态上下文，不应在业务层随意改成成功空页。`YamiboNetworkErrorPolicy` 只映射非取消的 `URLError`：断网或连接丢失归类离线，其他网络失败保留说明与诊断；解析错误、业务错误和取消原样传播。展示提示、离线回退和恢复时机由各业务决定。

源码入口：[页面可读性检查](../../Sources/YamiboXCore/Infrastructure/HTML/YamiboHTMLPageInspector.swift)、[论坛解析](../../Sources/YamiboXCore/Forum/Data/ForumHTMLParser.swift)、[标签解析](../../Sources/YamiboXCore/Forum/Data/ForumTagHTMLParser.swift)、[分页解析](../../Sources/YamiboXCore/Forum/Data/ForumPageNavigationParser.swift)、[仓储取消与缓存策略](../../Sources/YamiboXCore/Forum/Data/ForumRepository.swift)、[网络错误分类](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboNetworkErrorPolicy.swift)。

## 7. 本地 Docker 论坛的兼容边界

`YamiboLocalForumAdapter` 是窄范围资源适配，不负责把页面上的任意生产 URL 改成本地地址：

- 只将 Docker 发出的 `http://web/uc_server/avatar.php?...` 转换为所配置 baseURL 的 scheme、host 和 port，保留头像选择 query。
- 本地 `profileImage` 的 UCenter 头像 URL 保留 query；普通 profile-image 规范化规则可能去掉查询，不能用它清除 UCenter 所需的 UID／尺寸参数。
- 本地认证 Cookie 使用站点生成的 `_2132_auth` 后缀识别，不依赖生产站固定前缀。

页面模板、插件和测试数据仍应在本地论坛自身准备。资源适配器不是缺失头像、附件权限或服务器配置错误的通用修复层，也不会允许跨 origin 论坛请求携带本地凭据。

源码入口：[本地资源适配](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboLocalForumAdapter.swift)。

## 8. 修改此层时的验证重点

按实际影响选择以下场景，不默认新增单元测试。构建与交互均遵守 Local App 约定；标签专项步骤见[标签页回归](../tests/forum-tags.md)。

- **凭据与账号**：Cookie 的 domain／path／Secure／到期筛选；同 host 不同端口的本地请求；隔离登录成功后原生首屏认证；请求或 Cookie 同步期间切换账号。
- **重定向与动作**：同源只读重定向、站外继续链接、POST／token GET 的确认与不重放；新增业务直接调用公共客户端时单独审查默认重放策略。
- **响应分类**：401、非 2xx、空白与不可解码正文；带附件 header 的 HTML 错误；真正文件、下载进度、大小上限和上传文本结果。
- **WAF**：普通 405 不误判、不可用验证器有界失败、并发恢复、取消、仅刷新 clearance、一次重试仍失败，以及动作不自动重复提交。本地站不能真实复现的挑战必须注明未验证，不转向生产站测试。
- **图片 WAF**：多图自重定向共享一次验证、单次 302 正常通过、仅正文标识的 405、验证取消后新 clearance 定向恢复、成功页不重新请求，以及验证后仍自重定向的图片停止重试。挑战正文不得进入图片缓存；分页与滚动模式均需检查失败恢复。
- **路由**：静态／query 帖子链接、`findpost`、页码与锚点、单次阅读覆盖、智能漫画开关、登录和网页回退循环、网页登录后首次原生请求。
- **解析与取消**：正常空搜索、缺失结构、标签空页／关闭页／深链、各模板末页；快速切换查询或页面后没有旧结果覆盖与跨账号缓存污染。
- **Docker 资源**：UCenter 头像主机适配及 query 保留，正常附件仍由本地服务器权限决定。

这份清单是验证方法，不代表以上场景在每次文档更新时都已执行或全部通过。
