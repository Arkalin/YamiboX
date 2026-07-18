import Foundation
import os

public actor SettingsStore {
    public static let defaultKey = "yamibox.settings"

    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private let storage: UserDefaultsJSONStorage<AppSettings>

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.storage = Self.makeStorage(defaults: defaults, key: key)
    }

    public func load() async -> AppSettings {
        storage.load(default: AppSettings())
    }

    public func save(_ settings: AppSettings) async throws {
        try storage.save(settings)
        postChangeNotification()
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
        var settings = storage.load(default: AppSettings())
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
        makeStorage(defaults: defaults, key: key).load(default: AppSettings())
    }

    /// Shared by the instance storage and `loadSync`, so both read paths keep
    /// identical decode-failure handling.
    private nonisolated static func makeStorage(
        defaults: UserDefaults,
        key: String
    ) -> UserDefaultsJSONStorage<AppSettings> {
        UserDefaultsJSONStorage(defaults: defaults, key: key) { error in
            YamiboLog.persistence.error("Failed to decode persisted app settings, resetting to defaults: \(error)")
        }
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }
}
