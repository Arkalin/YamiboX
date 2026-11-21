import Foundation
import os

public actor SettingsStore {
    public static let defaultKey = "yamibox.settings"

    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private let storage: UserDefaultsJSONStorage<AppSettings>

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.storage = Self.makeStorage(defaults: defaults, key: key)
    }

    public func load() async -> AppSettings {
        storage.load(default: AppSettings())
    }

    public func save(_ settings: AppSettings) async throws {
        try persist(settings)
    }

    public func reset() async throws {
        try await save(AppSettings())
    }

    @discardableResult
    public func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws -> AppSettings {
        var settings = storage.load(default: AppSettings())
        let original = settings
        mutate(&settings)
        if settings != original {
            try persist(settings)
        }
        return settings
    }

    public nonisolated static func loadSync(
        defaults: UserDefaults = .standard,
        key: String = defaultKey
    ) -> AppSettings {
        makeStorage(defaults: defaults, key: key).load(default: AppSettings())
    }

    private nonisolated static func makeStorage(
        defaults: UserDefaults,
        key: String
    ) -> UserDefaultsJSONStorage<AppSettings> {
        let storage = UserDefaultsJSONStorage<AppSettings>(defaults: defaults, key: key) { error in
            YamiboLog.persistence.error("Failed to decode persisted app settings, resetting to defaults: \(error)")
        }
        if let data = defaults.data(forKey: key),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["novelOfflineCache"] != nil,
           let settings = storage.loadStored() {
            do { try storage.save(settings) }
            catch { YamiboLog.persistence.error("Failed to migrate download settings: \(error)") }
        }
        return storage
    }

    private func persist(_ settings: AppSettings) throws {
        try storage.save(settings)
        postChangeNotification()
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }
}
