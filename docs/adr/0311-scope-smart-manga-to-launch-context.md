# 以启动上下文决定智能漫画范围

漫画入口确定智能漫画模式和版块，阅读会话使用启动快照，不在打开后另查版块设置。目录搜索与标签结果都应限于启动版块，因为 Discuz 的标签列表本身会混合多个版块。翻过一个筛选后为空、原始结果仍有效的标签页不会结束分页，否则后续页的同版块章节会漏掉。见 [启动契约](../../Sources/YamiboXCore/Reader/Manga/Application/MangaReaderContracts.swift)、[阅读器装配](../../Sources/YamiboXUI/Features/Reader/Manga/Root/MangaReaderViewModel.swift)和[目录仓储](../../Sources/YamiboXCore/Reader/Manga/Data/YamiboMangaDirectoryRepository.swift)。

兼容性有两个不同边界：旧续读路线未记录模式时解码为模式开启，保持升级前的阅读行为；缺失版块仍解码为 `nil`，阅读器在构造目录查询时使用兼容版块 `30`。后者不是启动身份，不应回填到历史记录；历史重新打开时按记录的版块重新评估模式，没有版块则按模式关闭处理。

模式关闭时，不执行智能目录发现或自动更新。使用一份不保存为目录内容的单章目录，让[章节窗口](../../Sources/YamiboXCore/Reader/Manga/Domain/MangaChapterWindow.swift)仍保持非可选目录契约，同时自然失去相邻章节；不要为了关闭聚合而先发出目录请求再丢弃结果。[阅读会话](../../Sources/YamiboXCore/Reader/Manga/Application/MangaReaderWorkflow.swift)仍可解析和登记离线身份；单帖封面复用[普通帖封面解析](../../Sources/YamiboXUI/Features/Reader/Manga/Root/MangaReaderCoverModule.swift)。智能目录离线重建也限于当前会话，不能覆盖手动整理或同步得到的持久化目录。

[打开校验](../../Sources/YamiboXCore/Reader/Manga/Application/MangaReaderOpenValidator.swift)、详情与阅读器复用[离线归属解析](../../Sources/YamiboXCore/Reader/Manga/Application/MangaReaderDirectoryResolver.swift)和阅读投影，保证打开检查不会把实际能离线读取的章节误判为不可读。单帖恢复必须读取[精确的单帖进度](../../Sources/YamiboXCore/Reader/Manga/Application/MangaReadingResumeResolver.swift)，不能把同一章节所属目录的较新进度视为单帖记录。预览不写普通阅读进度、续读路线或收藏最近记录。

详见[阅读器设计](../architecture/readers.md#漫画目录章节窗口与显示页)。
