import Foundation
@preconcurrency import GRDB

enum YamiboDatabasePoolResolver {
    private nonisolated(unsafe) static var poolCache: [String: DatabasePool] = [:]
    private static let poolCacheLock = NSLock()

    static func resolvePool(defaults: UserDefaults, key: String) -> DatabasePool {
        do {
            if defaults === UserDefaults.standard {
                return try cachedPool(rootDirectory: YamiboDatabase.defaultRootDirectory())
            }
            let idKey = "\(key).grdbDatabaseID"
            let databaseID: String
            if let existing = defaults.string(forKey: idKey), !existing.isEmpty {
                databaseID = existing
            } else {
                databaseID = UUID().uuidString
                defaults.set(databaseID, forKey: idKey)
            }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("yamibo-x-store-db", isDirectory: true)
                .appendingPathComponent(databaseID, isDirectory: true)
            return try cachedPool(rootDirectory: root)
        } catch {
            fatalError("Failed to open store database for key \(key): \(error)")
        }
    }

    static func openDefaultPool(storeName: String) -> DatabasePool {
        do {
            return try YamiboDatabase.openPool()
        } catch {
            fatalError("Failed to open \(storeName) database: \(error)")
        }
    }

    private static func cachedPool(rootDirectory: URL) throws -> DatabasePool {
        let cacheKey = rootDirectory.standardizedFileURL.path
        poolCacheLock.lock()
        defer { poolCacheLock.unlock() }
        if let pool = poolCache[cacheKey] {
            return pool
        }

        let pool = try YamiboDatabase.openPool(rootDirectory: rootDirectory)
        poolCache[cacheKey] = pool
        return pool
    }
}
