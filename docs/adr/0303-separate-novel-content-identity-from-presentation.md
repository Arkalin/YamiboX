# 小说源内容、恢复位置和离线所有权独立于布局

小说以帖子页为加载单位；[投影加载器](../../Sources/YamiboXCore/Reader/Novel/Data/NovelReaderProjectionLoader.swift) 不像漫画章节加载那样合并进行中的同身份请求，因为小说会话用一个预取槽晋升已有结果，而不是在越界时重新请求。仅调整布局不使仍对应同一源内容的预取失效。明确作者范围的续读锚只能晋升同范围的预取；旧锚点没有该字段时沿用当前会话范围。章节序号取自当前源页投影里的段顺序，而不等待可能尚未加载的小说目录；序号只在同一源页内区分章节。

[续读会话](../../Sources/YamiboXCore/Reader/Novel/Application/NovelReadingSession.swift) 使用目标布局的索引恢复语义位置；布局变化后保留已接受的精确位置，直到翻页或实时采样提供新位置，不能用双页显示的可见边缘替换它。图片与文本续读沿用同一持久化字段，但图片对应的段身份位于外部图块而不在文本范围。图片要先按其自身身份定位，避免退回章节时跳到首个展示面。共享的 [续读位置规则](../../Sources/YamiboXCore/Reader/Novel/Domain/NovelReadingResumeResolver.swift) 不负责 I/O、导航或入口策略；从头阅读会清除旧位置但保留作者范围。预览不写阅读进度、恢复路由或收藏最近使用时间。

[小说投影存储](../../Sources/YamiboXCore/Reader/Novel/Data/NovelReaderProjectionStore.swift)只定义缓存命名空间和键，不另加隔离边界，读写与淘汰沿用共享存储。枚举同组页码使用编码后的键前缀，不用原始 ID；展示面与选区采样传递实际解析到的作者范围，因此喜欢回查不必猜测缓存键。在[组合根依赖](../../Sources/YamiboXCore/Reader/Novel/Application/NovelReaderDependencies.swift)边界组装章节评论、共享浏览历史和下载操作；消费投影快照的注解功能持有自己的持久化副作用，只读查询不需要缓存写权限。

[小说仓储](../../Sources/YamiboXCore/Reader/Novel/Data/NovelReaderRepository.swift) 不把离线回退当作新的在线响应，也不因此推进下载时间。在线源更新离线副本时，每个源页仅由一个 worker 顺序写入；写入挂起期间只保留最新待写源，避免旧事务后完成覆盖新数据。详情使用的短命仓储由 worker 保留到有限队列排空，避免返回详情即丢弃更新。[用户导入的字体](../../Sources/YamiboXCore/Reader/Novel/Data/ReaderFontFileStore.swift) 是持久用户文件而不是可重建缓存；再次导入同字节时复用已索引路径，即便扩展名不同也能修复缺失原文件。平台字体的解析结果本身不写入外观设置。
