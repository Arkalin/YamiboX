import Foundation

enum DownloadImageAcquisitionSource: Hashable, Sendable {
    case network
}

struct DownloadImageAcquisition: Hashable, Sendable {
    var data: Data
    var source: DownloadImageAcquisitionSource

    init(data: Data, source: DownloadImageAcquisitionSource) {
        self.data = data
        self.source = source
    }
}

protocol DownloadImageAcquiring: Sendable {
    func acquireImageData(for source: YamiboImageSource) async throws -> DownloadImageAcquisition
}

protocol DownloadImageTransporting: Sendable {
    func downloadImageData(for source: YamiboImageSource) async throws -> Data
}

actor DownloadImageAcquirer: DownloadImageAcquiring {
    private let imagePipeline: any YamiboImageDataLoading
    private let backgroundTransport: (any DownloadImageTransporting)?

    init(
        imagePipeline: any YamiboImageDataLoading = YamiboImagePipeline(),
        backgroundTransport: (any DownloadImageTransporting)? = nil
    ) {
        self.imagePipeline = imagePipeline
        self.backgroundTransport = backgroundTransport
    }

    func acquireImageData(for source: YamiboImageSource) async throws -> DownloadImageAcquisition {
        let data: Data
        if let backgroundTransport {
            data = try await backgroundTransport.downloadImageData(for: source)
        } else {
            data = try await imagePipeline.data(for: source)
        }
        return DownloadImageAcquisition(data: data, source: .network)
    }
}

public actor DownloadQueueExecutor {
    private var identityChangeDepth = 0
    private var resumeAfterIdentityChange = false
    private let store: any DownloadQueueStoring & DownloadImageAssetStoring
    private let runObserver: (any DownloadQueueRunObserving)?
    private let mangaWorkProcessor: DownloadWorkProcessor<MangaDownloadWorkProcessingStrategy>
    private let novelWorkProcessor: DownloadWorkProcessor<NovelDownloadWorkProcessingStrategy>?
    private let attachmentWorkProcessor: ForumAttachmentDownloadProcessor
    private var runTask: Task<Void, Never>?
    private var retiringRuns: [Int: Task<Void, Never>] = [:]
    private var runGeneration = 0
    private var isInvalidated = false
    private var externalCommandCount = 0
    private var externalCommandWaiters: [CheckedContinuation<Void, Never>] = []
    private let isSessionCurrent: @Sendable () async -> Bool

    init(
        store: any DownloadQueueStoring & DownloadImageAssetStoring,
        mangaDownloadStore: any MangaDownloadStoring,
        novelDownloadStore: (any NovelDownloadStoring)? = nil,
        readerProjectionLoader: any MangaReaderProjectionSnapshotLoading,
        novelSourcePageLoader: (any NovelDownloadSourcePageLoading)? = nil,
        imageAcquirer: any DownloadImageAcquiring,
        attachmentWorkProcessor: ForumAttachmentDownloadProcessor,
        runObserver: (any DownloadQueueRunObserving)? = nil,
        maxConcurrentImageTransfers: Int = 3,
        isSessionCurrent: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.store = store
        self.attachmentWorkProcessor = attachmentWorkProcessor
        self.runObserver = runObserver
        self.isSessionCurrent = isSessionCurrent
        let transferLimit = max(1, maxConcurrentImageTransfers)
        self.mangaWorkProcessor = DownloadWorkProcessor(
            store: store,
            imageAcquirer: imageAcquirer,
            runObserver: runObserver,
            maxConcurrentImageTransfers: transferLimit,
            strategy: MangaDownloadWorkProcessingStrategy(
                store: mangaDownloadStore,
                readerProjectionLoader: readerProjectionLoader
            )
        )
        if let novelSourcePageLoader, let novelDownloadStore {
            self.novelWorkProcessor = DownloadWorkProcessor(
                store: store,
                imageAcquirer: imageAcquirer,
                runObserver: runObserver,
                maxConcurrentImageTransfers: transferLimit,
                strategy: NovelDownloadWorkProcessingStrategy(
                    store: novelDownloadStore,
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
        try beginExternalCommand()
        defer { finishExternalCommand() }
        try await ensureExternalCommandAllowed()
        if identityChangeDepth > 0 {
            resumeAfterIdentityChange = true
            return
        }
        guard !deferRunForIdentityChange() else { return }
        try await store.retryFailedDownloadWorks()
        try await ensureExternalCommandAllowed()
        guard !deferRunForIdentityChange() else { return }
        try await store.setDownloadQueueRunState(.running)
        do {
            try await ensureExternalCommandAllowed()
        } catch {
            // Normal invalidation joins this command and performs the final
            // pause. If the transition failed before reaching invalidation,
            // retain the previous rollback rather than publishing a phantom run.
            if !isInvalidated { try await store.setDownloadQueueRunState(.paused) }
            throw error
        }
        guard !deferRunForIdentityChange() else { return }
        if let runTask, !runTask.isCancelled {
            return
        }

        if submitsUserInitiatedRun {
            await runObserver?.submitUserInitiatedRun()
        }
        try await ensureExternalCommandAllowed()
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
        try beginExternalCommand()
        defer { finishExternalCommand() }
        try await ensureExternalCommandAllowed()
        try await pauseQueueForTeardown()
    }

    // Account invalidation sets isInvalidated before it pauses and joins this
    // executor. Keep that teardown path private so retired executors cannot
    // accept ordinary UI mutations while cleanup can still pause the queue.
    private func pauseQueueForTeardown() async throws {
        resumeAfterIdentityChange = false
        cancelActiveRun()
        do {
            try await store.setDownloadQueueRunState(.paused)
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
            let wasRunning = try await store.downloadQueueRunState() == .running
            resumeAfterIdentityChange = resumeAfterIdentityChange || wasRunning || hadRunningTask
            try await store.setDownloadQueueRunState(.paused)
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
            YamiboLog.download.error("Could not resume queue after directory identity change: \(error)")
        }
    }

    func invalidateForAccountChange() async throws {
        isInvalidated = true
        cancelActiveRun()
        // Join admitted UI commands too: a store write already in flight may
        // finish after invalidation, but must finish before the final pause.
        if externalCommandCount > 0 {
            await withCheckedContinuation { externalCommandWaiters.append($0) }
        }
        try await pauseQueueForTeardown()
    }

    /// A factory result rejected before publication has no work to tear down.
    func rejectBeforeUse() {
        isInvalidated = true
    }

    public func cancelChapter(ownerName: String, tid: String) async throws {
        try beginExternalCommand()
        defer { finishExternalCommand() }
        let wasRunning = try await prepareExternalCancellation()
        try await store.cancelDownloadEntry(
            DownloadEntryID(readerKind: .manga, ownerKey: ownerName, entryKey: tid)
        )
        try await ensureExternalCommandAllowed()
        if wasRunning {
            try await continueQueue()
        }
    }

    public func cancelOwnerGroup(ownerName: String) async throws {
        try beginExternalCommand()
        defer { finishExternalCommand() }
        let wasRunning = try await prepareExternalCancellation()
        try await store.cancelDownloadGroup(
            DownloadGroupID(readerKind: .manga, ownerKey: ownerName)
        )
        try await ensureExternalCommandAllowed()
        if wasRunning {
            try await continueQueue()
        }
    }

    public func cancelWork(id: DownloadWorkID) async throws {
        try beginExternalCommand()
        defer { finishExternalCommand() }
        let wasRunning = try await prepareExternalCancellation()
        try await store.cancelDownloadWork(id: id)
        try await ensureExternalCommandAllowed()
        if wasRunning {
            try await continueQueue()
        }
    }

    public func cancelGroup(id: DownloadGroupID) async throws {
        try beginExternalCommand()
        defer { finishExternalCommand() }
        let wasRunning = try await prepareExternalCancellation()
        try await store.cancelDownloadGroup(id)
        try await ensureExternalCommandAllowed()
        if wasRunning {
            try await continueQueue()
        }
    }

    private func prepareExternalCancellation() async throws -> Bool {
        try await ensureExternalCommandAllowed()
        let wasRunning = try await store.downloadQueueRunState() == .running
        try await ensureExternalCommandAllowed()
        cancelActiveRun()
        await runObserver?.queueRunDidCancel()
        await joinRetiringRuns()
        try await ensureExternalCommandAllowed()
        return wasRunning
    }

    private func ensureExternalCommandAllowed() async throws {
        guard !isInvalidated else { throw CancellationError() }
        guard await isSessionCurrent() else { throw CancellationError() }
        guard !isInvalidated else { throw CancellationError() }
    }

    private func beginExternalCommand() throws {
        guard !isInvalidated else { throw CancellationError() }
        externalCommandCount += 1
    }

    private func finishExternalCommand() {
        externalCommandCount -= 1
        guard externalCommandCount == 0 else { return }
        let waiters = externalCommandWaiters
        externalCommandWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    public func waitForIdle() async {
        let task = runTask
        await task?.value
        await joinRetiringRuns()
    }

    private func runQueue(generation: Int) async {
        while !Task.isCancelled {
            var processingWork: DownloadProcessingWork?
            do {
                guard try await store.downloadQueueRunState() == .running else {
                    await runObserver?.queueRunDidFinish(success: false)
                    await finishRun(generation: generation, pauseQueue: false)
                    return
                }
                processingWork = try await store.nextDownloadProcessingWork()
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
                YamiboLog.download.error("Offline download queue run failed: \(error)")
                if let work = processingWork {
                    do {
                        try await store.markDownloadWorkFailed(
                            id: work.id,
                            message: Self.failureMessage(from: error)
                        )
                    } catch {
                        YamiboLog.download.error("Failed to persist offline download work \(work.id.rawValue) failure state: \(error)")
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
                try await store.setDownloadQueueRunState(.paused)
            } catch {
                YamiboLog.download.error("Failed to persist paused offline download queue run state: \(error)")
            }
        }
        guard runGeneration == generation else { return }
        runTask = nil
    }

    private func process(_ work: DownloadProcessingWork) async throws {
        switch work.id.readerKind {
        case .attachment:
            try await store.prepareDownloadWorkForRun(id: work.id, targetImageURLs: nil, completedImageURLs: [])
            await runObserver?.queueRunDidUpdateProgress(completedImageCount: 0, targetImageCount: 1)
            try await attachmentWorkProcessor.process(work)
            await runObserver?.queueRunDidUpdateProgress(completedImageCount: 1, targetImageCount: 1)
        case .manga:
            try await mangaWorkProcessor.process(work)
        case .novel:
            guard let novelWorkProcessor else {
                throw YamiboError.parsingFailed(context: "Novel Download")
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
