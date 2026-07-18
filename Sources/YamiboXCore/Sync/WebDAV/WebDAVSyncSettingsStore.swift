import Foundation

public actor WebDAVSyncSettingsStore {
    public static let defaultKey = "yamibox.webdav.sync.settings"

    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private let storage: UserDefaultsJSONStorage<WebDAVSyncSettings>

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.storage = UserDefaultsJSONStorage(defaults: defaults, key: key) { error in
            YamiboLog.sync.error("Failed to decode stored WebDAV sync settings, resetting to defaults: \(error)")
        }
    }

    public func load() async -> WebDAVSyncSettings {
        storage.load(default: WebDAVSyncSettings())
    }

    public func save(_ settings: WebDAVSyncSettings) async throws {
        try storage.save(settings)
        postChangeNotification()
    }

    public func reset() async throws {
        try await save(WebDAVSyncSettings())
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }
}
