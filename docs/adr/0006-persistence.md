# 共享存储的写入与失效边界

数据库连接由装配层持有，表的迁移与清理（含恢复必要的种子数据）由功能的 [Schema](../../Sources/YamiboXCore/Persistence/DatabaseSchemaModule.swift) 负责。让各 Store 自己决定 SQL、合并和通知条件，但共享[写入边界](../../Sources/YamiboXCore/Persistence/StoreWriteTransaction.swift)：失败的事务不发布失效信号。按偏好解析的[连接池入口](../../Sources/YamiboXCore/Persistence/YamiboDatabasePoolResolver.swift)只将真正的标准偏好实例绑定到默认文件；其他 suite 按 key 保存隔离目录的 UUID，并按根目录复用连接池以避免并发写入者争抢 WAL。未显式注入连接池的旧入口仍各开一个池，保留其独立连接行为；SQLite busy timeout 覆盖多连接池竞争。

[Store 通知](../../Sources/YamiboXCore/Persistence/StoreChangeBroadcaster.swift) 是每个实例的类型化失效信号，不是全局广播或变更日志。每位观察者同步注册自己的流，重读期间最多保留一个待处理信号，既能追上重读期间的写入，又不会积压重复刷新。广播先在锁内复制订阅列表，再在锁外投递，因为投递时流可能终止，终止回调也需要同一把锁。

[磁盘缓存](../../Sources/YamiboXCore/Persistence/DiskCacheStore.swift) 把可重建的 JSON 留在系统可以清理、不应备份的缓存目录；数据库只维护过期与淘汰所需的索引。淘汰只需要粗略的 LRU 顺序，因此短时间内重复命中不产生新的访问时间写事务。

[共享偏好解码](../../Sources/YamiboXCore/Persistence/UserDefaultsJSONStorage.swift) 将解码失败报告给各 Store 的日志并当作无可加载值，避免一个损坏的偏好值阻止加载；写入的编码失败则保留原始错误链并向调用者抛出。此策略不同于业务数据库读取，不意味着可以把数据库读取失败等同于空库。

[数据库打开](../../Sources/YamiboXCore/Persistence/YamiboDatabase.swift)只针对明确的 SQLite 损坏错误隔离主文件与 WAL/SHM 后建立新库，让应用恢复可打开状态，同时保留原文件供诊断。隔离并不是数据恢复，一般打开失败不应走清空数据库路径。

参见[持久化与身份设计](../architecture/persistence-and-identity.md)。
