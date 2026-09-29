import Foundation

public protocol DownloadUpdateObserving: Sendable {
    func downloadUpdates() -> AsyncStream<Void>
}

public protocol DownloadImageAssetStoring: Sendable {
    func offlineImageData(for imageURL: URL) async -> Data?
    /// Whether a downloaded copy of `imageURL` exists, without loading its bytes.
    /// "Is this image already downloaded?" checks used to go through
    /// `offlineImageData(for:)`, which reads the entire file into memory just
    /// to discard it — per image, per reconciliation pass.
    func hasOfflineImage(for imageURL: URL) async -> Bool
    func saveOfflineImageData(_ data: Data, for imageURL: URL) async throws
}

public protocol DownloadManagementStoring: DownloadUpdateObserving {
    func downloadedAttachmentURL(id: DownloadEntryID) async throws -> URL
    func downloadManagementSnapshot() async throws -> DownloadManagementSnapshot
    /// A read-only, work-level projection for entry surfaces. Unlike the
    /// management snapshot, this excludes queued and failed download work.
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

public protocol DownloadQueueStoring: DownloadUpdateObserving {
    /// Empty means no work, never a failed database read or queue recovery.
    func downloadQueueWorks() async throws -> [DownloadQueueWorkProjection]
    /// Nil means absent work, never a failed read or queue recovery.
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

public protocol DownloadStoreCore:
    DownloadUpdateObserving,
    DownloadImageAssetStoring,
    DownloadQueueStoring,
    DownloadManagementStoring {
    /// Called after the shared identity transaction commits. Wrappers must forward
    /// this invalidation to the same stream consumed by their observers.
    func notifyIdentityMigrationCommitted()
}

/// The full capability surface of the shared offline download store, as assembled
/// by the composition root and consumed by reader/library/account features.
public typealias DownloadStoring = DownloadStoreCore
    & ForumAttachmentDownloadStoring
    & MangaDownloadStoring
    & NovelDownloadStoring
    & YamiboOfflineImageDataProviding
