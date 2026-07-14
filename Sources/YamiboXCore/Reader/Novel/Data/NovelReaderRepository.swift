import Foundation

public actor NovelReaderRepository {
    private let client: YamiboClient
    private let cacheStore: NovelReaderProjectionStore
    private let forumCacheStore: ForumCacheStore
    private let offlineCacheStore: (any NovelOfflineCacheStoring)?
    private let projectionLoader: NovelReaderProjectionLoader
    private let novelOfflineAutoRefreshEnabled: @Sendable () async -> Bool
    private let novelOfflineRetainsInlineImages: @Sendable () async -> Bool

    init(
        client: YamiboClient,
        cacheStore: NovelReaderProjectionStore = NovelReaderProjectionStore(),
        forumCacheStore: ForumCacheStore = ForumCacheStore(),
        offlineCacheStore: (any NovelOfflineCacheStoring)? = nil,
        projectionLoader: NovelReaderProjectionLoader? = nil,
        novelOfflineAutoRefreshEnabled: @escaping @Sendable () async -> Bool = { true },
        novelOfflineRetainsInlineImages: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.client = client
        self.cacheStore = cacheStore
        self.forumCacheStore = forumCacheStore
        self.offlineCacheStore = offlineCacheStore
        self.projectionLoader = projectionLoader ?? NovelReaderProjectionLoader(
            client: client,
            projectionStore: cacheStore,
            forumCacheStore: forumCacheStore,
            offlineCacheStore: offlineCacheStore
        )
        self.novelOfflineAutoRefreshEnabled = novelOfflineAutoRefreshEnabled
        self.novelOfflineRetainsInlineImages = novelOfflineRetainsInlineImages
    }

    public func loadPage(_ request: NovelPageRequest) async throws -> NovelReaderProjection {
        try await loadPageResult(request).projection
    }

    public func loadPageResult(_ request: NovelPageRequest) async throws -> NovelReaderProjectionLoad {
        try await loadPage(request, ignoresCache: false)
    }

    public func loadPage(threadID: String, view: Int, authorID: String? = nil) async throws -> NovelReaderProjection {
        try await loadPage(NovelPageRequest(threadID: threadID, view: view, authorID: authorID))
    }

    public func prefetchNextPage(from request: NovelPageRequest) async {
        let current: NovelReaderProjection
        do {
            current = try await loadPage(request)
        } catch {
            return
        }

        guard current.view < current.maxView else { return }

        let nextRequest = NovelPageRequest(
            threadID: request.threadID,
            view: current.view + 1,
            authorID: current.resolvedAuthorID ?? request.authorID
        )
        _ = try? await loadPage(nextRequest)
    }

    public func cachedViews(
        for threadID: String,
        authorID: String?
    ) async -> Set<Int> {
        let normalizedThreadID = Self.normalizedThreadID(threadID)
        let projectionViews = await cacheStore.cachedViews(for: normalizedThreadID, authorID: authorID)
        guard let normalizedAuthorID = normalizedAuthorID(authorID) else {
            return projectionViews
        }
        let thread = ThreadIdentity(tid: normalizedThreadID)
        let sourceViews = await forumCacheStore.cachedThreadPageViews(thread: thread, authorID: normalizedAuthorID)
        return projectionViews.intersection(sourceViews)
    }

    public func deleteCachedViews(
        _ views: Set<Int>,
        for threadID: String,
        authorID: String?
    ) async throws {
        let normalizedThreadID = Self.normalizedThreadID(threadID)
        try await cacheStore.deleteViews(views, for: normalizedThreadID, authorID: authorID)
        if let normalizedAuthorID = normalizedAuthorID(authorID) {
            let thread = ThreadIdentity(tid: normalizedThreadID)
            try await forumCacheStore.deleteThreadPages(views, thread: thread, authorID: normalizedAuthorID)
        }
    }

    public func refreshCachedViews(
        _ views: Set<Int>,
        for threadID: String,
        authorID: String?
    ) async throws {
        let normalizedThreadID = Self.normalizedThreadID(threadID)
        let targets = views.isEmpty
            ? await cachedViews(for: normalizedThreadID, authorID: authorID)
            : views
        try await cacheStore.deleteViews(targets, for: normalizedThreadID, authorID: authorID)
        if let authorID = normalizedAuthorID(authorID) {
            let thread = ThreadIdentity(tid: normalizedThreadID)
            try await forumCacheStore.deleteThreadPages(targets, thread: thread, authorID: authorID)
        }
        for view in targets.sorted() {
            let request = NovelPageRequest(threadID: normalizedThreadID, view: view, authorID: authorID)
            _ = try await loadPageIgnoringCache(request)
        }
    }

    public func cacheViews(
        _ views: Set<Int>,
        for threadID: String,
        authorID: String?,
        progress: (@Sendable (NovelReaderCacheBatchProgress) async -> Void)? = nil
    ) async -> NovelReaderCacheBatchResult {
        let normalizedThreadID = Self.normalizedThreadID(threadID)
        let targets = views.sorted()
        guard !targets.isEmpty else {
            let result = NovelReaderCacheBatchResult(totalCount: 0, completedViews: [], failedViews: [], wasCancelled: false)
            await progress?(NovelReaderCacheBatchProgress(
                totalCount: 0,
                completedCount: 0,
                currentView: nil,
                completedViews: [],
                failedViews: [],
                status: .completed
            ))
            return result
        }

        var completedViews: [Int] = []
        var failedViews: [Int] = []
        var wasCancelled = false

        for view in targets {
            if Task.isCancelled {
                wasCancelled = true
                break
            }

            let request = NovelPageRequest(threadID: normalizedThreadID, view: view, authorID: authorID)
            do {
                _ = try await loadPageIgnoringCache(request)
                completedViews.append(view)
            } catch is CancellationError {
                wasCancelled = true
                break
            } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                wasCancelled = true
                break
            } catch {
                failedViews.append(view)
            }

            await progress?(NovelReaderCacheBatchProgress(
                totalCount: targets.count,
                completedCount: completedViews.count,
                currentView: view,
                completedViews: completedViews,
                failedViews: failedViews,
                status: .running
            ))
        }

        let status: NovelReaderCacheBatchProgress.Status = wasCancelled ? .cancelled : .completed
        let result = NovelReaderCacheBatchResult(
            totalCount: targets.count,
            completedViews: completedViews,
            failedViews: failedViews,
            wasCancelled: wasCancelled
        )
        await progress?(NovelReaderCacheBatchProgress(
            totalCount: targets.count,
            completedCount: completedViews.count,
            currentView: nil,
            completedViews: completedViews,
            failedViews: failedViews,
            status: status
        ))
        return result
    }

    public func loadPageIgnoringCache(_ request: NovelPageRequest) async throws -> NovelReaderProjection {
        try await loadPageIgnoringCacheResult(request).projection
    }

    public func loadPageIgnoringCacheResult(_ request: NovelPageRequest) async throws -> NovelReaderProjectionLoad {
        try await loadPage(request, ignoresCache: true)
    }

    public func loadPageIgnoringCache(threadID: String, view: Int, authorID: String? = nil) async throws -> NovelReaderProjection {
        try await loadPageIgnoringCache(NovelPageRequest(threadID: threadID, view: view, authorID: authorID))
    }

    public func loadNovelOfflineCacheSourcePage(
        _ request: NovelOfflineCacheWorkRequest
    ) async throws -> NovelOfflineCachePreparedSourcePage {
        let readerRequest = NovelPageRequest(
            threadID: request.threadID,
            view: request.view,
            authorID: request.authorID
        )
        let onlinePage = try await projectionLoader.loadOnlineProjection(readerRequest, ignoresCache: true)
        return NovelOfflineCachePreparedSourcePage(
            sourcePage: onlinePage.sourcePage,
            projection: onlinePage.projection
        )
    }

    public func fetchThreadDisplayTitle(threadID: String, authorID: String? = nil) async throws -> String {
        let html = try await client.fetchThreadById(tid: threadID, authorID: authorID, page: 1)
        guard let title = YamiboHTMLPageInspector.pageTitle(from: html) else {
            throw YamiboError.parsingFailed(context: L10n.string("context.thread_title"))
        }
        return title
    }

    private func loadPage(_ request: NovelPageRequest, ignoresCache: Bool) async throws -> NovelReaderProjectionLoad {
        let loaded = ignoresCache
            ? try await projectionLoader.loadProjectionIgnoringCache(request)
            : try await projectionLoader.loadProjection(request)
        if case let .online(sourceLoadedOnline) = loaded.source {
            await autoRefreshNovelOfflineCacheIfNeeded(loaded, sourceLoadedOnline: sourceLoadedOnline)
            return NovelReaderProjectionLoad(projection: loaded.projection, source: .online)
        }
        if case let .offlineFallback(updatedAt) = loaded.source {
            return NovelReaderProjectionLoad(
                projection: loaded.projection,
                source: .offlineFallback(updatedAt: updatedAt)
            )
        }
        return NovelReaderProjectionLoad(projection: loaded.projection, source: .online)
    }

    private func autoRefreshNovelOfflineCacheIfNeeded(
        _ onlinePage: NovelReaderProjectionLoadedPage,
        sourceLoadedOnline: Bool
    ) async {
        guard sourceLoadedOnline,
              let offlineCacheStore,
              await novelOfflineAutoRefreshEnabled(),
              let authorID = normalizedAuthorID(onlinePage.projection.resolvedAuthorID) else {
            return
        }
        guard let existing = await offlineCacheStore.novelOfflineSourcePageSnapshot(
            threadID: onlinePage.projection.threadID,
            view: onlinePage.projection.view,
            authorID: authorID
        ) else {
            return
        }
        let retainsInlineImages = await novelOfflineRetainsInlineImages()
        let targetImageURLs = retainsInlineImages ? Self.inlineImageURLs(in: onlinePage.projection) : []
        let request = NovelOfflineCacheWorkRequest(
            ownerTitle: existing.ownerTitle,
            title: NovelOfflineCacheEntry.defaultTitle(document: onlinePage.projection),
            threadID: onlinePage.projection.threadID,
            view: onlinePage.projection.view,
            authorID: authorID,
            targetImageURLs: targetImageURLs,
            retainsInlineImages: retainsInlineImages
        )
        do {
            try await offlineCacheStore.saveNovelOfflineSourcePage(
                onlinePage.sourcePage,
                request: request,
                updatedAt: .now,
                completesMatchingWork: targetImageURLs.isEmpty,
                preservesExistingImageReferencesWhenEmpty: !retainsInlineImages
            )
        } catch {
            YamiboLog.offlineCache.error("Failed to save auto-refreshed novel offline source page for thread \(onlinePage.projection.threadID), view \(onlinePage.projection.view): \(error)")
        }
        guard retainsInlineImages, !targetImageURLs.isEmpty else { return }
        do {
            _ = try await offlineCacheStore.enqueueNovelOfflineCacheUpdateWork(request)
        } catch {
            YamiboLog.offlineCache.warning("Failed to enqueue novel offline cache update work for thread \(onlinePage.projection.threadID), view \(onlinePage.projection.view): \(error)")
        }
    }

    private static func inlineImageURLs(in document: NovelReaderProjection) -> [URL] {
        var seen: Set<String> = []
        var urls: [URL] = []
        for segment in document.segments {
            guard case let .image(url, _) = segment else { continue }
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    private func normalizedAuthorID(_ authorID: String?) -> String? {
        let value = authorID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func normalizedThreadID(_ threadID: String) -> String {
        let value = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!value.isEmpty, "NovelReaderRepository requires a Yamibo thread tid")
        return value
    }

}

extension NovelReaderRepository: NovelOfflineCacheSourcePageLoading {}
