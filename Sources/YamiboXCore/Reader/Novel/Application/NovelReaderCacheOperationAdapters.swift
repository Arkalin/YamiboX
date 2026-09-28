import Foundation

struct NovelOfflineStoreReaderCacheOperationAdapter: NovelReaderCacheOperationRepository {
    private let store: any NovelOfflineCacheStoring & OfflineCacheQueueStoring
    private let novelOfflineCacheSettings: @Sendable () async -> NovelOfflineCacheSettings
    private let continueOfflineCacheQueue: (@Sendable () async throws -> Void)?

    init(
        store: any NovelOfflineCacheStoring & OfflineCacheQueueStoring,
        novelOfflineCacheSettings: @escaping @Sendable () async -> NovelOfflineCacheSettings = { .init() },
        continueOfflineCacheQueue: (@Sendable () async throws -> Void)? = nil
    ) {
        self.store = store
        self.novelOfflineCacheSettings = novelOfflineCacheSettings
        self.continueOfflineCacheQueue = continueOfflineCacheQueue
    }

    func cacheState(for context: NovelReaderCacheOperationContext) async -> NovelOfflineCacheViewsSnapshot {
        await store.novelOfflineCacheViewsSnapshot(
            ownerTitle: context.ownerTitle,
            threadID: context.threadID,
            authorID: context.authorID
        )
    }

    func cachedViews(for context: NovelReaderCacheOperationContext) async -> Set<Int> {
        await cacheState(for: context).cachedViews
    }

    func deleteCachedViews(
        _ views: Set<Int>,
        for context: NovelReaderCacheOperationContext
    ) async throws {
        try await store.removeNovelOfflineCacheViews(
            views,
            ownerTitle: context.ownerTitle,
            threadID: context.threadID,
            authorID: context.authorID
        )
    }

    func cacheViews(
        _ views: Set<Int>,
        for context: NovelReaderCacheOperationContext,
        progress _: (@Sendable (NovelReaderCacheBatchProgress) async -> Void)?
    ) async -> NovelReaderCacheBatchResult {
        await enqueue(views, for: context, isUpdate: false)
    }

    func updateCachedViews(
        _ views: Set<Int>,
        for context: NovelReaderCacheOperationContext,
        progress _: (@Sendable (NovelReaderCacheBatchProgress) async -> Void)?
    ) async -> NovelReaderCacheBatchResult {
        await enqueue(views, for: context, isUpdate: true)
    }

    private func enqueue(
        _ views: Set<Int>,
        for context: NovelReaderCacheOperationContext,
        isUpdate: Bool
    ) async -> NovelReaderCacheBatchResult {
        var submittedViews: [Int] = []
        var failedViews: [Int] = []
        var didEnqueueWork = false
        let settings = await novelOfflineCacheSettings()
        for view in views.sorted() {
            do {
                let request = NovelOfflineCacheWorkRequest(
                    ownerTitle: context.ownerTitle,
                    title: L10n.string("reader.page_number_spaced", view),
                    threadID: context.threadID,
                    view: view,
                    authorID: context.authorID,
                    retainsInlineImages: settings.retainsInlineImages
                )
                let result = try await (isUpdate
                    ? store.enqueueNovelOfflineCacheUpdateWork(request)
                    : store.enqueueNovelOfflineCacheWork(request))
                switch result {
                case .alreadyCached:
                    break
                case .alreadyQueued:
                    submittedViews.append(view)
                case .enqueued:
                    submittedViews.append(view)
                    didEnqueueWork = true
                }
            } catch {
                YamiboLog.offlineCache.error("Failed to enqueue novel offline cache work for thread \(context.threadID), view \(view): \(error)")
                failedViews.append(view)
            }
        }
        if didEnqueueWork {
            do {
                try await continueOfflineCacheQueueIfAllowed()
            } catch {
                YamiboLog.offlineCache.warning("Failed to continue novel offline cache queue for thread \(context.threadID) after enqueueing work: \(error)")
                failedViews.append(contentsOf: submittedViews.filter { !failedViews.contains($0) })
            }
        }
        let completedViews = submittedViews.filter { !failedViews.contains($0) }
        return NovelReaderCacheBatchResult(
            totalCount: views.count,
            completedViews: completedViews,
            failedViews: failedViews,
            wasCancelled: false
        )
    }

    private func continueOfflineCacheQueueIfAllowed() async throws {
        let works = try await store.offlineCacheQueueWorks()
        guard works.allSatisfy({ $0.state != .failed }) else { return }
        try await continueOfflineCacheQueue?()
    }
}
