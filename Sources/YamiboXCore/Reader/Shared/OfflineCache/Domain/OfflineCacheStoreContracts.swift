import Foundation

public protocol OfflineCacheUpdateObserving: Sendable {
    func offlineCacheUpdates() -> AsyncStream<Void>
}

public protocol OfflineCacheImageAssetStoring: Sendable {
    func offlineImageData(for imageURL: URL) async -> Data?
    func saveOfflineImageData(_ data: Data, for imageURL: URL) async throws
}

public protocol OfflineCacheManagementStoring: OfflineCacheUpdateObserving {
    func offlineCacheManagementSnapshot() async -> OfflineCacheManagementSnapshot
    func removeOfflineCacheGroup(_ id: OfflineCacheGroupID) async throws
    func removeOfflineCacheEntry(_ id: OfflineCacheEntryID) async throws
    func totalDiskUsageBytes() async -> Int
    func clearAll() async throws
}

public enum OfflineCacheQueueRunState: String, Codable, Hashable, Sendable {
    case paused
    case running
}

public protocol OfflineCacheQueueStoring: OfflineCacheUpdateObserving {
    func offlineCacheQueueWorks() async -> [OfflineCacheQueueWorkProjection]
    func nextOfflineCacheProcessingWork() async -> OfflineCacheProcessingWork?
    func offlineCacheProcessingWork(id: OfflineCacheWorkID) async -> OfflineCacheProcessingWork?
    func retryFailedOfflineCacheWorks() async throws
    func updateOfflineCacheWorkProgress(
        id: OfflineCacheWorkID,
        targetImageURLs: [URL]?,
        completedImageURLs: [URL],
        currentBytesPerSecond: Int?
    ) async throws
    func prepareOfflineCacheWorkForRun(
        id: OfflineCacheWorkID,
        targetImageURLs: [URL]?,
        completedImageURLs: [URL]
    ) async throws
    func finishOfflineCacheWork(id: OfflineCacheWorkID) async throws
    func markOfflineCacheWorkFailed(id: OfflineCacheWorkID, message: String?) async throws
    func cancelOfflineCacheWork(id: OfflineCacheWorkID) async throws
    func cancelOfflineCacheEntry(_ id: OfflineCacheEntryID) async throws
    func cancelOfflineCacheGroup(_ id: OfflineCacheGroupID) async throws
    func clearOfflineCacheQueue() async throws
    func offlineCacheQueueRunState() async -> OfflineCacheQueueRunState
    func setOfflineCacheQueueRunState(_ state: OfflineCacheQueueRunState) async throws
}

public protocol OfflineCacheStoreCore:
    OfflineCacheUpdateObserving,
    OfflineCacheImageAssetStoring,
    OfflineCacheQueueStoring,
    OfflineCacheManagementStoring {}

/// The full capability surface of the shared offline cache store, as assembled
/// by the composition root and consumed by reader/library/account features.
public typealias OfflineCacheStoring = OfflineCacheStoreCore
    & MangaOfflineCacheStoring
    & NovelOfflineCacheStoring
    & YamiboOfflineImageDataProviding
