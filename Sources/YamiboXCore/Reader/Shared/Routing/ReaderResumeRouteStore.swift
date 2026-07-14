import Foundation

public final class ReaderResumeRouteStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var suppressesPositionSaves = false

    public init(defaults: UserDefaults = .standard, key: String = "yamibox.novelReader.resumeRoute") {
        self.defaults = defaults
        self.key = key
    }

    public func load() async -> ReaderResumeRoute? {
        loadSync()
    }

    public func loadSync() -> ReaderResumeRoute? {
        lock.lock()
        let data = defaults.data(forKey: key)
        lock.unlock()

        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(ReaderResumeRoute.self, from: data)
        } catch {
            YamiboLog.reader.warning("ReaderResumeRouteStore failed to decode persisted resume route; treating as no resume route: \(error)")
            return nil
        }
    }

    public func save(_ route: ReaderResumeRoute) async throws {
        try saveSync(route)
    }

    public func saveSync(_ route: ReaderResumeRoute) throws {
        let data = try encode(route)

        lock.lock()
        suppressesPositionSaves = false
        defaults.set(data, forKey: key)
        lock.unlock()
    }

    public func saveReadingPosition(_ route: ReaderResumeRoute) async throws {
        try saveReadingPositionSync(route)
    }

    public func saveReadingPositionSync(_ route: ReaderResumeRoute) throws {
        let data = try encode(route)

        lock.lock()
        if !suppressesPositionSaves {
            defaults.set(data, forKey: key)
        }
        lock.unlock()
    }

    private func encode(_ route: ReaderResumeRoute) throws -> Data {
        do {
            return try JSONEncoder().encode(route)
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    public func clear() async {
        clearSync()
    }

    public func clearSync() {
        lock.lock()
        suppressesPositionSaves = true
        defaults.removeObject(forKey: key)
        lock.unlock()
    }
}
