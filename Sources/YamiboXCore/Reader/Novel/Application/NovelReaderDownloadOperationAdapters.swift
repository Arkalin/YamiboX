import Foundation

struct NovelOfflineStoreReaderDownloadOperationAdapter: NovelReaderDownloadOperationRepository {
    private let store: any NovelDownloadStoring & DownloadQueueStoring
    private let novelDownloadSettings: @Sendable () async -> NovelDownloadSettings
    private let continueDownloadQueue: (@Sendable () async throws -> Void)?

    init(
        store: any NovelDownloadStoring & DownloadQueueStoring,
        novelDownloadSettings: @escaping @Sendable () async -> NovelDownloadSettings = { .init() },
        continueDownloadQueue: (@Sendable () async throws -> Void)? = nil
    ) {
        self.store = store
        self.novelDownloadSettings = novelDownloadSettings
        self.continueDownloadQueue = continueDownloadQueue
    }

    func downloadState(for context: NovelReaderDownloadOperationContext) async -> NovelDownloadViewsSnapshot {
        await store.novelDownloadViewsSnapshot(
            ownerTitle: context.ownerTitle,
            threadID: context.threadID,
            authorID: context.authorID
        )
    }

    func downloadedViews(for context: NovelReaderDownloadOperationContext) async -> Set<Int> {
        await downloadState(for: context).downloadedViews
    }

    func deleteDownloadedViews(
        _ views: Set<Int>,
        for context: NovelReaderDownloadOperationContext
    ) async throws {
        try await store.removeNovelDownloadViews(
            views,
            ownerTitle: context.ownerTitle,
            threadID: context.threadID,
            authorID: context.authorID
        )
    }

    func downloadViews(
        _ views: Set<Int>,
        for context: NovelReaderDownloadOperationContext,
        progress _: (@Sendable (NovelReaderDownloadBatchProgress) async -> Void)?
    ) async -> NovelReaderDownloadBatchResult {
        await enqueue(views, for: context, isUpdate: false)
    }

    func updateDownloadedViews(
        _ views: Set<Int>,
        for context: NovelReaderDownloadOperationContext,
        progress _: (@Sendable (NovelReaderDownloadBatchProgress) async -> Void)?
    ) async -> NovelReaderDownloadBatchResult {
        await enqueue(views, for: context, isUpdate: true)
    }

    private func enqueue(
        _ views: Set<Int>,
        for context: NovelReaderDownloadOperationContext,
        isUpdate: Bool
    ) async -> NovelReaderDownloadBatchResult {
        var submittedViews: [Int] = []
        var failedViews: [Int] = []
        var didEnqueueWork = false
        let settings = await novelDownloadSettings()
        for view in views.sorted() {
            do {
                let request = NovelDownloadWorkRequest(
                    ownerTitle: context.ownerTitle,
                    title: L10n.string("reader.page_number_spaced", view),
                    threadID: context.threadID,
                    view: view,
                    authorID: context.authorID,
                    retainsInlineImages: settings.retainsInlineImages
                )
                let result = try await (isUpdate
                    ? store.enqueueNovelDownloadUpdateWork(request)
                    : store.enqueueNovelDownloadWork(request))
                switch result {
                case .alreadyDownloaded:
                    break
                case .alreadyQueued:
                    submittedViews.append(view)
                case .enqueued:
                    submittedViews.append(view)
                    didEnqueueWork = true
                }
            } catch {
                YamiboLog.download.error("Failed to enqueue novel offline download work for thread \(context.threadID), view \(view): \(error)")
                failedViews.append(view)
            }
        }
        if didEnqueueWork {
            do {
                try await continueDownloadQueueIfAllowed()
            } catch {
                YamiboLog.download.warning("Failed to continue novel offline download queue for thread \(context.threadID) after enqueueing work: \(error)")
                failedViews.append(contentsOf: submittedViews.filter { !failedViews.contains($0) })
            }
        }
        let completedViews = submittedViews.filter { !failedViews.contains($0) }
        return NovelReaderDownloadBatchResult(
            totalCount: views.count,
            completedViews: completedViews,
            failedViews: failedViews,
            wasCancelled: false
        )
    }

    private func continueDownloadQueueIfAllowed() async throws {
        let summary = try await store.downloadQueueSummary(readerKind: nil)
        guard summary.failedCount == 0 else { return }
        try await continueDownloadQueue?()
    }
}
