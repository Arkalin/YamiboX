# 内容详情状态不依赖布局和入口

[`ContentDetailScreen`](../../Sources/YamiboXUI/Features/ContentDetail/ContentDetailScreen.swift)组合通用页面，但由宿主决定如何打开阅读器、作者和原帖。[自适应布局](../../Sources/YamiboXUI/Features/ContentDetail/Shared/ContentDetailAdaptiveLayout.swift)在旋转时保持两个子树挂载，保留目录展开、滚动和详情状态。[页头](../../Sources/YamiboXUI/Features/ContentDetail/Shared/ContentDetailHeader.swift)在辅助功能大字号下为目录留出空间，同时用不限制字号的详情面板提供完整元数据；操作按钮按测量结果换行，不用候选子树重复挂载，也不压缩标签。主操作按分配宽度测量，避免较长的进度文案挤掉其他操作。

[`ChapterDirectory`](../../Sources/YamiboXUI/Features/ContentDetail/Shared/ChapterDirectory.swift)的可见性是内部记录，不应在行穿过工具栏时使整个目录重建。固定页头遮挡了部分 SwiftUI 报告的可见矩形，而顶部滚动锚点并不会预留页头空间。程序滚动需要补偿这个偏移，并在几何事务完成后执行，避免在几何回调中滚动递归触发同一测量。

[漫画](../../Sources/YamiboXUI/Features/ContentDetail/Manga/MangaDetailViewModel.swift)和[小说](../../Sources/YamiboXUI/Features/ContentDetail/Novel/NovelDetailViewModel.swift)详情的手动刷新都等待实际操作结束，不因重绘取消刷新控件任务就丢弃请求或缓存更新。小说进度读取失败保留上次的结果，不当作没有进度；[小说详情](../../Sources/YamiboXUI/Features/ContentDetail/Novel/NovelDetailView.swift)元数据加载失败也可以打开阅读器，因为离线内容仍可能可用。目录至多高亮一个小说章节，优先按稳定的楼层身份定位，避免重名章节一同高亮。

漫画作品详情是智能漫画入口，目录搜索使用启动版块 ID 而不是工作流的通用默认值。进度和收藏归属依赖目录身份，不应拖慢可独立开始的源内容投影。目录解析后按带类型的目录目标加载进度：只按章节 TID 取最新记录可能误用单帖进度。更新和修正都写同一目录，因此共用操作执行闸门。

阅读器或后台可能在详情仍挂载时改动目录。模型按启动章节重新解析目录，更新收藏归属、进度和封面，不重做初始投影。存在待完成的自动目录更新时，封面解析等到更新结束，因为第一章可能变化；没有加入收藏的作品也能在详情解析自动封面。不把显式文字封面当成缺失的图片，并在保存后直接读取封面，不依赖通知顺序。手动重建允许丢弃本地目录编辑，详见[目录发现与刷新](0313-preserve-directory-identity-through-refresh.md)。
