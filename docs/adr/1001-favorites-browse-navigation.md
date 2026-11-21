# 在收藏导航中保留页面各自的投影

交互式返回还没提交时，[收藏首页和详情](../../Sources/YamiboXUI/Features/Favorites/Organization/LocalFavoritesOrganizationView.swift)可以同时出现在视图树上。不能从当前打开的收藏夹或归档反推首页的范围，否则手势中途就会显示出详情数据。首页明确传入不受收藏夹或归档限制的 `rootDerived`，详情传入有范围的投影；布局和页头也接收显式范围。只有两种详情都没打开时，才允许[协调器](../../Sources/YamiboXUI/Features/Favorites/Engine/FavoriteLibraryOrganizer.swift)复用当前投影作为首页投影；归档可从首页直接打开，不一定伴随收藏夹选择。

iPad 根据设备类型使用[分栏容器](../../Sources/YamiboXUI/Features/Favorites/Organization/LocalFavoritesAdaptiveNavigation.swift)，不因窗口变窄而替换浏览栈。侧栏把选择交给[详情导航栈](../../Sources/YamiboXUI/Features/Favorites/Organization/LocalFavoritesNavigation.swift)，而不是让分栏的原生列表选择接管路径，以免从内容卡片打开收藏夹时栈被重置。回退上层详情仅关闭路径中已移除的页面，例如弹出内容详情不会连同下方收藏夹一起关闭。

各页面自行绘制收藏背景，因为推入导航栈的页面会用自己的背景覆盖底层。网格和列表共享[页头](../../Sources/YamiboXUI/Features/Favorites/Organization/LocalFavoriteBrowseChrome.swift)，不显示的行必须不进入堆栈，而不是显示空视图，以免仍产生间距。列表显式指定与网格相同的顶边距；两种布局也使用同一个条目排序投影，只有手动排序保留收藏夹在前，见 [ADR 0103](0103-favorite-library-projections.md)。
