# 按阅读模式保存续读位置

同一个帖子可以从普通帖、小说或漫画入口观看。一份按帖 ID 通用的进度会让一次“查看讨论”覆盖小说的书内位置，因此续读位置按模式隔离；浏览历史仍经配置的作品归属记录，不依赖是否保存普通帖进度。

- 普通帖以页码和保存时最靠上的可见楼层 PID 恢复。该功能由设置开启，显式页码或楼层链接优先；保存时重新读取设置，避免防抖或退出写入继续使用旧设置。小说/漫画按帖模糊查找进度时排除普通帖记录，否则更新更近的讨论位置会遮盖正文位置。读取失败与无记录不同，不能在失败时回到默认点再覆盖旧进度。
- 智能漫画开启时只更新作品目录的 `.mangaTitle` 记录；关闭时只更新当前正在读的章节帖 `.mangaThread`，而不是会话最初打开的章节。单章模式也有临时目录名，所以由入口传入的模式值选择保存范围，不凭有无目录名推断。每次保存只写一个位置，避免两次异步写入之间取消留下互相冲突的状态。代价是切换模式不会迁移进度，之前只在智能模式读过的章节关闭智能模式后从默认位置开始。
- 单帖漫画的收藏与续读使用同一个 `manga-thread:<tid>`，以 ID 精确关联，不猜标题。历史 API 名称和编码继续兼容，收藏与进度仍各自拥有目标类型，见[持久化、作品身份与迁移](../architecture/persistence-and-identity.md)。
- 串行等待正在进行的保存，再比较已落盘位置；用户在保存 B 时回到 A，不能因为 A 曾经是最后完成的位置就丢弃这次 A。

依据：[进度存储](../../Sources/YamiboXCore/Reader/Shared/Progress/ReadingProgressStore.swift)、[写入协调和历史适配器](../../Sources/YamiboXCore/Reader/Shared/Progress/ProgressSyncModule.swift)、[普通帖续读入口](../../Sources/YamiboXUI/Features/Forum/ThreadReader/ForumThreadReaderViewModel.swift)。
