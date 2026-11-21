# WebDAV 连接切换与写入的失败边界

单个服务 actor 不能在多个实例和异步挂起点之间独占连接；使用[设置共享的同步协调器](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVSyncCoordinator.swift)取消并等待旧任务、推进 epoch，再发布连接改动。普通回执不走这一屏障，避免一次同步取消自身。持有屏障的设置写入保持同步，避免协调器等待 Store 时 Store 又等待协调器；账号重置的屏障所有权由调用方显式传入，不从忙碌状态推断。

[传输](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVClient.swift)的强 ETag 只有在正文与验证器配对时才可复用；拿到不同验证器的 304 时完整读取，网络失败也不能拿缓存伪装成功。验证器的存在不证明服务器实施了条件请求，为此用独立临时探针实际验证且让清理不受原任务取消影响。PUT 前让缓存失效：客户端看到失败或取消时，服务端仍可能已经收到请求。

[凭据](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVSyncCredentialStore.swift)与论坛 vault 分开，并隔离 Local 和普通环境；`AfterFirstUnlockThisDeviceOnly` 兼顾首次解锁后的后台同步且不传播到其他安装。[设置 Store](../../Sources/YamiboXCore/Sync/WebDAV/WebDAVSyncSettingsStore.swift)必须先保存新凭据才能替换偏好内的引用，旧引用在替换前保持可恢复；旧项清理可重试。旧明文只解码以完成迁移，在安全写入成功前拒绝会丢失其唯一副本的普通回执写入；Keychain 暂时读不到时也不能把空值解释成用户要求删除。

参见 [WebDAV 传输、凭据与失败处理](../architecture/webdav-sync.md)。
