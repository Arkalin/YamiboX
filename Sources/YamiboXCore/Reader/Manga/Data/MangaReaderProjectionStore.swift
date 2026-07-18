import Foundation
@preconcurrency import GRDB

/// Thin façade over the shared `ReaderProjectionDiskStore`: owns only the
/// manga namespace and key semantics, so it needs no isolation of its own.
public final class MangaReaderProjectionStore: MangaReaderProjectionPersisting, Sendable {
    public static let projectionNamespace = "manga-reader-projections"

    private let store: ReaderProjectionDiskStore<MangaReaderProjection>

    init(
        databasePool: DatabasePool? = nil,
        rootDirectory: URL? = nil,
        baseDirectory: URL? = nil,
        diskCacheStore: DiskCacheStore? = nil
    ) {
        store = ReaderProjectionDiskStore(
            namespace: Self.projectionNamespace,
            databasePool: databasePool,
            rootDirectory: rootDirectory,
            baseDirectory: baseDirectory,
            diskCacheStore: diskCacheStore
        )
    }

    public func projection(for identity: MangaReaderProjectionSourceIdentity) async -> MangaReaderProjection? {
        await store.projection(forKey: projectionCacheKey(identity: identity))
    }

    public func save(_ projection: MangaReaderProjection) async throws {
        try await store.save(projection, forKey: projectionCacheKey(identity: projection.sourceIdentity))
    }

    public func clearAll() async throws {
        try await store.clearAll()
    }

    public func totalDiskUsageBytes() async -> Int {
        await store.totalDiskUsageBytes()
    }

    private func projectionCacheKey(identity: MangaReaderProjectionSourceIdentity) -> String {
        ReaderCacheKeyCodec.entryKey(
            threadID: identity.tid,
            view: identity.view,
            authorID: identity.authorID
        )
    }
}
