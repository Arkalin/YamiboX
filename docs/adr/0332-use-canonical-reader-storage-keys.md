# 共用阅读缓存与下载的键规则

小说下载和两种阅读投影曾各自构造以下划线分隔的缓存键，其中一处没有转义组件，导致含分隔符的键不能被另一处解析。统一由 [ReaderCacheKeyCodec](../../Sources/YamiboXCore/Reader/Shared/Domain/ReaderCacheKeyCodec.swift) 负责。安全字符原样保留，让正常数字 ID 的存量缓存仍命中；含分隔符等不安全字符的值转为稳定哈希，不借用进程内 `hashValue`。解码后的组件是键值而非原始 ID，匹配时要编码候选 ID 再比较。

下载图像的去重使用 `URL.absoluteString` 而不是 Foundation 的 URL 相等性，与 SQLite `image_url` 和记账的字符串身份保持一致。保留首次出现的图像及原顺序，因为顺序就是展示页顺序。见[共享图像去重](../../Sources/YamiboXCore/Reader/Shared/Domain/URLDeduplication.swift)和[下载与缓存边界](../architecture/downloads-and-storage.md)。
