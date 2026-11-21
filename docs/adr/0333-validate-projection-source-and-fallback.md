# 阅读投影只消费匹配且仍属当前会话的来源

Discuz 可能把越界页折回最后一页，也可能以 HTTP 成功状态返回删帖、访问限制或登录页面。使用不同页号的正文会覆盖正常缓存或下载，而只看 HTTP 状态则会遗漏离线回退。先验证帖子与页号，再写入源缓存或更新下载；来源和正文可读性错误可以回退到匹配的用户下载，收藏操作失败、本地持久化错误与取消不回退。服务器拒绝登录与客户端会话已切换也不同：前者可用本地下载，后者在回退前后都必须拦下旧请求。

小说路径可以并行持久化帖子页和派生投影，但成功返回仍等待已启动的帖子页写入，并不承诺技术缓存写入成功。共享加载的取消清理同时核对键与操作 ID，否则旧任务的迟到退出会清理后来开始的同键任务的等待者。

依据：[帖子页加载策略](../../Sources/YamiboXCore/Reader/Shared/Projection/ReaderThreadPageProjectionLoadingStrategy.swift)、[投影加载器](../../Sources/YamiboXCore/Reader/Shared/Projection/ReaderProjectionLoader.swift)。
