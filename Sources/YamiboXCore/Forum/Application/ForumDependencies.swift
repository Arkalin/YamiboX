import Foundation

/// Everything the Forum feature UI (home, boards, search, thread reader,
/// novel/manga detail pages, user space, messaging, blogs, in-app browser)
/// needs from the composition root.
public struct ForumDependencies: Sendable {
    public let sessionStore: SessionStore
    public let profileStore: YamiboProfileStore
    public let localFavoriteLibraryStore: FavoriteLibraryStore
    public let readingProgressStore: ReadingProgressStore
    /// Optional so test/preview compositions without a history database keep
    /// working; the app composition root always supplies one.
    public let browsingHistoryStore: BrowsingHistoryStore?
    public let settingsStore: SettingsStore
    public let contentCoverStore: ContentCoverStore
    public let mangaDirectoryStore: any MangaDirectoryPersisting
    public let mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState
    /// Optional because only the manga detail page's correction flow needs it
    /// (renaming a directory must also rename its offline-cache owner), and
    /// tests/previews shouldn't have to assemble an offline cache store.
    public let mangaOfflineCacheStore: (any MangaOfflineCacheStoring)?
    public let makeForumRepository: @Sendable () async -> ForumRepository
    public let makeForumThreadReaderRepository: @Sendable () async -> ForumThreadReaderRepository
    public let makeUserSpaceRepository: @Sendable () async -> UserSpaceRepository
    public let makeBlogReaderRepository: @Sendable () async -> BlogReaderRepository
    public let makeFavoriteRepository: @Sendable () async -> FavoriteRepository
    public let makeNovelReaderRepository: @Sendable () async -> NovelReaderRepository
    public let makeMangaReaderProjectionLoader: @Sendable () async -> any MangaReaderProjectionSnapshotLoading
    public let makeMangaDirectoryRepository: @Sendable () async -> any MangaDirectoryRepository
    public let makeThreadRouteResolver: @Sendable () async -> YamiboThreadRouteResolver

    public init(
        sessionStore: SessionStore,
        profileStore: YamiboProfileStore,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        readingProgressStore: ReadingProgressStore,
        browsingHistoryStore: BrowsingHistoryStore? = nil,
        settingsStore: SettingsStore,
        contentCoverStore: ContentCoverStore,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState,
        mangaOfflineCacheStore: (any MangaOfflineCacheStoring)? = nil,
        makeForumRepository: @escaping @Sendable () async -> ForumRepository,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> ForumThreadReaderRepository,
        makeUserSpaceRepository: @escaping @Sendable () async -> UserSpaceRepository,
        makeBlogReaderRepository: @escaping @Sendable () async -> BlogReaderRepository,
        makeFavoriteRepository: @escaping @Sendable () async -> FavoriteRepository,
        makeNovelReaderRepository: @escaping @Sendable () async -> NovelReaderRepository,
        makeMangaReaderProjectionLoader: @escaping @Sendable () async -> any MangaReaderProjectionSnapshotLoading,
        makeMangaDirectoryRepository: @escaping @Sendable () async -> any MangaDirectoryRepository,
        makeThreadRouteResolver: @escaping @Sendable () async -> YamiboThreadRouteResolver
    ) {
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.localFavoriteLibraryStore = localFavoriteLibraryStore
        self.readingProgressStore = readingProgressStore
        self.browsingHistoryStore = browsingHistoryStore
        self.settingsStore = settingsStore
        self.contentCoverStore = contentCoverStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.mangaDirectorySearchCooldownState = mangaDirectorySearchCooldownState
        self.mangaOfflineCacheStore = mangaOfflineCacheStore
        self.makeForumRepository = makeForumRepository
        self.makeForumThreadReaderRepository = makeForumThreadReaderRepository
        self.makeUserSpaceRepository = makeUserSpaceRepository
        self.makeBlogReaderRepository = makeBlogReaderRepository
        self.makeFavoriteRepository = makeFavoriteRepository
        self.makeNovelReaderRepository = makeNovelReaderRepository
        self.makeMangaReaderProjectionLoader = makeMangaReaderProjectionLoader
        self.makeMangaDirectoryRepository = makeMangaDirectoryRepository
        self.makeThreadRouteResolver = makeThreadRouteResolver
    }
}
