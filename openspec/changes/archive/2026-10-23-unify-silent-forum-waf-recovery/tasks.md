# Tasks

## 1. 建立请求与静默验证契约

- [x] 1.1 在 Core 的 `Infrastructure/Networking` 中定义必需的论坛执行器依赖、来源/会话上下文、操作 ID、传输能力和默认禁止重放的类型化策略；验证 Core 不引入 WebKit/UI 依赖，正常及能力不可用的装配均可通过 `YamiboX-Local` 编译检查。
- [x] 1.2 定义不含 presentation/fallback 能力的静默验证协议、WAF-only 结果及可区分的失败原因；检查每个终态均有明确调用方映射，正常业务登录能力与该协议分离。
- [x] 1.3 在 `docs/architecture/networking-and-routing.md` 登记设计中的逐入口迁移清单、重放许可和受控适配器职责；逐项对应当前 `YamiboClient`、原生 task、Nuke 和 WebKit 创建点，确认页面之外的图片、账号及后台路径没有遗漏。
- [x] 1.4 建立 `docs/tests/waf-recovery-regression.md` 的可执行本地验收步骤，并准备可清理的本地挑战 fixture、动作计数和非论坛对照来源；验证 fixture 能产生响应头/正文 405、自重定向、普通错误、延迟成功、永久阻断及交互要求，且所有地址仅在本地，不新增单元测试文件或 target。

## 2. 打通原生 HTTP 与统一静默恢复

- [x] 2.1 从 `YamiboWAF.swift` 和图片 detector 提取共享分类器，统一来源校验、128 KiB 正文上限及连续两次自重定向证据；接入受控 data 适配器后用本地普通 GET 验证普通 403/405、单次跳转不触发验证，已知挑战不进入 HTML 成功解析。
- [x] 2.2 实现恢复协调 actor，按来源、scope、generation、Cookie storage 和 UA 合并等待，复用迟到请求可用的新 clearance，并提供单等待者/最后等待者取消；通过同 scope 多个页面读取的本地事件记录确认一次兼容验证、取消隔离和最终资源释放。
- [x] 2.3 实现 8 秒默认上限、后台更短 lease、原子 WAF-only 提交与单次重放预算，保持原非 WAF Cookie、UA、Referer、请求 body 和取消策略；用本地只读请求与永久阻断 fixture 确认最多两个传输 attempt，重定向跳数单独受限，超时/取消/失效均能终结。
- [x] 2.4 提取 UI 平台的 `WebKitSilentForumVerifier`，整合前台和后台已有 JS、Cookie 采集及清理，禁止递归恢复，预热纳入相同协调器；用本地脚本成功、无新 Cookie、进程终止和需要交互的 fixture 验证成功依据、时限及所有终态均无可见验证。
- [x] 2.5 将 `YamiboClient` 的传输和 WAF 流程切换为必需执行器，移除其中重放循环及 `presentFallback`；同步迁移 App 主装配和必要构造点，验证普通页面读取可静默恢复，表单默认不重发，安装验证使用保留签名的 Local 构建。
- [x] 2.6 删除根视图及阅读器的 WAF presentation modifier/sheet/fullScreenCover，保留非 WAF 窗口协调功能；用阅读器中验证超时及重放失败的界面层级和请求计数确认不弹窗、不抢焦点且失败不是永久 spinner。
- [x] 2.7 为 operation、attempt、challenge、flight 和终态增加可关联诊断，更新网络架构文档的实际新流程；核对本组本地事件能追踪初次请求至重放结束，新增日志不含 Cookie、口令、完整挑战正文或可复用凭据，并将证据补入验收记录。

## 3. 迁移业务、账号与网页会话

- [x] 3.1 迁移 `ForumPageClient`、HTML 仓储、附件及上传请求，保留其重定向准入、文件分类、50 MiB 限制和单次 task 进度；用本地读取、POST、上传及需确认 GET 验证统一接管，副作用计数不增加且挑战正文不被当作文件。
- [x] 3.2 迁移 `YamiboAppContext` 的消息检查、黑名单、自动刷新及其余客户端工厂，删除按 interactive 状态省略恢复器的分支；对入口清单逐项留存请求/挑战记录，确认非交互业务也使用相同静默规则。
- [x] 3.3 迁移 `YamiboAccountRemoteRepository`、`YamiboAccountService` 及 `AccountRemoteContracts`，以独立候选/退役 scope 取代 `allowsWAFRecovery` 旁路；验证候选与当前账号同时挑战不混用凭据，退出后的旧恢复结果不能回写活跃账号。
- [x] 3.4 迁移 `YamiboCheckInRemoteRepository` 与后台签到装配，删除独立恢复流程及旧 WAF-only 包装器，显式区分读取、签到动作和推广访问；用本地计数验证签到不自动重复，推广仍不携带账号 Cookie，后台不足时有界失败。
- [x] 3.5 拆除 `AccountLoginSheet`、`AccountManagementView` 的 WAF 展示分支，将 WAF 失败映射为内联状态而非通用 alert，保留用户主动正常登录；验证候选校验超时或需要交互时没有新增验证或错误弹窗，普通主动网页登录和账号切换仍可完成。
- [x] 3.6 为 `ForumWebView`、显式登录 WebKit 和 `ForumWebSessionSyncState` 接入 scoped 会话桥接、可观察挑战提交及导航预算；验证 WAF-only 更新不 reload 成功网页，安全受阻导航最多恢复一次，验证器自身不递归，网页内部资源使用所属 scope 的 Cookie 状态。
- [x] 3.7 更新 `docs/architecture/account-lifecycle.md` 和网络文档的业务入口/网页边界，将本组隔离、无主动界面和安全重放结果补入验收记录；核对代码已无候选校验绕过或将 WAF 错误自动转为网页登录的残留路径。

## 4. 迁移图片传输与定向恢复

- [x] 4.1 将 `YamiboImageDataPipeline` 的 Nuke 流式加载器接为受控单次尝试适配器，用共享分类器替换图片私有判断；验证两次自重定向即停止、仅正文 405 可识别、正常图像保留流式进度，挑战字节不进入 Nuke 成功缓存。
- [x] 4.2 删除 `YamiboImagePipeline` 的独立 recover/replay，使用统一执行器并保留请求合并、原请求身份与成功缓存键；用本地多图并发及页面同时请求确认共享验证、各图最多两个传输 attempt 且自重定向有界，外站图片不启动论坛验证。
- [x] 4.3 将 `YamiboImageLoadCoordinator` 的受阻注册表改为绑定原 operation 和剩余预算的恢复 ticket，保留有界存储、revision 防遗漏和生命周期清理；验证迟到 clearance 只能消费一次 ticket，已重放仍失败、取消或失效的请求不会被新通知无限唤醒。
- [x] 4.4 迁移 `YamiboUIImagePipeline`、通用远端图片、`MangaReaderPageImageLoader`、分页及纵向视口的失败通知消费；用本地计数和截图确认只有有预算的失败图片恢复，通知先于 UI 失败也仅重试一次，成功图不重新下载且阅读位置不变。
- [x] 4.5 更新网络架构文档的图片与缓存章节，并在验收记录分别记录通用图片、两种漫画视口、成功缓存和取消交错证据；确认没有通过更改全局图片 epoch、ReaderSession 身份或整页刷新实现恢复。

## 5. 迁移下载与后台生命周期

- [x] 5.1 将 `DownloadBackgroundTransport`、`DownloadImageAcquirer` 和 App 下载装配接入统一执行器，使 pending task 绑定 operation/scope/generation/attempt；验证普通下载有进度且可取消，不再直接把未经分类的临时文件返回成功。
- [x] 5.2 实现响应头、文件前缀、metrics 和终态的协调判定及临时文件清理；用本地 405 正文、重定向循环和取消 fixture 验证挑战文件不进入离线目录，不能把非逐跳可见的后台行为误报为第二跳即拦截。
- [x] 5.3 实现传输能力准入：带论坛凭据且后台无法保证重定向约束时改用可控下载，lease 不足则返回不可用；用本地跨来源接收端确认没有论坛凭据泄漏，允许的公开无凭据任务仍能使用后台传输。
- [x] 5.4 完善旧 session 退役及重连逻辑，取消没有当前可信 pending/lease 的遗留任务，丢弃结果并完成系统事件回调；通过 Local App 显式重启后的受控重连验证无旧账号回写、不重建原操作预算、不丢失持久工作项。
- [x] 5.5 将超时、不可运行和预算耗尽映射为 `DownloadQueueExecutor` 的明确失败/暂停，保留继续入口且禁止 WAF 回调自行新建 run；验证失败后请求计数停止，用户继续才开启新有界运行，既有成功离线文件保持不变。
- [x] 5.6 更新 `docs/architecture/downloads-and-storage.md` 与本地验收记录，写明能力降级、旧任务处理和 Local 无参数后台重新拉起限制；验证文档与实际代码一致，模拟器未覆盖的系统投递时序被单独标注而非宣称通过。

## 6. 阻止新入口绕过统一契约

- [x] 6.1 扩展 `scripts/check-architecture.sh`，按确切文件与用途登记原生论坛、外部服务、网页会话及静默验证适配器，约束底层 URLSession/Nuke/WebKit 创建和执行入口；运行检查确认现有 Core/UI 规则仍生效，业务无可选恢复参数、独立 WAF 重放循环或自动展示路径。
- [x] 6.2 在临时源码副本注入直接论坛请求、旧可选恢复入口、未经登记的 WebKit 和自动 WAF 展示负例，逐项验证非零退出和位置；同时验证合法 WebDAV/更新和受控适配器正例不被误报，负例不进入正式源码或新增单元测试 target。
- [x] 6.3 保持 `.github/workflows/swift.yml` 的统一架构检查接线，记录适配器准入扩展方法及扫描局限；确认 CI 能使用同一命令执行规则，网络架构文档没有暗示文本扫描等同完整数据流证明。

## 7. 跨入口集成验收与收尾

- [x] 7.1 在全部迁移完成后执行混合页面/图片/下载、迟到请求、跨候选 scope、账号切换及取消的组合矩阵；以客户端关联日志、服务端计数和界面证据确认共用恢复、凭据隔离和总预算，记录到 `docs/tests/waf-recovery-regression.md`。
- [x] 7.2 完成“任何情况下不主动弹窗”的最终矩阵，覆盖前台、后台、阅读器、登录/候选账号和多窗口中的成功、超时、交互要求及重放耗尽；确认无新增验证 surface、WAF 错误弹窗、自动登录/浏览器或焦点变化，并确认普通主动登录仍可用。
- [x] 7.3 运行最终架构准入、`git diff --check` 和可用模拟器的签名 `YamiboX-Local` 构建，完成正常页面/附件/上传/缓存及非论坛网络的必要回归；记录检查结果与未覆盖项，不运行生产站、普通 App、旧 `swift test` 工作流或新增未授权单元测试。
- [x] 7.4 清理本地 fixture、临时论坛 hook 和本轮修改的测试设置，核对已有账号、成功缓存、离线文件及无关工作保持完整；汇总与两份规格逐项对应的验收结论及真实后台投递限制，确认没有把未验证项或既有首图问题标成新功能通过。
