import Foundation

struct NovelReaderProjectionLoadedPage: Sendable {
    var projection: NovelReaderProjection
    var sourcePage: ForumThreadPage
    var source: ReaderProjectionLoadSource

    init(
        projection: NovelReaderProjection,
        sourcePage: ForumThreadPage,
        source: ReaderProjectionLoadSource
    ) {
        self.projection = projection
        self.sourcePage = sourcePage
        self.source = source
    }
}

actor NovelReaderProjectionLoader {
    private let loader: ReaderProjectionLoader<ReaderThreadPageProjectionLoadingStrategy<NovelProjectionAdapter>>

    init(
        client: YamiboClient,
        projectionStore: NovelReaderProjectionStore = NovelReaderProjectionStore(),
        forumCacheStore: ForumCacheStore = ForumCacheStore(),
        offlineCacheStore: (any NovelOfflineCacheStoring)? = nil
    ) {
        // Uses the `ReaderProjectionLoader` default of not coalescing
        // in-flight requests: the novel workflow loads one web-view document
        // at a time and holds a single prefetched next document that
        // navigation *promotes* (`promotePrefetchedDocument`) instead of
        // re-requesting, so identical concurrent requests do not arise the
        // way they do for manga chapter prefetch vs. user navigation
        // (see `MangaReaderProjectionLoader`, which opts in).
        loader = ReaderProjectionLoader(
            strategy: ReaderThreadPageProjectionLoadingStrategy(
                adapter: NovelProjectionAdapter(
                    client: client,
                    projectionStore: projectionStore,
                    forumCacheStore: forumCacheStore,
                    offlineCacheStore: offlineCacheStore
                )
            )
        )
    }

    func loadProjection(_ request: NovelPageRequest) async throws -> NovelReaderProjectionLoadedPage {
        try await loadProjection(request, ignoresCache: false)
    }

    func loadProjectionIgnoringCache(_ request: NovelPageRequest) async throws -> NovelReaderProjectionLoadedPage {
        try await loadProjection(request, ignoresCache: true)
    }

    func loadOnlineProjection(
        _ request: NovelPageRequest,
        ignoresCache: Bool
    ) async throws -> ReaderProjectionPreparedSourcePage<NovelReaderProjection, ForumThreadPage> {
        try await loader.loadOnlineOnly(request, ignoresCache: ignoresCache)
    }

    private func loadProjection(
        _ request: NovelPageRequest,
        ignoresCache: Bool
    ) async throws -> NovelReaderProjectionLoadedPage {
        let loaded = try await loader.load(request, ignoresCache: ignoresCache)
        return NovelReaderProjectionLoadedPage(
            projection: loaded.projection,
            sourcePage: loaded.sourcePage,
            source: loaded.source
        )
    }
}

extension NovelPageRequest: ReaderThreadPageProjectionRequesting {}

private struct NovelProjectionIdentity: ReaderThreadPageProjectionIdentifying {
    var threadID: String
    var view: Int
    var authorID: String?
}

private struct NovelProjectionAdapter: ReaderThreadPageProjectionAdapter {
    typealias Request = NovelPageRequest
    typealias Identity = NovelProjectionIdentity
    typealias Projection = NovelReaderProjection

    private static let projectionSchemaVersion = 1

    let client: YamiboClient
    let projectionStore: NovelReaderProjectionStore
    let forumCacheStore: ForumCacheStore
    let offlineCacheStore: (any NovelOfflineCacheStoring)?

    var authorScopeErrorContext: String { "小说作者范围" }

    func makeIdentity(request: NovelPageRequest, authorID: String) -> NovelProjectionIdentity {
        NovelProjectionIdentity(threadID: request.threadID, view: request.view, authorID: authorID)
    }

    func offlineSourcePage(
        for request: NovelPageRequest
    ) async -> ReaderProjectionOfflineSourcePageLoad<NovelProjectionIdentity, ForumThreadPage>? {
        guard let offlineCacheStore else { return nil }
        let normalizedRequestAuthorID = ReaderThreadPageProjectionLoadingStrategy<Self>.normalizedAuthorID(request.authorID)
        guard let sourceSnapshot = await offlineCacheStore.novelOfflineSourcePageSnapshot(
            threadID: request.threadID,
            view: request.view,
            authorID: normalizedRequestAuthorID
        ) else {
            return nil
        }
        let effectiveAuthorID = normalizedRequestAuthorID
            ?? sourceSnapshot.sourcePage.posts.first?.author.uid.flatMap {
                ReaderThreadPageProjectionLoadingStrategy<Self>.normalizedAuthorID($0)
            }
        guard let effectiveAuthorID else { return nil }

        return ReaderProjectionOfflineSourcePageLoad(
            sourcePage: sourceSnapshot.sourcePage,
            identity: NovelProjectionIdentity(
                threadID: request.threadID,
                view: request.view,
                authorID: effectiveAuthorID
            ),
            updatedAt: sourceSnapshot.updatedAt
        )
    }

    func fingerprintIdentityComponents(for identity: NovelProjectionIdentity) -> [String] {
        [
            identity.threadID.trimmingCharacters(in: .whitespacesAndNewlines),
            String(max(1, identity.view)),
            identity.authorID ?? ""
        ]
    }

    func cachedProjection(for identity: NovelProjectionIdentity) async -> NovelReaderProjection? {
        await projectionStore.loadProjection(
            for: NovelPageRequest(threadID: identity.threadID, view: identity.view, authorID: identity.authorID)
        )
    }

    func isReusableProjection(
        _ projection: NovelReaderProjection,
        identity: NovelProjectionIdentity,
        fingerprint: String
    ) -> Bool {
        projection.projectionSchemaVersion == Self.projectionSchemaVersion &&
            projection.projectionSourceFingerprint == fingerprint &&
            !Self.isLegacyCachedProjectionMissingChapterCommentSources(projection)
    }

    func buildProjection(
        sourcePage: ForumThreadPage,
        identity: NovelProjectionIdentity,
        fingerprint: String
    ) throws -> NovelReaderProjection {
        try NovelReaderProjectionBuilder.build(
            from: sourcePage,
            request: NovelPageRequest(threadID: identity.threadID, view: identity.view, authorID: identity.authorID),
            authorID: identity.authorID ?? "",
            projectionSourceFingerprint: fingerprint,
            projectionSchemaVersion: Self.projectionSchemaVersion
        )
    }

    func saveProjection(_ projection: NovelReaderProjection) async throws {
        try await projectionStore.save(projection)
    }

    private static func isLegacyCachedProjectionMissingChapterCommentSources(_ projection: NovelReaderProjection) -> Bool {
        guard projection.retainedChapterCount > 0, !projection.segments.isEmpty else {
            return false
        }
        return !projection.segmentSources.contains { source in
            source?.ownerPostID?.isEmpty == false
        }
    }
}
