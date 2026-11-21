# 让论坛导航容器投影同一条路径，并隔离阅读器内的浏览

宽窄布局使用同一条路径，避免尺寸类别切换时丢失当前目的地。宽布局将路径拆成列表与详情，两列的回调必须标明来自哪一列；绑定建立时读取可观察路径，并记录路径与布局修订。换容器先使旧绑定失效，避免 SwiftUI 拆除界面时把旧路径写回。详情再打开作者或表单时，仍以详情栈中最新的帖子为上下文。导航器只持有路径、显式依赖和有限的呈现动作；应用层组装留在目的地宿主。

活动阅读器上的原帖／评论覆盖层有自己的论坛栈，不替换下方阅读位置，也不再呈现第二个全屏阅读器。帖子链接先入栈再原地解析（包括 `findpost` 的网络页码定位），因此等待和失败出现在点击后的目标界面。全屏覆盖层的根提供显式关闭按钮。只有真正能打开帖子的行和能够呈现其他阅读器的栈才装配单次阅读模式菜单：没有处理器时，空的 SwiftUI 菜单仍会截获长按。公告仍进文档页。

覆盖层不是一律禁止历史：阅读器打开自身作品讨论，或栈内链接指回该作品（含已知漫画章节），均标记为讨论视图，避免普通帖访问按同 tid 改写作品的历史形式；收藏等独立访问保留普通历史。论坛路由到不使用智能模式的漫画时，先验证可打开，再用原始标题从帖首直接进入单帖阅读，不经过目录详情。显式内容目的地只跳过内容分类，不绕过实际加载与权限。

冷启动的论坛搜索快捷操作可能早于视图挂载，因此挂载时也尝试领取。接力请求用自己的 ID 刷新保留的帖子视图，即使启动参数相同，旧视图也可能已经读到另一个位置。结果列表的方向键和回车处理只在列表有焦点时生效，不拦截搜索输入框或阅读器的按键。

入口：[导航器](../../Sources/YamiboXUI/Features/Forum/Navigation/ForumDestinationNavigator.swift)、[目的地组装](../../Sources/YamiboXUI/Features/Forum/Navigation/ForumDestinationScreen.swift)、[覆盖层](../../Sources/YamiboXUI/Features/Forum/Navigation/ForumThreadOverlay.swift)、[论坛宿主](../../Sources/YamiboXUI/Features/Forum/Navigation/ForumNavigationHostView.swift)、[阅读模式菜单](../../Sources/YamiboXUI/Features/Forum/Shared/ForumThreadSummaryRowView.swift)。路由分类与网络策略见[论坛接入、认证与路由](../architecture/networking-and-routing.md)。
