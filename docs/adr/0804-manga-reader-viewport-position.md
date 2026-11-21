# 漫画视口保留语义阅读位置，不迁移原生几何

显示器、单双页布局和图片尺寸都可能变化，原生缩放偏移量只对创建它的视口有效。视口交接携带页 ID、归一化图片坐标和缩放倍率，不复用原生变换。分页计划重建前从仍挂载的视口捕获焦点；重建后只在目标跨页仍包含该图片时使用。分页布局缓存属于视口寿命而不发布到观察层，避免选页或工具栏变化再触发整个布局。

竖滚使用未缩放的章节几何索引；可见范围从二分定位得到。显式跳转在用户移动前拥有阅读位置，否则视口在文末钳位时可能把面积更大的另一页误报为当前页。图片长宽比或预取内容变化时，以保留的目标页锚定重新布局；窗口变化后，旧请求的下标不再适用，只有新定位请求可以覆盖当前页。收到显式定位时同步回调去重值，让读者滚回之前可见的页时仍能报告该页。

竖滚重设虚拟集合窗口时禁用隐式动画，以免单元格及其图片继承外层缩放动画。原生手势、弹性回弹或程序驱动的缩放变换期间推迟图片长宽比更新，避免变换动画与主视口几何同时变化。分页视口分别拥有图片预取会话；系统开启「减弱动态效果」时用快速淡入淡出替代立体卷页，保留直接操控的平移方式。

实现：[分页视口宿主](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/MangaReaderViewportHost.swift)、[竖滚视口](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/MangaVerticalCollectionViewport.swift)、[竖滚几何索引](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/MangaVerticalCollectionZoomLayout.swift)、[语义焦点](../../Sources/YamiboXUI/Features/Reader/Manga/Viewports/MangaViewportFocus.swift)。
