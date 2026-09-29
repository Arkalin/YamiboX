import Foundation

struct DownloadPreparedWork<Payload: Sendable>: Sendable {
    var workID: DownloadWorkID
    var targetImageURLs: [URL]
    var refererURL: URL
    var payload: Payload

    init(
        workID: DownloadWorkID,
        targetImageURLs: [URL],
        refererURL: URL,
        payload: Payload
    ) {
        self.workID = workID
        self.targetImageURLs = targetImageURLs.removingDuplicateURLs()
        self.refererURL = refererURL
        self.payload = payload
    }
}

protocol DownloadWorkProcessingStrategy: Sendable {
    associatedtype Payload: Sendable

    func prepare(_ work: DownloadProcessingWork) async throws -> DownloadPreparedWork<Payload>
    func persistPreparedSource(_ preparedWork: DownloadPreparedWork<Payload>) async throws
    func finish(_ preparedWork: DownloadPreparedWork<Payload>) async throws
}

struct DownloadWorkProcessor<Strategy: DownloadWorkProcessingStrategy>: Sendable {
    private let store: any DownloadQueueStoring & DownloadImageAssetStoring
    private let imageAcquirer: any DownloadImageAcquiring
    private let runObserver: (any DownloadQueueRunObserving)?
    private let maxConcurrentImageTransfers: Int
    private let strategy: Strategy

    init(
        store: any DownloadQueueStoring & DownloadImageAssetStoring,
        imageAcquirer: any DownloadImageAcquiring,
        runObserver: (any DownloadQueueRunObserving)? = nil,
        maxConcurrentImageTransfers: Int,
        strategy: Strategy
    ) {
        self.store = store
        self.imageAcquirer = imageAcquirer
        self.runObserver = runObserver
        self.maxConcurrentImageTransfers = max(1, maxConcurrentImageTransfers)
        self.strategy = strategy
    }

    func process(_ work: DownloadProcessingWork) async throws {
        try Task.checkCancellation()
        guard try await store.downloadProcessingWork(id: work.id) != nil else {
            throw CancellationError()
        }

        let preparedWork = try await strategy.prepare(work)
        try await strategy.persistPreparedSource(preparedWork)

        guard !preparedWork.targetImageURLs.isEmpty else {
            try await strategy.finish(preparedWork)
            return
        }

        var completedImageURLs = await reconciledCompletedImageURLs(preparedWork.targetImageURLs)
        try await store.prepareDownloadWorkForRun(
            id: preparedWork.workID,
            targetImageURLs: preparedWork.targetImageURLs,
            completedImageURLs: completedImageURLs
        )
        await runObserver?.queueRunDidUpdateProgress(
            completedImageCount: completedImageURLs.count,
            targetImageCount: preparedWork.targetImageURLs.count
        )

        if completedImageURLs.count < preparedWork.targetImageURLs.count {
            completedImageURLs = try await transferMissingImages(
                workID: preparedWork.workID,
                refererURL: preparedWork.refererURL,
                targetImageURLs: preparedWork.targetImageURLs,
                completedImageURLs: completedImageURLs
            )
        }

        try Task.checkCancellation()
        guard try await store.downloadProcessingWork(id: preparedWork.workID) != nil else {
            throw CancellationError()
        }
        try await strategy.finish(preparedWork)
    }

    private func reconciledCompletedImageURLs(_ targetImageURLs: [URL]) async -> [URL] {
        var completed: [URL] = []
        for imageURL in targetImageURLs {
            // Existence check only — loading the image bytes here would read
            // every already-downloaded image of the work into memory per run.
            if await store.hasOfflineImage(for: imageURL) {
                completed.append(imageURL)
            }
        }
        return completed
    }

    private func transferMissingImages(
        workID: DownloadWorkID,
        refererURL: URL,
        targetImageURLs: [URL],
        completedImageURLs: [URL]
    ) async throws -> [URL] {
        var completedKeys = Set(completedImageURLs.map(\.absoluteString))
        var completed = targetImageURLs.filter { completedKeys.contains($0.absoluteString) }
        let pending = targetImageURLs.filter { !completedKeys.contains($0.absoluteString) }

        try await withThrowingTaskGroup(of: DownloadImageTransferResult.self) { group in
            var pendingIterator = pending.makeIterator()
            var activeCount = 0

            func submitNext() {
                guard activeCount < maxConcurrentImageTransfers, let imageURL = pendingIterator.next() else {
                    return
                }
                activeCount += 1
                group.addTask { [store, imageAcquirer] in
                    try Task.checkCancellation()
                    guard try await store.downloadProcessingWork(id: workID) != nil else {
                        throw CancellationError()
                    }
                    let startedAt = Date()
                    let acquisition = try await imageAcquirer.acquireImageData(
                        for: YamiboImageSource(url: imageURL, refererPageURL: refererURL)
                    )
                    guard !acquisition.data.isEmpty else {
                        throw YamiboError.invalidResponse(statusCode: nil)
                    }
                    try Task.checkCancellation()
                    guard try await store.downloadProcessingWork(id: workID) != nil else {
                        throw CancellationError()
                    }
                    try await store.saveOfflineImageData(acquisition.data, for: imageURL)
                    return DownloadImageTransferResult(
                        imageURL: imageURL,
                        bytesPerSecond: Self.bytesPerSecond(byteCount: acquisition.data.count, startedAt: startedAt)
                    )
                }
            }

            for _ in 0..<maxConcurrentImageTransfers {
                submitNext()
            }

            while let result = try await group.next() {
                activeCount -= 1
                completedKeys.insert(result.imageURL.absoluteString)
                completed = targetImageURLs.filter { completedKeys.contains($0.absoluteString) }
                try await store.updateDownloadWorkProgress(
                    id: workID,
                    targetImageURLs: targetImageURLs,
                    completedImageURLs: completed,
                    currentBytesPerSecond: result.bytesPerSecond
                )
                await runObserver?.queueRunDidUpdateProgress(
                    completedImageCount: completed.count,
                    targetImageCount: targetImageURLs.count
                )
                submitNext()
            }
        }

        return completed
    }

    private static func bytesPerSecond(byteCount: Int, startedAt: Date) -> Int {
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        return max(0, Int(Double(byteCount) / elapsed))
    }
}

private struct DownloadImageTransferResult: Sendable {
    var imageURL: URL
    var bytesPerSecond: Int
}
