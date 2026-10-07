# 论坛接入、认证与路由

本文描述当前代码中的论坛 HTTP 传输、页面解析和原生／网页导航边界。开发和交互验证仅使用 `YamiboX-Local` 与本地论坛；环境准备见[本地开发入门](../development/local-development.md)，参数以[测试 App 启动参数](../tests/launch-arguments.md)为准。

## 1. 接入方式与职责

App 的论坛接入主要是读取 Discuz HTML、提取页面模型，以及提交 Discuz 表单或操作链接；不能把本地测试站的开发插件接口当作 App 的统一 REST API。图片、附件和部分操作响应也不一定是 HTML。

```text
用户操作／业务 workflow
    -> 业务仓储：选择 URL、分页、缓存与操作语义
    -> YamiboClient：凭据、会话校验、传输、WAF 恢复
    -> URLSession / NetworkLoggedTransport
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

本地模式额外限制显式 Cookie 头只能发往所选 origin。系统 Cookie 匹配不包含端口，因此普通本地请求关闭自动 Cookie 处理；只有隔离登录流程的私有 ephemeral cookie jar，且请求仍属论坛 origin 时，才允许自动接收和携带 Cookie。生产默认 session 并非统一无 Cookie 存储，业务可显式传入 `handlesCookies: false`。

两种“隔离”不要混淆：

- `isolatedLoginService` 有私有 Cookie jar，用于登录响应与后续请求间传递 `Set-Cookie`，不共享普通登录流程的 jar。
- `makeCookieIsolatedSession` 完全不读写 Cookie storage，仅依赖调用方筛选后的显式请求头。

账号身份的切换、持久化与清理见[账号与应用生命周期](account-lifecycle.md)。网络客户端可注入 `validateSession`，在初次请求前、响应后和 WAF 恢复／重试后检查会话。该能力不是每个独立客户端自动具备的代次校验，仓储和 workflow 仍须按其契约防止迟到结果写入新账号。

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

WAF 识别当前针对站点的 **405** 响应：需满足站点 URL 判断，且响应带 `baidu_waf`／`bdwaf-request-id` 标识，或正文前 128 KiB 含至少两个已知挑战标记。不是所有 403、405 或登录失败都属于 WAF。

恢复流程如下：

1. 传输发现挑战后，调用 UI 实现的 `YamiboWAFChallengeRecovering`。挑战包含 URL、method、User-Agent 和既有 clearance 的单向指纹／有效期，不把 Cookie 明文放入挑战对象。
2. UI 的 `ForumWebSessionCoordinator` 在 App 活跃且非账号切换状态下合并并发等待者，准备 WebKit 当前会话，再通过**登录页** 完成验证，而不是打开可能有副作用的原始失败 URL。
3. WebKit Cookie 观察与导航结束读取共同更新会话。验证要求得到有效的新 clearance；必要时从隐藏验证切换到可见交互，用户取消或账号切换会结束等待。
4. Core 保留原请求的非 WAF Cookie，仅替换 `nox_*` WAF 凭据，不用恢复结果替换论坛账号身份。
5. 调用方允许时，原请求最多重发一次，并忽略本地 HTTP 缓存。仍被 WAF 阻断则展示登录验证回退并抛出 `securityVerificationRequired`，不无限循环。

`ForumPageClient` 仅允许不需确认的 GET 自动重放；POST 和需确认的 GET 即使完成恢复也抛出验证错误，等待用户重新操作。**这是该适配器的规则，不是所有 `YamiboClient` 调用的统一保证**：公共接口的 `allowsWAFReplay` 默认开启，其他业务入口必须自行确定动作是否可重放。

预热与需求验证是不同路径：预热不能主动强迫用户操作；需求等待可显示验证页面。后台签到还有专门的恢复适配器，不能据此推断所有后台任务都能弹出或完成 WebKit 验证。

源码入口：[WAF 契约与检测](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboWAF.swift)、[UI 验证协调器](../../Sources/YamiboXUI/AppEntry/ForumWebSessionCoordinator.swift)。

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
- **WAF**：普通 405 不误判、无 recoverer 时返回验证错误、并发恢复、取消、仅刷新 clearance、一次重试仍失败，以及动作不自动重复提交。本地站不能真实复现的挑战必须注明未验证，不转向生产站测试。
- **路由**：静态／query 帖子链接、`findpost`、页码与锚点、单次阅读覆盖、智能漫画开关、登录和网页回退循环、网页登录后首次原生请求。
- **解析与取消**：正常空搜索、缺失结构、标签空页／关闭页／深链、各模板末页；快速切换查询或页面后没有旧结果覆盖与跨账号缓存污染。
- **Docker 资源**：UCenter 头像主机适配及 query 保留，正常附件仍由本地服务器权限决定。

这份清单是验证方法，不代表以上场景在每次文档更新时都已执行或全部通过。
