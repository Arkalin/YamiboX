import Foundation
@preconcurrency import GRDB

public actor NovelReaderProjectionStore {
    public static let projectionNamespace = "novel-reader-projections"

    private let cacheStore: DiskCacheStore
    private nonisolated(unsafe) let fileManager: FileManager
    private let memoryCache = NSCache<NSString, CacheBox>()

    init(
        databasePool: DatabasePool? = nil,
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil,
        baseDirectory: URL? = nil,
        diskCacheStore: DiskCacheStore? = nil
    ) {
        if let diskCacheStore {
            self.cacheStore = diskCacheStore
        } else {
            // An injected directory hosts both the database and the cache
            // files (tests); the no-argument fallback mirrors the app context:
            // yamibox.sqlite in Application Support, yamibox-cache in Caches.
            let injectedRootDirectory = rootDirectory ?? baseDirectory
            let resolvedDatabase = databasePool ?? Self.openDatabase(
                rootDirectory: injectedRootDirectory ?? YamiboDatabase.defaultRootDirectory(fileManager: fileManager),
                fileManager: fileManager
            )
            self.cacheStore = DiskCacheStore(
                writer: resolvedDatabase,
                rootDirectory: injectedRootDirectory ?? YamiboDatabase.defaultCacheRootDirectory(fileManager: fileManager)
            )
        }
        self.fileManager = fileManager
    }

    public func loadProjection(
        for request: NovelPageRequest
    ) async -> NovelReaderProjection? {
        let key = projectionCacheKey(threadID: request.threadID, view: request.view, authorID: request.authorID)

        let projection: NovelReaderProjection?
        do {
            projection = try await cacheStore.get(
                namespace: Self.projectionNamespace,
                key: key
            )
        } catch {
            YamiboLog.offlineCache.warning("Failed to read cached novel reader projection for key \(key): \(error)")
            projection = nil
        }
        guard let projection else {
            memoryCache.removeObject(forKey: key as NSString)
            return nil
        }

        memoryCache.setObject(CacheBox(projection: projection), forKey: key as NSString)
        return projection
    }

    public func save(_ projection: NovelReaderProjection) async throws {
        let key = projectionCacheKey(projection: projection)
        try await cacheStore.set(projection, namespace: Self.projectionNamespace, key: key)
        try await cacheStore.trimNamespace(Self.projectionNamespace, maximumEntryCount: 100)
        memoryCache.setObject(CacheBox(projection: projection), forKey: key as NSString)
    }

    public func cachedViews(
        for threadID: String,
        authorID: String?
    ) async -> Set<Int> {
        let identity = NovelReaderCacheIdentity(threadID: threadID, view: 1, authorID: authorID)
        let normalizedAuthorID = authorID?.nilIfBlank
        let entries: [DiskCacheStore.CacheEntry]
        do {
            entries = try await cacheStore.entries(namespace: Self.projectionNamespace)
        } catch {
            YamiboLog.offlineCache.warning("Failed to enumerate cached novel reader projection entries for thread \(threadID): \(error)")
            entries = []
        }
        return Set(entries.compactMap { entry -> Int? in
            guard let parsed = projectionKeyComponents(from: entry.key),
                  parsed.threadID == identity.threadID,
                  parsed.authorID == normalizedAuthorID else {
                return nil
            }
            return parsed.view
        })
    }

    public func deleteViews(
        _ views: Set<Int>,
        for threadID: String,
        authorID: String?
    ) async throws {
        for view in views {
            let key = projectionCacheKey(threadID: threadID, view: view, authorID: authorID)
            try await cacheStore.remove(namespace: Self.projectionNamespace, key: key)
            memoryCache.removeObject(forKey: key as NSString)
        }
    }

    public func deleteAll(
        for threadID: String,
        authorID: String?
    ) async throws {
        let views = await cachedViews(for: threadID, authorID: authorID)
        try await deleteViews(views, for: threadID, authorID: authorID)
    }

    public func totalDiskUsageBytes() async -> Int {
        let entries: [DiskCacheStore.CacheEntry]
        do {
            entries = try await cacheStore.entries(namespace: Self.projectionNamespace)
        } catch {
            YamiboLog.offlineCache.warning("Failed to enumerate cached novel reader projection entries for disk usage accounting: \(error)")
            return 0
        }
        var total = 0
        for entry in entries {
            guard let fileURL = try? await cacheStore.fileURL(namespace: entry.namespace, key: entry.key),
                  let byteCount = try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber else {
                continue
            }
            total += byteCount.intValue
        }
        return total
    }

    public func clearAll() async throws {
        try await cacheStore.clearNamespace(Self.projectionNamespace)
        memoryCache.removeAllObjects()
    }

    private func projectionCacheKey(projection: NovelReaderProjection) -> String {
        projectionCacheKey(
            threadID: projection.threadID,
            view: projection.view,
            authorID: projection.resolvedAuthorID
        )
    }

    private func projectionCacheKey(
        threadID: String,
        view: Int,
        authorID: String?
    ) -> String {
        let identity = NovelReaderCacheIdentity(threadID: threadID, view: view, authorID: authorID)
        return [
            "tid", identity.threadID,
            "author", authorID?.nilIfBlank ?? "all",
            "view", String(identity.view)
        ].joined(separator: "_")
    }

    private func projectionKeyComponents(from key: String) -> ProjectionKeyComponents? {
        let components = key.components(separatedBy: "_")
        guard components.count == 6,
              components[0] == "tid",
              components[2] == "author",
              components[4] == "view",
              let view = Int(components[5]) else {
            return nil
        }
        let authorID = components[3] == "all" ? nil : components[3]
        return ProjectionKeyComponents(
            threadID: components[1],
            authorID: authorID,
            view: max(1, view)
        )
    }

    private static func openDatabase(
        rootDirectory: URL,
        fileManager: FileManager
    ) -> DatabasePool {
        do {
            return try YamiboDatabase.openPool(rootDirectory: rootDirectory, fileManager: fileManager)
        } catch {
            fatalError("Failed to open NovelReaderProjectionStore database: \(error)")
        }
    }
}

private final class CacheBox: NSObject {
    let projection: NovelReaderProjection

    init(projection: NovelReaderProjection) {
        self.projection = projection
    }
}

private struct ProjectionKeyComponents: Sendable {
    var threadID: String
    var authorID: String?
    var view: Int
}
