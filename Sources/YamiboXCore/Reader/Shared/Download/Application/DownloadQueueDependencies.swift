import Foundation

public struct DownloadQueueDependencies: Sendable {
    public let sessionStore: SessionStore
    public let downloadStore: any DownloadQueueStoring
    public let mangaDirectoryStore: any MangaDirectoryPersisting
    public let makeDownloadQueueExecutor: @Sendable () async -> DownloadQueueExecutor

    public init(
        sessionStore: SessionStore,
        downloadStore: any DownloadQueueStoring,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        makeDownloadQueueExecutor: @escaping @Sendable () async -> DownloadQueueExecutor
    ) {
        self.sessionStore = sessionStore
        self.downloadStore = downloadStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.makeDownloadQueueExecutor = makeDownloadQueueExecutor
    }
}
