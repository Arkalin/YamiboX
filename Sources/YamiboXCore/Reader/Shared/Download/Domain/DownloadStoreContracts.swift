import Foundation

public protocol DownloadUpdateObserving: Sendable {
    func downloadUpdates() -> AsyncStream<Void>
}

public protocol DownloadImageAssetStoring: Sendable {
    func offlineImageData(for imageURL: URL) async -> Data?
    func hasOfflineImage(for imageURL: URL) async -> Bool
    func saveOfflineImageData(_ data: Data, for imageURL: URL) async throws
}

public protocol DownloadManagementStoring: DownloadUpdateObserving {
    func downloadedAttachmentURL(id: DownloadEntryID) async throws -> URL
    func downloadManagementSnapshot() async throws -> DownloadManagementSnapshot
    func downloadedWorks() async -> [DownloadedWork]
    func removeDownloadGroup(_ id: DownloadGroupID) async throws
    func removeDownloadEntry(_ id: DownloadEntryID) async throws
    func totalDiskUsageBytes() async -> Int
    func clearAll() async throws
}

public enum DownloadQueueRunState: String, Codable, Hashable, Sendable {
    case paused
    case running
}

public struct DownloadQueueSummary: Equatable, Sendable {
    public var entryCount: Int
    public var failedCount: Int
    public var runState: DownloadQueueRunState

    public init(entryCount: Int, failedCount: Int, runState: DownloadQueueRunState) {
        self.entryCount = entryCount
        self.failedCount = failedCount
        self.runState = runState
    }
}

public protocol DownloadQueueStoring: DownloadUpdateObserving {
    func downloadQueueWorks() async throws -> [DownloadQueueWorkProjection]
    func downloadQueueSummary(readerKind: DownloadReaderKind?) async throws -> DownloadQueueSummary
    func downloadQueueWorkCount() async throws -> Int
    func containsDownloadWork(id: DownloadWorkID) async throws -> Bool
    func recordCompletedDownloadImage(id: DownloadWorkID, imageURL: URL, targetIndex: Int, currentBytesPerSecond: Int) async throws -> Bool
    func nextDownloadProcessingWork() async throws -> DownloadProcessingWork?
    func downloadProcessingWork(id: DownloadWorkID) async throws -> DownloadProcessingWork?
    func retryFailedDownloadWorks() async throws
    func updateDownloadWorkProgress(
        id: DownloadWorkID,
        targetImageURLs: [URL]?,
        completedImageURLs: [URL],
        currentBytesPerSecond: Int?
    ) async throws
    func prepareDownloadWorkForRun(
        id: DownloadWorkID,
        targetImageURLs: [URL]?,
        completedImageURLs: [URL]
    ) async throws
    func finishDownloadWork(id: DownloadWorkID) async throws
    func markDownloadWorkFailed(id: DownloadWorkID, message: String?) async throws
    func cancelDownloadWork(id: DownloadWorkID) async throws
    func cancelDownloadEntry(_ id: DownloadEntryID) async throws
    func cancelDownloadGroup(_ id: DownloadGroupID) async throws
    func clearDownloadQueue() async throws
    func downloadQueueRunState() async throws -> DownloadQueueRunState
    func setDownloadQueueRunState(_ state: DownloadQueueRunState) async throws
}

public extension DownloadQueueStoring {
    func downloadQueueWorkCount() async throws -> Int { try await downloadQueueWorks().count }
    func containsDownloadWork(id: DownloadWorkID) async throws -> Bool { try await downloadProcessingWork(id: id) != nil }

    func recordCompletedDownloadImage(id: DownloadWorkID, imageURL: URL, targetIndex: Int, currentBytesPerSecond: Int) async throws -> Bool {
        guard let work = try await downloadProcessingWork(id: id),
              work.targetImageURLs.indices.contains(targetIndex), work.targetImageURLs[targetIndex] == imageURL else { return false }
        let keys = Set((work.completedImageURLs + [imageURL]).map(\.absoluteString))
        try await updateDownloadWorkProgress(id: id, targetImageURLs: nil,
            completedImageURLs: work.targetImageURLs.filter { keys.contains($0.absoluteString) }, currentBytesPerSecond: currentBytesPerSecond)
        return true
    }

    func downloadQueueSummary(readerKind: DownloadReaderKind? = nil) async throws -> DownloadQueueSummary {
        let works = try await downloadQueueWorks().filter { readerKind == nil || $0.id.readerKind == readerKind }
        return DownloadQueueSummary(
            entryCount: works.count,
            failedCount: works.filter { $0.state == .failed }.count,
            runState: try await downloadQueueRunState()
        )
    }
}

public protocol DownloadStoreCore:
    DownloadUpdateObserving,
    DownloadImageAssetStoring,
    DownloadQueueStoring,
    DownloadManagementStoring {
    func notifyIdentityMigrationCommitted()
}

public typealias DownloadStoring = DownloadStoreCore
    & ForumAttachmentDownloadStoring
    & MangaDownloadStoring
    & NovelDownloadStoring
    & YamiboOfflineImageDataProviding
