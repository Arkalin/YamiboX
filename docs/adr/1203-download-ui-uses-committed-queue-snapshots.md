# 下载页面以已提交的队列状态为准

两个下载入口共用[一对根页面和次级页面](../../Sources/YamiboXUI/Features/Download/DownloadsScreen.swift)；切回初始页面应返回而非递归推入新的下载页面。[管理页面刷新](../../Sources/YamiboXUI/Features/Download/DownloadManagementViewModel.swift)记录另一加载任务正在取消时收到的请求，避免子页面丢掉首次刷新。合并密集的进度通知，只有管理页面观察存活时才为它扫描存储。

[队列模型](../../Sources/YamiboXUI/Features/Download/DownloadQueueViewModel.swift)在列表和子页面至少一个可见时共享详细投影，其余时间只读摘要。只有当前账号和代次的完整成功读数才发布；模型可以跨越账号代次，所以每次命令重新解析装配根提供的 executor。[队列视图](../../Sources/YamiboXUI/Features/Download/DownloadQueueViews.swift)在最后一行消失时保留数据区，不使用会立即移除行的破坏性滑动角色，因为仍需等待下载 worker 停止并删除存储记录。行由刷新后的快照移除，不由手势移除。
