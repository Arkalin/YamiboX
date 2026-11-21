# 浏览历史是访问记录的本地投影，不是续读存储

[浏览历史](../../Sources/YamiboXCore/History/Domain/BrowsingHistoryEntry.swift)存放离线列表的显示信息并独立限制条数；删除历史绝不能删掉独立的 `reading_progress`。实际访问来源不一定等于当时启用的阅读器，也不一定等于当前续读的章节。同步保留独立于设备阅读方式的来源访问，列表按板块的当前设置、确认过的漫画目录及本地进度投影。目录级行的当前章节可用于新收藏锚点或关闭智能漫画后的导航，不决定既有收藏是否包含该作品。

投影归一化由[应用级 History Workflow](../../Sources/YamiboXCore/History/Application/BrowsingHistoryWorkflow.swift)协调而不是由可见窗口持有。普通进度保存从已有访问取来源信息，从单个规范目标的进度取位置，只能更新而不能插入；删除与异步刷新竞争时不能复活记录。配置或作品身份变化仍须完整归一化。单帖模式切换吸收同帖旧行；漫画目录吸收成员的旧单帖行；目录行自身不含帖子 ID，目录身份改变时靠旧行 ID 移除。

批量补全板块归属时，[应用装配](../../Sources/YamiboXCore/App/YamiboAppContext.swift)一次扫描收藏，跨阅读方式保留同帖首个已知板块；只对缺失者再读论坛页面缓存，不逐帖重复扫描收藏。

[Store](../../Sources/YamiboXCore/History/Data/BrowsingHistoryStore.swift) 在写事务内重新检查快照及删除记录：冲突是不写入的 `false`，存储错误抛出，不作为可重试冲突处理。即使访问提交后才发生设置或目录变化，返回前仍须归一化，但不重放访问时间；只有完成的全量归一化才能作为跳过无关设置通知的凭据。同步合并在写锁内重解析双方和 tombstone，不能沿用锁外的目录解析。未解析的旧 tombstone 保留原导入语义；不以显示名强绑有歧义的旧记录。

同步记录还要比较展示名，否则只改名的合并会被「快照未变」短路，留下与上传端不一致的本地指纹。旧迁移用相同表名存过完整条目，[迁移](../../Sources/YamiboXCore/History/Data/BrowsingHistoryDatabaseSchema.swift)必须先解码再替换，转换失败整体回滚；已发布的 `history.v3.webdav` 使用冻结的 [V1 规则](../../Sources/YamiboXCore/History/Domain/BrowsingHistorySyncMergeV1.swift)，运行时算法变更不能追溯修改迁移。
