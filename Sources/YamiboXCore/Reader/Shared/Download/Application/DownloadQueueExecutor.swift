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
    func acquireImageData(
        for source: YamiboImageSource,
        progress: @escaping @Sendable (DownloadTransferProgress) -> Void
    ) async throws -> DownloadImageAcquisition
}

protocol DownloadImageTransporting: Sendable {
    func downloadImageData(
        for source: YamiboImageSource,
        progress: @escaping @Sendable (DownloadTransferProgress) -> Void
    ) async throws -> Data
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

    func acquireImageData(
        for source: YamiboImageSource,
        progress: @escaping @Sendable (DownloadTransferProgress) -> Void
    ) async throws -> DownloadImageAcquisition {
        let data: Data
        if let backgroundTransport {
            data = try await backgroundTransport.downloadImageData(for: source, progress: progress)
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
    private var isFinishingRun = false
    private var retiringRuns: [Int: Task<Void, Never>] = [:]
    private var runGeneration = 0
    private var runID: DownloadRunID?
    private var completedWorkCount = 0
    private var remainingWorkCount = 0
    private var currentTitle = ""
    private var currentProgress = DownloadWorkProgress()
    private var lastProgressLog: ContinuousClock.Instant?
    private var isInvalidated = false
    private var externalCommandCount = 0
    private var externalCommandWaiters: [CheckedContinuation<Void, Never>] = []
    private var commandIsActive = false
    private var commandAdmissionWaiters: [CheckedContinuation<Void, Never>] = []
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
        try await beginExternalCommand()
        defer { finishExternalCommand() }
        try await continueQueueAfterAdmission(submitsUserInitiatedRun: submitsUserInitiatedRun)
    }

    private func continueQueueAfterAdmission(submitsUserInitiatedRun: Bool) async throws {
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
            try await refreshRunProgress(generation: runGeneration)
            if isFinishingRun || self.runTask == nil {
                // A new enqueue/Continue may overlap the last worker's pause
                // write. Join that write before publishing another running state.
                await runTask.value
                try await continueQueueAfterAdmission(submitsUserInitiatedRun: submitsUserInitiatedRun)
            }
            return
        }

        // Publish worker ownership before the first suspension involved in
        // background submission. Concurrent Continue commands reuse this worker.
        let startsSystemTask = runID == nil && submitsUserInitiatedRun
        if runID == nil {
            runID = DownloadRunID()
            completedWorkCount = 0
            lastProgressLog = nil
        }
        currentTitle = ""
        currentProgress = DownloadWorkProgress()
        runGeneration += 1
        let generation = runGeneration
        runTask = Task { [weak self] in
            await self?.runQueue(generation: generation, startsSystemTask: startsSystemTask)
        }
    }

    private func deferRunForIdentityChange() -> Bool {
        guard identityChangeDepth > 0 else { return false }
        resumeAfterIdentityChange = true
        return true
    }

    public func pauseQueue() async throws {
        try await beginExternalCommand()
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
        await endSession(success: false)
        do {
            try await store.setDownloadQueueRunState(.paused)
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
        isFinishingRun = false
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
            await joinRetiringRuns()
        } catch {
            await joinRetiringRuns()
            identityChangeDepth = 0
            await endSession(success: false)
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
            await endSession(success: false)
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
        try await cancelSelection {
            try await self.store.cancelDownloadEntry(
                DownloadEntryID(readerKind: .manga, ownerKey: ownerName, entryKey: tid)
            )
        }
    }

    public func cancelOwnerGroup(ownerName: String) async throws {
        try await cancelSelection {
            try await self.store.cancelDownloadGroup(
                DownloadGroupID(readerKind: .manga, ownerKey: ownerName)
            )
        }
    }

    public func cancelWork(id: DownloadWorkID) async throws {
        try await cancelSelection { try await self.store.cancelDownloadWork(id: id) }
    }

    public func cancelGroup(id: DownloadGroupID) async throws {
        try await cancelSelection { try await self.store.cancelDownloadGroup(id) }
    }

    private func cancelSelection(_ remove: () async throws -> Void) async throws {
        try await beginExternalCommand()
        defer { finishExternalCommand() }
        try await ensureExternalCommandAllowed()
        do {
            let wasRunning = try await store.downloadQueueRunState() == .running
            try await ensureExternalCommandAllowed()
            cancelActiveRun()
            await joinRetiringRuns()
            try await ensureExternalCommandAllowed()
            try await remove()
            try await ensureExternalCommandAllowed()
            if wasRunning {
                // Removing an item keeps the logical run and its completed
                // count, but never manufactures another user-initiated request.
                try await continueQueueAfterAdmission(submitsUserInitiatedRun: false)
            } else {
                await endSession(success: false)
            }
        } catch {
            await endSession(success: false)
            throw error
        }
    }

    private func ensureExternalCommandAllowed() async throws {
        guard !isInvalidated else { throw CancellationError() }
        guard await isSessionCurrent() else { throw CancellationError() }
        guard !isInvalidated else { throw CancellationError() }
    }

    private func beginExternalCommand() async throws {
        guard !isInvalidated else { throw CancellationError() }
        externalCommandCount += 1
        if commandIsActive {
            await withCheckedContinuation { commandAdmissionWaiters.append($0) }
        }
        commandIsActive = true
    }

    private func finishExternalCommand() {
        externalCommandCount -= 1
        if commandAdmissionWaiters.isEmpty {
            commandIsActive = false
        } else {
            commandAdmissionWaiters.removeFirst().resume()
        }
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

    private func runQueue(generation: Int, startsSystemTask: Bool) async {
        do {
            try await refreshRunProgress(generation: generation)
            try checkRun(generation)
            if startsSystemTask, remainingWorkCount > 0, let id = runID {
                await runObserver?.queueRunDidStart(id: id, progress: progressSnapshot) { [weak self] in
                    await self?.pauseRun(id: id)
                }
                try checkRun(generation)
            }
        } catch {
            await finishRun(generation: generation, pauseQueue: true)
            return
        }

        while !Task.isCancelled {
            var processingWork: DownloadProcessingWork?
            do {
                guard try await store.downloadQueueRunState() == .running else {
                    await finishRun(generation: generation, pauseQueue: false)
                    return
                }
                try checkRun(generation)
                processingWork = try await store.nextDownloadProcessingWork()
                try checkRun(generation)
                guard let work = processingWork else {
                    await finishRun(generation: generation, pauseQueue: true, success: completedWorkCount > 0)
                    return
                }
                currentTitle = work.title
                currentProgress = DownloadWorkProgress()
                try await refreshRunProgress(generation: generation)
                try checkRun(generation)
                try await process(work, generation: generation)
                try checkRun(generation)
                completedWorkCount += 1
                currentTitle = ""
                currentProgress = DownloadWorkProgress()
                try await refreshRunProgress(generation: generation)
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
                            id: work.id, message: Self.failureMessage(from: error)
                        )
                    } catch {
                        YamiboLog.download.error("Failed to persist download failure: \(error)")
                    }
                }
                await finishRun(generation: generation, pauseQueue: true)
                return
            }
        }
        await finishRun(generation: generation, pauseQueue: false)
    }

    private func checkRun(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == runGeneration, !isInvalidated else { throw CancellationError() }
    }

    private var progressSnapshot: DownloadQueueRunProgress {
        DownloadQueueRunProgress(
            completedWorkCount: completedWorkCount,
            totalWorkCount: completedWorkCount + remainingWorkCount,
            currentTitle: currentTitle,
            phase: currentProgress.phase,
            currentWorkFraction: currentProgress.fraction,
            receivedBytes: currentProgress.receivedBytes,
            hasUnknownLength: currentProgress.hasUnknownLength
        )
    }

    private func refreshRunProgress(generation: Int) async throws {
        let count = try await store.downloadQueueWorkCount()
        try checkRun(generation)
        remainingWorkCount = count
        if let id = runID {
            await runObserver?.queueRunDidUpdateProgress(id: id, progress: progressSnapshot)
        }
    }

    private func receiveProgress(_ progress: DownloadWorkProgress, generation: Int) async {
        guard generation == runGeneration, let id = runID else { return }
        let now = ContinuousClock.now
        if currentProgress.phase != progress.phase || lastProgressLog.map({ now - $0 >= .seconds(1) }) != false {
            lastProgressLog = now
            YamiboLog.download.debug("Download run \(id.rawValue): \(self.completedWorkCount)/\(self.completedWorkCount + self.remainingWorkCount) items, current fraction \(progress.fraction), bytes \(progress.receivedBytes), unknown length \(progress.hasUnknownLength)")
        }
        currentProgress = progress
        await runObserver?.queueRunDidUpdateProgress(id: id, progress: progressSnapshot)
    }

    private func pauseRun(id: DownloadRunID) async {
        do {
            try await beginExternalCommand()
            defer { finishExternalCommand() }
            guard runID == id, !isInvalidated else { return }
            // No session lookup/await between identity validation and cancellation.
            try await pauseQueueForTeardown()
        }
        catch { YamiboLog.download.error("Could not persist expired download pause: \(error)") }
    }

    private func endSession(success: Bool) async {
        guard let id = runID else { return }
        runID = nil
        YamiboLog.download.info("Download queue run \(id.rawValue) finished, success: \(success), completed items: \(self.completedWorkCount)")
        await runObserver?.queueRunDidFinish(id: id, success: success)
    }

    private func finishRun(generation: Int, pauseQueue: Bool, success: Bool = false) async {
        guard runGeneration == generation else { return }
        isFinishingRun = true
        var completedSuccessfully = success
        if pauseQueue {
            do {
                try await store.setDownloadQueueRunState(.paused)
            } catch {
                completedSuccessfully = false
                YamiboLog.download.error("Failed to persist paused download queue: \(error)")
            }
        }
        guard runGeneration == generation else { return }
        runTask = nil
        isFinishingRun = false
        await endSession(success: completedSuccessfully)
    }

    private func process(_ work: DownloadProcessingWork, generation: Int) async throws {
        // A single ordered consumer avoids spawning an unbounded number of
        // actor tasks for URLSession's synchronous byte callbacks.
        let (updates, continuation) = AsyncStream<DownloadWorkProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task {
            for await progress in updates {
                await receiveProgress(progress, generation: generation)
            }
        }
        let report: @Sendable (DownloadWorkProgress) -> Void = { continuation.yield($0) }
        do {
            switch work.id.readerKind {
            case .attachment:
                try await store.prepareDownloadWorkForRun(id: work.id, targetImageURLs: nil, completedImageURLs: [])
                try await attachmentWorkProcessor.process(work, progress: report)
            case .manga:
                try await mangaWorkProcessor.process(work, progress: report)
            case .novel:
                guard let novelWorkProcessor else {
                    throw YamiboError.parsingFailed(context: "Novel Download")
                }
                try await novelWorkProcessor.process(work, progress: report)
            }
            continuation.finish()
            await consumer.value
        } catch {
            continuation.finish()
            await consumer.value
            throw error
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
