# 板块收藏不进入本地收藏库

[板块收藏页](../../Sources/YamiboXUI/Features/Favorites/FavoriteBoardListView.swift)管理的是论坛账户上的板块列表，与支持本地分类和双向同步的帖子收藏不同。[页面模型](../../Sources/YamiboXUI/Features/Favorites/FavoriteBoardListViewModel.swift)从论坛加载和删除，不创建本地收藏、离线队列或同步副本；删除在远程成功后才从列表移除，避免显示尚未生效的账户变更。
