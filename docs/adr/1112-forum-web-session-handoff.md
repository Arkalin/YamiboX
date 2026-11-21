# 原生页面在 Web 会话交接后开始加载

网页跳转到原生论坛页面前先提交 WebKit 会话更新，否则原生页面的第一个请求可能早于登录凭据写入。保留当前账号作用域；仅通行状态变化时，不重载已正确显示的网页，也不重设进行中的网页导航所用的登录凭据。目标新窗口的请求统一由导航策略处理，而不是再创建一份 WebView；没有原生实现的页面直接使用桌面模板，避免把移动模板提示页当作实际功能。

入口：[浏览器模型与显示](../../Sources/YamiboXUI/Features/Forum/Web/ForumBrowserView.swift)、[导航与会话同步](../../Sources/YamiboXUI/Features/Forum/Web/ForumWebView.swift)。完整边界见[论坛接入、认证与路由](../architecture/networking-and-routing.md#webkit-接回原生页面)。
