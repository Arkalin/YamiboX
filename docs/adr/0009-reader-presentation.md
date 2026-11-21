# 小说阅读器只发布当前会话的已提交展示

小说正文准备、TextKit 排版和视口放置不在同一次更新中完成。不能用「加载完成」表示「用户已看到正确位置」，也不能让旋转、窗口切换或跳章前的结果覆盖当前内容。Core [按布局代次提交](0301-publish-novel-layout-as-a-transaction.md)，UI 另有以下发布边界；阶段与职责分工见[阅读器设计](../architecture/readers.md#初次展示与运行时变化)。

- [初次准备](../../Sources/YamiboXUI/Features/Reader/Novel/Root/NovelReaderPreparationCoordinator.swift)可先读取数据，但等入场过渡结束、几何有效后才开始同步 TextKit 索引，以免卡在半透明的呈现帧。窗口几何可能先于出现任务；已经收到的布局优先。释放准备任务的准入权放在该次工作退出时，而不是等异步调用方被唤醒，便于下一次几何回调开始新的准备。撤下绘制报告器只解除显示等待；真正更换视口时另行作废旧工作。强制重载等待旧准备任务退出后再替换工作流。
- [加载](../../Sources/YamiboXUI/Features/Reader/Novel/Root/NovelReaderLoadingCoordinator.swift)在提交首个展示前消化已到达的布局变更，而已发生的浏览历史不属于可取消的预取：即使读者关闭，记录仍独立落盘，而且不持有视口。
- [导航遮罩](../../Sources/YamiboXUI/Features/Reader/Novel/Root/NovelReaderNavigationOverlayDisplayProbe.swift)以第二个显示时钟回调确认遮罩至少获得一帧绘制机会，而不是设定毫秒延时。入场等待同时判断 UIKit 控制器转场和 SwiftUI 切换模式时的祖先图层淡入。
- [布局与外观更新](../../Sources/YamiboXUI/Features/Reader/Novel/Root/NovelReaderRuntimeUpdateCoordinator.swift)用请求、工作流与布局所有权区分并发提交。相同几何也可能属于更新的外观请求，旧窗口请求不能回滚它。若同一布局请求仍有效，但跳章换了文档，可按新文档代次重试；不因空结果本身重试。交接窗口直接给 TextKit 目标几何和目标外观，不先在旧窗口重新索引；视图重用同一组排版输入，外观提交期间不额外触发分页，完成后再读取视口几何。论坛自带文本颜色、底色和引用样式相对于纸色计算对比度；进入或离开 quiet 也会改变字形颜色，这些换主题不能走仅更新表面的快捷路径。
- [非线性导航](../../Sources/YamiboXUI/Features/Reader/Novel/Root/NovelReaderNavigationCoordinator.swift)共用成功后的还原与刷新步骤。上一个位置的还原不能再制造一条新跳转历史；书签和喜欢等用户主动定位可以，连续线性阅读则让这些回退位置过期。没有工作流时，跨论坛页的章节锚点导航可回退到打开源页。只有显式越过当前文档时才消耗下一文档预取；停在最后一页仍应先读完本页。
- [视图接入](../../Sources/YamiboXUI/Features/Reader/Novel/Root/NovelReaderView.swift)在首份投影与语义阅读位置可用后刷新书签及章节序号，避免把已有书签画成添加操作或展示无法解析的章节标题。失败且未准备好的会话不保存默认第一页；同文档注解捕获前如需要从竖向视口取位置，先同步可能落后于交互的采样。
- [下载状态](../../Sources/YamiboXUI/Features/Reader/Novel/Download/NovelReaderDownloadCoordinator.swift)的刷新任务可以被多次导航共享。某次导航取消，只取消它的等待，不能让后来加入的请求失去同一次数据库读取的结果。
