# 集中处理 Discuz 页面模板兼容规则

[表单令牌提取](../../Sources/YamiboXCore/Infrastructure/HTML/DiscuzFormHashParser.swift)由一个入口维护，避免各写操作分别使用字符范围与回退层级不同的模式。优先使用有明确语义的表单字段和退出链接，再兼容只保留原始 HTML 的路径与移动模板中嵌入的数据；内联数据只作为字面值读取，不执行脚本。

Discuz 的部分 AJAX 响应把 HTML 片段放在 CDATA 中。[HTMLTextExtractor](../../Sources/YamiboXCore/Infrastructure/HTML/HTMLTextExtractor.swift)提供回退提取；调用者先解封装再解析 DOM，避免首个标签被破坏且尾部分隔符进入可见文本。该入口只提取片段，不负责校验完整 XML。重复使用的正则表达式按模式与选项缓存；部分模式含动态帖子 ID，故用可自行淘汰的 `NSCache` 限制长期积累，而不是用只增不减的字典。

[图片提取](../../Sources/YamiboXCore/Infrastructure/HTML/YamiboImageReferenceExtractor.swift)按模板选择资源属性而不是统一取 `src`：漫画移动页的 `zsrc` 可能才是延迟加载的原图，论坛内容中的 `none.gif` 是占位图，发帖图片列表的 `static/image/` 是页面装饰，小说的 `smiley/` 是表情。已选引用若属于被排除项，丢弃当前元素而非继续取较低优先级的属性。漫画页的表情过滤仍由[选择器](../../Sources/YamiboXCore/Reader/Manga/Data/MangaHTMLParser.swift)按其模板结构处理。
