# 「我的」窗口独立保留导航状态和原生布局

[`MineSidebarNavigationState`](../../Sources/YamiboXUI/Features/Mine/MineSidebarNavigationState.swift)独立于详情栈维护侧栏状态。历史和喜欢在内容上方显示筛选器，不在侧栏推入筛选页。窄窗口进入设置子菜单时先显示侧栏，不直接跳进默认详情。[原生标签辅助功能探针](../../Sources/YamiboXUI/Features/Mine/MineSidebarView.swift)挂在分栏内部，包裹整个分栏会改变原生导航栏的安全区。

[登录监听器](../../Sources/YamiboXUI/Features/Mine/MineLoginViews.swift)在读会话快照前订阅变化，但不单靠事件判断成功，否则错过基线读取前就已认证的会话。
