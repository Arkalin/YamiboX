import Foundation

/// Queue screens need cache state, directory labels and queue commands, not account services.
public struct OfflineCacheQueueDependencies: Sendable {
    public let offlineCacheStore: any OfflineCacheQueueStoring
    public let mangaDirectoryStore: any MangaDirectoryPersisting
    public let makeOfflineCacheQueueExecutor: @Sendable () async -> OfflineCacheQueueExecutor

    public init(
        offlineCacheStore: any OfflineCacheQueueStoring,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        makeOfflineCacheQueueExecutor: @escaping @Sendable () async -> OfflineCacheQueueExecutor
    ) {
        self.offlineCacheStore = offlineCacheStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.makeOfflineCacheQueueExecutor = makeOfflineCacheQueueExecutor
    }
}
