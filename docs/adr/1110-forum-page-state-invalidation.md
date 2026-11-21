# 按内容边界失效论坛界面状态

跨页面修改的失效标记要保留到目标再次出现，各个已加载视图自行消费。回复表单有时没有板块 ID，这时让板块列表刷新，不猜所属板块，也不重载不相关的帖子。列表的分页控件从调用方接收当前页，而不重读最近一次服务器快照，才能表达用户刚发出的翻页请求。

同一个板块的换页和刷新可以彼此取代，所以只允许当前请求清理加载状态，而且要能清理被取代的另一类请求的指示器；跳过重复刷新必须发生在推进代次前，否则会作废仍在运行的唯一刷新。用户空间则给个人资料与内容列表分别计代次：列表只依赖用户 ID，切换子页不能使个人资料请求失效；切回已经缓存的个人资料时，即使未发新请求，也要废弃旧内容请求并清理它的状态。搜索的翻页身份归属最近一次已提交查询，不跟随正在编辑的搜索框或仍在等待的替换请求。

入口：[失效状态](../../Sources/YamiboXUI/Features/Forum/Navigation/ForumContentRefreshState.swift)、[板块模型](../../Sources/YamiboXUI/Features/Forum/Board/ForumBoardViewModel.swift)、[用户空间模型](../../Sources/YamiboXUI/Features/Forum/UserSpace/UserSpaceViewModel.swift)、[搜索模型](../../Sources/YamiboXUI/Features/Forum/Search/ForumSearchViewModel.swift)。
