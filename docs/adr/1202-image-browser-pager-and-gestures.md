# 保持图片分页结构稳定并明确手势归属

[图片浏览器](../../Sources/YamiboXUI/Features/ImageBrowser/ImageBrowserView.swift)即使尚无位图，也保持图片和状态浮层子树挂载；如果切换图片触发加载或取消时同时替换子树，分页动画可能中途停止。分页式 `TabView` 可能提前构造所有页面，因此只加载选中页附近的内容，已加载图的保留窗口略大，避免来回翻页时重复解码。只有可见页播放动画。离开加载窗口触发的取消不进入错误重试路径；透明浮层不拦截图片手势。工具栏用数字而非圆点显示位置，以免大型图集的指示器溢出。图片操作使用静止长按，不和轻触、翻页或缩放争抢；分享只在用户选择发送时生成导出文件，不在打开浏览器时预先生成。

[`ImageBrowserZoomableScrollView`](../../Sources/YamiboXUI/Features/ImageBrowser/ImageBrowserZoomableScrollView.swift)用原生 `UIScrollView` 提供锚定捏合、回弹、惯性和以触点为中心的双击缩放，不用 SwiftUI 手势模拟。倍率以图片恰好适应容器为基准；原生平移和页面关闭共享倍率阈值。最小倍率下显式拒绝原生平移，避免浮点误差让内容尺寸略大于容器，从而错误拦截翻页和关闭。动图播放只替换位图，避免重置缩放和内容边距。

[关闭手势](../../Sources/YamiboXUI/Features/ImageBrowser/ImageBrowserDismissPanGesture.swift)在识别前拒绝横向和向上的移动；等识别后再忽略它们，已经会阻塞外层分页。[自定义关闭判断](../../Sources/YamiboXUI/Features/ImageBrowser/ImageBrowserSwipeDismissGesture.swift)按带方向的松手速度预测终点，短而明确的甩动可关闭，向上反转则可取消。退出动画沿用松手速度；没有可测量的图片时仍以容器高度兜底。启用「减少动态效果」时用交叉淡出。

[`ImageBrowserPresentationStyle`](../../Sources/YamiboXUI/Features/ImageBrowser/ImageBrowserPresentationStyle.swift)在宿主可提供匹配的缩略图 ID 时使用系统缩放，否则用淡入淡出，例如小说排版内的图片。翻页后向当前图的缩略图过渡；缩略图不在视口时可降级为普通转场。系统缩放负责整个交互式关闭；再单独移动图片会让系统从错位的几何位置开始。因此重置页面几何属于翻页，不在开始关闭时执行。
