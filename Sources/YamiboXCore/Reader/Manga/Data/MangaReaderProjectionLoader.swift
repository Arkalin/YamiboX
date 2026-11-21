import Foundation

actor MangaReaderProjectionLoader: MangaReaderProjectionSnapshotLoading {
    private let loader: ReaderProjectionLoader<ReaderThreadPageProjectionLoadingStrategy<MangaProjectionAdapter>>

    init(
        client: YamiboClient,
        projectionStore: any MangaReaderProjectionPersisting,
        forumCacheStore: ForumCacheStore,
        downloadStore: (any MangaDownloadStoring)? = nil
    ) {
        loader = ReaderProjectionLoader(
            strategy: ReaderThreadPageProjectionLoadingStrategy(
                adapter: MangaProjectionAdapter(
                    client: client,
                    projectionStore: projectionStore,
                    forumCacheStore: forumCacheStore,
                    downloadStore: downloadStore
                )
            ),
            coalescesInFlightRequests: true
        )
    }

    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        try await loadReaderProjectionSnapshot(request).projection
    }

    func loadReaderProjectionSnapshot(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjectionSnapshot {
        try await loadReaderProjectionSnapshot(request, ignoresCache: false)
    }

    func loadReaderProjectionSnapshot(_ request: MangaReaderProjectionRequest, ignoresCache: Bool) async throws -> MangaReaderProjectionSnapshot {
        let loaded = try await loader.load(request, ignoresCache: ignoresCache)
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
    let downloadStore: (any MangaDownloadStoring)?

    var authorScopeErrorContext: String { L10n.string("parsing_context.manga_author_scope") }

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
        guard let downloadStore,
              let membership = await downloadStore.mangaOfflineMembership(for: request) else {
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
}
