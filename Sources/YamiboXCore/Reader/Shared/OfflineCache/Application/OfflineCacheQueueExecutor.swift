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

actor OfflineCacheImageAcquirer: OfflineCacheImageAcquiring {
    private let imagePipeline: any YamiboImageDataLoading
    private let backgroundTransport: (any OfflineCacheImageTransporting)?

    init(
        imagePipeline: any YamiboImageDataLoading = YamiboImagePipeline(),
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
    private var identityChangeDepth = 0
    private var resumeAfterIdentityChange = false
    private let store: any OfflineCacheQueueStoring & OfflineCacheImageAssetStoring
    private let runObserver: (any OfflineCacheQueueRunObserving)?
    private let mangaWorkProcessor: OfflineCacheWorkProcessor<MangaOfflineCacheWorkProcessingStrategy>
    private let novelWorkProcessor: OfflineCacheWorkProcessor<NovelOfflineCacheWorkProcessingStrategy>?
    private var runTask: Task<Void, Never>?
    private var retiringRuns: [Int: Task<Void, Never>] = [:]
    private var runGeneration = 0
    private var isInvalidated = false
    private let isSessionCurrent: @Sendable () async -> Bool

    init(
        store: any OfflineCacheQueueStoring & OfflineCacheImageAssetStoring,
        mangaCacheStore: any MangaOfflineCacheStoring,
        novelCacheStore: (any NovelOfflineCacheStoring)? = nil,
        readerProjectionLoader: any MangaReaderProjectionSnapshotLoading,
        novelSourcePageLoader: (any NovelOfflineCacheSourcePageLoading)? = nil,
        imageAcquirer: any OfflineCacheImageAcquiring,
        runObserver: (any OfflineCacheQueueRunObserving)? = nil,
        maxConcurrentImageTransfers: Int = 3,
        isSessionCurrent: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.store = store
        self.runObserver = runObserver
        self.isSessionCurrent = isSessionCurrent
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
        if identityChangeDepth > 0 {
            resumeAfterIdentityChange = true
            return
        }
        guard !isInvalidated, await isSessionCurrent() else { throw CancellationError() }
        guard !deferRunForIdentityChange() else { return }
        try await store.retryFailedOfflineCacheWorks()
        guard !isInvalidated, await isSessionCurrent() else { throw CancellationError() }
        guard !deferRunForIdentityChange() else { return }
        try await store.setOfflineCacheQueueRunState(.running)
        guard !isInvalidated, await isSessionCurrent() else {
            try await store.setOfflineCacheQueueRunState(.paused)
            throw CancellationError()
        }
        guard !deferRunForIdentityChange() else { return }
        if let runTask, !runTask.isCancelled {
            return
        }

        if submitsUserInitiatedRun {
            await runObserver?.submitUserInitiatedRun()
        }
        guard !isInvalidated, await isSessionCurrent() else { throw CancellationError() }
        guard !deferRunForIdentityChange() else { return }
        // Another continuation may have installed a worker during the awaits.
        guard runTask == nil || runTask?.isCancelled == true else { return }
        runGeneration += 1
        let generation = runGeneration
        runTask = Task { [weak self] in
            await self?.runQueue(generation: generation)
        }
    }

    private func deferRunForIdentityChange() -> Bool {
        guard identityChangeDepth > 0 else { return false }
        resumeAfterIdentityChange = true
        return true
    }

    public func pauseQueue() async throws {
        resumeAfterIdentityChange = false
        cancelActiveRun()
        do {
            try await store.setOfflineCacheQueueRunState(.paused)
            await runObserver?.queueRunDidCancel()
            await joinRetiringRuns()
        } catch {
            await joinRetiringRuns()
            throw error
        }
    }

    private func cancelActiveRun() {
        if let running = runTask {
            running.cancel()
            retiringRuns[runGeneration] = running
        }
        runGeneration += 1
        runTask = nil
    }

    private func joinRetiringRuns() async {
        let runs = retiringRuns
        for (generation, task) in runs {
            await task.value
            retiringRuns.removeValue(forKey: generation)
        }
    }

    /// Cancel and join the worker before any identity references are moved.
    /// Merely clearing runTask would leave a suspended writer alive.
    func suspendForIdentityChange() async throws {
        identityChangeDepth += 1
        guard identityChangeDepth == 1 else { return }
        let hadRunningTask = runTask != nil
        cancelActiveRun()
        do {
            let wasRunning = try await store.offlineCacheQueueRunState() == .running
            resumeAfterIdentityChange = resumeAfterIdentityChange || wasRunning || hadRunningTask
            try await store.setOfflineCacheQueueRunState(.paused)
            await runObserver?.queueRunDidCancel()
            await joinRetiringRuns()
        } catch {
            await joinRetiringRuns()
            identityChangeDepth = 0
            throw error
        }
    }

    func finishIdentityChange() async {
        guard identityChangeDepth > 0 else { return }
        identityChangeDepth -= 1
        guard identityChangeDepth == 0, resumeAfterIdentityChange else { return }
        resumeAfterIdentityChange = false
        do {
            try await continueQueue(submitsUserInitiatedRun: false)
        } catch {
            YamiboLog.offlineCache.error("Could not resume queue after directory identity change: \(error)")
        }
    }

    func invalidateForAccountChange() async throws {
        isInvalidated = true
        try await pauseQueue()
    }

    public func cancelChapter(ownerName: String, tid: String) async throws {
        let wasRunning = try await store.offlineCacheQueueRunState() == .running
        cancelActiveRun()
        await runObserver?.queueRunDidCancel()
        await joinRetiringRuns()
        try await store.cancelOfflineCacheEntry(
            OfflineCacheEntryID(readerKind: .manga, ownerKey: ownerName, entryKey: tid)
        )
        if wasRunning {
            try await continueQueue()
        }
    }

    public func cancelOwnerGroup(ownerName: String) async throws {
        let wasRunning = try await store.offlineCacheQueueRunState() == .running
        cancelActiveRun()
        await runObserver?.queueRunDidCancel()
        await joinRetiringRuns()
        try await store.cancelOfflineCacheGroup(
            OfflineCacheGroupID(readerKind: .manga, ownerKey: ownerName)
        )
        if wasRunning {
            try await continueQueue()
        }
    }

    public func cancelWork(id: OfflineCacheWorkID) async throws {
        let wasRunning = try await store.offlineCacheQueueRunState() == .running
        cancelActiveRun()
        await runObserver?.queueRunDidCancel()
        await joinRetiringRuns()
        try await store.cancelOfflineCacheWork(id: id)
        if wasRunning {
            try await continueQueue()
        }
    }

    public func cancelGroup(id: OfflineCacheGroupID) async throws {
        let wasRunning = try await store.offlineCacheQueueRunState() == .running
        cancelActiveRun()
        await runObserver?.queueRunDidCancel()
        await joinRetiringRuns()
        try await store.cancelOfflineCacheGroup(id)
        if wasRunning {
            try await continueQueue()
        }
    }

    public func waitForIdle() async {
        let task = runTask
        await task?.value
        await joinRetiringRuns()
    }

    private func runQueue(generation: Int) async {
        while !Task.isCancelled {
            var processingWork: OfflineCacheProcessingWork?
            do {
                guard try await store.offlineCacheQueueRunState() == .running else {
                    await runObserver?.queueRunDidFinish(success: false)
                    await finishRun(generation: generation, pauseQueue: false)
                    return
                }
                processingWork = try await store.nextOfflineCacheProcessingWork()
                try Task.checkCancellation()
                guard let work = processingWork else {
                    await runObserver?.queueRunDidFinish(success: true)
                    await finishRun(generation: generation, pauseQueue: true)
                    return
                }
                try await process(work)
            } catch is CancellationError {
                await finishRun(generation: generation, pauseQueue: false)
                return
            } catch {
                guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else {
                    await finishRun(generation: generation, pauseQueue: false)
                    return
                }
                YamiboLog.offlineCache.error("Offline cache queue run failed: \(error)")
                if let work = processingWork {
                    do {
                        try await store.markOfflineCacheWorkFailed(
                            id: work.id,
                            message: Self.failureMessage(from: error)
                        )
                    } catch {
                        YamiboLog.offlineCache.error("Failed to persist offline cache work \(work.id.rawValue) failure state: \(error)")
                    }
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
        guard runGeneration == generation else { return }
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
           let description = localizedError.errorDescription?.nilIfBlank {
            return description
        }
        return error.localizedDescription
    }
}
