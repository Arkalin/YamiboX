# 喜欢锚点保留定位所需的阅读上下文

小说文本和插图锚点保留捕获时的论坛页码与实际作者筛选。小说章节通常用帖子 ID 标识，不能由它反推出论坛页码；投影缓存又以帖子、页码和作者共同定位，省略作者会落到另一个缓存键。章节标题优先使用已保存的显示快照，只有缺失时才用对应投影或漫画目录补齐，缓存淘汰不应让标题消失。列表查询按页码和作者复用同一次缓存读取，包括未命中的读取；补齐写入在事务内核对锚点，避免覆盖同步过程中已经替换的条目。

文本锚点保存同一章内的两个端点。正文可因插图被拆成多个文本段，同段的偏移差无法表示跨段范围；端点按文档顺序比较，避免反向拖选或跨段时误用段内的 `Character` 偏移。插图则用图片段标识一个点，不需要字符范围。旧的单段锚点在解码时转换，不另做 SQL 迁移，因为数据库把锚点当作 JSON 保存。编码仍提供旧客户端必读的单段字段；跨段时让不支持端点的客户端看到起点上的一个字符，是为了不让整份旧客户端载荷无法解析，并不保证旧客户端重新导出时能保留跨段范围。

漫画图片按章节和页内序号辨认；论坛板块只用于重开时读取当前的阅读设置，不改变图片身份。没有板块的旧记录保持默认开启智能漫画的兼容行为，打开仍使用漫画阅读器。喜欢与书签共用作品身份，旧的 `LikeWorkKey`、`LikeWorkKind` 作为源代码兼容别名保留。

涉及实现：[锚点和编码](../../Sources/YamiboXCore/Like/Domain/LikeItem.swift)、[端点排序](../../Sources/YamiboXCore/Like/Application/NovelLikeTextEndpointOrdering.swift)、[标题补齐](../../Sources/YamiboXCore/Like/Application/LikeChapterInfoResolver.swift)、[漫画跳转](../../Sources/YamiboXUI/Features/Like/LikeMangaOpenTargetPolicy.swift)。
