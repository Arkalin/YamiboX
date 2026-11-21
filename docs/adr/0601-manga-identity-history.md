# 分离漫画身份、目录内容与历史兼容

目录缓存可重建，身份注册表和引用不能随缓存删除；历史同名也不能证明是同一本作品。以章节和不透明身份作证据，歧义记录保持未决；没有目录缓存的身份仍可并入已有目录。各业务适配器在同一个写事务内改写自己的引用，不各开事务，避免部分重映射。见[身份注册表](../../Sources/YamiboXCore/Persistence/Identity/MangaDirectoryIdentityDatabase.swift)、[合并事务](../../Sources/YamiboXCore/Persistence/Identity/GRDBMangaDirectoryIdentityMigration.swift)和[引用协调器](../../Sources/YamiboXCore/Persistence/Identity/MangaIdentityRemapping.swift)。

导入时先合并本地目录缓存再发布其重定向，否则无法区分两个来源行。整个批次选出最终标题后才处理重名，因为本批次的另一个重命名可能让出名称；暂用名只写唯一约束列，不能注册为别名或推进标题时钟。合并前未同步的本地名称也要参与比较。独立的标题时钟不得替代内容时钟，否则先收到注解中的身份元数据可能使稍后收到的真实章节列表在时间比较时落败。

旧格式标题可能恰好有不透明 ID 的前缀，只有明确通过旧格式边界的键才按旧名称别名解释。改名造成的旧名保护不是对存活身份的删除；只有时间证据支持时才降为旧名保护（比较前统一日期基准）。早期格式共用标记时，注册表或确认标记是实际删除的证据；尚不能确定的删除保持可重试，不从墓碑制造身份。[运行时墓碑 remapper](../../Sources/YamiboXCore/Persistence/Identity/MangaIdentityDeletionRemapping.swift) 与 [旧 WebDAV JSON 兼容](../../Sources/YamiboXCore/Sync/WebDAV/MangaIdentityLegacyJSONV1.swift)只改写结构化引用，不改标题、正文、URL 或章节 ID。兼容转换先应用胜出的标题再合并内容，使导出的回执和存储一致；启动上下文或已解析收藏有明确目录字段，但只有猜测名称不能据此取得身份。

历史升级需要在以后仍重现相同的结果，因此[已发布的本地迁移](../../Sources/YamiboXCore/Persistence/Identity/MangaIdentitySchemaMigration.swift) 有自己的[冻结规则](../../Sources/YamiboXCore/Persistence/Identity/MangaIdentityMigrationV1%2BRules.swift)和页面解码器，不依赖运行时模型。迁移先为孤立业务引用赋予身份，再改写数据；更换表时先拷贝父子数据以免级联删除。GRDB 迁移期间级联可能关闭，因此在历史离线下载冲突处理中显式处理子项，只有冲突需要读取旧载荷，不改名或写入实际下载文件。

[WebDAV 装饰器](../../Sources/YamiboXCore/Sync/WebDAV/MangaIdentityWebDAVParticipant.swift)让每份载荷自带身份信息，即使对端没有启用目录同步也能解析注解。新载荷由业务提供类型化规范化规则；只有[旧格式导入](../../Sources/YamiboXCore/Sync/WebDAV/MangaIdentityWebDAVMigration.swift)了解旧 JSON 的形状。导入先整批验证，成功条件写入新位置才记为完成，且不会因旧位置或其他账号的回执压住第一次新格式导出，也不会把挂起前读到的内容和切换后的连接拼在一起。

参见[持久化和身份迁移](../architecture/persistence-and-identity.md#历史迁移与旧格式兼容)与 [WebDAV 旧格式导入](../architecture/webdav-sync.md#7-漫画身份与旧格式迁移)。
