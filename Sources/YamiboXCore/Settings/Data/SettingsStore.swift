import Foundation
import os

public actor SettingsStore {
    public static let didChangeNotification = Notification.Name("yamibox.settingsStore.didChange")
    public static let changeIDUserInfoKey = "changeID"
    public static let defaultKey = "yamibox.settings"

    public nonisolated let changeID = UUID().uuidString

    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() async -> AppSettings {
        Self.loadSync(defaults: defaults, key: key)
    }

    public func save(_ settings: AppSettings) async throws {
        do {
            let data = try encoder.encode(settings)
            defaults.set(data, forKey: key)
            postChangeNotification()
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    public func reset() async throws {
        try await save(AppSettings())
    }

    /// Atomic read-modify-write: load, mutate, and save run inside the actor
    /// as one uninterruptible step, so two concurrent writers can never
    /// interleave `load()`/`save()` pairs and clobber each other with a stale
    /// whole-blob save. Skips the save (and the change notification) when the
    /// mutation leaves the settings unchanged. Returns the settings as
    /// persisted (or as loaded, when unchanged).
    @discardableResult
    public func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws -> AppSettings {
        var settings = Self.loadSync(defaults: defaults, key: key)
        let original = settings
        mutate(&settings)
        if settings != original {
            try await save(settings)
        }
        return settings
    }

    public nonisolated static func loadSync(
        defaults: UserDefaults = .standard,
        key: String = defaultKey
    ) -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return AppSettings() }
        return decodeSettings(from: data)
    }

    private nonisolated func postChangeNotification() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [Self.changeIDUserInfoKey: changeID]
        )
    }

    private nonisolated static func decodeSettings(from data: Data) -> AppSettings {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(AppSettings.self, from: data)
        } catch {
            YamiboLog.persistence.error("Failed to decode persisted app settings, resetting to defaults: \(error)")
            return AppSettings()
        }
    }
}
