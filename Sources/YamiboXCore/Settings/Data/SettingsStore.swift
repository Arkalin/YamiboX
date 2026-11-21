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
        Self.loadSnapshot(from: storage).settings
    }

    func loadForSync() throws -> AppSettings {
        try Self.loadSnapshot(from: storage).requiringReadableSettings()
    }

    public func save(_ settings: AppSettings) async throws {
        try persist(settings)
    }

    public func reset() async throws {
        try await save(AppSettings())
    }

    @discardableResult
    public func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws -> AppSettings {
        let snapshot = Self.loadSnapshot(from: storage)
        var settings = snapshot.settings
        let original = settings
        mutate(&settings)
        if settings != original {
            _ = try snapshot.requiringReadableSettings()
            try persist(settings)
        }
        return settings
    }

    public nonisolated static func loadSync(
        defaults: UserDefaults = .standard,
        key: String = defaultKey
    ) -> AppSettings {
        loadSnapshot(from: makeStorage(defaults: defaults, key: key)).settings
    }

    private nonisolated static func makeStorage(
        defaults: UserDefaults,
        key: String
    ) -> UserDefaultsJSONStorage<AppSettings> {
        let storage = UserDefaultsJSONStorage<AppSettings>(defaults: defaults, key: key) { error in
            YamiboLog.persistence.error("Failed to decode persisted app settings during legacy migration: \(error)")
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

    private enum PersistedSnapshot {
        case missing
        case decoded(AppSettings)
        case recovered(AppSettings)
        case unreadable

        func requiringReadableSettings() throws -> AppSettings {
            guard case .unreadable = self else { return settings }
            throw YamiboPersistenceError(context: L10n.string("settings.error.unreadable_snapshot"))
        }

        var settings: AppSettings {
            switch self {
            case .missing, .unreadable: AppSettings()
            case let .decoded(settings), let .recovered(settings): settings
            }
        }
    }

    private nonisolated static func loadSnapshot(
        from storage: UserDefaultsJSONStorage<AppSettings>
    ) -> PersistedSnapshot {
        guard let rawValue = storage.defaults.object(forKey: storage.key) else { return .missing }
        guard let data = rawValue as? Data else {
            YamiboLog.persistence.error("Persisted app settings are not stored as data; keeping the original value")
            return .unreadable
        }
        do {
            return .decoded(try JSONDecoder().decode(AppSettings.self, from: data))
        } catch {
            if let recovered = recoverSnapshot(data) {
                YamiboLog.persistence.warning("Recovered valid fields from partially unreadable app settings")
                return .recovered(recovered)
            }
            YamiboLog.persistence.error("Persisted app settings could not be decoded; keeping the original data")
            return .unreadable
        }
    }

    private nonisolated static func recoverSnapshot(_ data: Data) -> AppSettings? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let encodedDefaults = try? JSONEncoder().encode(AppSettings()),
              let defaults = (try? JSONSerialization.jsonObject(with: encodedDefaults)) as? [String: Any] else {
            return nil
        }
        let decoder = JSONDecoder()
        var repairedPaths: Set<[String]> = []
        for _ in 0..<128 {
            do {
                return try decoder.decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
            } catch let error as DecodingError {
                var path = damagedPath(error)
                var repaired = false
                while !path.isEmpty {
                    if repairedPaths.insert(path).inserted, replaceDamagedValue(in: &object, with: defaults, at: path[...]) {
                        repaired = true
                        break
                    }
                    path.removeLast()
                }
                guard repaired else { return nil }
            } catch {
                return nil
            }
        }
        return nil
    }

    private nonisolated static func damagedPath(_ error: DecodingError) -> [String] {
        switch error {
        case let .keyNotFound(key, context):
            return context.codingPath.map(\.stringValue) + [key.stringValue]
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
            return context.codingPath.map(\.stringValue)
        @unknown default:
            return []
        }
    }

    private nonisolated static func replaceDamagedValue(
        in object: inout [String: Any],
        with defaults: [String: Any],
        at path: ArraySlice<String>
    ) -> Bool {
        guard let key = path.first else { return false }
        if path.count == 1 {
            guard object[key] != nil || defaults[key] != nil else { return false }
            object[key] = defaults[key]
            return true
        }
        guard var nested = object[key] as? [String: Any],
              replaceDamagedValue(in: &nested, with: defaults[key] as? [String: Any] ?? [:], at: path.dropFirst()) else {
            return false
        }
        object[key] = nested
        return true
    }

    private func persist(_ settings: AppSettings) throws {
        try storage.save(settings)
        postChangeNotification()
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }
}
