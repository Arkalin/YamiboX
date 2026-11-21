# 漫画阅读身份以会话模式为准

关闭智能漫画后，阅读器仍构造单章目录以复用视口和窗口逻辑。该目录也有作品名，因而不能根据目录或名称是否存在来判断智能漫画模式。以会话的 `isSmartModeEnabled` 为准：关闭时用当前章节帖子的封面键，不赋予阅读会话漫画作品级的注解身份；开启时等到真实目录 ID 可用，再以该 ID 标识作品封面与注解。下载面板查找本地收藏时按启动帖 ID 匹配，因为收藏存的是帖子，不以合并目录标题标识。

普通帖子在加入收藏时会解析自动封面；漫画阅读器没有对应的收藏按钮。因此，关闭智能漫画的会话在成功准备后尝试复用同一帖子封面解析器，缺少解析依赖时跳过。它可以刷新自动封面候选，但不替换手动封面。开启智能漫画时，这个入口不写帖子封面，作品封面仍由独立的收藏投影回填路径管理。

喜欢模块拥有观察任务和变更逻辑，`likedPageIDs` 仍写回可观察的阅读器 ViewModel：SwiftUI 观察 ViewModel，而不是模块。竖滚视口只刷新已挂载单元格的喜欢标记，不因标记变化重配页面或重载图片。

实现：[封面模块](../../Sources/YamiboXUI/Features/Reader/Manga/Root/MangaReaderCoverModule.swift)、[喜欢模块](../../Sources/YamiboXUI/Features/Reader/Manga/Root/MangaReaderLikeModule.swift)、[下载面板](../../Sources/YamiboXUI/Features/Reader/Manga/Download/MangaReaderDownloadModule.swift)、[竖滚视口](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/MangaVerticalCollectionViewport.swift)。
