import Foundation
@preconcurrency import GRDB
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

@Suite("GRDB store migration issue 001")
struct StoreMigrationIssue001Tests {
    @Test func databaseBootstrapCreatesCacheEntriesAndYieldsDefaultFavoriteDocument() async throws {
        let root = makeTemporaryPersistenceRoot()
        let pool = try YamiboDatabase.openPool(rootDirectory: root)

        let cacheColumns = try await pool.read { db in
            try Set(Row.fetchAll(db, sql: "PRAGMA table_info(cache_entries)").map { row in
                let name: String = row["name"]
                return name
            })
        }
        #expect(cacheColumns == ["namespace", "cache_key", "created_at", "last_accessed_at"])

        try YamiboDatabase.migrate(pool)

        // A fresh database stores no document row; loading synthesizes the
        // default document with exactly the default category.
        let store = FavoriteLibraryStore(databasePool: pool)
        let fresh = try await store.load()
        #expect(fresh.categories.count == 1)
        let defaultCategory = try #require(fresh.categories.first)
        #expect(defaultCategory.id == FavoriteCategory.defaultID)
        #expect(defaultCategory.name == FavoriteCategory.defaultStorageName)
        #expect(defaultCategory.manualOrder == 0)
        #expect(defaultCategory.isDefault)
        #expect(await store.hasStoredDocument() == false)
    }

    @Test func genericCacheStoresJSONBodyOnDiskAndThinMetadataInDatabase() async throws {
        let (pool, root) = try makeMigratedDatabase()
        let store = DiskCacheStore(writer: pool, rootDirectory: root)
        let payload = CachePayload(title: "首页", page: 1)

        try await store.set(payload, namespace: "forum", key: "home")

        let fileURL = try await store.fileURL(namespace: "forum", key: "home")
        #expect(fileURL.path.hasSuffix("/yamibox-cache/forum/home.json"))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try JSONDecoder().decode(CachePayload.self, from: Data(contentsOf: fileURL)) == payload)

        let rows = try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM cache_entries").map { row in
                let namespace: String = row["namespace"]
                let cacheKey: String = row["cache_key"]
                return (namespace: namespace, cacheKey: cacheKey)
            }
        }
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.namespace == "forum")
        #expect(row.cacheKey == "home")
        let metadataColumns = try await pool.read { db in
            try Set(Row.fetchAll(db, sql: "PRAGMA table_info(cache_entries)").map { row in
                let name: String = row["name"]
                return name
            })
        }
        #expect(metadataColumns == ["namespace", "cache_key", "created_at", "last_accessed_at"])
    }

    @Test func readsDoNotExtendTTLAndOnlyUpdateLRUAccessTimePastTheTouchThrottle() async throws {
        let (pool, root) = try makeMigratedDatabase()
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 100)
        let store = DiskCacheStore(writer: pool, rootDirectory: root, now: { now })

        try await store.set(CachePayload(title: "第一页", page: 1), namespace: "novel", key: "tid-9-page-1")

        // Within the 5-minute touch throttle a hit leaves last_accessed_at alone.
        now = Date(timeIntervalSince1970: 120)
        let throttled: CachePayload? = try await store.get(namespace: "novel", key: "tid-9-page-1", ttl: 3_000)
        #expect(throttled?.title == "第一页")
        let throttledEntry = try #require(try await store.entries(namespace: "novel").first)
        #expect(throttledEntry.lastAccessedAt == Date(timeIntervalSince1970: 100))

        // Past the throttle window the hit refreshes LRU recency.
        now = Date(timeIntervalSince1970: 500)
        let loaded: CachePayload? = try await store.get(namespace: "novel", key: "tid-9-page-1", ttl: 3_000)
        #expect(loaded?.title == "第一页")

        let entry = try #require(try await store.entries(namespace: "novel").first)
        #expect(entry.createdAt == Date(timeIntervalSince1970: 100))
        #expect(entry.lastAccessedAt == Date(timeIntervalSince1970: 500))

        now = Date(timeIntervalSince1970: 3_101)
        let expired: CachePayload? = try await store.get(namespace: "novel", key: "tid-9-page-1", ttl: 3_000)
        #expect(expired == nil)
        #expect(try await store.entries(namespace: "novel").isEmpty)
    }

    @Test func trimNamespaceEvictsLeastRecentlyAccessedEntries() async throws {
        let (pool, root) = try makeMigratedDatabase()
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 100)
        let store = DiskCacheStore(writer: pool, rootDirectory: root, now: { now })

        try await store.set(CachePayload(title: "旧", page: 1), namespace: "forum", key: "old")
        now = Date(timeIntervalSince1970: 110)
        try await store.set(CachePayload(title: "新", page: 2), namespace: "forum", key: "new")
        // Far enough past the touch throttle that this hit refreshes recency.
        now = Date(timeIntervalSince1970: 500)
        let old: CachePayload? = try await store.get(namespace: "forum", key: "old")
        #expect(old?.title == "旧")

        try await store.trimNamespace("forum", maximumEntryCount: 1)

        #expect(try await store.entries(namespace: "forum").map(\.key) == ["old"])
        let oldAfterTrim: CachePayload? = try await store.get(namespace: "forum", key: "old")
        let newAfterTrim: CachePayload? = try await store.get(namespace: "forum", key: "new")
        #expect(oldAfterTrim?.title == "旧")
        #expect(newAfterTrim == nil)
    }

    @Test func namespaceClearAndPrefixDeletionRemoveMetadataAndFiles() async throws {
        let (pool, root) = try makeMigratedDatabase()
        let store = DiskCacheStore(writer: pool, rootDirectory: root)

        try await store.set(CachePayload(title: "第一页", page: 1), namespace: "thread_pages", key: "tid-1-page-1")
        try await store.set(CachePayload(title: "第二页", page: 2), namespace: "thread_pages", key: "tid-1-page-2")
        try await store.set(CachePayload(title: "其他", page: 1), namespace: "thread_pages", key: "tid-2-page-1")
        try await store.set(CachePayload(title: "首页", page: 1), namespace: "forum_home", key: "home")

        try await store.deleteKeys(namespace: "thread_pages", matchingPrefix: "tid-1-")
        #expect(try await store.entries(namespace: "thread_pages").map(\.key) == ["tid-2-page-1"])
        #expect(!FileManager.default.fileExists(atPath: try await store.fileURL(namespace: "thread_pages", key: "tid-1-page-1").path))
        #expect(FileManager.default.fileExists(atPath: try await store.fileURL(namespace: "forum_home", key: "home").path))

        try await store.clearNamespace("thread_pages")
        #expect(try await store.entries(namespace: "thread_pages").isEmpty)
        #expect(try await store.entries(namespace: "forum_home").map(\.key) == ["home"])
    }

    @Test func missingFileAndDecodeFailureSelfHealToCacheMiss() async throws {
        let (pool, root) = try makeMigratedDatabase()
        let store = DiskCacheStore(writer: pool, rootDirectory: root)

        try await store.set(CachePayload(title: "missing", page: 1), namespace: "forum", key: "missing")
        try FileManager.default.removeItem(at: try await store.fileURL(namespace: "forum", key: "missing"))
        let missing: CachePayload? = try await store.get(namespace: "forum", key: "missing")
        #expect(missing == nil)
        #expect(try await store.entries(namespace: "forum").isEmpty)

        try await store.set(CachePayload(title: "bad", page: 2), namespace: "forum", key: "bad-json")
        try Data("not-json".utf8).write(to: try await store.fileURL(namespace: "forum", key: "bad-json"), options: [.atomic])
        let corrupt: CachePayload? = try await store.get(namespace: "forum", key: "bad-json")
        #expect(corrupt == nil)
        #expect(try await store.entries(namespace: "forum").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try await store.fileURL(namespace: "forum", key: "bad-json").path))
    }

    @Test func resetClearsNewDatabaseStateAndManagedCacheWithoutTouchingLegacyUserDefaults() async throws {
        let (pool, root) = try makeMigratedDatabase()
        let suiteName = YamiboTestDefaults.suiteName(prefix: "grdb-reset-legacy")
        let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
        defaults.set(Data("legacy-json".utf8), forKey: "yamibox.favoriteLibrary.localFirst")

        let store = DiskCacheStore(writer: pool, rootDirectory: root)
        try await store.set(CachePayload(title: "缓存", page: 1), namespace: "forum", key: "home")
        let libraryStore = FavoriteLibraryStore(databasePool: pool)
        var document = FavoriteLibraryDocument()
        _ = document.createCategory(name: "Custom")
        try await libraryStore.save(document)
        #expect(await libraryStore.hasStoredDocument())

        try YamiboDatabase.reset(writer: pool, rootDirectory: root)

        #expect(defaults.data(forKey: "yamibox.favoriteLibrary.localFirst") == Data("legacy-json".utf8))
        #expect(!FileManager.default.fileExists(atPath: YamiboDatabase.cacheDirectoryURL(rootDirectory: root).path))
        let reset = try await libraryStore.load()
        #expect(reset.categories.map(\.id) == [FavoriteCategory.defaultID])
        #expect(await libraryStore.hasStoredDocument() == false)
        #expect(try await store.entries(namespace: "forum").isEmpty)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private struct CachePayload: Codable, Equatable {
    var title: String
    var page: Int
}

private func makeTemporaryPersistenceRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func makeMigratedDatabase() throws -> (DatabasePool, URL) {
    let root = makeTemporaryPersistenceRoot()
    return (try YamiboDatabase.openPool(rootDirectory: root), root)
}
