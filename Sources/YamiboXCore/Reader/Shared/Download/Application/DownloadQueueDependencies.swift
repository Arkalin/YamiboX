import Foundation

/// Queue screens need download state, directory labels and queue commands, not account services.
public struct DownloadQueueDependencies: Sendable {
    public let downloadStore: any DownloadQueueStoring
    public let mangaDirectoryStore: any MangaDirectoryPersisting
    public let makeDownloadQueueExecutor: @Sendable () async -> DownloadQueueExecutor

    public init(
        downloadStore: any DownloadQueueStoring,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        makeDownloadQueueExecutor: @escaping @Sendable () async -> DownloadQueueExecutor
    ) {
        self.downloadStore = downloadStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.makeDownloadQueueExecutor = makeDownloadQueueExecutor
    }
}
