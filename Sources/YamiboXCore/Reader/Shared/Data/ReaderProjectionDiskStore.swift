import Foundation
@preconcurrency import GRDB

/// Disk-backed projection cache shared by the novel and manga readers. Owns
/// everything the two stores previously duplicated verbatim: shared-database
/// fallback wiring, the 100-entry namespace trim, byte accounting, and
/// logged-degrade reads.
actor ReaderProjectionDiskStore<Projection: Codable & Sendable> {
    private let namespace: String
    private let cacheStore: DiskCacheStore
    private nonisolated(unsafe) let fileManager: FileManager
    private let maximumEntryCount = 100

    init(
        namespace: String,
        databasePool: DatabasePool? = nil,
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil,
        baseDirectory: URL? = nil,
        diskCacheStore: DiskCacheStore? = nil
    ) {
        self.namespace = namespace
        if let diskCacheStore {
            self.cacheStore = diskCacheStore
        } else {
            // An injected directory hosts both the database and the cache
            // files (tests); the no-argument fallback mirrors the app context:
            // yamibox.sqlite in Application Support, yamibox-cache in Caches.
            let injectedRootDirectory = rootDirectory ?? baseDirectory
            let resolvedDatabase = databasePool ?? Self.openDatabase(
                rootDirectory: injectedRootDirectory ?? YamiboDatabase.defaultRootDirectory(fileManager: fileManager),
                fileManager: fileManager,
                namespace: namespace
            )
            self.cacheStore = DiskCacheStore(
                writer: resolvedDatabase,
                rootDirectory: injectedRootDirectory ?? YamiboDatabase.defaultCacheRootDirectory(fileManager: fileManager)
            )
        }
        self.fileManager = fileManager
    }

    func projection(forKey key: String) async -> Projection? {
        do {
            return try await cacheStore.get(namespace: namespace, key: key)
        } catch {
            YamiboLog.offlineCache.warning("Failed to read cached reader projection in \(self.namespace) for key \(key): \(error)")
            return nil
        }
    }

    func save(_ projection: Projection, forKey key: String) async throws {
        try await cacheStore.set(projection, namespace: namespace, key: key)
        try await cacheStore.trimNamespace(namespace, maximumEntryCount: maximumEntryCount)
    }

    func removeProjection(forKey key: String) async throws {
        try await cacheStore.remove(namespace: namespace, key: key)
    }

    func entryKeys() async -> [String] {
        do {
            return try await cacheStore.entries(namespace: namespace).map(\.key)
        } catch {
            YamiboLog.offlineCache.warning("Failed to enumerate cached reader projection entries in \(self.namespace): \(error)")
            return []
        }
    }

    func totalDiskUsageBytes() async -> Int {
        var total = 0
        for key in await entryKeys() {
            guard let fileURL = try? await cacheStore.fileURL(namespace: namespace, key: key),
                  let byteCount = try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber else {
                continue
            }
            total += byteCount.intValue
        }
        return total
    }

    func clearAll() async throws {
        try await cacheStore.clearNamespace(namespace)
    }

    private static func openDatabase(
        rootDirectory: URL,
        fileManager: FileManager,
        namespace: String
    ) -> DatabasePool {
        do {
            return try YamiboDatabase.openPool(rootDirectory: rootDirectory, fileManager: fileManager)
        } catch {
            fatalError("Failed to open reader projection store database (\(namespace)): \(error)")
        }
    }
}
