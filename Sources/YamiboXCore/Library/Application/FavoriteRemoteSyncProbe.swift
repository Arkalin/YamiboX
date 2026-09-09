import Foundation

/// Repository composition for a single sync run. The UI owns the run's task,
/// while classification, metadata, covers and add-token reuse stay in Core.
public extension FavoriteYamiboSyncClient {
    init(
        repository: FavoriteRepository,
        resolver: YamiboThreadRouteResolver,
        coverRepository: ForumThreadReaderRepository,
        contentCoverStore: ContentCoverStore
    ) {
        let probe = FavoriteRemoteSyncProbe(
            resolve: { try await resolver.resolveForFavoriteSync($0) },
            repository: coverRepository,
            saveCover: { url, target in
                guard let key = ContentCoverKey(target: target) else { return }
                _ = try await contentCoverStore.setAutomaticCover(url, for: key)
            }
        )
        let formHash = FavoriteSyncFormHashStore()
        self.init(
            fetchPage: { page in
                let result = try await repository.fetchFavoritesPage(page: page)
                return FavoriteYamiboRemotePage(
                    entries: result.favorites.map {
                        YamiboRemoteFavoriteEntry(
                            remoteFavoriteID: $0.remoteFavoriteID ?? $0.id,
                            threadID: $0.threadID,
                            title: $0.title
                        )
                    },
                    currentPage: result.currentPage,
                    totalPages: result.totalPages
                )
            },
            probe: { try await probe.probe($0) },
            addFavorite: { threadID in
                let token = try await formHash.value(repository: repository)
                _ = try await repository.addThreadFavorite(
                    threadID: threadID, formHash: token, resolveRemoteFavorite: false
                )
            }
        )
    }
}

/// One attempt only: the engine owns retry policy for the whole probe so
/// nested metadata retries cannot multiply requests or erase their errors.
struct FavoriteRemoteSyncProbe: Sendable {
    var resolve: @Sendable (YamiboThreadRouteRequest) async throws -> YamiboThreadRouteTarget
    var repository: any ThreadCoverPageResolving
    var saveCover: @Sendable (URL, FavoriteItemTarget) async throws -> Void

    func probe(_ entry: YamiboRemoteFavoriteEntry) async throws -> FavoriteThreadProbeResult {
        try Task.checkCancellation()
        let url = YamiboRoute.threadByID(tid: entry.threadID, page: 1, authorID: nil, reverse: false).url
        let route = try await resolve(YamiboThreadRouteRequest(threadURL: url, title: entry.title))
        let payload: YamiboThreadRoutePayload
        let target: FavoriteItemTarget
        let authorID: String?
        switch route {
        case let .novel(resolved):
            payload = resolved
            target = .novelThread(threadID: resolved.thread.tid)
            authorID = resolved.authorID
        case let .manga(resolved), let .mangaDirect(resolved):
            // Smart Comic Mode changes presentation, never the favorite's
            // thread identity or its original per-chapter title.
            payload = resolved
            target = .mangaThread(threadID: resolved.thread.tid)
            authorID = nil
        case let .thread(resolved):
            payload = resolved
            target = .normalThread(threadID: resolved.thread.tid)
            authorID = nil
        case let .webFallback(fallbackURL):
            let canonicalURL = YamiboThreadURLCanonicalizer.canonicalThreadURL(from: fallbackURL)
            guard let threadID = YamiboThreadURLCanonicalizer.threadID(from: canonicalURL) else {
                throw FavoriteActionError.missingFavoriteThreadID
            }
            payload = YamiboThreadRoutePayload(
                thread: ThreadIdentity(tid: threadID), title: entry.title ?? "",
                canonicalURL: canonicalURL, requestedURL: fallbackURL
            )
            target = .normalThread(threadID: threadID)
            authorID = nil
        }

        try Task.checkCancellation()
        let page: ForumThreadPage
        if let cached = await repository.cachedThreadPage(
            thread: payload.thread, title: payload.title, authorID: nil, page: 1
        ) {
            page = cached
        } else {
            page = try await repository.fetchThreadPage(
                thread: payload.thread, title: payload.title, authorID: nil, page: 1
            )
        }
        try Task.checkCancellation()

        let forumID = page.forumID ?? page.thread.fid
        let sourceGroup: FavoriteSourceGroup = if let forumID, !forumID.isEmpty {
            .forumBoard(id: forumID, label: page.forumName ?? forumID)
        } else {
            .unknown
        }
        let coverURL = ThreadCoverResolver.findThreadCoverCandidate(in: page)
        if let coverURL {
            do {
                try await saveCover(coverURL, target)
            } catch {
                try Task.checkCancellation()
                if LoadDiagnosticError.isCancellation(error) { throw error }
                YamiboLog.sync.warning("Failed to persist automatic cover during sync for thread \(entry.threadID): \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()
        return FavoriteThreadProbeResult(
            target: target,
            title: payload.title,
            sourceGroup: sourceGroup,
            coverURL: coverURL,
            contentUpdatedAt: page.posts.first.flatMap {
                FavoriteContentUpdateDateResolver.date(lastEditedText: $0.lastEditedText, postedAtText: $0.postedAtText)
            },
            authorID: authorID
        )
    }
}

private actor FavoriteSyncFormHashStore {
    private var cached: String?

    func value(repository: FavoriteRepository) async throws -> String {
        if let cached { return cached }
        let value = try await repository.currentFormHash()
        cached = value
        return value
    }
}
