# Design

## Context

动机见 [proposal.md](proposal.md)。本设计以当前工作树为基线，包括上一轮尚未提交的图片 WAF 修复，不假定其他 OpenSpec change 已实施。

当前会影响实现选择的事实如下：

| 现有位置 | 已观察到的职责或缺口 |
| --- | --- |
| `Infrastructure/Networking/YamiboClient.swift` | 内嵌 405 检测、恢复、一次重放及 `presentFallback`；`wafRecoverer` 可选，`allowsWAFReplay` 默认开启，通用表单也可能重放 |
| `Forum/Data/ForumPageClient.swift` | 已对表单和有副作用的 GET 禁止重放，另有重定向、附件分类、50 MiB 文件限制和进度语义，不能被通用包装丢弃 |
| `Infrastructure/Images/YamiboImageDataPipeline.swift` 与 `YamiboImagePipeline.swift` | Nuke 使用独立流式任务；上一轮已增加两次自重定向、受限 405 正文检测和恢复，存在与页面客户端重复的流程 |
| `Reader/Shared/Download/Application/DownloadBackgroundTransport.swift` | 实际用于离线图片下载；直接创建后台任务并把临时文件读成 Data，没有统一挑战分类。恢复任务只有 URL 描述和日志，无原等待者；后台重定向记录来自 metrics，而非逐跳 delegate |
| `YamiboAppContext.swift`、账号仓储 | 消息检查、非交互黑名单检查、候选 profile 校验和远端退出等会省略恢复器；这些差异包含真实会话隔离意图，不能机械注入当前账号恢复器 |
| `ForumWebSessionCoordinator` | 同时持有 WebKit、Cookie 同步、合并等待、预热和可见 presentation；根视图、阅读器、登录和候选账号界面均有 WAF 展示接线 |
| `BackgroundCheckInWAFRecoverer` | 已有非持久 WebKit、WAF-only Cookie、8 秒限制和代次校验，但另行实现整套规则 |
| `ForumWebView` / `ForumWebSessionSyncState` | 用户网页有独立导航及 Cookie 同步，不经过原生请求客户端；当前会话变化处理不能被简单替换为全量网页 reload |

`Package.swift` 当前只有 Core/UI 两个业务 target。Core 禁止依赖 WebKit、UIKit 和 SwiftUI。本变更沿用这一边界，不改依赖版本。现有下载队列会记录失败并暂停，继续入口会重试失败项，可承接静默验证不可用的结果，无需新增无限重试服务。

## Goals / Non-Goals

**Goals:**
- 将“必须接受 WAF 管理”变成客户端装配和底层任务准入的默认事实，而不是逐调用方约定。
- 将恢复状态机与平台脚本执行分开；平台能力只产生通行结果或失败，不拥有任何自动展示权。
- 用同一个逻辑操作身份贯穿适配器、恢复、定向重试与后台生命周期，避免多层各自重试造成预算放大。
- 保持业务 HTTP 结果、流式读取、缓存身份、账号生命周期和离线载荷契约。

**Non-Goals:**
- 不实施 `decouple-forum-source` 的七 target 拆分，不移动无关 Reader 模块，不修改另外两个 change。
- 不建设通用反爬平台，不支持验证码识别或人工验证，不用方法替换、私有 API 或全局 `URLProtocol` 声称拦截所有 WebKit/后台流量。
- 不改论坛正常登录产品流程，不重做下载队列，不新增数据库 schema、离线文件格式或单元测试体系。
- 不解决上一轮已在原始基线复现的漫画冷启动首图停留加载问题，不将其混作本变更回归。

## Decisions

### 1. 单一策略入口，多种受控传输适配器

在 `Sources/YamiboXCore/Infrastructure/Networking` 内建立论坛执行子系统，建议将集中策略放入 `ForumWAF/`。以下名称是拟新增职责，不表示现有实现已经存在：

```text
业务仓储 / 图片加载 / 下载工作流
  -> ForumRequestExecutor
       -> ForumRequestContext + ForumRequestPolicy
       -> ForumWAFResponseClassifier
       -> ForumWAFRecoveryCoordinator（actor）
       -> 受控 data / streaming / download 适配器
       -> ForumSilentVerifying（Core 协议）
            -> WebKitSilentForumVerifier（UI 平台实现）

用户主动打开的论坛网页
  -> 受控网页会话桥接
       -> 同一会话状态 / 挑战提交 / 恢复通知
       -> 同一 ForumWAFRecoveryCoordinator
```

`ForumRequestExecutor` 负责一次完整原生逻辑请求的准入、分类、恢复和有界重放，不解释帖子或图片内容。传输适配器只执行单次尝试、提供响应摘要及传输能力声明，不独立调用恢复器。底层任务只接受执行器产生的尝试上下文；其构造入口不向业务暴露可省略的 WAF 参数。通用 `NetworkLoggedTransport` 可继续服务外部网络，但论坛调用必须通过受控适配边界。

`YamiboClient` 保留请求构造和 HTML 解码职责，改为持有必需的执行器。图片保留 Nuke 的任务合并、流式数据和缓存通路；后台下载保留 download task、进度及队列出口。`YamiboAppContext` 及隔离登录工厂统一装配依赖；平台无法验证时也注入明确返回 unavailable 的能力，不允许用 `nil` 绕过检测。

**Alternatives considered:** 只提取 `recover()` 工具仍要求每个入口记得调用，不能防止遗漏；把所有请求改为一次性 `data(for:)` 会破坏图片流、文件进度和后台任务；增加通用网络 target 则会扩大为尚未批准的模块迁移。

### 2. 请求上下文与重放许可显式建模

上下文携带不可变的来源范围、会话作用域 ID、代次、Cookie storage 身份、原始凭据快照、User-Agent、逻辑操作 ID，以及有效性检查和受条件保护的 WAF 更新能力。凭据不是日志字段。业务只选择请求语义与所需传输能力，不获得“关闭 WAF”的选项。

请求策略分开表示：
- 重放：默认 `.never`；经过业务确认的只读、可重建请求显式选择 `.safeReadOnce`。GET 不是自动许可，流式或文件上传也不因 body 可重建就被视为幂等。
- 运行条件：前台或后台运行 lease、剩余 deadline、取消行为。这里没有 interactive/presentation 策略。
- 传输约束：允许的重定向范围、凭据发送范围、响应体/文件限制及进度回调。

页面读取、profile 校验、图片和附件读取采用已审定的只读许可。发帖、编辑、上传、收藏动作、签到、退出、带 `formhash` 或其他动作参数的 GET 使用 `.never`。`YamiboCheckInRemoteRepository.submit(at:)` 和通用 `submitForm` 必须显式迁移，不能保留 `YamiboClient` 的默认重放。推广访问保持 WAF-only 凭据与既有尽力完成语义，不将其 GET 自动认作无副作用。

保留 `.completeStartedRequest` 的既有“已启动传输可以完成”语义，但它不代表在操作所有者失效后还能新建恢复或重放。持续运行必须有明确仍有效的工作 lease。

**Alternatives considered:** 沿用布尔 `allowsWAFReplay` 容易保留危险默认值；仅按 HTTP 方法推断会重复 Discuz 的有副作用 GET；让验证器接管业务重发又会把 HTTP 操作语义错误下沉到 UI。

### 3. 同一分类器处理响应证据，不缓存挑战

分类器接收传输生成的纯值证据：初始/最终 URL、HTTP 状态与头、有界正文前缀、实际重定向序列、是否离开受信来源，以及原始网络错误。保留当前已知规则：
- 受信论坛 405 搭配 `baidu_waf`、`bdwaf-request-id`，或前 128 KiB 正文中的至少两个现有标记。
- 同一 URL 连续两次自重定向。能逐跳观察时在第二次截断；不能逐跳观察时依据 metrics 和最终响应归类，不承诺提前终止系统的所有跳转。
- 单次正常跳转、普通 403/405、一般超时及仅有 `httpTooManyRedirects` 而无论坛自循环证据不直接判为 WAF。

数据和流式适配器先判响应头；可能为挑战的响应仅隔离前缀，不交给 Nuke 或业务解析。后台临时文件先检查响应和文件前缀，再决定恢复、丢弃或按现有协议转换成 Data，不能先宣告成功再检查。正文上限达到后未匹配标记，返回原始 HTTP/内容错误，不继续无限读取以寻找标记。受支持挑战之外的新增站点特征须有明确材料再扩展，不猜测每个图片错误都由 WAF 引起。

重定向准入与 WAF 分类共用同一来源策略。论坛来源从现有环境的合法 origin/明确受信范围构造，保留本地 scheme、host、有效端口、URL 无用户名密码等规则；Cookie 的 domain/path/Secure 校验另行保留。外站资源走明确的非论坛通路，不能通过自动重定向把论坛认证带到外部。

**Alternatives considered:** 全量缓冲再检测破坏资源性能；凭所有 403/405 启动验证会掩盖权限/接口错误；仅检查最终 URL 会忽略先离开信任边界再返回的传输。

### 4. Core 统一并发、时限、提交与重放预算

恢复合并键为来源范围、会话作用域、有效代次、Cookie storage 身份和 User-Agent。同一键只运行一个验证 flight；其等待者保留各自 challenge 的旧 clearance 指纹、到期信息、取消及 deadline。

处理顺序为：
1. 校验原上下文并读取该作用域最新 WAF 状态。若已有相对本请求更新且适用的 clearance，直接进入有预算的重放，不重复启动验证。
2. 加入已有兼容 flight 或启动一个静默执行。验证返回 WAF-only 结果，不直接替换账号会话。
3. 在同一个受保护提交点检查代次并合并允许的 WAF Cookie；再次校验操作有效性，再唤醒仍有效等待者。
4. 仅对允许重放的操作原子消耗唯一机会，重建原请求的 WAF 部分。非 WAF Cookie、User-Agent、Referer、body 和业务语义保持原上下文。
5. 唯一重放仍被拦截则直接终止，不再次验证。不可重放操作返回 `replayNotPermitted` 结果，即使已更新通行状态也不宣称业务成功。

默认静默执行上限采用现有后台实现的 **8 秒**，clearance 采用现有 **至少剩余 60 秒** 且相对旧状态有更新的规则，作为首版可调的集中策略常量。后台剩余运行 lease 更短时按更短期限停止；一个等待者到期不取消其他仍有效等待者，flight 本身也不能通过后来加入者无限延长。取消最后一个等待者时停止 WebKit 执行和计时。每个异步返回和结果发布前检查会话/操作有效性；账号失效触发对应 scope 的整体收尾。

错误使用类型化原因，至少区分 challenge、silentTimeout、runtimeUnavailable、interactionRequired、sessionInvalidated、replayNotPermitted 和 replayExhausted；UI 将其映射为内联失败或队列失败状态，不复用会主动弹出 alert 的通用错误路径。实际任务取消保持 CancellationError，普通验证失败不能伪装成取消而留下永远加载。预算按初始传输与 WAF 重放的 attempt 计数；同一 attempt 的 HTTP 重定向跳数另外受限，诊断和验收不能混用两种计数。

**Alternatives considered:** 以全站单例不分账号合并会污染候选会话；只依靠 WebKit Cookie observer 会产生校验与写回竞态；每层维护一个“最多一次”会使总自动重放次数超过一次。

### 5. WebKit 仅提供无展示权的静默执行

在 UI 的平台区域实现 `WebKitSilentForumVerifier`，把当前 `ForumWebSessionCoordinator` 和 `BackgroundCheckInWAFRecoverer` 中必要的 JS、Cookie 观察、导航日志和清理能力提取到同一个实现。使用隔离非持久 WebKit 上下文、原请求 User-Agent 和 WAF-only Cookie；加载已知无副作用的站点入口，而非原始 POST、动作 GET 或资源地址。可先沿用现有登录页的安全 GET 作为隐藏验证入口，这不是显示登录界面，也不得据此修改账号认证。

验证器通过正常 WebKit 运行能力执行脚本并采集 WAF Cookie，默认无可见宿主；若仍需隐藏 host 保障生命周期，它不得拥有 presentation、焦点或导航控制权。执行器检测到需要交互时返回 `interactionRequired`，超时返回 `silentTimeout`，绝不以呈现页面挽救执行。后台无可用运行条件立即返回 `runtimeUnavailable`。

删除 WAF 协议上的 `presentFallback`，移除自动 `presentation`、交互检测后展示、超时升级及重复失败的可见回退。逐点拆除 `RootTabView`（含阅读器 modifier）、`AccountLoginSheet` 和 `AccountManagementView` 的 WAF sheet/fullScreenCover 接线。正常显式网页登录和用户网页保留；`YamiboWindowCoordinator` 的窗口字段还有非 WAF 用途，不连带删除。

已有预热如果继续保留，必须作为同一 scope 的有界参与者进入该协调器，不维护另一份验证任务和计时器；不新增周期性后台预热。

**Alternatives considered:** 将“是否允许弹窗”作为开关仍可能被其他调用方重新打开；保留空实现 `presentFallback` 会留下误导性权限；继续维护前台和后台两套流程容易再次发生差异。

### 6. 账号和网页桥接保持隔离，不冒充全网拦截

活跃账号、候选登录和退役账号尽力退出分别有明确 scope。候选登录使用自己的 SessionStore/私有 Cookie jar，WAF 结果只提交候选 scope；去掉 `allowsWAFRecovery: false` 的旧旁路，用隔离执行器取代。远端退出若在本地账号提交后发起，使用受限、短生命周期的退役 scope，只执行原始退出且不自动重放，恢复结果不写回活跃账号。WAF-only 推广请求不能因共享验证而拿到认证 Cookie。

`ForumWebView` 与显式网页登录通过会话桥接注册所属 scope，更新对应 Cookie store；仅 WAF 更新时不重新加载已经成功的网页。可观察的导航挑战交给协调器，导航重试也使用逻辑操作预算。验证码页面或 WAF 错误不得被普通“打开网页/重新登录”错误映射自动接管；只有独立的真实账号登录需求可以保留原产品行为。

WebKit 内部子资源由其引擎使用同一个 scoped Cookie store 发送，平台公开导航回调不等于全部子资源逐请求拦截。本变更保证它们使用统一通行状态、受控生命周期和可观察挑战桥接；不承诺 URLSession 能观察或重放每一个 WebKit 私有传输。隐藏验证页及其子资源标记为 verification role，只受当前 flight 限制，不递归请求自己。

**Alternatives considered:** 把候选账号的恢复直接指向当前全局协调器会破坏登录隔离；重写页面资源到自定义 scheme 属于另一套网页加载架构，本次不采用；对所有 Cookie 更新执行网页 reload 会重复提交或扰动成功内容。

### 7. 后台使用能力准入，无法证明安全时有界退出

`DownloadBackgroundTransport` 改为受控单次尝试适配器，当前进程的 pending 记录绑定逻辑操作、scope、generation 和 attempt。响应、文件前缀和 metrics 组成统一证据；不能因 `didFinishDownloadingTo` 比完整 metrics 更早到达就先交付成功。只保留完成判定所需的临时文件，终态、取消或无归属时清理。

后台 URLSession 的重定向不走普通逐跳回调，不能声称添加 delegate 就解决了凭据准入。适配器必须声明能保证的重定向与凭据约束：对携带论坛凭据且无法保证所需逐跳约束的请求，在创建任务前选择可控下载适配器；当前后台 lease 不足以运行时，返回 `runtimeUnavailable` 由队列暂停。无论坛凭据且业务允许该重定向范围的公开资源仍可使用系统后台传输。禁止用不可靠的预先 HEAD 探测来承诺后续 GET 一定不会改向。

首版**不接管旧进程遗留任务继续恢复**：重连时没有当前有效 pending/lease 的任务一律取消，结果不得交付到当前账号。沿用并完善已有后台 session 退役/启动复位机制，处理旧 session 标识的在途任务，收到 finish-events 时仍正常释放系统 completion handler。没有可信原上下文就不猜测来源账号或重建重放预算。

这些工作由既有持久下载项保留；记录可解释失败并暂停，通过明确的继续入口或既有获准的新 run 执行。后台恢复回调本身不能开启新 run。新的 run 有新的有限预算，同一 run 失败后不能自己循环重启。采用此方案无需新增持久元数据表，不在 taskDescription 写 Cookie、口令或可复用凭据，也不承诺跨进程保留原来的内存等待者。

**Alternatives considered:** 为旧 task 仅恢复 URL 并套当前账号不安全；持久化完整 HTTP 请求/凭据会扩大迁移与泄漏面；在后台无限等待前台 WebView 不符合运行约束；为保留无人值守传输而忽略跨来源约束不可接受。代价是部分有认证下载可能暂停后续跑，而非持续使用系统后台传输。

### 8. 定向恢复共享预算，不通过缓存失效重载

上一轮图片修复的成功缓存隔离和失败资源通知继续保留，但将恢复条件及预算归到统一执行器。执行器可给暂时恢复失败且仍有一次重放机会的资源返回受限 `RecoveryTicket`：绑定 operation ID、scope/generation、资源键、已见 clearance 版本及剩余预算。

UI/图片层只能用该 ticket 请求一次恢复，不得把通知转换为不带上下文的新请求来重置预算。ticket 被原子消费后只执行余下的一次尝试，遇到 WAF 直接终止；已验证后仍失败的操作不登记可自动唤醒 ticket。观察者离开、账号变化、显式失效、成功或容量/期限淘汰时移除 ticket，不保持悬挂的网络 Task。沿用当前有界注册表思路，保留最新恢复 revision，使通知早于失败状态写入时仍可被识别且只消费一次。

`YamiboImageLoadCoordinator` 继续负责图片请求合并与缓存代次；`YamiboUIImagePipeline`、通用远端图片、分页和纵向漫画视口只订阅自身失败资源。WAF clearance 更新不改变成功缓存键、全局图片 epoch 或 ReaderSession 身份，也不发全页刷新。

**Alternatives considered:** 清空所有图片缓存最容易恢复但会重复下载；每次通知直接增加 UI attempt 会重置底层重放预算；完全不提供迟到恢复通知会让已经显示失败的图片长期不恢复。

### 9. 用装配收口、源代码准入与负例共同防遗漏

扩展 `scripts/check-architecture.sh`，保留现有 Core/UI 和业务边界检查。新增清单按确切适配器文件声明 native-forum、external-service、web-session、silent-verifier 角色，禁止整目录豁免；如果采用结构化清单，使用对应解析器读取。

检查涵盖 `URLSession` 的创建/shared、data/bytes/upload/download 及 task API，`NetworkLoggedTransport` 的论坛调用，Nuke 默认网络入口，以及 `WKWebView`/configuration 构造点。业务只能接收执行器/业务仓储；旧 `wafRecoverer?`、`allowsWAFRecovery`、`presentFallback` 和 WAF presentation 路径必须清除。WebDAV/更新被登记为外部用途，不能据此成为论坛请求的万能通道。访问级别和工厂装配约束配合文本规则，明确文本扫描不是完整 Swift 数据流证明。

在临时源码副本中注入非法直接请求、缺失恢复依赖的旧入口、自动 WAF 展示和未经登记的 WebKit 构造，确认非零退出及位置；合规外部适配器作为正例。CI 复用已有架构检查步骤，不为了本变更新建测试 target 或恢复 UI 测试 host。

**Alternatives considered:** 只靠文档约定会重现漏接；只列现有文件而不做负例无法证明检查有效；为此引入编译器插件或新测试框架成本过高。

### 10. 验收按具体行为矩阵，而非仅以构建通过

实施阶段在本地论坛布置临时、可清理的挑战端点与请求计数，使用签名有效的 `YamiboX-Local`。参数与导航语法只引用 `docs/tests/launch-arguments.md`，每次启动显式使用本地论坛。关键矩阵如下：

| 维度 | 必须保留的证据 |
| --- | --- |
| 全入口 | 页面、通用图片、两种漫画视口、前台附件/上传、消息/刷新/签到、候选登录及后台下载逐项能到统一决策，不以抽样页面替代入口清单 |
| 挑战分类 | 响应头 405、仅正文 405、两次自重定向、普通单次跳转、普通 403/405、永久受阻及外站相似响应 |
| 并发和预算 | 混合页面/图片/下载只启动一个兼容 flight；每个只读操作最多两个传输 attempt；动作操作一个 attempt；重定向跳数独立检查；迟到请求复用已更新 clearance |
| 无主动界面 | 脚本成功、超时、交互要求、不可运行、重放失败；阅读器、登录页和多窗口均无新增 WAF surface、焦点变化或自动网页登录 |
| 隔离与取消 | 候选/活跃 scope 并行、账号切换时迟到完成、单等待者取消/全部取消、原 non-WAF Cookie/UA 不变、外站不收到论坛凭据 |
| 定向恢复 | 失败图片恢复且成功图片请求计数不增加；通知早于失败提交、取消后通知、预算耗尽后通知均没有重复请求 |
| 后台与交付 | 文件正文隔离、运行 lease 到期、缺少上下文的恢复任务、finish-events 清理、队列暂停/继续；挑战文件不进入离线目录 |
| 基础回归 | 正常显式登录、普通网页导航、页面附件限制、进度/取消、Nuke 缓存命中，以及 WebDAV/更新的非论坛网络路径 |

Local App 当前不支持无参数的系统后台重新拉起；模拟器可以验证当前进程后台任务、恢复任务拒绝及队列状态，不能据此宣称真实系统终止后投递时序已验证。该限制单独记录，不擅自用普通 App、生产论坛或真机补齐。本次不新增单元测试、单元测试文件或 target；若另需单元覆盖，先单独申请，不阻塞其余已授权验证。

## Risks / Trade-offs

- [真实 WAF 未来要求人工操作] → 明确返回失败；绝不保留自动弹窗作为“兜底”，保证用户确认的静默契约。
- [相同 URL 自重定向也可能是站点异常] → 严格限定来源和连续证据，仅执行一次恢复与重放；普通错误不泛化。
- [系统后台传输无法提供逐跳安全控制] → 在任务创建前依据能力选择可控适配器或暂停；接受部分认证任务需要后续运行机会，而不虚构安全保证。
- [不接管旧进程任务可能损失已下载进度] → 只丢弃无可信上下文的在途结果，保留既有完成文件和持久工作项；不清空整个离线库。
- [WebKit 内部子资源不可逐请求拦截] → 明确采用会话契约和可观察挑战桥接，不把原生拦截能力宣传为 WebKit 全流量代理。
- [广泛构造器迁移遗漏调用点] → 必需依赖、精确准入清单、负例和各业务入口验收共同约束，过渡可选入口不得留到交付。
- [图片定向通知重新创建操作扩大预算] → ticket 携带原操作 ID 和原子预算；终态不自动重新入队，成功资源不失效。
- [未来来源拆分与本变更重叠] → 本次只形成职责边界；后续搬迁复用这些契约，并以本次全静默要求替换旧规划中的可见交互假设。

## Migration Plan

1. 在当前 Core/UI 边界中建立执行契约、分类器、恢复协调器和平台静默适配器，保留现有请求语义作为迁移参照。
2. 同一可构建切换批次中迁移普通 HTTP、账号、图片及下载装配，清除所有可选恢复入口和独立重放循环；不发布仅覆盖部分入口的中间状态。
3. 移除全部 WAF 主动展示接线，保留普通网页登录；整合网页会话桥接、图片 ticket 及后台无上下文任务清理。
4. 完成架构负例、签名 Local 构建和本地行为矩阵，更新网络、账号、下载架构文档，并把证据写入专门验收记录。
5. 在明确请求前不提交、推送或发布。本变更不迁移用户数据格式；回退只撤销本变更的相关代码与接线，不用破坏性 Git 操作覆盖其他工作，不以清空数据掩盖问题。

当前提案只建立上述规划，不改变现有运行行为。实施所需决策已在本文给出，无需在 tasks 中另设泛化的“探索代码/决定方案”步骤。
