# 下载队列的高频路径不物化全部图片列表

## 排队、完成与统计遵循同一持久身份

队列视图和 worker 共用跨类型的插入顺序，全局 `MAX` 可用插入序号索引并令新任务排到所有旧任务之后。读取队首时用惰性游标跳过不能识别的 reader kind，只加载第一个可用任务的图片列表；`LIMIT 1` 会让未知的队首行掩盖后续任务。读取的 GRDB 游标行要先复制，再发起子查询。

队列写入用 `ON CONFLICT … DO UPDATE`，不用 `INSERT OR REPLACE`：后者会删除冲突的父行并级联删除图片引用，迫使每次进度更新重建列表。已完成图片位置沿用原目标位置，允许空缺，从而可幂等地提交乱序完成的单图；处理旧稠密列表时按当前位置归一化。图片列表更新只改变化位置；新增后缀可直接写入，避免一个章节下载期间反复删除、重写相同数据。

清理下载和全局擦除共用同一组表的子表到父表顺序，新增下载表时只维护一处。命名迁移逆序遍历该清单，先迁移父表，让 SQLite 在原地维护外键引用。

迟到的单图结果只在原 `work_id` 和目标位置仍匹配时写入当前身份，不用早先的作品名重建条目。身份规范化与实际增删须在同一事务，避免重定向变化使操作命中旧键；外部身份事务提交后，包装器仍须向已有观察者转发同一失效通知。账号、作品身份和队列的提交边界另见[下载与存储](../architecture/downloads-and-storage.md#3-入队执行与完成)。

## 读侧不牺牲历史数据兼容

队列列表按 SQL 分组计数，而不是把每个工作项的 URL 列表带入 Swift。聚合仍用 Foundation 的 URL 可解析规则筛选，按位置计数（重复 URL 的不同位置也算），不把所有行直接视作有效 URL。作品显示保留原组身份，图片计数则使用规范作品身份；显示名读持久身份注册表，不依赖可重建目录或要求旧任务再次保存。

批量显示只读取标题和重定向，不装载注册表的历史别名；终止重定向环时沿用原单项读取行为。批量标题、重定向和字节数读取沿用旧标量读取对 SQLite 值的转换。SQLite BINARY 区分 NFC/NFD 文本键，而 Swift String 相等会折叠两者；批量 join 所用的原始工作键不 trim，也不经可能丢失原始字节的 TEXT 解码。使用 BLOB 读取原始字节，并保留 TEXT 绑定原先的存储类型限制。

空间聚合对唯一 URL 分批做索引 SUM，避免逐 URL 查询及超出 SQLite 参数限制；清理使用引用索引逐个探测候选，不枚举整个引用库。持久日期仍以 epoch 秒编码，保持现有恢复及同步兼容；下载层保留应用域错误，并把其他持久化错误包装时保留原始原因。

代码入口：[排序、游标、进度和列表聚合](../../Sources/YamiboXCore/Reader/Shared/Download/Data/DownloadQueueRecords.swift)、[队列历史 schema](../../Sources/YamiboXCore/Reader/Shared/Data/ReaderDatabaseSchema.swift)、[批量作品身份](../../Sources/YamiboXCore/Reader/Shared/Download/Data/DownloadDirectoryIdentity.swift)、[资产统计与引用探测](../../Sources/YamiboXCore/Reader/Shared/Download/Data/DownloadImages.swift)、[持久化转换](../../Sources/YamiboXCore/Reader/Shared/Download/Data/DownloadSQLSupport.swift)。
