# 目录发现、刷新和同步保持独立的身份与内容来源

同一作品的并发首次发现必须在写事务中检查已登记名称和别名，再复用身份或创建目录；未持久化的随机种子不是第二个业务身份。并发发现可补充章节，但不能抹掉已保存的章节和手动编辑。选择重建目录时，提交网络种子及后续正常刷新，允许清除手动章节编辑，但保留现有 ID 和权威标题，使引用在重建后继续有效。见[目录存储](../../Sources/YamiboXCore/Reader/Manga/Data/MangaDirectoryStore.swift)与[目录 workflow](../../Sources/YamiboXCore/Reader/Manga/Application/MangaDirectoryWorkflow.swift)。

只有兼容旧格式时才能从旧名称派生确定性 ID，允许多个设备独立导入相同的旧主键。旧收藏身份仅供旧格式导入；遇到身份冲突不得按同名标题兜底，否则会把旧历史误绑到后来使用该标题的新作品。重命名或合并与已有引用改写必须同事务提交，失败不保留任何一侧的中间状态。

合并可能保留目标 ID，因此仅校验 ID 不能发现过期刷新。刷新比较内容来源，只补入本次请求新发现的章节，不能恢复合并前的章节子集或回退权威标题和关键词。事务内可复用重定向快照，但标题和内容来源仍须读取当前事务中的最新写入；不要复用跨事务快照。

携带漫画作品引用的当前 WebDAV 数据集同时携带[可移植身份快照](../../Sources/YamiboXCore/Reader/Manga/Data/MangaDirectoryIdentitySnapshot.swift)。[WebDAV 目录合并](../../Sources/YamiboXCore/Reader/Manga/Application/MangaDirectoryWebDAVParticipant.swift)在改写身份前保存内容来源，并在比较版本与删除墓碑前，于写事务重新规范化双方身份。身份重定向不证明对应章节已合并。先排除被墓碑删除的快照，再为尚未纳入的来源合并章节，避免被删除的快照借版本推进而复活；赢家已含相同来源时保持正常的最新版优先，保留刻意删除章节的结果。

收藏和历史的[批量读取契约](../../Sources/YamiboXCore/Reader/Manga/Application/MangaDirectoryReadContracts.swift)要求一次读取复用同一目录，避免逐帖查询。每组 `IN` 参数保守限制为 500 个，不依赖链接的 SQLite 使用较新的参数上限。详见[持久化与作品身份](../architecture/persistence-and-identity.md#漫画身份注册与运行时合并)。
