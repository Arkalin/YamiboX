import Foundation

public struct WebDAVSyncDependencies: Sendable {
    public let settingsStore: WebDAVSyncSettingsStore
    public let makeSyncService: @Sendable () -> WebDAVSyncService

    public init(
        settingsStore: WebDAVSyncSettingsStore,
        makeSyncService: @escaping @Sendable () -> WebDAVSyncService
    ) {
        self.settingsStore = settingsStore
        self.makeSyncService = makeSyncService
    }
}
