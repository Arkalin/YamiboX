# 图片管线分开管理原图字节、解码变体和动画

[Core 图片管线](../architecture/downloads-and-storage.md)拥有原图字节的会话、离线与磁盘缓存策略；[UI 管线](../../Sources/YamiboXUI/Platform/Images/YamiboUIImagePipeline.swift)解码并缓存带尺寸／用途的图片变体。预览共享原图字节而不共用解码键，封面还要以恢复代次区分：旧封面或阅读器的内存命中不能跳过新封面的字节写入。一个变体加载成功能让同源失败视图重试字节，但不同变体不能直接采用它的解码结果。

预取只解码能进入内存缓存的图片，估算包含对齐后的 RGBA 行宽与多帧原始字节。过大图片仍预热字节并通知失败视图，但在实际显示时才付出大图解码成本。

[动图播放](../../Sources/YamiboXUI/Platform/Images/YamiboAnimatedImage.swift)通过容器帧时序元数据判断是否有动画，不为分类而解码帧，也避免把 ICO 多分辨率图等无时序容器当作动图。默认解码器对 GIF 保留字节的策略不足以覆盖动 WebP／APNG；只有可播放的完整载荷才随解码结果保留字节，缩略图只保留海报。播放将时钟、帧解码及循环交给 ImageIO，只缓冲最新帧，避免一次保留全帧或积压补播；取消在 ImageIO 的下一次回调生效。保留海报比例并在前后台和自动播放设置切换时保持静态回退。

[封面组件](../../Sources/YamiboXUI/SharedUI/Components/BookCoverThumbnail.swift)以调用方给出的容器尺寸摆放图片和文字回退。在列表按钮标签里，最大宽高为无穷的 frame 可能参加理想尺寸测量而撑开封面；因此让 `GeometryReader` 读取实际提议尺寸。文字回退沿用 Android 的标题长度分档，并设字号下限，避免小封面不可读。
