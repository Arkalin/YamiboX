import Foundation

actor MangaReaderProjectionLoader: MangaReaderProjectionSnapshotLoading {
    private let loader: ReaderProjectionLoader<ReaderThreadPageProjectionLoadingStrategy<MangaProjectionAdapter>>

    init(
        client: YamiboClient,
        projectionStore: any MangaReaderProjectionPersisting,
        forumCacheStore: ForumCacheStore,
        offlineCacheStore: (any MangaOfflineCacheStoring)? = nil
    ) {
        loader = ReaderProjectionLoader(
            strategy: ReaderThreadPageProjectionLoadingStrategy(
                adapter: MangaProjectionAdapter(
                    client: client,
                    projectionStore: projectionStore,
                    forumCacheStore: forumCacheStore,
                    offlineCacheStore: offlineCacheStore
                )
            ),
            // Manga chapter requests race within one reader session:
            // `MangaReaderWorkflow.prefetchAdjacentChaptersIfNeeded` fetches an
            // adjacent chapter opportunistically while user navigation
            // (`jumpToAdjacentChapter`/`jumpToPosition`) may request the same
            // chapter identity concurrently. Coalescing lets navigation await
            // the in-flight prefetch instead of duplicating the thread-page
            // fetch and projection build. (The novel loader keeps the default
            // `false`; see `NovelReaderProjectionLoader`.)
            coalescesInFlightRequests: true
        )
    }

    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        try await loadReaderProjectionSnapshot(request).projection
    }

    func loadReaderProjectionSnapshot(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjectionSnapshot {
        let loaded = try await loader.load(request, ignoresCache: false)
        return MangaReaderProjectionSnapshot(projection: loaded.projection, sourcePage: loaded.sourcePage)
    }

    func loadReaderProjectionIgnoringCache(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        try await loader.load(request, ignoresCache: true).projection
    }
}

extension MangaReaderProjectionRequest: ReaderThreadPageProjectionRequesting {}

extension MangaReaderProjectionSourceIdentity: ReaderThreadPageProjectionIdentifying {
    var threadID: String { tid }
}

private struct MangaProjectionAdapter: ReaderThreadPageProjectionAdapter {
    typealias Request = MangaReaderProjectionRequest
    typealias Identity = MangaReaderProjectionSourceIdentity
    typealias Projection = MangaReaderProjection

    let client: YamiboClient
    let projectionStore: any MangaReaderProjectionPersisting
    let forumCacheStore: ForumCacheStore
    let offlineCacheStore: (any MangaOfflineCacheStoring)?

    var authorScopeErrorContext: String { "漫画作者范围" }

    func makeIdentity(request: MangaReaderProjectionRequest, authorID: String) -> MangaReaderProjectionSourceIdentity {
        MangaReaderProjectionSourceIdentity(
            tid: request.threadID,
            authorID: authorID,
            view: request.view
        )
    }

    func offlineSourcePage(
        for request: MangaReaderProjectionRequest
    ) async -> ReaderProjectionOfflineSourcePageLoad<MangaReaderProjectionSourceIdentity, ForumThreadPage>? {
        guard let offlineCacheStore,
              let ownerName = request.offlineOwnerName?.mangaReaderTrimmedNonEmpty,
              let membership = await offlineCacheStore.mangaOfflineCacheMembership(ownerName: ownerName, tid: request.threadID),
              membership.tid == request.threadID,
              membership.sourcePage.thread.tid == request.threadID,
              sourcePageMatchesRequestedView(membership.sourcePage, view: request.view) else {
            return nil
        }

        let authorID = ReaderThreadPageProjectionLoadingStrategy<Self>.normalizedAuthorID(request.authorID)
            ?? membership.sourcePage.posts.first?.author.uid.flatMap {
                ReaderThreadPageProjectionLoadingStrategy<Self>.normalizedAuthorID($0)
            }
        guard let authorID else { return nil }

        return ReaderProjectionOfflineSourcePageLoad(
            sourcePage: membership.sourcePage,
            identity: makeIdentity(request: request, authorID: authorID),
            updatedAt: nil
        )
    }

    func fingerprintIdentityComponents(for identity: MangaReaderProjectionSourceIdentity) -> [String] {
        [
            identity.tid,
            identity.authorID ?? "",
            String(identity.view)
        ]
    }

    func cachedProjection(for identity: MangaReaderProjectionSourceIdentity) async -> MangaReaderProjection? {
        await projectionStore.projection(for: identity)
    }

    func isReusableProjection(
        _ projection: MangaReaderProjection,
        identity: MangaReaderProjectionSourceIdentity,
        fingerprint: String
    ) -> Bool {
        projection.sourceIdentity == identity &&
            projection.sourceFingerprint == fingerprint &&
            projection.schemaVersion == MangaReaderProjection.schemaVersion &&
            projection.parserVersion == MangaReaderProjection.parserVersion &&
            !projection.imageURLs.isEmpty
    }

    func buildProjection(
        sourcePage: ForumThreadPage,
        identity: MangaReaderProjectionSourceIdentity,
        fingerprint: String
    ) throws -> MangaReaderProjection {
        try MangaReaderProjectionBuilder.build(
            from: sourcePage,
            identity: identity,
            sourceFingerprint: fingerprint
        )
    }

    func saveProjection(_ projection: MangaReaderProjection) async throws {
        try await projectionStore.save(projection)
    }

    private func sourcePageMatchesRequestedView(_ sourcePage: ForumThreadPage, view: Int) -> Bool {
        guard let currentPage = sourcePage.pageNavigation?.currentPage else { return true }
        return currentPage == max(1, view)
    }
}
