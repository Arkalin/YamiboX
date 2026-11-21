# 流式传输施加正文上限，诊断不参与恢复判断

业务可通过小前缀给特定正文分类并限制保留量，但普通 HTML 与错误文档仍沿用既有响应契约。不采用会在 Foundation 内累积完整响应体的 async 或 completion-handler API 执行有上限的请求；改用 [delegate data task](../../Sources/YamiboXCore/Infrastructure/Networking/NetworkLoggedTransport.swift)，在保留超限块前中止，取消和准入加锁串行化，避免在取消后才启动请求。拒绝重定向时保留原响应给调用方检查继续地址，即使此时没有收到常规响应回调。适配器主动转发安装 per-task delegate 前已发生的创建事件，并在完成时解除对 task 的反向引用，以免形成保留环。

[错误策略](../../Sources/YamiboXCore/Infrastructure/Networking/YamiboNetworkErrorPolicy.swift)只翻译非取消的传输错误，业务判断仍看保留的错误类型，不从展示文案推断是否需认证、重试或返回缓存。已识别的服务器拒绝不当作 HTML 解析失败归档。[诊断快照](../../Sources/YamiboXCore/Infrastructure/Networking/LoadFailureDetails.swift)是暂时、已脱敏的视图，同一份文本可用于查看和复制，不随内容缓存；错误默认字符串不输出响应正文。遍历底层 NSError 链时用对象标识防环，不能假设来自第三方的是树。

[正文脱敏](../../Sources/YamiboXCore/Infrastructure/Networking/LoadFailureRedactor.swift)利用 DOM 识别字段，但替换原文区间，而不是重新序列化可能本就有问题的 HTML。还须覆盖出现在普通文本中的敏感值；不能遍历并直接展示任意 `NSError.userInfo`。

技术缓存与用户下载用不同的 [系统日志类别](../tests/README.md)；调查缓存读写时使用历史 `offline-cache` 类别，不能按它判断用户下载队列状态。
