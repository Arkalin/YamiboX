# 由漫画 workflow 校验并提交章节窗口

[漫画阅读 workflow](../../Sources/YamiboXCore/Reader/Manga/Application/MangaReaderWorkflow.swift)由调用者隔离而非跨 actor 共享，保持同步翻页入口。异步导航和目录修改在 workflow 所有者内检查各自的代次，因为 UI 拒绝发布过期结果也无法阻止旧任务改写内部窗口。目录操作返回后应把结果应用到最新窗口及位置，避免抹掉等待期间已经提交的翻页或章节加载；外部目录变更同样保留已加载的图页。

[章节窗口](../../Sources/YamiboXCore/Reader/Manga/Domain/MangaChapterWindow.swift)一次性应用追加、排序和裁剪，再为最终窗口重建索引。目录面板的派生数据在目录、排序或章节发生变化时更新，不在每次翻页或倒计时重复构建。[漫画投影加载器](../../Sources/YamiboXCore/Reader/Manga/Data/MangaReaderProjectionLoader.swift)合并同身份的在途请求，让主动跳转能够等待已启动的预取，而不是重复下载并解析同一源页。

无动画、平移和快速淡入淡出仍使用同一个已挂载的分页视口，相互切换不发出新的位置请求，否则会取消尚未落位的翻页；与卷页之间切换才涉及分页实现的交换。详见[阅读器设计](../architecture/readers.md#稳定位置与双页显示)。
