# 持久化注解的阅读顺序

书签和点赞摘录既需要语义锚点定位，也需要跨章排序。锚点在章内才有可比较的位置；同一论坛页上两篇帖的先后还需要目录。列表和只同步了注解的设备不一定有目录，因此保存一个独立的线性顺序值，不在打开列表时再用锚点重算。

小说将论坛页、章序、段在章内的出现顺序和显示文本偏移依次打包到 `Int64`。各字段夹在自己的位宽内而非溢出进位，避免过大的段或字符偏移被读成下一章的位置。漫画书签可直接使用作品全局页索引；按章保存的漫画点赞用章序和章内页索引组合。顺序值只用于比较，不代替锚点或作品身份。共享的 `ReadingWorkKey` 保留旧 `LikeWorkKey` 的字段和枚举编码，以兼容已有数据。

依据：[共享排序键](../../Sources/YamiboXCore/Reader/Shared/Domain/ReaderAnnotationSortKey.swift)、[点赞排序](../../Sources/YamiboXCore/Like/Domain/LikeSortKey.swift)、[书签排序](../../Sources/YamiboXCore/Bookmark/Domain/ReaderAnnotationSortKey+Bookmark.swift)、[作品键](../../Sources/YamiboXCore/Reader/Shared/Domain/ReadingWorkKey.swift)。
