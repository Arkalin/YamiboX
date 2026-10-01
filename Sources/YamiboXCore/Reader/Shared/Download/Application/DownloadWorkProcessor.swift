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
    private let maxConcurrentImageTransfers: Int
    private let strategy: Strategy

    init(
        store: any DownloadQueueStoring & DownloadImageAssetStoring,
        imageAcquirer: any DownloadImageAcquiring,
        maxConcurrentImageTransfers: Int,
        strategy: Strategy
    ) {
        self.store = store
        self.imageAcquirer = imageAcquirer
        self.maxConcurrentImageTransfers = max(1, maxConcurrentImageTransfers)
        self.strategy = strategy
    }

    func process(
        _ work: DownloadProcessingWork,
        progress: @escaping @Sendable (DownloadWorkProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard try await store.containsDownloadWork(id: work.id) else {
            throw CancellationError()
        }

        let preparedWork = try await strategy.prepare(work)
        try Task.checkCancellation()
        progress(DownloadWorkProgress(
            phase: preparedWork.targetImageURLs.isEmpty ? .saving : .transferring,
            fraction: preparedWork.targetImageURLs.isEmpty ? 0.95 : 0.05
        ))
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
        let tracker = DownloadImageProgressTracker(
            urls: preparedWork.targetImageURLs,
            completed: completedImageURLs,
            report: progress
        )
        tracker.publish()

        if completedImageURLs.count < preparedWork.targetImageURLs.count {
            completedImageURLs = try await transferMissingImages(
                workID: preparedWork.workID,
                refererURL: preparedWork.refererURL,
                targetImageURLs: preparedWork.targetImageURLs,
                completedImageURLs: completedImageURLs,
                tracker: tracker
            )
        }

        try Task.checkCancellation()
        guard try await store.containsDownloadWork(id: preparedWork.workID) else {
            throw CancellationError()
        }
        progress(DownloadWorkProgress(phase: .saving, fraction: 0.95))
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
        completedImageURLs: [URL],
        tracker: DownloadImageProgressTracker
    ) async throws -> [URL] {
        var completedKeys = Set(completedImageURLs.map(\.absoluteString))
        let pending = targetImageURLs.enumerated().filter { !completedKeys.contains($0.element.absoluteString) }

        try await withThrowingTaskGroup(of: DownloadImageTransferResult.self) { group in
            var pendingIterator = pending.makeIterator()
            var activeCount = 0

            func submitNext() {
                guard activeCount < maxConcurrentImageTransfers, let (targetIndex, imageURL) = pendingIterator.next() else {
                    return
                }
                activeCount += 1
                group.addTask { [store, imageAcquirer] in
                    try Task.checkCancellation()
                    guard try await store.containsDownloadWork(id: workID) else {
                        throw CancellationError()
                    }
                    let startedAt = Date()
                    let acquisition = try await imageAcquirer.acquireImageData(
                        for: YamiboImageSource(url: imageURL, refererPageURL: refererURL),
                        progress: { tracker.update(url: imageURL, progress: $0) }
                    )
                    guard !acquisition.data.isEmpty else {
                        throw YamiboError.invalidResponse(statusCode: nil)
                    }
                    try Task.checkCancellation()
                    guard try await store.containsDownloadWork(id: workID) else {
                        throw CancellationError()
                    }
                    try await store.saveOfflineImageData(acquisition.data, for: imageURL)
                    return DownloadImageTransferResult(
                        imageURL: imageURL,
                        targetIndex: targetIndex,
                        bytesPerSecond: Self.bytesPerSecond(byteCount: acquisition.data.count, startedAt: startedAt)
                    )
                }
            }

            for _ in 0..<maxConcurrentImageTransfers {
                submitNext()
            }

            while let result = try await group.next() {
                activeCount -= 1
                try Task.checkCancellation()
                completedKeys.insert(result.imageURL.absoluteString)
                guard try await store.recordCompletedDownloadImage(
                    id: workID, imageURL: result.imageURL, targetIndex: result.targetIndex,
                    currentBytesPerSecond: result.bytesPerSecond
                ) else { throw CancellationError() }
                tracker.finish(url: result.imageURL)
                submitNext()
            }
        }

        return targetImageURLs.filter { completedKeys.contains($0.absoluteString) }
    }

    private static func bytesPerSecond(byteCount: Int, startedAt: Date) -> Int {
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        return max(0, Int(Double(byteCount) / elapsed))
    }
}

private struct DownloadImageTransferResult: Sendable {
    var imageURL: URL
    var targetIndex: Int
    var bytesPerSecond: Int
}

/// Network delegates can run concurrently. Report while holding this private
/// lock so snapshots reach the stream in the same order as the byte updates.
private final class DownloadImageProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private var completed: Set<URL>
    private var transfers: [URL: DownloadTransferProgress] = [:]
    private var completedBytes: Int64 = 0
    private let report: @Sendable (DownloadWorkProgress) -> Void

    init(urls: [URL], completed: [URL], report: @escaping @Sendable (DownloadWorkProgress) -> Void) {
        count = urls.count
        self.completed = Set(completed)
        self.report = report
    }

    func update(url: URL, progress: DownloadTransferProgress) {
        lock.withLock {
            guard !completed.contains(url) else { return }
            transfers[url] = progress
            report(snapshot)
        }
    }

    func finish(url: URL) {
        lock.withLock {
            guard completed.insert(url).inserted else { return }
            if let transfer = transfers.removeValue(forKey: url) {
                completedBytes += max(0, transfer.receivedBytes)
            }
            report(snapshot)
        }
    }

    func publish() { lock.withLock { report(snapshot) } }

    private var snapshot: DownloadWorkProgress {
        let fraction = (Double(completed.count) + transfers.values.reduce(0) { $0 + ($1.fraction ?? 0) })
            / Double(max(1, count))
        return DownloadWorkProgress(
            phase: .transferring,
            fraction: 0.05 + 0.9 * fraction,
            receivedBytes: completedBytes + transfers.values.reduce(0) { $0 + max(0, $1.receivedBytes) },
            hasUnknownLength: transfers.values.contains { $0.fraction == nil }
        )
    }
}
