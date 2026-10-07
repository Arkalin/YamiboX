# 平台集成与资源维护

本文说明系统能力和资源的维护入口，不代替用户操作手册，也不表示所有设备或后台场景已验证。最低系统版本与包配置以 [Package.swift](../../Package.swift) 为准：Swift 6.2、iOS 18，Core 和 UI 都通过 `.process("Resources")` 打包各自资源。

## 责任边界与装配

Core 定义业务契约，UI 提供需要系统界面的实现，App target 接入系统生命周期和主 Bundle 资源。

| 能力 | Core 的责任 | UI / App 的责任 |
| --- | --- | --- |
| 收藏更新通知 | 通知内容、目标身份、未读状态和 `FavoriteUpdateNotifying` | 权限、投递、移除通知和系统角标 |
| WebDAV 后台保护 | 连续性工作流和 `AppBackgroundExecutionProtecting` | 有限时长的后台执行额度，到期取消操作并释放额度 |
| 下载任务 | 队列、运行状态、`DownloadQueueRunObserving`；后台 URLSession transport | 持续处理任务的系统进度、到期处理；App delegate 接收 URLSession 事件 |
| 网页会话 | 账号会话、网络凭据、WAF 恢复和网站数据清理契约 | WebKit Cookie、验证界面、网页回退、账号切换和清理 |
| 阅读外设 | 设置、绑定和逻辑阅读动作 | 接收手柄、键盘、Apple Pencil 事件，按窗口和页面派发 |
| 本地化和主题 | 文案查询、主题设置及持久化模型 | 配色、网页样式、交互和图像展示 |

[App 入口](../../YamiboX/YamiboXApp.swift)先接受论坛环境配置，再准备存储和运行时，注入平台实现并创建窗口协调器。新增系统能力应沿现有契约注入，不让业务工作流直接持有 `UIApplication`、`WKWebView` 或 SwiftUI 视图。

## 通知、后台任务与快捷入口

### 收藏更新通知

[通知适配器](../../Sources/YamiboXUI/Platform/Notifications/UserNotificationFavoriteUpdateNotifier.swift)把 `UNUserNotificationCenter` 权限转换成 Core 枚举。通知携带目标 ID，内容、identifier、thread identifier 和角标来自业务层。App delegate 在启动结束前设置代理，支持冷启动点击；前台通知只显示角标，避免与收藏页提示重复。点击通知先准备运行时再交给窗口路由，新增字段需同步核对 Core 模型和窗口路由。

### 后台能力不能等同于定时保证

- [收藏刷新调度器](../../Sources/YamiboXUI/AppEntry/FavoriteUpdateBackgroundScheduler.swift)在启动阶段注册 `BGAppRefreshTask`，进入后台后按配置提交请求。`earliestBeginDate` 不是确定执行时间，实际执行由系统调度；前台补查弥补间隔。到期会中断所属检查。
- [WebDAV 后台保护](../../Sources/YamiboXUI/Platform/BackgroundTasks/AppBackgroundExecution.swift)以 `beginBackgroundTask` 保护已经开始的操作，包括前台进入后台的同步。额度到期会取消操作并幂等释放额度，不提供无限后台运行或未来自动唤醒。
- [下载持续处理适配器](../../Sources/YamiboXUI/Platform/BackgroundTasks/DownloadContinuedProcessingCoordinator.swift)在 iOS 26 及以上、前台启动队列时申请 `BGContinuedProcessingTask`。申请被拒绝不破坏普通下载；到期结束系统所有权并暂停所属运行。启动时取消上一进程遗留请求，不能靠旧请求重新执行恢复的队列。

[Info.plist](../../YamiboX/Info.plist)声明 `fetch`、`processing` 及允许的任务标识。新增或更名时同时核对注册、请求 identifier、通配符和清理逻辑；后台 URLSession 还需核对 App delegate 的 completion handler 路由。

### Local 环境的边界

[论坛环境](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboForumEnvironment.swift)在 Local 中令 `supportsBackgroundRelaunch` 为 `false`：不注册或提交收藏自动刷新任务，下载后台 URLSession 不发送重新启动 App 的事件，签到 Intent 返回测试环境不可用说明。测试站准备流程取消调度请求；发生数据重置时还清除通知和角标。

这不表示所有前台发起下载或短时后台保护被禁用。模拟器前台结果不是后台唤醒、锁屏下载或实体设备调度的证明。验证使用签名 Local App，见[测试 App 启动参数](../tests/launch-arguments.md)，不能为验证后台能力擅自切换正式 App 或生产论坛。

### App Intent 与主屏幕快捷操作

签到 Intent 和 `AppShortcutsProvider` 位于 [App 入口](../../YamiboX/YamiboXApp.swift)，不是独立扩展 target。Intent 使用当前会话签到，不要求打开 App；未登录、安全验证失败和测试环境都有返回说明，取消不伪装成功。

主屏幕“搜索”由 Info.plist 的静态 shortcut item 声明。Scene delegate 分别处理冷启动连接选项和运行中点击，携带 scene identifier 交给窗口协调器。新增快捷入口沿窗口路由接入，不直接替换 SwiftUI 的窗口创建流程。

## WebKit、照片与阅读外设

### 网页会话

[网页会话协调器](../../Sources/YamiboXUI/AppEntry/ForumWebSessionCoordinator.swift)持有 WAF 恢复 WebView，管理 Cookie 观察、当前会话安装、验证呈现和取消。普通网页由 [ForumWebView](../../Sources/YamiboXUI/Features/Forum/Web/ForumWebView.swift)桥接；二者使用共享的默认 `WKWebsiteDataStore`，不是隔离的账号容器。

- Cookie 写回检查会话 generation。切换账号先取消并等待旧任务、停止加载，再清除和安装 Cookie，防止迟到回调污染新账号。
- [WebKitWebsiteDataClearer](../../Sources/YamiboXUI/Platform/WebKit/WebKitWebsiteDataClearer.swift)注入 Core。清论坛 Cookie 与清默认 data store 的全部网站记录范围不同，必须尊重调用方的选择。
- 网页回退需要同时核对 Cookie、User-Agent、原生路由和注入样式；修改 CSS 不能解决会话或权限问题。

### 保存到照片

[ImagePhotoSaver](../../Sources/YamiboXUI/Platform/Photos/ImagePhotoSaver.swift)申请 `.addOnly` 权限，不读取照片库。先保存原始数据，失败后尝试 UIImage 解码保存；拒绝或受限权限作为错误返回。权限说明在 Info.plist 的 `NSPhotoLibraryAddUsageDescription`。新增入口复用此路径，不预先申请完整读写权限。

### 外设与多窗口

[阅读外设管理器](../../Sources/YamiboXUI/Features/Reader/Shared/Gamepad/ReaderPeripheralInputManager.swift)把手柄和硬件键盘转成统一阅读事件。两者开关独立，绑定捕获抢占对应来源的派发；阅读器和评论面板以可移除 token 维护消费者栈，消失时必须注销。

[窗口输入宿主](../../Sources/YamiboXUI/AppEntry/YamiboWindowInputHost.swift)观察实际 UIWindow 的事件，不抢 first responder、不吞手势。键盘输入检查当前 key window、文本编辑状态和命令修饰键，不能向后台窗口误发动作。

[Apple Pencil 交互层](../../Sources/YamiboXUI/Features/Reader/Shared/ApplePencilPageTurnInteractionOverlay.swift)接收双击和捏合结束事件，受 App 开关、能否翻页和系统偏好 `.ignore` 约束；透明层不截获触摸。能展示设置不代表已验证硬件，验证记录注明实际设备、系统和输入方式。

## 本地化与资源 Bundle

| 归属 | 当前资源 | 读取方式 |
| --- | --- | --- |
| Core 包 | `Resources/zh-Hans.lproj`、`zh-Hant.lproj` 的业务与 UI 文案 | [L10n](../../Sources/YamiboXCore/Infrastructure/Localization/YamiboLocalization.swift)使用 Core 的 `Bundle.module` |
| UI 包 | `Resources/AboutIconGeometry.json` | UI target 内的 `Bundle.module` |
| App target | `Assets.xcassets`、`AppIcon.icon`、Intent 简繁文案、Info.plist | `Bundle.main`；Intent 使用主 App 的 Localizable 表 |

- 常规文案同时维护 Core 简繁表，通过 `L10n.string` / `L10n.resource` 查询；缺键回退为 key，不算正确翻译。
- 带参数文案的占位符和参数类型保持一致。用户内容和服务端消息不当作本地化 key。
- 签到 Intent 标题与描述另在 App target 的两种语言表维护，只加 Core 文案不足以更新系统快捷指令标题。
- 包资源不改用 `Bundle.main`；`AppIconPreview`、`LaunchIcon` 则属于 App 资产，不在 UI 包中。
- Package 默认本地化与 Xcode development region 都是 `zh-Hans`；登记 `zh-Hant` 不代表可省略翻译。

## 主题、图标与版本适配

[Core 主题库](../../Sources/YamiboXCore/Settings/Domain/AppThemeLibrary.swift)保存身份、名称、颜色和选中项；经典主题不可删除，删除当前自定义主题会回退经典。UI [AppTheme](../../Sources/YamiboXUI/SharedUI/Theme/AppTheme.swift)注入强调色和 [ForumTheme](../../Sources/YamiboXUI/SharedUI/Theme/ForumTheme.swift)语义颜色，区分文本、装饰、背景、警告和危险状态。阅读器仍有独立背景与评论语义色，不能全局覆盖。

主题变更检查浅色、深色、界面染色关闭、自定义色以及原生和网页表面；不用装饰色代替正文或操作文字。图标源资产、脚本与检查方法见[App 图标维护](../design/app-icon.md)。桌面 `.icon`、App 内 SceneKit 图标和普通预览图片是不同渲染路径。

新增 SDK API 保持 iOS 18 可用路径，按实际条件使用 `#if os(iOS)`、`canImport`、`#available`，旧版本降级保留业务能力。例如持续处理任务以 iOS 26 为 guard，需覆盖类型使用和调用，不只隐藏按钮。

本文以源码和配置为依据，不把编译或历史验证泛化成设备兼容。平台行为变更按风险验证权限拒绝、账号切换、窗口断开、主题切换、简繁文案和资源缺失；实体外设与后台调度未验证时明确标注，不以截图替代行为证据。
