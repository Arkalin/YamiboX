# 论坛静默 WAF 恢复验收

## 范围与证据规则

仅使用签名 `YamiboX-Local`、可用 iOS 模拟器和 `http://127.0.0.1:8088`。启动参数与页面目标只引用[测试 App 启动参数](launch-arguments.md)。不创建单元测试或测试 target，不改用生产论坛。原始基线的漫画冷启动首图问题不算本变更通过项。

每项记录客户端 operation/attempt/challenge/flight/终态、服务端计数及必要截图／界面层级。动作只有一次传输，只读操作最多两次；重定向跳数单独记录。构建通过不是行为验收通过，端点 smoke 通过也不是 App 恢复通过。

## 可清理 fixture

源码：`scripts/fixtures/waf-recovery.php`、`waf-recovery-hook.php`、`waf-recovery-content.php`。HTTP fixture 仅在本地容器环境变量 `YAMIBO_LOCAL_RUNTIME=1` 且 Host 为 `127.0.0.1:8088` 或 `127.0.0.1:8087` 时响应；内容脚本额外要求 CLI。不要部署到其他环境。

1. 按本地开发文档恢复现有 Docker 论坛，确认 `/forum.php` 可用；不重建或清空论坛数据。
2. 将 fixture 复制到本地论坛 `.local/site/waf-recovery.php`，若同名文件已存在先停止并检查来源，不覆盖。记录文件哈希以便只清理本轮文件。
3. 每次验证使用独立的 `run` 参数（字母、数字、下划线、短横线，最多 64 字符）；PHP 容器 `/tmp/yamibox-waf-<run>.json` 记录按方法／mode 的次数，不记录 Cookie 值或正文。
4. 以 `/waf-recovery.php?mode=<模式>&run=<运行ID>` 请求。`counts` 返回当前计数但自身不增加计数。`headers` 是带专用头 405；`body` 是仅正文标记 405；`self` 连续自重定向；`single` 追加查询标记后仅跳一次，不依赖自动 Cookie jar；`plain403`／`plain405` 无挑战证据；`delay` 延迟 1.5 秒发新 Cookie；`permanent` 永久阻断；`interaction` 要求输入；`no-cookie` 不生成新 Cookie。
5. `cross-origin` 跳到 `http://127.0.0.1:8087/waf-recovery.php?mode=receiver`。对照端须另以本地绑定启动，不能将论坛凭据发送给外部站点；`receiver` 只记录是否出现论坛 auth Cookie，不保存其值。同 host 不同端口也必须视为非论坛 origin。
6. fixture 的验证 Cookie 仅为可辨认的本地测试值，有效期 180 秒。App 验证器仍只能加载安全入口，不允许为方便验收加载动作 URL。安全入口临时 hook 安装前保存原内容／哈希，按本轮 run 显式开启，验收后恢复并核对哈希。
7. 清理本轮 endpoint、安全入口 hook、对照服务、容器计数文件及测试 Cookie；保留原账号、成功缓存、离线文件和无关 fixture。

App 场景通过用户主动打开 `mode=seed&run=<ID>` 后进入本地论坛种入 WAF 测试标记。临时 hook 仅作用于该标记；容器 `/tmp/yamibox-waf-active-<ID>.json` 的 `challenge` 控制业务请求，`verification` 控制安全登录 GET，`images` 控制图片（默认关闭）。内容脚本 `php waf-recovery-content.php create <ID>` 创建六图专属帖子，`delete <ID>` 只删除同名专属帖子。修改业务 PHP 入口前必须保存原件，清理时按安装后哈希检查并恢复原件。

追加场景配置：`version` 轮换期望 clearance，而不更换 `nox_fixture`，避免浏览器与 SessionStore 的测试标记不同步。`image_slow_ms`（0–2000）流式返回约 2.4 MB 的合法 PNG；较长延迟用于进程退出后仍在传输的旧后台任务，普通完整下载应使用低于既有请求时限的延迟。`checkin: true` 提供本地模拟签到页及始终受阻的动作，不执行真实签到；`observe_promotion: true` 只记录推广请求是否带 auth。`mode=origin-probe` 从 8088 网页请求 8087 子资源，接收端使用独立 run。种入标记后，`/forum.php?mod=attachment&fixture_file=normal|large|slow` 分别返回 1 KiB、50 MiB+1 字节及限速 4 MiB 文本附件，不写入真实附件表。

上述 attachment URL 默认走 Web fallback，不能据此验收原生文件限制。原生 `ForumPageClient` 场景追加 `&action=download`，经现有 actionForm 路由让用户确认后读取；hook 仍只返回 fixture 字节，不执行任何真实动作。该表单读取路径不提供下载队列的字节进度，进度需另用真实附件下载入口验证。

矩阵续验可在可写的 `yamibo-discuz-local-php-1` 容器中使用 `php /var/www/html/waf-recovery-content.php create <ID> <variant>` 创建缓存键独立的六图帖子，通过 `images_by_variant` 指定该组挑战。`cross` 前缀的 variant 使用 8087 公开来源。`attachments` 创建三条本轮专属的真实附件记录与小型占位文件，同时写入 `/tmp/yamibox-waf-attachments-<ID>.json`；hook 将其附件 ID 映射至 normal／large／slow 响应。清理必须使用同一个 ID 与 variant 调用 `delete`，它只删除同名帖子、专属附件和映射。不要在只读 web 容器创建或清理附件；配置与映射必须放在处理 HTTP 的 PHP 容器。`profile` 配置可单独控制账号资料请求，不改变其他业务挑战，用于候选账号校验与活跃 scope 的并发场景。请求参数 `fixture_response_delay_ms`（0–8000）只延迟受阻响应，供真实并发请求验证迟到挑战复用；正常重放不延迟。

端点 smoke 示例（不等同于 App 验收）：

```sh
curl -i 'http://127.0.0.1:8088/waf-recovery.php?mode=body&run=smoke'
curl -i 'http://127.0.0.1:8088/waf-recovery.php?mode=plain405&run=smoke'
curl -s 'http://127.0.0.1:8088/waf-recovery.php?mode=counts&run=smoke'
```

## 执行矩阵

| 组 | 操作与断言 | 状态 |
| --- | --- | --- |
| 分类 | 头／正文 405、自循环；普通 403/405 与单跳不验证；外站不触发论坛恢复 | 全部已在实际 App 验证，区分系统后台跳转上限与受控论坛第二次自跳拦截 |
| 原生页面 | 普通 GET 恢复；表单、上传、确认 GET 与签到不自动重发；附件进度、取消及 50 MiB 限制 | 通过；上传使用实际图片上传覆盖共享 multipart 入口，确认页既有错误可见性与离开取消缺口单列，不冒称修复 |
| 合并与隔离 | 页面、多图、下载共享一次兼容 flight；候选账号另起 flight；迟到请求复用新 clearance | 三种真实传输共享一个 flight、候选独立 scope、迟到页面复用及迟到图片 ticket 均通过 |
| 代次与取消 | 恢复中换账号；取消一个等待者不影响其他；最后等待者离开清理；不得旧账号回写 | 通过，含真实切换、退出及退出后迟到挑战；旧 operation 均失效且不重放 |
| 静默终态 | 成功、8 秒超时、无新 Cookie、进程终止、交互要求、运行不足、重放耗尽均无新增验证界面 | 通过；实际后台 DBL_MAX、显式 2 秒 lease、已过期 lease 分别留证，不混称 UIKit 返回了有限后台时间 |
| 账号与网页 | 主动正常登录／切换可用；候选失败内联；网页 WAF-only 更新不 reload；安全导航最多一次恢复 | 主动网页／原生登录、切换、候选失败、活跃网页挑战取消／一次成功重放、WAF-only 不 reload 及跨端口子资源无 auth 通过 |
| 图片 | 通用图片、漫画分页／纵向分别验证；通知先于失败仍恢复一次；取消／耗尽不唤醒；成功图计数与阅读位置不变 | 通过；通知先到竞态使用临时可取消调度延迟、真实网络与 ticket，验后已移除；既有首图问题保留 |
| 后台下载 | 挑战文件不交付；头、前缀、metrics 协调；凭据传输降级；无可信旧 pending 取消；队列失败停止且用户继续才开新 run | 真实后台 URLSession 成功／405／循环／旧任务受控重连通过；无参数系统重新拉起投递仍属明确平台限制 |
| 无主动界面 | 前台、后台、阅读器、登录／候选、多窗口均不新增 sheet、alert、浏览器、登录页或焦点变化 | 通过，含两个真实窗口的 focus ID 前后相同与内联失败截图 |
| 架构准入 | 未注册原生任务、可选恢复、WebKit 和 WAF presentation 负例均报位置且非零；外部服务正例通过 | 通过 |
| 最终回归 | 签名 Local 构建、架构脚本、diff 检查、正常页面／附件／上传／缓存与非论坛网络 | 通过；最终登录修复签名包完成 seeded 原生登录／资料恢复回归，正常页面／附件／上传／缓存、WebDAV／更新及完整工厂证据见下文 |

## 本轮记录（2026-10-21，持续补充）

- 已完成逐入口代码迁移，见[网络架构](../architecture/networking-and-routing.md)。以下是行为证据，不将代码完成等同于完整矩阵通过。
- 开始时本地论坛不可用且模拟器枚举进程失效；重新启动 Docker Desktop 后本地 compose 健康检查通过，模拟器列表恢复。未操作生产环境。
- 签名 Local 构建多轮通过，最新已覆盖执行器、三种传输、WebKit 桥接、恢复 ticket 和 UI 消费。日志 `/tmp/yamibox-silent-waf-build.log`。未新增单元测试、测试文件或 target。
- 专用 iPhone 16 / iOS 27.0 模拟器 `97D7D35C-D2C8-4945-9A7A-F32453251C02`，证据目录 `/tmp/yamibox-waf-device-evidence`。普通论坛与用户主动网页登录通过，截图／层级 `baseline-forum`、`baseline-web-login`。
- 原生正文 405 恢复：operation `4D158575-FED0-4070-994A-0C0ABD16A94A`，flight `0C6E1C38-375A-438B-BC70-79D44E59BCA6`；初次挑战、一次验证、attempt 2 成功，板块显示 23 个帖子，没有验证弹层。`native-success.{png,txt}`。
- 交互要求：operation `533CBAC8-06BD-4487-ADE3-1C007638723E`，flight `6B334A5D-1B3C-47AE-BA7F-3002A093D759`，约 3 秒返回 `interactionRequired`；一次挑战、一次验证、没有重放。板块内联失败，不自动打开登录或错误 alert。`interaction-required.{png,txt}`。
- 无新 Cookie：operation `6C9E2155-2458-46BD-B30E-6EFF5174A7CA`，flight `6A030EB2-2623-4E58-BF83-5E9C7DA079CB`，8.008 秒返回 `silentTimeout`，无重放、无弹层。`no-cookie-timeout.{png,txt}`。此记录证明有界失败，不证明每次都能区分到 `noUpdatedClearance`（冷启动导航可能先耗尽时限）。
- 永久阻断：operation `5B390969-D2E9-42AC-94AA-40F43AF9F941`，flight `43790A28-033E-43CB-AA7E-E25A42419BD2` 成功后只重放一次，随后 `replayExhausted` 内联失败；本阶段计数为业务 2 次、验证 1 次。`replay-exhausted.{png,txt}`。
- 六图漫画下载：三个并发受阻请求共享 flight `C1FCCF24-91CA-4EE3-ABED-81EA23F40FD5`，6.25 秒验证成功，三个请求各重放一次；其余三个图片正常读取。下载工作项 `477B224E-A00D-4207-8F2B-143A58340596` 成功、UI 显示已下载。`manga-download-success.{png,txt}`。这是前台执行的受控下载，不是系统终止后的后台投递。
- 同一漫画首次读取的四图挑战合并到一个预热 flight；其中一个操作提前取消，其他等待者仍等到 8 秒终态，没有被连带取消。冷启动 WebKit 的一次导航到第 7.5 秒才完成，1.5 秒延迟脚本来不及完成；一次用户重试也超时。可见第二图进入失败，未弹窗。首图仍有既有冷启动 spinner，不能据此宣称首图修复；`image-timeout-stuck.{png,txt}` 保留为未通过证据。40 秒 lease 结束后，后续下载验证不应重新唤醒这些旧 ticket。
- 架构正例通过；临时副本四类负例（直接 native task、可选旧恢复器、未登记 WebKit、自动 WAF presentation）均退出 1 并报告 `Bypass.swift:1`。原件未加入负例。日志 `/tmp/yamibox-waf-architecture-negative/{native,optional,webkit,presentation}.log`。
- PHP 三个 fixture 语法检查通过；单跳端点无 Cookie 跟随得到 HTTP 200、redirects=1。端点 smoke 还覆盖头／正文 405、循环、普通错误、延迟／永久／交互／无 Cookie，不代表这些全都完成了 App 验收。
- 服务端最终累积计数含种入标记、预热及其他页面请求；断言使用阶段差值并关联客户端 operation，不能把最终总数误写为单个操作次数。
- 自重定向：operation `23B0CF8D-B2BE-422D-9411-A3CA31933D96` 初始 attempt 只产生 2 个自跳请求，flight `0BE3F5CC-8862-4ED3-9FFD-2F147CA5D8A2` 在 3.21 秒成功，attempt 2 正常显示板块；`self-redirect-success`。同场景延迟脚本曾超时，未扩大 8 秒上限。
- 普通 403／405 各一次请求，没有 challenge/replay；单跳是 attempt 1 内两个 HTTP 请求，没有验证，传输成功（fixture 返回空板块，并非真实帖子解析回归）。`plain403`、`plain405`、`single-redirect`。跨 origin 302 没有跟随，8087 接收端计数未出现，4 个原生请求均 attempt 1；独立启动预热不能误归因于这些跳转。`cross-origin-blocked`。
- 重新打开已下载漫画后，纵向和分页首图均正常显示，服务端图片计数完全不变。`manga-cached-vertical`、`manga-cached-paged`。未将此次重开等同于首次冷启动恢复或同视图自动通知成功。
- 原生添加 `api_fixture` 并登录成功；已保存 admin 候选受阻时使用独立 scope `62D54A71…`（活跃账号 `B72AE987…`），flight `546F8DB3…` 返回交互要求，当前账号仍为 api_fixture，错误内联。关闭 fixture 后切回 admin 成功。`native-login-api-success`、`candidate-isolation-failure`、`candidate-switch-success`。
- 迟到图片恢复：专属六图帖的纵向第 2 页可见失败后，下载 flight `1A33AE29…` 成功提交新 clearance。原图片 operation `1F69FA8F…`、`AD6C760F…`、`2D504560…` 于 11:56:03.935 注册 ticket，11:56:39.852 收到通知，39.855 消费；均沿用原 operation 执行 attempt 2 成功，未出现 attempt 3。35.92 秒未超过原 40 秒 lease，画面保持第 2/6 页，无手动重试或整页刷新。`late-vertical-before`、`late-vertical-recovered`。安全验证 GET 未携带论坛 auth，业务图片请求仍携带 auth；服务端只记录布尔值。此前另一帖首图取消及不可见预取的尝试不计为本项通过。
- 下载失败与继续：三个图片请求共享 flight `CCC4A962…`，因未取得相对挑战更新的 Cookie 返回 `noUpdatedClearance`，工作队列 `9F9A75D7…` 失败且完成数为 0，UI 显示已暂停、1 失败、0/6。失败后直到带本地参数显式重启，图片请求累计计数一直保持 `1:4, 2:2, 3:2, 4:1`；重启保留工作项，不自动续跑。关闭图片挑战并点击“重试失败并继续全部”后，新队列 `F694C9AD…` 成功，六图各新增一次正常读取，先前下载的漫画仍显示已下载 34 KB。证据 `download-failed-paused`、`download-retained-after-restart`、`download-manual-resume-success`。此失败发生在 attempt 1 验证阶段，不冒称下载重放耗尽或系统后台重连通过。
- 原生回复 POST：operation `92AE4E28-79AC-4627-B3A5-9809EE6E6111` 只执行 attempt 1，flight `30D2252A…` 验证成功后操作仍返回失败，无 attempt 2；服务端 POST `/forum.php` 一分钟后仍恰好为 1，验证 GET 增量为 1。草稿保留且表单重新可用，没有 WAF 弹窗。证据 `post-blocked-no-replay`。截图未捕获现有定时消失的错误 toast，故不把错误提示可见性标为通过；代码路径为 `ForumPageSession.setError` → `transientFeedback`，没有新增错误 alert。
- 活跃网页响应头挑战：在同一已打开浏览器中点击安全登录 GET，operation `847A06B0-0B35-4BFC-BE74-3F1AEB44B105` 识别 attempt 1 挑战并在显示正文前取消，独立 flight `F1925770…` 有界返回 `noUpdatedClearance`，没有重放；原 seed 页面保持且显示错误 toast，无新验证界面。`web-header-cancel-no-clearance`。该次新 seed 仅写入浏览器 jar，SessionStore 仍持有旧 fixture 标记，验证 GET 因而命中旧 run；这是此验收 setup 的限制，既不证明网页成功重放，也不足以认定产品缺陷。前一尝试由启动预热先更新了 clearance，不能冒充活跃网页挑战通过。
- Local 无参数系统后台重新拉起不受支持；模拟器不能证明真实终止后系统投递时序。该项必须单独列为限制，不以普通 App 或真机替代。

## 继续验收记录（2026-10-21）

- 使用新建专用模拟器 `58F24D5D-CF4F-48B1-B0EE-A360705CE812`，证据位于 `/tmp/yamibox-waf-resume2-evidence`。仍只使用签名 `YamiboX-Local` 与 8088 本地论坛，没有新增单元测试。
- 正常图片上传成功，operation `AB47B048-92B4-4732-B6AA-9260DC5BFF1A` 只有 attempt 1。阻断上传 operation `CC91A30E-23C5-4E9C-A761-AA8B76946F7A` 经 flight `410514B0…` 成功后返回 `replayNotPermitted`；服务端 POST `/misc.php` 恰好一次，未产生挑战附件，原 50 字草稿和两张已上传图片保留，错误在原表单内呈现，无验证弹层。`image-upload-success`、`image-upload-blocked-no-replay`。中间一次尚未安装 misc hook 的上传正常成功，不冒称为受阻上传通过。
- 签到读取、动作各一次：operation `F45AEB92-BE3B-4E12-B658-78213A763237`、flight `36FDBF05-2603-47B8-B16C-4E9D6092CA5C`，验证成功后动作返回 `replayNotPermitted`，无 attempt 2。推广 GET 恰好一次，接收记录 `auth_seen=false`。`checkin-no-replay-promotion-isolated`。这是前台增强签到验证，不等同后台短 lease 通过。
- Web 成功恢复曾暴露真实回归：Cookie 全量同步先删除 auth 再异步写回，可能与恢复重放竞争，使网页显示 guest，虽然原生账号仍有效。现改为 WAF-only 增量同步，同 identity 的非 WAF Cookie 原位替换，不先删除。修复后 operation `991FCAC2-B5AC-4105-AA49-DD2CC7F67834`、flight `80669D6D…` 恢复成功，仅一次 attempt 2；member 入口计数 6→9（初始、验证、重放），页面仍欢迎 admin。`web-fixed-auth-retained`。
- Web 子资源曾向同主机 8087 接收端发送 auth，证据 `web-origin-probe`。新增 `ForumWebCookieBoundary`，在首次导航前安装 WebKit Cookie 阻断规则：同 Cookie 域的非精确 origin 不发送 Cookie，精确论坛 origin 保留。用户网页、主动登录与静默验证器共同使用；编译规则失败则不准入。新 run `wfweboriginfixed20261021` 的 8087 接收端只有一次 GET，`received_forum_auth=false`、`auth_seen=false`，证据 `web-origin-fixed-no-auth`。这覆盖子资源而不只主导航，不将原来仅原生 302 的验证冒充 Web 隔离。
- 新版手动网页登录提交后正常返回我的页面，显示 admin / UID 1，`web-fixed-explicit-login`。新会话重种测试标记后，在同一进程保留已成功的 admin 欢迎网页，切到原生资料触发 operation `3D499A19…`、flight `B04CF3D1…`，成功并仅重放一次；member 计数 9→10 只有验证器一次，切回网页后仍为 10，原 URL 和登录状态保持，`web-fixed-no-reload`。验证器没有递归开启新的恢复，WAF-only 更新没有 reload 原网页。
- 原生附件：用户确认 `action=download` 后，1 KiB 文件呈现为 `local-waf-fixture.txt` 卡片，QuickLook 可读；50 MiB+1 响应由 operation `1F766735-DDD6-4D00-8A30-DD8F2943A516` 单次请求拒绝，不交付文件。底层取消产生 CFNetwork -999，但 `NetworkResponseBodyReceiver.complete` 优先保留 `fileTooLarge`。该确认页没有显示大小错误，原因是未修改的 `ForumPageScreen` 优先显示 `requiresLoadConfirmation` 分支，且无 page 时不发 toast；记录为既有入口错误可见性缺口，不声称修复或误报为取消错误覆盖。
- 慢附件 operation `8B5F37DC-42BC-4D50-8E47-202DFD6834EC`：确认后约 2 秒内返回列表，等待超过完整传输时长，没有迟到文件页或错误 UI；但请求仍在 13 秒后成功接收全部 4 MiB，不能标为“离开取消网络”通过。该确认按钮沿用既有非结构化 Task，页面离开未取消它；本轮保留此生命周期缺口，未扩展修改。文件计数共 4 次，分别是最初 Web fallback 对照、原生 normal、large、slow，各一次。
- 新版签名构建与架构检查通过，日志 `/tmp/yamibox-waf-resume2-build.log`、`/tmp/yamibox-waf-resume2-architecture.log`；OpenSpec strict 与 diff 检查通过。以上 Web 修复已有新版 App 的行为证据。

## 第三轮矩阵续验（2026-10-21，进行中）

- 用户要求继续完成 36/36，继续使用实际 Local App、可清理论坛 fixture 和运行时事件，不新增单元测试文件或 target。以下续验取代前两轮的暂停状态，但不会将未执行项目预先标成完成。
- 本轮使用专用 iPhone 16 `0A43FB29-8D9B-422E-A65D-DC05E21207BC` 与 iPad `8AA16BB3-334F-488D-A660-4BF728B3D091`，证据分别写入 `/tmp/yamibox-waf-matrix-evidence` 与 `/tmp/yamibox-waf-ipad-evidence`。仅操作 8088 论坛与 8087 对照端。
- 候选原生登录的资料 GET 现在可能更新 WAF clearance，因此最终保存会话前重新读取候选 jar，避免以资料校验之前的 Cookie 快照覆盖新 clearance。保持原 generation 校验与 WAF-only 合并边界。
- 后台公开下载补齐有界文件前缀采样，以及文件、metrics、task completion 汇合；缺少可信 pending 的旧任务直接取消，不为迟到回调创建新的网络记录。签名构建日志 `/tmp/yamibox-waf-matrix-download-build.log` 已通过，实际后台路径验收另记，不以编译代替。
- 通用帖子六图仅正文挑战：帖子 1320 六个图片操作各为 attempt 1 challenge／attempt 2 success，共用 flight `B7367BEA…`，每图 HTTP 计数恰好 2；验证 GET 恰好 1 且不带 auth，业务图片携带原 auth。`generic-body-success`、`body-counts.json`。自重定向帖子 1321 共用 flight `72783F65…`，每图初始 attempt 在两次自跳处停止，验证后 attempt 2 成功，HTTP 计数各 3，不把三次 HTTP 误写成三个逻辑 attempt。`image-self-success`、`self-counts.json`。
- 公开外部六图下载：新版构建中队列 `FDDB10CA-8527-4E06-B4F9-501CD280C9DE` 于 12:55:25.077 实际创建 `com.arkalin.YamiboX.local.download.backgroundDownloads` URLSession，25.213 成功完成一个工作项，六图均 attempt 1 success，UI 显示已下载。8087 接收端六图 `auth_seen=false`；文件、metrics 与终态汇合未造成等待 lease 超时。证据 `cross-download-success`、`cross-receiver-counts.json`。这是 App 运行时的真实后台 URLSession 传输，不等同系统杀进程后重新投递；模拟器 BGTaskScheduler Code 1 不记为持续后台任务通过。
- 同 scope 页面读取与取消：iPad 中两个真实 `refreshProfile` 请求共用 flight `EB6C64D6-0E7C-4763-87A9-7D4E0E4CAE2E`；其中一个在约 1 秒取消，日志 `remaining=1`，另一请求仍完成验证并 attempt 2 成功。独立请求 `A7117C7B-AFF0-47BE-96FA-E80D634F4566` 取消最后等待者时，flight `1B9C9FFF…` 同毫秒记录 `remaining=0`、`lastWaiterRemoved` 与验证器资源释放，没有重放。调用由调试器启动实际 App workflow，未替换传输或编写 mock 测试。
- 迟到页面挑战复用：并发真实资料读取，一条请求延迟 6 秒返回原始挑战。快速操作 `93934BB0…` 经 flight `72FE52CF…` 于 12:59:51.423 成功；迟到操作 `D207A1F6…` 于 52.769 才收到旧挑战，记录 `clearance=reuse-current`，52.821 attempt 2 成功，没有开启第二次验证。`ipad-late.txt` 与 `verification-summary.txt` 留存结果和执行步骤。
- 候选与活跃账号并发：活跃 admin（UID 1）scope `87CFE2B3…`／flight `465C016B…` 与实际隔离登录的 api_fixture（UID 2）scope `A318AE41…`／flight `683B6DC7…` 同时验证，各自 attempt 2 成功、返回正确 UID；前后认证 Cookie 数组分别完全相等。证据只记录 `uid` 与 `authUnchanged=true`，不记录凭据值。该场景不替代退出／代次失效交错。
- 非交互消息检查与黑名单读取共用 flight `AB7F4CFB-BBB0-42C3-94E9-2143B494714B`；消息入口含标记已读语义，遵守 `.never` 返回 `replayNotPermitted`，黑名单读取 attempt 2 成功。服务端对应 home 请求增量 3、验证增量 1，不因 interactive 状态跳过执行器。
- 验证器 WebContent 进程终止：只终止专用 iPad 该验证器实际 WebView 的进程，flight `653F2C3D-DC3F-4242-AEAB-188784F6496C` 于 12:57:15.397 启动、16.610 返回 `processTerminated` 并释放资源，App 本身保持运行。先前为定位 PID 而人工停断点 32 秒的操作不计入超时证据；此有效场景使用单次自动断点执行并立即继续。
- 慢图受控下载与取消：队列 `65C75A01…` 逐秒记录字节从 1,015,240 增长至 10,785,431，进度从 0.11 到 0.72；12:58:02 暂停后剩余三个 operation `9FBD978C…`、`36C2FE8C…`、`0DE29902…` 均取消，保留完成的 3/6 图片。暂停至显式重启后，服务端图片计数逐字节相同，UI 保留 3/6、7.2 MB 以及先前成功的外部漫画 34 KB。仅用户点击继续后启动新 run `6A95F1A7…`，只请求第 4–6 图，各新增一次 attempt 1，约 7.6 秒完成；第 1–3 图计数不变。证据 `slow-download-paused`、`slow-restart-persisted`、`slow-resumed-success` 与阶段计数。这证明持久工作项与显式继续，不替代旧 URLSession pending 的重连验收。
- 真实旧后台任务受控重连：crossrestart2 帖子 1340 于 13:04:55 启动系统后台下载后终止本轮 App，57 秒带 Local 参数显式启动，UI 保留暂停的 0/6 工作项。用户继续后，13:05:18 重连原后台 session `0693BA97…`，未完成 task 3、2 均记录 `rejected=missingContext`，随后 CFNetwork -999 取消；旧 operation 只有退出前 attempt 1 start，未重建预算、未重放或写回旧完成结果。新 scope／generation 下新 run `B42E6979…` 于 13:05:50.775 成功，队列清空。`background2-before-termination`、`background2-after-restart`、`background2-new-run-success` 和阶段计数。第一次 crossrestart 中旧任务已完成，只覆盖迟到完成回调不交付；第二次才覆盖未完成任务取消。此受控重连不是 Local 不支持的无参数系统重启投递。
- 后台外站失败分类：实际 App 下载适配器读取 8087 `crossfail` 第 5 图，operation `EDC86B9D…` attempt 1 返回普通 `invalidResponse(405)`，没有交付 Data 或写入离线文件；`crossself` 第 5 图的后台 URLSession task 2 返回系统 -1007（重定向过多），operation `C58C8E24…` attempt 1 失败。均未开启论坛 flight 或 attempt 2，启动预热早于这两个操作 7 秒且已结束，不归入其验证次数。后台循环由系统限制后失败，不宣称像受控论坛传输一样在第二跳拦截。
- 外站接收计数确认：crossfail 第 5 图恰好 1 次 HTTP 405；crossself 第 5 图为系统跟随的 21 次 HTTP 跳转，逻辑 operation 始终只有 attempt 1，不是 21 次应用重放。两者 `auth_seen=false`。
- 非论坛网络对照：实际 `AppSourceLoader.fetch`＋`decode` 与 `WebDAVClient.fetchPayload` 请求 8087 的挑战样式正文 405，均保持普通 `invalidResponse(405)`，没有启动论坛 flight。`ipad-external-update.txt`、`ipad-external-dav.txt`。WebDAV 使用专用本地假 Basic 凭据，没有注入论坛 Cookie。
- 后台实测发现并修复极大时间值崩溃：iPad 已进入后台时，UIKit 返回 `backgroundTimeRemaining=DBL_MAX`，直接转换为 `Duration` 触发整数范围断言。平台验证器现先把可用时间限制到 8 秒，再构造时限；后台剩余时间不足 1 秒仍直接不可用。签名修复构建与签名验证通过，日志 `/tmp/yamibox-waf-background-budget-build.log`；后台行为的重跑结果另记，原崩溃不计为通过。
- 后台修复重跑：新版 iPad 真实签到工作流在 Home 后仍观察到 `applicationState=2`、`backgroundTimeRemaining=DBL_MAX`；operation `CBDDFB5E…`／flight `1737C787…` 于 13:05:32.427 开始、40.395 返回 `noUpdatedClearance` 并释放资源，整体 7.99055 秒，无崩溃和重放。返回我的页仍是 admin，无验证界面或永久加载。`ipad-background-fixed*.txt`、`background-fixed-before/home/after` 截图与层级；实际剩余时间为极大值，不将此场景冒称为有限短后台 lease。
- 同 scope 三种真实传输合并：同一 AppContext 并发页面仓储 `fetchPage`、`imagePipeline.data` 和 `downloadBackgroundDownloadTransport.downloadImageData`，scope `5F3AC7C8…`／generation `1E450435…`，operation `1F6AF5F8…`、`2879EB5F…`、`1D9EB6ED…` 均 attempt 1 challenge，共用 flight `A02EA3CA…`（一次 start、两次 join），13:10:58 验证成功后各自 attempt 2 成功。图片与下载各得到 2,404,965 字节真实 PNG，未替换传输或重建 operation。
- 正常图片流式交付：在生产 `StreamingDeliveryHandler` 的真实 `didReceive` 处设置自动继续的调试断点，同一个 data task 收到约 50 个 Data chunk，首个 49,032 字节；最终得到完整 PNG。没有为验收添加正常图片逐块日志或替代 loader，也不以下载队列的进度冒充 Nuke 增量交付。
- 流式紧凑证据另存 `stream3-chunks.tsv`：同一个 data task 共 69 个 chunk，累计精确 2,404,965 字节。宿主休眠期间中断的 stream2 不计为成功或时限证据。
- 分页可见失败图恢复：帖子 1333 第 2/6 页，operation `B7C34884…` 在 15:44:08 返回 `interactionRequired` 并注册 ticket。保持原 reader／第 2 页，不手动刷新；另一个真实页面读取 flight `C1FE5F73…` 于 15:44:26 成功后，该原 operation 的 ticket notified／consumed、attempt 2 成功，第 2 页自动显示图片且位置仍为 33%。`paged2-before-recovery`、`paged2-after-recovery`。首次开始前仅续期因宿主长时间休眠而过期的测试标记，不更换认证或 generation；之后的恢复没有重新发起操作。
- 分页重放耗尽不复活：同 reader 第 4/6 页，operation `18E40FD7…`、`43609A59…` 于 15:44:56 attempt 2 返回 `replayExhausted`。保持第 4 页，后续真实页面 flight `39E1E530…` 于 15:50:06 成功，旧操作没有 ticket 或 attempt 3；即使关闭图片阻断，图片计数仍前后完全相同，UI 保持明确失败与 67% 位置，不是 spinner。`visible-exhaust-before`、`visible-exhaust-after`。不将此前已有的首次首图取消／spinner 问题算作修复。
- 通知早于 UI 失败的竞态：只在本地 DEBUG 验收构建为 `notifyrace` 图片的“真实 ticket 已登记、原始错误尚未向 UI 传播”之间加入可取消的异步延迟，真实 HTTP、验证器、ticket 和通知均未替换。帖子 1342 第 4/6 页原 operation `46DE3BE4…` 于 15:52:30.997 登记 ticket 并进入延迟；真实页面 flight `71A2784B…` 成功后，36.024 通知该 ticket；原错误到 41.190 才继续传播，通知提前 5.166 秒。UI 在 41.246 消费同一 ticket，原 operation attempt 2 于 41.278 成功，无重进、手动重试或阅读位置变化，仍为第 4 页／67%。`notification-before-failure-recovered` 与计数。验收后已完整删除延迟 gate、环境变量读取及其日志代码，再构建正常签名产物；不将临时调度注入留在产品中。
- 业务工厂验收发现两个只读 URL 漏写重放许可：`fetchContentUpdatePage`（自动更新）operation `890D73EA…`／flight `A73BEB02…`，以及 `fetchTagPage` operation `5A7C90D6…`／flight `8D8BE4A7…` 均在验证成功后错误地返回 `replayNotPermitted`。现显式补充 `.safeReadOnce`，默认未知 URL 仍保持 `.never`，签到动作、推广与黑名单删除不因此放开。签名构建 `/tmp/yamibox-waf-read-permissions-build.log` 通过，修复后的行为另记。
- 短 lease 与不可运行：实际执行器＋真实 `ForumDataTransport`，2 秒 lease 的 operation `DB074DF9…`／flight `D2A6D3F6…` 在 1.963 秒内 `silentTimeout` 并释放资源。另用已过期的 10 ms lease 调用真实执行器，operation `CB62B4D9…` 只记录 `runtimeUnavailable`，没有 attempt、没有调用传输，服务端计数前后完全相同。这里验证的是显式运行 lease，不假称模拟器实际返回了有限的 UIKit 后台剩余时间。
- 两个真实窗口：scene `C13352AB…`／`5FB473B9…`、窗口 `96DAEE0D…`／`3232A02D…`。第一窗口的线程读取成功 flight `FDB3AEDE…` 时，焦点保持第二窗口书架；第二窗口自身验证超时 flight `82801F3D…` 后保留缓存内容，无 spinner 或弹层；第一窗口资料读取 `C970B1A4…` 返回 `interactionRequired` 时仍不抢第二窗口焦点。三案 before／after 前台 window ID 均为 `3232A02D…`，scene 数始终为 2；随后由测试者显式激活第一窗口，看到正常内联失败。`multi-*` 截图／层级及焦点记录，不把测试者主动新建和切换窗口算作 App 自动展示。
- 原生附件 task 进度与取消：帖子 1339 的实际 aid 29，经 `ForumPageClient.fetchDocument` 单次 task 读取。operation `D613AF0C…` 共 112 次进度回调，从 0 到 4,194,304／4,194,304 字节，返回相同大小文件；operation `B3312B3E…` 显式取消，32 次进度止于 982,608 字节，返回 `CancellationError` 后不再回调。该结果证明传输能力，不覆盖此前确认页非结构化 Task 的“离开页面即取消”既有缺口。
- 原生需确认 GET：先显示确认页，打开页面不产生业务请求；仅点击一次继续，operation `6FABA7D0…` attempt 1 challenge，flight `DAE03632…` 成功后返回 `replayNotPermitted`，无 attempt 2。服务端 forum GET＋1、verify GET＋1，等待后的计数仍不变，没有挑战文件卡片或新增 WebView。`confirm-before/after`、`confirm-counts-delta.json`。现有确认页会隐藏终态错误、回到确认占位，仍单列为基线可见性缺口，不声称此问题修复。
- 最终无临时 gate 的签名构建、签名验证、架构准入、diff 与 OpenSpec strict 校验通过：`/tmp/yamibox-waf-final-{build,architecture,openspec}.log`。手机重新安装正常产物，不传临时环境变量，下载管理正常打开、队列为空，四个原成功项仍保留（cross 34 KB，crossrestart／crossrestart2／slow 各 14.4 MB）。`final-build-downloads-smoke`。最终源码中没有调度 gate、临时环境变量或逐块诊断注入；未新增单元测试、测试文件或 target。

### 业务工厂与账号最终回归

专用模拟器 `AFA264E5-45D1-4D7F-9A9E-122F359C6513`，证据 `/tmp/yamibox-waf-factories-evidence`。通过调试器调用已安装 App 的真实 AppContext 工厂与工作流，未替换传输或验证器。以下各入口均记录初次挑战、一次 flight、原 operation attempt 2 和成功业务解析；计数差值见 `server-phase-deltas.json`。

| 入口 | operation | 结果 |
| --- | --- | --- |
| 小说仓储 | `338340A3…` | 正常投影，后续源请求复用当前 clearance |
| 帖子仓储 | `E40978F7…` | 一条真实帖子 |
| 收藏自动更新 resolver | `C7E6F487…` | 修复重放许可后成功读取一条帖子 |
| 标签页 | `5FF56718…` | 修复重放许可后成功读取一条主题 |
| 漫画目录 | `A1C1C9C5…` | 当前章节 1341 |
| 用户空间 | `1193318B…` | uid 2 资料解析成功 |
| 博客 | `40CEC123…` | 本地 blog 1 解析成功 |
| 章节评论 | `3DE8F498…` | 1341／1693 评论页解析成功 |
| 路由补全 | `8BFBD32B…` | 原生帖子 1341，fid 2，author uid 1 |
| 远程收藏 | `87DA892E…` | 真实添加本轮帖子后读取一条收藏 |

- 空收藏页先前返回既有 `parsingFailed(收藏页)`，不计业务成功；仅通过真实 `addThreadFavorite` 添加本轮帖后验证，新增 favid 2 纳入精确清理，原 favid 1 保留。该空列表解析观察不作为本次 WAF 已修复项。
- 恢复中切换：旧 uid 1 operation `3C697009…`／flight `63019B26…` 于 16:01:32.568 开始，650 ms 后真实 `switchAccount(uid:2)`。33.418 旧操作 `sessionInvalidated`、资源释放，无 attempt 2；新 generation `61B9FBA0…` 的认证 Cookie 不变，旧 clearance 不存在。`switch-runtime.txt`、`after-switch.png`。
- 退出及迟到挑战：operation `954A6D9E…` 已在 flight `C174FF0E…`；另一实际 findpost operation `3EF4A1BB…` 的受阻响应延迟 3 秒。650 ms 后真实 `signOut()`，旧 flight 和迟到响应均 `sessionInvalidated`，不重放、不启动新 flight。退役 scope 下退出 operation `E44C7040…` 验证后 `replayNotPermitted`，只发送一次退出 GET。最终 guest／generation `6D2D066C…`，Cookie 数为 0，迟到任务结束后状态相同。`logout-runtime.txt`、`after-logout.png`。
- 最终原生登录修复：带 clearance 的候选登录曾因显式 Cookie header 遮蔽私有 jar 的表单会话 Cookie 而返回本地 Discuz 503。现只合并该候选私有 jar 和最新 WAF Cookie，不导入活跃认证。签名最终构建 `/tmp/yamibox-waf-login-final-build.log` 通过；新包实际 login form operation `8C0A80D4…` 挑战后 attempt 2 成功，POST `9B2A52DE…` 仅 attempt 1 成功，不再 503。
- 候选资料保存回归：在真实登录的资料 GET 前用单次调试断点轮换 fixture 版本，随后继续运行。profile operation `DA0306CD…`／flight `0AC030B1…` 挑战后 attempt 2 成功；最终 uid 2、`newClearanceSaved=true`、`authenticated=true`、`activeUnchanged=true`，证明保存的是资料校验后新 clearance 而非旧快照。最终签名、架构与 OpenSpec strict 均通过，日志 `/tmp/yamibox-waf-login-final-{architecture,openspec}.log`。

## 前两轮清理与当时剩余验收

- 首轮四个临时帖子（1313–1316）及其 position 辅助记录已删除；没有创建成功回复、修改论坛账号或清空论坛数据。
- 首轮四个 PHP 入口先核对安装后哈希，再逐字节恢复原备份；三个部署 fixture 已移除，端点返回 404，正常论坛仍返回 200。8087 对照容器已停止，精确 run 的计数／配置文件已移除。原始计数归档于 `/tmp/yamibox-waf-device-evidence/server/fixture-records.tar`。
- 首轮交互会话与日志流已关闭，新建专用模拟器已删除以清除测试 Cookie、账号、草稿与设置；其他模拟器、共享 scheme 和既有 App 数据未重置。删除前已验证先前成功的本轮离线漫画在失败与继续过程中保持可读。
- 首轮签名构建、架构准入、diff 和 OpenSpec strict 校验通过；当时设备证据早于最终纯日志增强。继续验收已安装包含该增强和 WebKit 修复的最新签名 Local 构建，相关结果见上一节。
- 继续验收的帖子 1317 与 position 记录、未使用附件 aid 22/23 已删除，附件先核对名称、作者、未绑定状态及文件大小，再删除本轮图片和两张表的对应记录。没有发布回复或真实签到。
- 继续验收的六个 PHP 入口均通过安装后 SHA-256 检查，再逐字节恢复备份；三个部署 fixture 按当前源码比较后删除。8 份精确 run 计数／配置已归档到 `/tmp/yamibox-waf-resume2-evidence/server/{forum,receiver}-records.tar` 并从容器删除，8087 对照容器已停止。论坛 HTTP 200，fixture HTTP 404，仅原有四个论坛服务仍在运行。
- 继续验收的交互会话、日志流已关闭，专用模拟器 `58F24D5D-CF4F-48B1-B0EE-A360705CE812` 已关闭并删除。仓库保留可复用 fixture 源码和验收记录，不保留运行中的 hook、测试 Cookie 或模拟器设置。
- 前两轮结束时，取消／代次／回调顺序和通知交错尚缺确定性覆盖。用户此前明确选择不新增单元测试，随后要求继续完成 36/36；第三轮改用实际 App 运行时与本地服务继续补齐，不创建测试文件或 target，也不将未执行条目标为通过。没有提交或推送。

## 最终清理

- 第三轮 23 条专属帖子及对应 position 记录已删除；六个专属附件 aid 24–29、占位文件和两个专属目录已清除。仅删除本轮 favid 2，原 favid 1 与八个既有账号保留，前后清单见 `/tmp/yamibox-waf-matrix-evidence/server/{before,after}-cleanup.json`。
- 六个入口在安装后 SHA-256 全部匹配后逐字节恢复原备份；三个部署 fixture 与仓库源码比较一致后移除。11 份论坛配置／计数／附件映射及三份接收端记录先归档为 `server/{forum,receiver}-records.tar`，再按精确名称清除，附件映射由内容清理脚本移除。容器中无本轮残留配置或附件目录。
- 8087 专属接收容器已停止；仅原有四个论坛服务运行。正常论坛 HTTP 200，fixture HTTP 404。三台本轮专用模拟器均关闭并删除，调试器、日志流和交互会话全部关闭；未重置其他模拟器或无关 App 数据。删除专用测试环境前已核对成功缓存和四个离线项保留，未以清空数据掩盖恢复缺陷。
- 最终产品源码没有临时通知调度 gate；仓库只保留可复用 fixture 源码、实现及文档。36 项验收完成，不包含 Local 无参数系统重新拉起的真实 OS 投递证明，也不宣称修复既有首图、确认页错误可见性／离开取消或空收藏解析问题。未提交、推送或归档 OpenSpec change。

## 规格逐项对应

以下结论对应上述真实 App、服务端计数及界面证据；系统无参数重启投递和既有 UI 缺口明确单列，不以构建或端点 smoke 代替行为验证。

| 规格要求 | 实现边界与本轮结论 |
| --- | --- |
| gateway：论坛原生请求强制接入 | 必需执行器与 data、Nuke、download 适配器已接入；页面、图片、下载、账号、共享 multipart 上传、确认 GET、签到及非交互工厂实测 |
| gateway：挑战内容不得交付为成功资源 | 共享有界分类器；图片／下载挑战未交付成功，50 MiB+1 拒绝、Nuke 流式交付、4 MiB 附件进度与取消均通过 |
| gateway：网页会话参与相同的隔离与恢复契约 | scoped WebKit 桥与非递归验证器已接入；主动登录、活跃挑战静默失败／一次成功恢复、WAF-only 不 reload 通过 |
| gateway：论坛来源与非论坛流量隔离 | exact origin、逐跳拒绝及公开下载无凭据策略；原生跳转、Web 子资源及公开后台下载均验证 8087 不携带论坛 auth；实际 WebDAV／更新挑战样式错误不触发论坛恢复 |
| gateway：后台和恢复任务具有可终结的 WAF 状态 | 可信 pending／lease 准入与旧任务取消；显式 Local 重启队列验证，系统终止后的真实投递未覆盖 |
| gateway：新调用方不得静默绕过接入契约 | 精确文件例外与原生／可选恢复／WebKit／展示四类负例通过；文本扫描不是完整数据流证明 |
| gateway：恢复尝试可追溯且不泄露凭据 | operation、attempt、scope、flight、类型化终态日志；新增日志没有 Cookie、口令或完整正文 |
| silent：WAF 恢复绝不主动展示界面 | 自动 WAF surface 已删除；前台、后台、阅读器、候选账号和两个真实窗口均无新增弹层或焦点变化，用户主动登录保留 |
| silent：挑战识别使用明确且有界的证据 | 正文、自循环、普通 403／405、单跳、Web 头挑战和 Nuke 两次自跳实测；后台系统循环单独报告实际 21 跳，不冒称第二跳拦截 |
| silent：兼容会话中的并发挑战共享恢复 | 同 scope 页面／图片／下载共享一个 flight，候选独立；迟到页面直接复用 clearance，图片消费原 ticket |
| silent：静默执行具有时限和可用性边界 | 8 秒、无新 Cookie、交互要求、验证器进程终止、真实后台 DBL_MAX、显式 2 秒及过期 lease 均有有界终态证据 |
| silent：取消按等待者隔离 | 单等待者取消不影响其余；最后等待者离开释放资源；已取消图片不被通知唤醒；迟到响应复用与代次失效分别验证 |
| silent：仅更新仍有效会话的 WAF 凭据 | 原子 expected-generation 合并与 WAF-only jar；候选隔离、非 WAF 认证保留、恢复中切换／退出及迟到挑战均通过 |
| silent：自动重放默认保守且最多一次 | 默认禁止、原 operation 预算、永久阻断两次 attempt；表单、共享 multipart 上传、签到、确认 GET、消息已读及退出均不自动重发 |
| silent：恢复只重试有效的受阻资源 | 通用图片及两种漫画视口定向消费原 ticket；通知先于 UI 失败仍仅 attempt 2；耗尽不复活，成功缓存和阅读位置不变 |
