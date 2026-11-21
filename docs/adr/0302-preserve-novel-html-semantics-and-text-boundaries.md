# 小说源投影保留 HTML 与文本边界语义

[小说投影构建](../../Sources/YamiboXCore/Reader/Novel/Data/NovelReaderProjectionBuilder.swift) 只复用当前论坛解析器生成的单个简单文本块。多个块的边缘已去空白，拼接可能丢段落；论坛解析器也会把 NBSP 转成全角空格。复杂内容仍由小说解析器处理，以保留图片、图标、附件与回复过滤语义。每个直接的 `rt` 注音属于其前面的基底节点组，不能把整段 ruby 压成一个注音；子节点的 `text-decoration: none` 也不应抹掉祖先已绘制的下划线或删除线。去除文件附件下载卡片时保留 `.attm` 图片附件；以解析后的绝对 URL 记录被排除的文件图标，以免备用图片列表用另一种 URL 写法把它们加回来。

性能优化不应改变投影依赖的匹配方式。按原始 HTML 子串找图片引用，包括属性以外的引用，而不是匹配 byte 或规范化 URL；多模式匹配以 Swift `Character` 为键，保留 Unicode 规范等价与字素边界语义，只需记录每个引用首次命中，已消费的后缀链不再重复遍历。跨 DOM/style run 拼接文本时用末尾字素判断新字符是否合并，避免每次追加重新扫描整段的 `String.count`。

[TextKit 准备](../../Sources/YamiboXCore/Reader/Novel/Domain/NovelTextLayout.swift) 先决定哪些文本实际可见，再判断缺失的 TextKit 范围是否为错误：例如隐藏作者回复后只剩图片时，空的文本范围是正常输出。繁简转换对完整段落执行，避免不可见的样式边界拆散受上下文影响的词组。样式端点在字素总数不变时使用序号映射；总数变化时用转换后前缀的长度估算端点并保持顺序，前缀绝不用于替代完整段落的显示文本。

[运行时索引](../../Sources/YamiboXCore/Reader/Novel/Domain/NovelTextCoordinateIndex.swift) 用不同类型区分文档级和文本段级 UTF-16 偏移；源样式与已持久化的续读、书签和喜欢仍以 Swift `Character` 序号为兼容边界。不能把转换后文本的 UTF-16 偏移直接应用于未转换的原文。每份文本的坐标索引在其展示范围之间共享；派生索引不会改变文档的语义身份。竖向选区可跨展示面，故选区端点在共享文档空间解析；摘录上下文只复制附近所需范围，避免为短选区复制整章。

[搜索](../../Sources/YamiboXCore/Reader/Novel/Domain/NovelReaderSearch.swift) 先交付首个结果，再批量跨隔离边界更新列表。对有序不相交的范围用单向游标；不规则范围继续采用首个包含或最近范围，距离相同选原先靠前者，避免优化改变跳转结果。
