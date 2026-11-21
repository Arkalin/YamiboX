# 让论坛编辑器维护源码语义，适配系统输入与服务端表单

可视编辑端不把 UIKit 的选择和输入通知顺序当成源码顺序：如果选区通知到达时可视文字尚未与投影一致，就不将选区写回。纯格式命令可在文字不变时改变属性，渲染不能只更新字符串。按 ID 索引节点时保留与文档查询相同的深度优先首个匹配。空选区改变的是后续输入样式；新文字可继承外层样式，但不可继承图片本身的 BBCode。TextKit 输入可能丢弃自定义来源属性，因此只在输入法组合结束后补回这些属性。中日韩回退字体的斜体通过在直立字体上统一加倾斜实现，避免拉丁字体被倾斜两次。

SwiftUI 更新时让输入代理立即拒绝被禁用的输入，但把 UIKit 的可编辑性变更延后到主队列；同步设置可能 resign first responder 并重入视图更新。附件视图提供器仅用于主 actor 上的编辑器，UIKit 对应同步回调没有 actor 标注，桥接在运行时断言边界。嵌套块允许继续使用编辑器；属性面板用类型擦除截断递归的 SwiftUI 泛型。键盘挤压评论编辑空间时让表头滚动，而不是缩小无障碍字体。

高保真粘贴先尝试剪贴板声明的表示；部分图片来源只有 `UIImage`，广告中的原始表示不可读，此时仍允许本地转码。上传保留服务端接受的原始 JPEG、PNG、GIF，避免丢失原编码、透明或动画。需要转换 HEIF 时，方向变换已经写入像素，不再复制 EXIF 方向或 GPS。日志表单由服务端决定有哪些字段及选项，客户端决定布局与隐私字段的条件呈现；只有可编辑的业务表单装配上传、编辑和提交状态，纯文档页不承担这些职责。

加载任务挂在稳定的页面外层，避免加载和错误视图互换时重新触发。确认只对本次请求有效，刷新不能继承；提交快照只能消费一次，即使弹窗先清理也不丢失已确认操作。可编辑表单嵌在没有导航能力的宿主时，意外返回的重定向显示为可重试失败，而不是无期限加载。登录后重新获取服务端令牌并保留本地编辑；提交响应不明确时也不清空草稿。后续验证与安全边界见[论坛编辑器与本地草稿](../architecture/forum-editor.md)。

入口：[UIKit 编辑会话](../../Sources/YamiboXUI/Features/Forum/Composer/ForumBBCodeSession.swift)、[编辑器协调](../../Sources/YamiboXUI/Features/Forum/Composer/ForumComposerEditor.swift)、[附件提供器](../../Sources/YamiboXUI/Features/Forum/Composer/ForumBBCodeTextCodec.swift)、[图片导入](../../Sources/YamiboXUI/Features/Forum/Attachments/ForumUploadImage.swift)、[表单会话](../../Sources/YamiboXUI/Features/Forum/Pages/ForumPageSession.swift)。
