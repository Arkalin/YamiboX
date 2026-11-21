# 收藏条目、智能漫画卡片与封面不共用身份

论坛收藏保存单帖；即使多个漫画章节合成一张智能卡片，每个收藏仍有自己的帖子 ID、标题和论坛映射。让 [FavoriteItemTarget](../../Sources/YamiboXCore/Library/Domain/FavoriteItemTarget.swift) 与阅读进度的目标类型分离，避免为并不存在的目录级收藏写回退分支。单帖漫画收藏与单帖进度的 `manga-thread:<tid>` 格式有意保持一致，供精确匹配；其他用途不要依赖目标枚举名称相同。目录改名不必重写按帖保存的收藏条目。身份注册、旧别名、当前格式历史/进度中的章节证据要求见 [持久化、作品身份与迁移](../architecture/persistence-and-identity.md)。

[封面索引](../../Sources/YamiboXCore/Library/Data/ContentCoverStore.swift)的普通帖、小说帖和单帖漫画按 tid 共享线程型封面：阅读方式改变不代表作品换了。智能合集卡片通过 [收藏卡片投影](../../Sources/YamiboXCore/Library/Application/LocalFavoriteLibraryProjection.swift)改用目录的持久 ID，不按代表章节或显示名存取；备选的手动/自动图片不因启用文字封面而丢弃，显式请求换图或恢复自动封面则关闭文字覆盖。旧来源页只可补到同一个 URL 的同一选择槽；目录的显式合并是一次新的封面选择，推进时间戳以阻止旧来源通过重定向覆盖选中的封面。与 WebDAV 合并并发时要在写事务内重新解析两边的身份，而非信任事务外已做的规范化；旧的删除标记也必须保留其导入过滤含义。

智能漫画提示和卡片聚合都不能只查一侧版块的开关：目录会跨版块，用户关闭其中一个版块的智能模式时，那一侧收藏仍独立展示。关闭角标只是视觉选择，不改变聚合、归档入口或按作品删除的行为。开启作品级删除时，移除整张智能卡片会影响它当前包含的全部已收藏章节，而不是只移除代表章；逐条管理由归档界面承担。

[漫画自动封面服务](../../Sources/YamiboXCore/Library/Application/MangaAutomaticCoverService.swift)统一按目录持久 ID 和首章推导自动封面。调用方拥有任务生命周期和展示；网络查询之后提交时，在写事务内用 `onlyIfMissing` 再确认，避免覆盖等待期间设置的手动或文字封面。

收藏错误由收藏领域的 [FavoriteActionError](../../Sources/YamiboXCore/Library/Domain/FavoriteActionError.swift) 定义，不能为新增本地收藏操作反复改动通用传输错误枚举。
