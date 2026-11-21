# 在应用装配处统一初始化和数据归属

[AppContext](../../Sources/YamiboXCore/App/YamiboAppContext.swift)统一装配基础设施和功能依赖包，只有启动、宿主与续读流程持有完整上下文；论坛页面只接收论坛包，导航宿主才为目的地另外接收对应依赖。数据库先打开和迁移才装配 Store，失败可从启动页重试，避免半升级的运行时；GRDB Store 共享已经准备好的连接池。

- **保护用户资料的边界不等于目录边界。** 离线下载是用户主动保存的内容：不能用可随时被系统淘汰的 Caches，但也不应计入系统备份。只对 Application Support 内的下载目录打排除标记，数据库、喜欢图片和收藏背景不继承该规则。准备失败记录错误，首次写入仍会尝试创建；旧封面迁移未完等下次启动，普通缓存淘汰不动封面。退役的下载执行器要继续留在注册表，直至其写入任务退出，身份迁移才能等到所有旧账号写入结束。参见[下载与存储](../architecture/downloads-and-storage.md)。
- **清理是通过所属 Store 执行的有序操作。** [重置流程](../../Sources/YamiboXCore/App/AppDataResetWorkflow.swift)按注册顺序清理，在首个错误处停下并传播原始错误。[直接存取的 UI 偏好键](../../Sources/YamiboXCore/App/YamiboAppStorageKey.swift)集中管理，新增键须显式决定是否加入清理清单；常用登录名有意保留。高亮默认样式是跨作品共用的本机操作习惯，不随作品或 WebDAV 同步。
- **Local 论坛绑定不构成地址回退。** [测试站准备](../../Sources/YamiboXCore/App/YamiboTestSiteBootstrap.swift)只认本次启动地址；重置在 WebView、会话观察和运行时启动前执行，并确认 Nuke 缓存的排队删除已落盘，避免另一管线读回旧缓存。
- **显示顺序与发布身份由更新源决定。** [更新记录](../../Sources/YamiboXCore/Update/AppChangelogLoader.swift)始终用发布产品的标识查找来源条目，避免 Debug 或重签安装改变查询键。保留来源版本列表顺序，使首项与更新检查认定的最新版本一致。
