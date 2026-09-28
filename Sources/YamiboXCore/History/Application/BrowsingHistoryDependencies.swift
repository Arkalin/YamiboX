import Foundation

/// Shared by history destinations without importing the entire favorites feature package.
public struct BrowsingHistoryDependencies: Sendable {
    public let browsingHistoryStore: BrowsingHistoryStore
    public let browsingHistoryWorkflow: BrowsingHistoryWorkflow
    public let localFavoriteLibraryStore: FavoriteLibraryStore
    public let readingProgressStore: ReadingProgressStore
    public let settingsStore: SettingsStore
    public let contentCoverStore: ContentCoverStore
    public let mangaDirectoryStore: any MangaDirectoryPersisting
    public let makeFavoriteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating

    public init(
        browsingHistoryStore: BrowsingHistoryStore,
        browsingHistoryWorkflow: BrowsingHistoryWorkflow,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        readingProgressStore: ReadingProgressStore,
        settingsStore: SettingsStore,
        contentCoverStore: ContentCoverStore,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        makeFavoriteRepository: @escaping @Sendable () async -> any ForumThreadFavoriteRemoteOperating
    ) {
        self.browsingHistoryStore = browsingHistoryStore
        self.browsingHistoryWorkflow = browsingHistoryWorkflow
        self.localFavoriteLibraryStore = localFavoriteLibraryStore
        self.readingProgressStore = readingProgressStore
        self.settingsStore = settingsStore
        self.contentCoverStore = contentCoverStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.makeFavoriteRepository = makeFavoriteRepository
    }
}
