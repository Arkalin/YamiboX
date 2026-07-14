import Foundation

/// Everything the WebDAV sync settings UI needs from the composition root.
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
