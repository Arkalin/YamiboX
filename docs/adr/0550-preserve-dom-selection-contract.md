# 通过 Kanna 适配层保持 DOM 选择语义

论坛与阅读器通过 [KannaSoup](../../Sources/YamiboXCore/Infrastructure/HTML/KannaSoup.swift) 使用 DOM。文档无法建立时才抛出解析错误；Kanna 的选择与属性读取本来不抛错，适配层也不让业务为缺失节点增加一层无效的错误处理。[HTMLElementScanner](../../Sources/YamiboXCore/Infrastructure/HTML/HTMLElementScanner.swift) 只统一高频的文本、属性和 URL 读取约定，以免不同页面解析器各自修剪、解码和解析相对链接；节点移除、兄弟遍历和片段解析仍直接使用 DOM 适配层。与 HTML 无关的[字符串判空规则](../../Sources/YamiboXCore/Infrastructure/StringPresence.swift)在包内共享：已规范化的输入可以保留纯空白，未规范化的输入按需修剪；不把这些规则作为对外 API。

多个选择器都能转换时，使用 libxml 的 XPath union 按文档顺序返回去重后的结果，避免逐一比较不同包装器。文档根节点按文档范围查询，其他元素按其子树查询；不能使用 union 时保留兼容选择路径，例如把同一元素上的多个属性条件交给 Swift 过滤。Kanna 的列表分隔和 XPath 字面量转换对带引号的属性值有限制，因此这类条件也不进入 union 路径；适配层不是通用 CSS 引擎。

Kanna 的公开节点接口不提供底层指针，包装器本身也不唯一；序列化子树再比较既昂贵，又会误把内容相同的相邻元素当成同一节点。适配层改用元素兄弟序号构成的位置路径，仅用于同一文档、结构未变化时的比较。节点不跨并发任务共享；缓存属于当前包装器，不是可跨文档或跨 DOM 变更复用的节点 ID。
