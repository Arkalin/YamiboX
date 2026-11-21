# 小说注解菜单与徽标分离呈现

[注解协调器](../../Sources/YamiboXUI/Features/Reader/Novel/Root/NovelReaderAnnotationCoordinator.swift)先订阅书签和喜欢变动再首次读取，避免在首次读取和订阅接入之间漏掉编辑。订阅与阅读器出现任务同寿命；持久化仍由 Core 服务负责。

[正文视口适配器](../../Sources/YamiboXUI/Features/Reader/Novel/Support/NovelTextDisplayAdapter.swift)单独建立文本选区、无选区的注解，以及[样式选取](0910-novel-highlight-style-menu.md)三种菜单交互。没有选区时选区菜单不会建立，不能只用配置标识符区分。保存待操作的注解是为了跨过 UIKit 发起呈现到询问菜单内容之间的空档。命中注解时，宿主视图主动取得第一响应者身份；其他点击交还视口层的翻页和显隐工具栏手势。系统菜单浮在视口外，不随回收自动移除，离开窗口时必须主动关闭。视图与选择控制器相互登记而不应强持有成环。

备注徽标是在字形后绘制的主题纸色孔和单独的描边子视图。正文表面透明，用清除混合能露出当前主题的真实背景而不用同步纸色；描边可能跨出排版表面边界，若一起画进正文的绘制缓冲区会被裁切。徽标仅表示有备注，不额外拦截点击或重复朗读；整条注解保持同一触点。[跨表面的注解](0911-novel-text-annotation-anchors.md)只在有全局起点的表面画徽标，选区手柄也只在端点实际所在的表面绘制。离开表面或不再有备注时回收徽标，避免保留过去显示过的每个条目。

[图片交互](../../Sources/YamiboXUI/Features/Reader/Novel/Support/NovelReaderImageInteraction.swift)共用命中与事件交接规则，但手势和回调调度器归各物理视口。双击识别器复用 UIKit 的时间和位移判断；未命中已加载图片就立即失败，使普通单击不必等待第二次点击。
