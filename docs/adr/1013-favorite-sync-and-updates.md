# 将收藏同步和更新检查的运行状态与页面分开

## 远端收藏同步

同步引擎通过共享收藏 Store 提交数据，浏览页面订阅该 Store，而不是由同步会话直接刷新页面。同步开始时读取的分类名称只用于展示；引擎仍须自行读取文档并确认目标分类。智能漫画导入提示也只基于本地目录批量读取和版块设置，不能为生成提示单独触发目录解析。

同步会话恢复记录时，若找不到仍在运行的对应任务，则将遗留的「运行中」标记为中断。写入中断快照的数据库操作不继承已取消任务的取消状态，否则 GRDB 也会取消这次写入。会话先尝试写入引擎进度，再发布给 UI；写入失败会被记录，并不保证 UI 只显示持久化成功的数据。隐藏状态归页面所有：用户可在写进度期间隐藏卡片，因此会话只补写隐藏字段，避免用旧界面快照覆盖较新的日志与进度。

从收藏页推入的详情依靠导航栈的返回按钮，只有作为设置页弹层的根视图时才需要另设关闭按钮。日志、警告和错误各用单个高度受限的可滚动文本区域，而不是逐行扩展表单；短消息保持自然高度，长日志不会挤占其他运行指标。180pt 上限来自与 Android 同步消息组件对齐的设计。

代码：[同步会话](../../Sources/YamiboXUI/Features/Favorites/Sync/FavoriteRemoteSyncSession.swift)、[同步引擎](../../Sources/YamiboXCore/Library/Application/FavoriteRemoteSync.swift)、[同步进度页](../../Sources/YamiboXUI/Features/Favorites/Sync/FavoriteRemoteSyncProgressSheet.swift)。

## 收藏更新检查

Core 的引擎拥有更新检测和通知逻辑；前台、多个窗口和后台可以拥有不同的 monitor，但同一个更新 Store 只准入一个运行。后台任务过期只能取消自己启动的运行，不能取消它借由共享 registry 观察到的前台运行。后台调度仅是尽力而为，收藏首页仍在前台补查。前台补查和手动检查允许最多三个非标签漫画目录，后台只允许一个，以限制短暂的系统执行预算内启动的目录请求数量。

页面按变更字段接收引擎状态，让 UI 可以关闭错误提示，而不会被无关进度更新重新弹出。进度更新也不应使未读索引或更新列表扫描收藏库：按收藏项、目录、事件和筛选输入的修订号重用派生结果。版块与分类筛选结果由铃铛和更新页共享；单条收藏用当前归属，智能漫画事件则以运行记录的目录归属为准，不能拿目录 ID 去匹配收藏项 ID。一个未读事件可显示在多个收藏或收纳夹中，但仍按事件 ID 确认。

设置页与更新页分别拥有 monitor，但读取和编辑同一 SettingsStore；从另一页返回时必须重新读取共享设置，不能只信首次加载的本地状态。通知设置通过用户操作的 binding 写回。系统拒绝授权时，状态可以直接回退为关闭，无需再次调用 setter 或重弹提示。

代码：[更新 monitor](../../Sources/YamiboXUI/Features/Favorites/Updates/FavoriteUpdateMonitor.swift)、[运行 registry](../../Sources/YamiboXCore/Library/Application/FavoriteUpdateActiveRunRegistry.swift)、[后台调度](../../Sources/YamiboXUI/AppEntry/FavoriteUpdateBackgroundScheduler.swift)、[未读索引](../../Sources/YamiboXUI/Features/Favorites/Updates/FavoriteUnreadIndex.swift)、[事件筛选](../../Sources/YamiboXUI/Features/Favorites/Updates/FavoriteUpdateEventScope.swift)、[通知设置](../../Sources/YamiboXUI/Features/Favorites/Updates/FavoriteUpdateSettingsSection.swift)。
