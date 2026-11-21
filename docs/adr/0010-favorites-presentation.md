# 在打开收藏时确定阅读范围

[收藏入口](../../Sources/YamiboXUI/Features/Favorites/Engine/LocalFavoriteOpenTargetResolver.swift)从同一份设置快照决定阅读方式与智能漫画开关，避免在一次打开过程中读到彼此不一致的设置。已配置的版块覆盖收藏时记录的类型，但不改写收藏数据；没有配置时保留原类型。显式选择「普通」与未配置的区别见 [ADR 0711](0711-store-explicit-board-reader-selection.md)。

- 漫画卡片通常遵循版块设置。智能漫画开启且已知本地目录时，[续读解析器](../../Sources/YamiboXCore/Reader/Manga/Application/MangaReadingResumeResolver.swift)先用目录进度，缺失时从目录首章开始；本地没有可用目录时读单帖进度，不在解析入口中新增远端查找。关闭时不查目录。归档成员卡显式使用单帖范围；否则点开不同成员也会回到同一作品目录，无法逐章阅读。归档键和成员投影分别见 [ADR 1011](1011-favorites-cards-and-actions.md) 和 [ADR 0103](0103-favorite-library-projections.md)。
- 首选卡片动作可以打开详情；显式续读或从头读不走此偏好。[更新页](../../Sources/YamiboXUI/Features/Favorites/LocalFavoritesRootView.swift)和[通知](../../Sources/YamiboXUI/Features/Favorites/Updates/FavoriteUpdateNotificationRouting.swift)复用显式续读。目录更新只有稳定目录 ID，不绑定某次展示所用的代表收藏；打开时重新查找仍在收藏中的目录成员。当目标已经不存在或无法打开时，通知退回收藏页。收藏页只在实际成功打开后确认已读，因为漫画可能在目标解析之后的校验中失败。
- 收藏页里的普通帖子使用全屏覆盖层，以保留下方收藏页的浏览位置；它是真实的论坛访问，不是某个活动阅读会话的讨论伴随页，因此记入历史。
