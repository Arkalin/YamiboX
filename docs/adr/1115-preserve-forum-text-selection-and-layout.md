# 论坛正文保留原生换行、选区和复制

常规帖子把正文和内嵌表情组合成一个 SwiftUI `Text`，不以独立视图拼排，避免换行和选区在附件旁断开。SwiftUI 会递归展开插值的 `Text`，因此相邻片段成对合并，保证长正文和重复表情不会构成很深的单边插值链；同一个属性范围里仍须按字符数显示所有表情。可播放的动画只换图片帧，不改变附件尺寸或为每帧重新拆分静态片段。

有段落排版或注音的正文使用单个可选中的 TextKit 1 容器。使用字形几何单独绘制注音，使它不成为独立的不可换行视图或复制时混入的替换字符，并保留系统链接、无障碍和选区。领域样式范围是字素偏移，桥接时转成 UTF-16。文字尺寸通过正文 Dynamic Type 度量缩放；SwiftUI 端按视图复用格式化结果，避免可见性或其他上层更新重复格式化相同正文而不忽略主题和大小变化。在 TextKit 路径中，动画帧修改现有附件的图像，不重建文本存储或其排版度量。

作为源页面兼容的一部分，原帖视图仍防御旧缓存中的重复附件，避免内文已有的附件再出现在页脚。缓存保留与临时重解析见[帖子内容抓取与缓存](0401-forum-thread-capture-and-cache.md)。

实现：[内联正文](../../Sources/YamiboXUI/Features/Forum/ThreadReader/ForumThreadInlineTextView.swift)、[原生富文本](../../Sources/YamiboXUI/Features/Forum/ThreadReader/ForumThreadRichTextBlockView.swift)、[格式化缓存](../../Sources/YamiboXUI/Features/Forum/ThreadReader/ForumThreadTextBlockFormatter.swift)、[帖子卡片](../../Sources/YamiboXUI/Features/Forum/ThreadReader/ForumThreadPostCard.swift)。
