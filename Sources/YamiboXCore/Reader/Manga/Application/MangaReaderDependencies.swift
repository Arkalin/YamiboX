import Foundation

public struct MangaReaderDependencies: Sendable {
    public let settingsStore: SettingsStore
    public let readingProgressStore: ReadingProgressStore
    public let browsingHistoryStore: BrowsingHistoryStore
    public let browsingHistoryWorkflow: BrowsingHistoryWorkflow
    public let localFavoriteLibraryStore: FavoriteLibraryStore
    public let mangaDirectoryStore: any MangaDirectoryPersisting
    public let mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState
    public let downloadStore: any DownloadStoring
    public let contentCoverStore: ContentCoverStore
    public let imagePipeline: any YamiboImageDataLoading
    public let makeProjectionLoader: @Sendable () async -> any MangaReaderProjectionLoading
    public let makeDirectoryRepository: @Sendable () async -> any MangaDirectoryRepository
    public let makeChapterCommentsRepository: @Sendable () async -> any ReaderChapterCommentsLoading
    public let makeDownloadQueueExecutor: @Sendable () async -> DownloadQueueExecutor
    public let makeForumThreadReaderRepository: @Sendable () async -> any ThreadCoverPageResolving
    public let downloadQueue: DownloadQueueDependencies
    public let like: LikeDependencies

    public init(
        settingsStore: SettingsStore,
        readingProgressStore: ReadingProgressStore,
        browsingHistoryStore: BrowsingHistoryStore,
        browsingHistoryWorkflow: BrowsingHistoryWorkflow,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState,
        downloadStore: any DownloadStoring,
        contentCoverStore: ContentCoverStore,
        makeProjectionLoader: @escaping @Sendable () async -> any MangaReaderProjectionLoading,
        makeDirectoryRepository: @escaping @Sendable () async -> any MangaDirectoryRepository,
        makeChapterCommentsRepository: @escaping @Sendable () async -> any ReaderChapterCommentsLoading,
        makeDownloadQueueExecutor: @escaping @Sendable () async -> DownloadQueueExecutor,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> any ThreadCoverPageResolving,
        downloadQueue: DownloadQueueDependencies,
        like: LikeDependencies,
        imagePipeline: any YamiboImageDataLoading
    ) {
        self.settingsStore = settingsStore
        self.readingProgressStore = readingProgressStore
        self.browsingHistoryStore = browsingHistoryStore
        self.browsingHistoryWorkflow = browsingHistoryWorkflow
        self.localFavoriteLibraryStore = localFavoriteLibraryStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.mangaDirectorySearchCooldownState = mangaDirectorySearchCooldownState
        self.downloadStore = downloadStore
        self.contentCoverStore = contentCoverStore
        self.imagePipeline = imagePipeline
        self.makeProjectionLoader = makeProjectionLoader
        self.makeDirectoryRepository = makeDirectoryRepository
        self.makeChapterCommentsRepository = makeChapterCommentsRepository
        self.makeDownloadQueueExecutor = makeDownloadQueueExecutor
        self.makeForumThreadReaderRepository = makeForumThreadReaderRepository
        self.downloadQueue = downloadQueue
        self.like = like
    }
}
