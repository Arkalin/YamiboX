import Foundation
@preconcurrency import GRDB

/// Single home for the `init(defaults:key:)` store backdoor that used to be
/// copied into every GRDB-backed store: `.standard` defaults resolve the
/// shared production `yamibox.sqlite` pool, while any other suite (tests and
/// previews) gets its own throwaway database in a temporary directory, keyed
/// by a UUID persisted in that suite so repeat constructions against the same
/// suite+key reuse the same database file.
enum YamiboDatabasePoolResolver {
    /// Process-wide pool cache keyed by database root path. Handing every
    /// caller of the same root the same `DatabasePool` (instead of a fresh
    /// pool per store instance) keeps concurrent writers on one WAL
    /// connection pool; `YamiboDatabase.openPool`'s busy timeout still covers
    /// the residual multi-pool case (e.g. a pool injected by tests).
    /// `nonisolated(unsafe)` is sound because every access is serialized by
    /// `poolCacheLock`.
    private nonisolated(unsafe) static var poolCache: [String: DatabasePool] = [:]
    private static let poolCacheLock = NSLock()

    /// `key` only matters for non-standard suites, where it namespaces the
    /// persisted database UUID (two stores sharing one test suite but using
    /// different keys stay in separate databases, exactly like the per-store
    /// copies behaved).
    static func resolvePool(defaults: UserDefaults, key: String) -> DatabasePool {
        do {
            // Identity comparison on purpose: only the literal standard suite
            // means "production storage"; a test suite that happens to proxy
            // standard values must still get isolated storage.
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
            // One shared directory name for every store: the per-store names
            // the copies used ("yamibo-x-favorite-updates", ...) carried no
            // meaning — isolation comes from the per-suite UUID segment.
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("yamibo-x-store-db", isDirectory: true)
                .appendingPathComponent(databaseID, isDirectory: true)
            return try cachedPool(rootDirectory: root)
        } catch {
            // Deliberately fatal, matching every store's historical crash
            // policy: `YamiboDatabase.openPool` already self-heals corruption
            // by quarantining the file, so a failure that survives it has no
            // runtime recovery worth limping through.
            fatalError("Failed to open store database for key \(key): \(error)")
        }
    }

    /// Shared form of the no-argument `openDatabase()` helper that
    /// `OfflineCacheStore`/`MangaDirectoryStore`/`BrowsingHistoryStore` each
    /// carried as a private copy: a default-root pool behind the historical
    /// per-store crash message. Deliberately NOT routed through `cachedPool`
    /// — the copies always opened their own pool, and folding them into the
    /// cache would change pool-sharing behavior; this consolidation must stay
    /// behavior-identical.
    static func openDefaultPool(storeName: String) -> DatabasePool {
        do {
            return try YamiboDatabase.openPool()
        } catch {
            // Same crash policy as `resolvePool`: `openPool` already
            // self-heals corruption, so a surviving failure is unrecoverable.
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
