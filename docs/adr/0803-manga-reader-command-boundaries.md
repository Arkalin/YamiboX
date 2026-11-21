# 漫画阅读器的目录、会话与导航分别决定何时提交结果

[目录命令层](../../Sources/YamiboXUI/Features/Reader/Manga/Root/MangaReaderDirectoryLane.swift)串行管理目录命令与计时。其代次决定哪个任务可以发布 UI，取消任务时也必须使旧代次失效，因为旧请求还可能继续执行错误或清理分支。Core 的 workflow 独立检查哪个结果可以提交章节窗口，不能用 UI 代次替代。目录内容修改走 ViewModel 的完整发布路径；更新中、冷却倒计时和错误提示只写面板状态，以免重复触发浏览历史与进度副作用。

[会话协调器](../../Sources/YamiboXUI/Features/Reader/Manga/Root/MangaReaderLifecycleCoordinator.swift)在重试替换 workflow 前等待已取消的准备任务退出。仅内容版本变动时废弃相邻预取，不在这里废弃章节加载：目录提交后，合法的导航仍可能基于新目录定位同一目标，由 Core 判定。

[导航协调器](../../Sources/YamiboXUI/Features/Reader/Manga/Root/MangaReaderNavigationCoordinator.swift)持有导航历史，ViewModel 执行实际内容恢复，避免把预取取消、内容代次和展示发布在两处实现。恢复成功时提交历史并从返回的页索引继续预取；目标加载失败仅丢弃该候选并尝试下一个，整个请求中止则保留剩余候选。浏览历史独立于此导航历史，[浏览历史记录器](../../Sources/YamiboXUI/Features/Reader/Manga/Root/MangaReaderBrowsingHistoryRecorder.swift)按章节记录造访，页位置由进度适配器保存，目录元数据由历史 workflow 观察更新。

[目录面板](../../Sources/YamiboXUI/Features/Reader/Manga/Directory/MangaDirectorySheet.swift)允许滑动直接移除非当前章节。批量移除一次影响多项，需要确认；包含正在阅读的章节时，无论单章或批量命令都先阻止删除。
