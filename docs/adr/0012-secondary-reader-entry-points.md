# 二次打开入口分别处理作品身份和阅读方式

[书架](../../Sources/YamiboXUI/Features/Bookshelf/BookshelfView.swift)是已有浏览历史的投影，不另建阅读库。浏览历史推入书架自己的栈；从[我的](../../Sources/YamiboXUI/Features/Mine/MineHomeView.swift)进入时，历史和帖子的跳转也保留在同一路径。阅读器盖住书架期间停止观察，返回后刷新一次，避免每次保存位置都重建隐藏的书架。打开前显式保存滚动坐标，因为用户滚动后的 `ScrollPosition` 不会保留可恢复的具体偏移。iPad 独立书架保留顶栏共用的原生导航栏安全区，不重复显示标题；书架标题效果直接跟随滚动距离，反向滚动无需等待动画队列。

[`ReadingOpenTargetResolver`](../../Sources/YamiboXUI/Features/History/BrowsingHistoryOpenTargetResolver.swift)从同一历史快照决定打开哪种阅读器及是否启用智能漫画，避免打开过程中设置变化导致选择不一致。已知版块没有覆盖设置时使用普通阅读器，未知版块可保留记录身份对应的阅读器。普通帖阅读器自行恢复位置，所以历史入口传第一页且不指定定位点；小说查自己的进度类型。智能漫画开启时可按目录续读；关闭后，旧目录行改为以单帖方式打开当前章节，并优先使用该帖进度。目录进度被清除时，仍可从章节元数据取得源页 `view`，避免在多页帖子中打开错误的源页。

[`BrowsingHistoryView`](../../Sources/YamiboXUI/Features/History/BrowsingHistoryView.swift)按当前打开类别显示，但允许从旧行形状读取位置，避免设置变更后原有的页码无法显示。[视图模型](../../Sources/YamiboXUI/Features/History/BrowsingHistoryViewModel.swift)观察历史、收藏和设置，包括该页面自身写入的变更；存储重载与内存搜索分别去抖，重载时由同一 workflow 快照替换类别、身份和位置。

[`LikeMangaOpenTargetPolicy`](../../Sources/YamiboXUI/Features/Like/LikeMangaOpenTargetPolicy.swift)始终用漫画阅读器打开图片锚点。当前版块设置只决定是否附带目录；缺失版块 ID 的旧锚点保留捕获时的智能漫画假设。[喜欢条目](../../Sources/YamiboXUI/Features/Like/LikeWorkItemsView.swift)在阅读器面板中直接打开锚点，在「我的」中先打开详情。小说注解使用锚点派生的持久排序键而不是对帖子 ID 作字符串排序；漫画注解读取当前目录中的章节顺序，重复章节用首次出现的位置，不保存会过时的章序号。

[作品列表](../../Sources/YamiboXUI/Features/Like/LikeWorkListView.swift)和[条目列表](../../Sources/YamiboXUI/Features/Like/LikeWorkItemsView.swift)即使没有结果也保持可搜索的列表挂载，否则导航期间替换列表曾导致搜索栏短暂覆盖首行。视图的观察任务处理仍在订阅时的存储变更，重新出现时完整加载，补上离开期间错过的更新。

图片浏览器的[封面操作](../../Sources/YamiboXUI/Features/ImageBrowser/ImageBrowserCoverActions.swift)由宿主注入，浏览器本身不解析收藏库身份。宿主提供当前智能漫画状态；已存在的目录不代表关闭智能漫画后的版块还应提供目录封面操作。帖子封面不受此开关影响。
