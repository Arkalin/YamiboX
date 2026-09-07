import Foundation

/// Stores and repository factories used by the manga detail feature.
public struct MangaDetailDependencies: Sendable {
    public let localFavoriteLibraryStore: FavoriteLibraryStore
    public let readingProgressStore: ReadingProgressStore
    public let settingsStore: SettingsStore
    public let contentCoverStore: ContentCoverStore
    public let mangaDirectoryStore: any MangaDirectoryPersisting
    public let mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState
    /// Directory corrections also rename the offline-cache owner when present.
    public let mangaOfflineCacheStore: (any MangaOfflineCacheStoring)?
    public let makeFavoriteRepository: @Sendable () async -> FavoriteRepository
    public let makeForumThreadReaderRepository: @Sendable () async -> ForumThreadReaderRepository
    public let makeMangaReaderProjectionLoader: @Sendable () async -> any MangaReaderProjectionSnapshotLoading
    public let makeMangaDirectoryRepository: @Sendable () async -> any MangaDirectoryRepository

    public init(
        localFavoriteLibraryStore: FavoriteLibraryStore,
        readingProgressStore: ReadingProgressStore,
        settingsStore: SettingsStore,
        contentCoverStore: ContentCoverStore,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState,
        mangaOfflineCacheStore: (any MangaOfflineCacheStoring)? = nil,
        makeFavoriteRepository: @escaping @Sendable () async -> FavoriteRepository,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> ForumThreadReaderRepository,
        makeMangaReaderProjectionLoader: @escaping @Sendable () async -> any MangaReaderProjectionSnapshotLoading,
        makeMangaDirectoryRepository: @escaping @Sendable () async -> any MangaDirectoryRepository
    ) {
        self.localFavoriteLibraryStore = localFavoriteLibraryStore
        self.readingProgressStore = readingProgressStore
        self.settingsStore = settingsStore
        self.contentCoverStore = contentCoverStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.mangaDirectorySearchCooldownState = mangaDirectorySearchCooldownState
        self.mangaOfflineCacheStore = mangaOfflineCacheStore
        self.makeFavoriteRepository = makeFavoriteRepository
        self.makeForumThreadReaderRepository = makeForumThreadReaderRepository
        self.makeMangaReaderProjectionLoader = makeMangaReaderProjectionLoader
        self.makeMangaDirectoryRepository = makeMangaDirectoryRepository
    }
}
