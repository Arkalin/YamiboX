# 设置页分管表单，共享操作和存储状态

[设置装配根](../../Sources/YamiboXUI/Features/Settings/SystemSettings/SystemSettingsViewModel.swift)一次读取设置快照并分给各页，避免每次导航重新读取；磁盘枚举和下载空间统计由存储页单独触发，不阻塞其他设置。阅读器可以独立展示[外设设置](../../Sources/YamiboXUI/Features/Settings/SystemSettings/SettingsPeripheralsViewModel.swift)，此时外设页自行读取设置。

[共享设置状态](../../Sources/YamiboXUI/Features/Settings/SystemSettings/SystemSettingsSharedState.swift)集中保存繁忙状态与待显示错误，而不是按页隔离。这样进行清理时，[设置导航入口](../../Sources/YamiboXUI/Features/Settings/SettingsHomeView.swift)可以禁止切换分类和退出登录，切回标签时也不会让重新加载接管现有操作；异步保存失败即使发生在离开原页面之后，仍能在当前设置页显示。整应用重置只由存储页调用持久化工作流；各页内存状态由装配根负责刷新，而不是由存储页持有这些页面。重置回调捕获各子模型而不是装配根本身，避免子模型持有闭包、闭包又持有父模型的循环引用。成功重置后关闭设置展示，再通知应用重新加载。

常规编辑通过[设置持久化适配器](../../Sources/YamiboXUI/Features/Settings/SystemSettings/SystemSettingsPersistence.swift)捕获本次字段改动，并交给 Store 在同一 actor 内原子读改写，避免不同页面以各自旧快照覆盖别的字段。异步编辑在 UI 乐观展示；较新的成功提交成为回滚下界，早先失败不能撤销它（包括值恰好相同时），而仍未确认的先前值需要保留，直到较新的连续失败被回滚。收藏网格滑块在拖动时只更新预览，在结束后才写入；保存失败仍展示目标值和错误，不在拖动结束时突然改变预览。

[论坛设置页](../../Sources/YamiboXUI/Features/Settings/SystemSettings/SettingsForumViewModel.swift)只能编辑阅读模式，真实版名快照由[版块页](../../Sources/YamiboXUI/Features/Forum/Board/ForumBoardViewModel.swift)提供；名称缺失时的占位只用于展示。持久化按版块条目更新而不是覆盖整份设置。原子更新避免覆盖其他版块的异动，但若把视图传入的整条条目写入，仍不能保证保留同一版块刚刷新的名称。

下载与漫画目录管理子页会删减存储页展示的数据，因此共用并刷新同一份空间统计。刷新按代次发布，清理或更新的读取能淘汰清理前仍在等待的快照；应用重置成功后直接将计数归零，不为已知结果重新扫描。漫画目录删除可能部分成功，故即使上游任务取消也要读取实际目录、收缩选择集合并更新空间占用；读取期间又收到失效通知则再读一次。[存储统计口径与清理范围](../architecture/downloads-and-storage.md)区分可重新获取的渲染缓存和下载等用户数据；未知分类不能被算作零字节。

[网络日志页](../../Sources/YamiboXUI/Features/Settings/SystemSettings/NetworkLogViewModel.swift)合并后台变化流中的高频图片请求完成事件，仅限制事件触发的快照刷新频率，手动刷新不经该等待路径。
