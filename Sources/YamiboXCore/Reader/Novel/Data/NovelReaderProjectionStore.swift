import Foundation
@preconcurrency import GRDB

/// Thin façade over the shared `ReaderProjectionDiskStore`: owns only the
/// novel namespace and key semantics, so it needs no isolation of its own.
public final class NovelReaderProjectionStore: Sendable {
    public static let projectionNamespace = "novel-reader-projections"

    private let store: ReaderProjectionDiskStore<NovelReaderProjection>

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

    public func loadProjection(
        for request: NovelPageRequest
    ) async -> NovelReaderProjection? {
        await store.projection(
            forKey: projectionCacheKey(threadID: request.threadID, view: request.view, authorID: request.authorID)
        )
    }

    public func save(_ projection: NovelReaderProjection) async throws {
        try await store.save(projection, forKey: projectionCacheKey(projection: projection))
    }

    public func cachedViews(
        for threadID: String,
        authorID: String?
    ) async -> Set<Int> {
        let identity = NovelReaderCacheIdentity(threadID: threadID, view: 1, authorID: authorID)
        // Compare against the re-encoded (sanitized) group prefix rather than
        // the raw ids: stored keys only ever contain sanitized components.
        let groupPrefix = ReaderCacheKeyCodec.groupKey(
            threadID: identity.threadID,
            authorID: identity.authorID
        ) + "_view_"
        return Set(await store.entryKeys().compactMap { key -> Int? in
            guard key.hasPrefix(groupPrefix),
                  let parsed = ReaderCacheKeyCodec.components(from: key) else {
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
            try await store.removeProjection(
                forKey: projectionCacheKey(threadID: threadID, view: view, authorID: authorID)
            )
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
        await store.totalDiskUsageBytes()
    }

    public func clearAll() async throws {
        try await store.clearAll()
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
        return ReaderCacheKeyCodec.entryKey(
            threadID: identity.threadID,
            view: identity.view,
            authorID: identity.authorID
        )
    }
}
