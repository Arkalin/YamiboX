import Foundation

public actor WebDAVSyncSettingsStore {
    public static let didChangeNotification = Notification.Name("yamibox.webDAVSyncSettingsStore.didChange")
    public static let changeIDUserInfoKey = "changeID"
    public static let defaultKey = "yamibox.webdav.sync.settings"

    public nonisolated let changeID = UUID().uuidString

    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() async -> WebDAVSyncSettings {
        guard let data = defaults.data(forKey: key) else { return WebDAVSyncSettings() }
        do {
            return try decoder.decode(WebDAVSyncSettings.self, from: data)
        } catch {
            YamiboLog.sync.error("Failed to decode stored WebDAV sync settings, resetting to defaults: \(error)")
            return WebDAVSyncSettings()
        }
    }

    public func save(_ settings: WebDAVSyncSettings) async throws {
        do {
            let data = try encoder.encode(settings)
            defaults.set(data, forKey: key)
            postChangeNotification()
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    public func reset() async throws {
        try await save(WebDAVSyncSettings())
    }

    private nonisolated func postChangeNotification() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [Self.changeIDUserInfoKey: changeID]
        )
    }
}
