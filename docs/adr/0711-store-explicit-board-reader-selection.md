# 区分未配置板块与显式选择普通阅读

[板块阅读设置](../../Sources/YamiboXCore/Settings/Domain/BoardReaderSettings.swift)用一个按板块 ID 索引的映射保存阅读模式。显式选择「普通」时保存 `.normal`，而不是删除设置：两者打开普通论坛帖时行为相同，但[从收藏打开](../../Sources/YamiboXUI/Features/Favorites/Engine/LocalFavoriteOpenTargetResolver.swift)时，前者覆盖收藏中的旧分类，后者允许按收藏已保存的种类打开。工厂预设沿用此前内置的小说、漫画板块分类，避免升级或重置时无意改变这些板块的阅读方式。

智能漫画只在板块设置为 `.manga(smartEnabled: true)` 时启用，不能通过已有目录或非空书名推断：目录数据可能早于当前设置。启动入口可将该选择传给本次阅读会话，见[智能漫画启动范围](0311-scope-smart-manga-to-launch-context.md)。

板块名称是展示快照，不是身份。[板块页面](../../Sources/YamiboXUI/Features/Forum/Board/ForumBoardViewModel.swift)只刷新已有设置的名称，不因浏览页面创建模式条目。找不到名称时由[展示层](../../Sources/YamiboXUI/Features/Settings/SystemSettings/SettingsForumView.swift)生成占位文本，不写入存储。
