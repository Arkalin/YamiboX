import Foundation

public actor WebDAVSyncSettingsStore {
    nonisolated let syncCoordinator = WebDAVSyncCoordinator()
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

    public func saveConnection(baseURLString: String, username: String, password: String, isAutoSyncEnabled: Bool) throws -> WebDAVSyncSettings {
        try update { settings in
            settings.baseURLString = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.password = password
            settings.isAutoSyncEnabled = isAutoSyncEnabled
        }
    }

    @discardableResult
    public func setContent(_ content: WebDAVSyncContent, enabled: Bool) throws -> WebDAVSyncSettings {
        try update { settings in
            guard settings.isEnabled(content) != enabled else { return }
            let id = content.rawValue
            settings.contentSelectionRevision &+= 1
            if enabled {
                settings.disabledContentIDs.remove(id)
                settings.dirtyDatasetIDs.insert(id)
                settings.lastSyncedFingerprintByDatasetID[id] = nil
                settings.lastAppliedRemoteUpdatedAtByDatasetID[id] = nil
                settings.lastAppliedRemoteRevisionByDatasetID[id] = nil
            } else {
                settings.disabledContentIDs.insert(id)
            }
        }
    }

    @discardableResult
    func update(_ transform: @Sendable (inout WebDAVSyncSettings) -> Void) throws -> WebDAVSyncSettings {
        var settings = storage.load(default: WebDAVSyncSettings())
        transform(&settings)
        try storage.save(settings)
        postChangeNotification()
        return settings
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }
}
