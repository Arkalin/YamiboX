import Foundation
@preconcurrency import GRDB

public actor MangaReaderProjectionStore: MangaReaderProjectionPersisting {
    public static let projectionNamespace = "manga-reader-projections"

    private let cacheStore: DiskCacheStore
    private nonisolated(unsafe) let fileManager: FileManager

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

    public func projection(for identity: MangaReaderProjectionSourceIdentity) async -> MangaReaderProjection? {
        do {
            return try await cacheStore.get(
                namespace: Self.projectionNamespace,
                key: projectionCacheKey(identity: identity)
            )
        } catch {
            YamiboLog.offlineCache.warning("Failed to read cached manga reader projection: \(error)")
            return nil
        }
    }

    public func save(_ projection: MangaReaderProjection) async throws {
        try await cacheStore.set(
            projection,
            namespace: Self.projectionNamespace,
            key: projectionCacheKey(identity: projection.sourceIdentity)
        )
        try await cacheStore.trimNamespace(Self.projectionNamespace, maximumEntryCount: 100)
    }

    public func clearAll() async throws {
        try await cacheStore.clearNamespace(Self.projectionNamespace)
    }

    public func totalDiskUsageBytes() async -> Int {
        let entries: [DiskCacheStore.CacheEntry]
        do {
            entries = try await cacheStore.entries(namespace: Self.projectionNamespace)
        } catch {
            YamiboLog.offlineCache.warning("Failed to enumerate cached manga reader projections for disk usage: \(error)")
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

    private func projectionCacheKey(identity: MangaReaderProjectionSourceIdentity) -> String {
        [
            "tid",
            stableKeyComponent(identity.tid),
            "author",
            stableKeyComponent(identity.authorID ?? "all"),
            "view",
            String(max(1, identity.view))
        ].joined(separator: "_")
    }

    private func stableKeyComponent(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "empty" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        if normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return normalized
        }
        return stableIdentifier(for: normalized)
    }

    private func stableIdentifier(for value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static func openDatabase(
        rootDirectory: URL,
        fileManager: FileManager
    ) -> DatabasePool {
        do {
            return try YamiboDatabase.openPool(rootDirectory: rootDirectory, fileManager: fileManager)
        } catch {
            fatalError("Failed to open MangaReaderProjectionStore database: \(error)")
        }
    }
}
