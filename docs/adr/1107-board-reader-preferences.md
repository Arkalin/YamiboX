# 板块阅读设置不因打开或重选而创建条目

[板块阅读设置区分未配置与显式普通](0711-store-explicit-board-reader-selection.md)。原本没设置的板块在选择器中也显示“普通”，但重选不写入条目；否则仅打开设置就可能影响收藏路由。新启用漫画的板块默认不聚合同目录章节。

板块打开时在存储 mutation 内重新读取条目再刷新名称，以免还原其他入口已经删除的条目。板块页在同一视图模型中依序提交模式编辑和名称刷新，展示时避免迟到的首次读取覆盖本地乐观编辑。这种局部排序不保证跨页面对同一条目的字段级合并。

入口：[板块阅读设置](../../Sources/YamiboXUI/Features/Forum/Board/ForumBoardReaderSettingsSheet.swift)、[板块模型](../../Sources/YamiboXUI/Features/Forum/Board/ForumBoardViewModel.swift)。分类行为见[论坛路由](../architecture/networking-and-routing.md#页面路由和帖子分类分开)。
