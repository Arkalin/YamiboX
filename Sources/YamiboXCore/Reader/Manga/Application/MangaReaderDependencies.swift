import Foundation

/// Everything the manga reader feature UI (reader, directory panel, offline
/// cache sheet) needs from the composition root.
public struct MangaReaderDependencies: Sendable {
    public let settingsStore: SettingsStore
    public let readingProgressStore: ReadingProgressStore
    /// Optional so test/preview compositions without a history database keep
    /// working; the app composition root always supplies one.
    public let browsingHistoryStore: BrowsingHistoryStore?
    public let localFavoriteLibraryStore: FavoriteLibraryStore
    public let mangaDirectoryStore: any MangaDirectoryPersisting
    public let mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState
    public let offlineCacheStore: any OfflineCacheStoring
    public let contentCoverStore: ContentCoverStore
    public let makeProjectionLoader: @Sendable () async -> any MangaReaderProjectionSnapshotLoading
    public let makeDirectoryRepository: @Sendable () async -> any MangaDirectoryRepository
    public let makeChapterCommentsRepository: @Sendable () async -> ReaderChapterCommentsRepository
    public let makeOfflineCacheQueueExecutor: @Sendable () async -> OfflineCacheQueueExecutor
    /// Smart Comic Mode off (design decision #16): the reader reuses
    /// `ThreadCoverResolver` to auto-resolve a `.thread(tid:)` cover for the
    /// chapter being read, the same mechanism
    /// `ForumThreadReaderViewModel`/`ForumNovelDetailViewModel` already use
    /// for normal threads — this is what drives it.
    public let makeForumThreadReaderRepository: @Sendable () async -> ForumThreadReaderRepository
    /// The cache sheet embeds the account feature's offline queue view model.
    public let account: AccountDependencies
    public let like: LikeDependencies

    public init(
        settingsStore: SettingsStore,
        readingProgressStore: ReadingProgressStore,
        browsingHistoryStore: BrowsingHistoryStore? = nil,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState,
        offlineCacheStore: any OfflineCacheStoring,
        contentCoverStore: ContentCoverStore,
        makeProjectionLoader: @escaping @Sendable () async -> any MangaReaderProjectionSnapshotLoading,
        makeDirectoryRepository: @escaping @Sendable () async -> any MangaDirectoryRepository,
        makeChapterCommentsRepository: @escaping @Sendable () async -> ReaderChapterCommentsRepository,
        makeOfflineCacheQueueExecutor: @escaping @Sendable () async -> OfflineCacheQueueExecutor,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> ForumThreadReaderRepository,
        account: AccountDependencies,
        like: LikeDependencies
    ) {
        self.settingsStore = settingsStore
        self.readingProgressStore = readingProgressStore
        self.browsingHistoryStore = browsingHistoryStore
        self.localFavoriteLibraryStore = localFavoriteLibraryStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.mangaDirectorySearchCooldownState = mangaDirectorySearchCooldownState
        self.offlineCacheStore = offlineCacheStore
        self.contentCoverStore = contentCoverStore
        self.makeProjectionLoader = makeProjectionLoader
        self.makeDirectoryRepository = makeDirectoryRepository
        self.makeChapterCommentsRepository = makeChapterCommentsRepository
        self.makeOfflineCacheQueueExecutor = makeOfflineCacheQueueExecutor
        self.makeForumThreadReaderRepository = makeForumThreadReaderRepository
        self.account = account
        self.like = like
    }
}
