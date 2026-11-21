# 小说阅读器按展示投影发布，只在需要时观察

[已提交状态](../../Sources/YamiboXUI/Features/Reader/Novel/Root/NovelReaderPublishedState.swift)包含同一代的布局、位置和外观。让视图观察整个状态会使每次位置变动都刷新不变的视口或控件；分开赋值则会短暂暴露新位置和旧文档的组合。因此只给变化的投影发送嵌套通知，中间替换一次快照，让通知分别看到完整旧状态或完整新状态。[会话展示缓存](../../Sources/YamiboXUI/Features/Reader/Novel/Chrome/NovelReaderPresentationCache.swift)只保存 UI 派生值，不持有 TextKit 对象图或图片。

视口几何、TextKit 采样等[逐帧数据](../../Sources/YamiboXUI/Features/Reader/Novel/Viewports/NovelReaderViewportSupport.swift)由命令式的位置采样和还原读取，不进入 SwiftUI 的响应式状态。否则每次滚动都重算阅读器视图树。还原请求和加载遮罩需要观察，但[还原协调器](../../Sources/YamiboXUI/Features/Reader/Novel/Root/NovelReaderVerticalRestoreCoordinator.swift)仅在状态实际改变时替换；内部任务句柄也不观察，保持析构时可直接取消。帧、任务与最近一次采样属于该物理视口，不能跟阅读会话一起交接。

[分页内容](../../Sources/YamiboXUI/Features/Reader/Novel/Viewports/NovelReaderPagedContent.swift)为布局和选中页单独建立观察边界。[横向集合视口](../../Sources/YamiboXUI/Features/Reader/Novel/Viewports/NovelReaderPagedCollectionViewport.swift)和[竖向视口](../../Sources/YamiboXUI/Features/Reader/Novel/Viewports/NovelReaderVerticalViewport.swift)可能在 SwiftUI 提交期间布局；通过回调调度器推迟发布这些布局产生的选中页、帧和采样。图片喜欢状态与文字注解就地更新，避免重建宿主而丢选区或滚动位置。[接力组件](../../Sources/YamiboXUI/Features/Reader/Novel/Root/NovelReaderHandoffSource.swift)也独立观察文本偏移，不让每个细粒度位置变化回到整个阅读器的根视图。
