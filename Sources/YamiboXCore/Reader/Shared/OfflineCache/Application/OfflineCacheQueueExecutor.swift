import Foundation

enum OfflineCacheImageAcquisitionSource: Hashable, Sendable {
    case network
}

struct OfflineCacheImageAcquisition: Hashable, Sendable {
    var data: Data
    var source: OfflineCacheImageAcquisitionSource

    init(data: Data, source: OfflineCacheImageAcquisitionSource) {
        self.data = data
        self.source = source
    }
}

protocol OfflineCacheImageAcquiring: Sendable {
    func acquireImageData(for source: YamiboImageSource) async throws -> OfflineCacheImageAcquisition
}

protocol OfflineCacheImageTransporting: Sendable {
    func downloadImageData(for source: YamiboImageSource) async throws -> Data
}

protocol OfflineCacheQueueRunObserving: Sendable {
    func submitUserInitiatedRun() async
    func queueRunDidUpdateProgress(completedImageCount: Int, targetImageCount: Int) async
    func queueRunDidFinish(success: Bool) async
    func queueRunDidCancel() async
}

actor OfflineCacheImageAcquirer: OfflineCacheImageAcquiring {
    private let imagePipeline: YamiboImagePipeline
    private let backgroundTransport: (any OfflineCacheImageTransporting)?

    init(
        imagePipeline: YamiboImagePipeline = .shared,
        backgroundTransport: (any OfflineCacheImageTransporting)? = nil
    ) {
        self.imagePipeline = imagePipeline
        self.backgroundTransport = backgroundTransport
    }

    func acquireImageData(for source: YamiboImageSource) async throws -> OfflineCacheImageAcquisition {
        let data: Data
        if let backgroundTransport {
            data = try await backgroundTransport.downloadImageData(for: source)
        } else {
            data = try await imagePipeline.data(for: source)
        }
        return OfflineCacheImageAcquisition(data: data, source: .network)
    }
}

public actor OfflineCacheQueueExecutor {
    private let store: any OfflineCacheQueueStoring & OfflineCacheImageAssetStoring
    private let runObserver: (any OfflineCacheQueueRunObserving)?
    private let mangaWorkProcessor: OfflineCacheWorkProcessor<MangaOfflineCacheWorkProcessingStrategy>
    private let novelWorkProcessor: OfflineCacheWorkProcessor<NovelOfflineCacheWorkProcessingStrategy>?
    private var runTask: Task<Void, Never>?
    private var runGeneration = 0

    init(
        store: any OfflineCacheQueueStoring & OfflineCacheImageAssetStoring,
        mangaCacheStore: any MangaOfflineCacheStoring,
        novelCacheStore: (any NovelOfflineCacheStoring)? = nil,
        readerProjectionLoader: any MangaReaderProjectionSnapshotLoading,
        novelSourcePageLoader: (any NovelOfflineCacheSourcePageLoading)? = nil,
        imageAcquirer: any OfflineCacheImageAcquiring,
        runObserver: (any OfflineCacheQueueRunObserving)? = nil,
        maxConcurrentImageTransfers: Int = 3
    ) {
        self.store = store
        self.runObserver = runObserver
        let transferLimit = max(1, maxConcurrentImageTransfers)
        self.mangaWorkProcessor = OfflineCacheWorkProcessor(
            store: store,
            imageAcquirer: imageAcquirer,
            runObserver: runObserver,
            maxConcurrentImageTransfers: transferLimit,
            strategy: MangaOfflineCacheWorkProcessingStrategy(
                store: mangaCacheStore,
                readerProjectionLoader: readerProjectionLoader
            )
        )
        if let novelSourcePageLoader, let novelCacheStore {
            self.novelWorkProcessor = OfflineCacheWorkProcessor(
                store: store,
                imageAcquirer: imageAcquirer,
                runObserver: runObserver,
                maxConcurrentImageTransfers: transferLimit,
                strategy: NovelOfflineCacheWorkProcessingStrategy(
                    store: novelCacheStore,
                    sourcePageLoader: novelSourcePageLoader
                )
            )
        } else {
            self.novelWorkProcessor = nil
        }
    }

    public func continueQueue() async throws {
        try await continueQueue(submitsUserInitiatedRun: true)
    }

    public func continueQueue(submitsUserInitiatedRun: Bool) async throws {
        try await store.retryFailedOfflineCacheWorks()
        try await store.setOfflineCacheQueueRunState(.running)
        if let runTask, !runTask.isCancelled {
            return
        }

        if submitsUserInitiatedRun {
            await runObserver?.submitUserInitiatedRun()
        }
        runGeneration += 1
        let generation = runGeneration
        runTask = Task { [weak self] in
            await self?.runQueue(generation: generation)
        }
    }

    public func pauseQueue() async throws {
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        try await store.setOfflineCacheQueueRunState(.paused)
        await runObserver?.queueRunDidCancel()
    }

    public func cancelChapter(ownerName: String, tid: String) async throws {
        let wasRunning = await store.offlineCacheQueueRunState() == .running
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        await runObserver?.queueRunDidCancel()
        try await store.cancelOfflineCacheEntry(
            OfflineCacheEntryID(readerKind: .manga, ownerKey: ownerName, entryKey: tid)
        )
        if wasRunning {
            try await continueQueue()
        }
    }

    public func cancelOwnerGroup(ownerName: String) async throws {
        let wasRunning = await store.offlineCacheQueueRunState() == .running
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        await runObserver?.queueRunDidCancel()
        try await store.cancelOfflineCacheGroup(
            OfflineCacheGroupID(readerKind: .manga, ownerKey: ownerName)
        )
        if wasRunning {
            try await continueQueue()
        }
    }

    public func cancelWork(id: OfflineCacheWorkID) async throws {
        let wasRunning = await store.offlineCacheQueueRunState() == .running
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        await runObserver?.queueRunDidCancel()
        try await store.cancelOfflineCacheWork(id: id)
        if wasRunning {
            try await continueQueue()
        }
    }

    public func cancelGroup(id: OfflineCacheGroupID) async throws {
        let wasRunning = await store.offlineCacheQueueRunState() == .running
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        await runObserver?.queueRunDidCancel()
        try await store.cancelOfflineCacheGroup(id)
        if wasRunning {
            try await continueQueue()
        }
    }

    public func waitForIdle() async {
        let task = runTask
        await task?.value
    }

    private func runQueue(generation: Int) async {
        while !Task.isCancelled {
            guard await store.offlineCacheQueueRunState() == .running else {
                await runObserver?.queueRunDidFinish(success: false)
                await finishRun(generation: generation, pauseQueue: false)
                return
            }

            guard let work = await store.nextOfflineCacheProcessingWork() else {
                await runObserver?.queueRunDidFinish(success: true)
                await finishRun(generation: generation, pauseQueue: true)
                return
            }

            do {
                try await process(work)
            } catch is CancellationError {
                await finishRun(generation: generation, pauseQueue: false)
                return
            } catch {
                do {
                    try await store.markOfflineCacheWorkFailed(
                        id: work.id,
                        message: Self.failureMessage(from: error)
                    )
                } catch {
                    YamiboLog.offlineCache.error("Failed to persist offline cache work \(work.id.rawValue) failure state: \(error)")
                }
                await runObserver?.queueRunDidFinish(success: false)
                await finishRun(generation: generation, pauseQueue: true)
                return
            }
        }

        await runObserver?.queueRunDidFinish(success: false)
        await finishRun(generation: generation, pauseQueue: false)
    }

    private func finishRun(generation: Int, pauseQueue: Bool) async {
        guard runGeneration == generation else { return }
        if pauseQueue {
            do {
                try await store.setOfflineCacheQueueRunState(.paused)
            } catch {
                YamiboLog.offlineCache.error("Failed to persist paused offline cache queue run state: \(error)")
            }
        }
        runTask = nil
    }

    private func process(_ work: OfflineCacheProcessingWork) async throws {
        switch work.id.readerKind {
        case .manga:
            try await mangaWorkProcessor.process(work)
        case .novel:
            guard let novelWorkProcessor else {
                throw YamiboError.parsingFailed(context: "Novel Offline Cache")
            }
            try await novelWorkProcessor.process(work)
        }
    }

    private static func failureMessage(from error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription?.mangaReaderTrimmedNonEmpty {
            return description
        }
        return error.localizedDescription
    }
}
