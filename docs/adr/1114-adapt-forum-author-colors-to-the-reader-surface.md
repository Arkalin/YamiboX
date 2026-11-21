# 论坛文字按阅读表面调整作者配色

帖子里的固定 sRGB 色是在作者的页面上选的，原样套到 App 的浅色或深色表面上可使正文不可读。作者只指定不透明前景时，以正文 4.5:1 为目标，只在有需要的主题一侧调整 HSL 明度；通常保留色相、饱和度，以及原本可读的一侧。二分搜索找离原始明度最近的合格值。接近黑白且低饱和度的颜色用该主题的正文色代替，避免把常规正文样式转换成洗灰的文字；前景透明度属于作者表达，不拿它换对比度。

带作者背景的片段改为针对其实际背景选正文和链接色，而不是照搬针对 App 页面设计的颜色。不透明背景只选一次；半透明背景分别在浅、深表面上合成再选色。明确指定前景和背景的配色仍保留，不能把自动适配当作所有作者配色都能达到 AA 的保证。

实现：[配色适配](../../Sources/YamiboXUI/Features/Forum/ThreadReader/ForumThreadAuthorColorAdapter.swift)、[富文本链接与背景](../../Sources/YamiboXUI/Features/Forum/ThreadReader/ForumThreadTextBlockFormatter.swift)。
