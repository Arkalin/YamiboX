# 漫画分页：交互、落位和渲染各有唯一所有者

滑动分页与卷页都把图片缩放交给原生图片宿主，把翻页取舍交给各自的协调器。原生滚动、布局和动画回调可能同步重入或迟到，所以外层偏移量、渲染完成事件和手势结束事件本身都不能成为阅读进度提交。

## 手势与落位

- 离散翻页手势在开始时捕获视口、选页和图片宿主身份，在结束时校验同一上下文。手指释放方向、距离和速度可以用于已准入手势的目标判断，但不能补办准入。轻触语义上的上一页或下一页不改变同一物理边缘的露图方向；设备输入在没有挂载视口时不退回到直接改页码。参见 [输入会话](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/Interaction/Model/MangaNavigationSession.swift)、[轻触策略](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/Interaction/Model/MangaNavigationPolicy.swift)与[设备输入桥接](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/MangaPagedReaderSurfaceInteraction.swift)。
- [滑动协调器](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/MangaPagedScrollCoordinator.swift)在触发 UIKit 布局或偏移更新前安装转场所有权，以免同步回调抢占。离散手势到释放并解析目标才拥有翻页权；已准入的拖动不会因页面大小或效果变化而重新准入，也不会在手势中途改变 UIKit 的 `isEnabled`，后者会取消手势。未落位的显式定位在布局重算后仍有效，普通相邻翻页则回到原锚点。布局触发的 SwiftUI 回调要[延后发布](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/MangaPagedReaderViewport.swift)，因为 UIKit 布局可能正在 SwiftUI 的渲染事务内。
- [卷页的手势代理](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/MangaPagedPageCurlNavigationAdapter.swift)拦截卷页原有的平移准入，排除卷页手势与原生图片缩放宿主的同时识别，其余判断交回原 UIKit 代理；集合视口用自己的委托。卷页叶片索引按物理左右排列，阅读方向已由[卷页序列](../../Sources/YamiboXUI/Features/Reader/Manga/Support/MangaPagedReadingPlan.swift)处理；检查是否还有相邻叶片时不再做一次左右换算。每个选页单位都有两个物理叶片，包括空书和末尾无图的一侧；单页右装订时，背面在物理顺序上先于正面。[卷页协调器](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/MangaPagedPageCurlCoordinator.swift)在已有翻页进行时拒绝新的相邻翻页；显式替换选页则作废旧转场，防止旧完成回调提交已被替换的页。外部定位不走用户翻页回调，因此清除进度去重记录，让用户回到上次报告页时能再次报告进度。
- [转场执行器](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/MangaPagedTransitionDriver.swift)不决定进度：快速淡入淡出以新页落位交接输入，淡出结束只清除旧截图。此时再次快速翻页就在同一淡出截图下切换，不堆叠过渡截图。

## 图片布局与原生宿主

- 双页是一个可缩放的宿主，内页在静止时完整适配各自槽位，不能独立平移。[几何计算](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/Interaction/Model/MangaSurfaceGeometry.swift)把单槽宽作为上限，也约束高度。UIKit 决定双页容器的实际尺寸，SwiftUI 只填满它，否则固定框可能在剩余安全区内重新居中。可选的顶部留白只由[最外层分页布局](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/MangaPagedLayoutPolicy.swift)预留一次，并且不随状态栏显示/隐藏重新测算；竖向滚动一直延伸到顶部区域。
- [双页 SwiftUI 宿主](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/Interaction/Rendering/MangaPagedReaderZoomableSpreadSurface.swift)应分别读取左右槽的加载状态，再合成可用性，避免短路求值漏掉一侧的观察依赖。双页卷页复用宿主时，旧页的可用性仍可能短暂存在；新页重配后才应用继承的缩放。目标图片还没布局时，[原生宿主](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/Interaction/Rendering/MangaNativeSurfaceView.swift)保持未缩放占位，确保可见的重试入口不被裁出，同时保留待应用的倍率。
- 原生宿主在 `layoutSubviews` 中处理纯视口尺寸变化，因为它持有变更前的边界快照，而 representable 更新可能更早或更晚执行。[运行时](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/Interaction/Runtime/MangaSurfaceRuntime.swift)提供快照给分页逻辑查询，SwiftUI 不逐帧重绘原生运动；仅开关工具栏时也不替换 `UIHostingConfiguration`，以免拆下仍拥有手势的原生宿主。
- [卷页背面](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/MangaPagedPageCurlSupport.swift)使用图片与几何的值快照，不能在正面 runtime 上挂载第二个原生宿主。单页缩放在卷页视图的加速动画子树内，使用相反的时间缩放抵消继承的加速；双页缩放宿主在卷页控制器外层，不需要抵消。
