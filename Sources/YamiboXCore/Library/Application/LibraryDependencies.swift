import Foundation

/// Dependency package the favorites feature's composition roots use to build
/// their modules. Each module (`FavoriteLibraryOrganizer`,
/// `FavoriteRemoteSyncSession`, `FavoriteUpdateMonitor`,
/// `LocalFavoriteOpenTargetResolver`) declares a narrow initializer taking
/// only the stores it uses; this struct just carries them from the app
/// composition root to those call sites.
public struct LibraryDependencies: Sendable {
    public let localFavoriteLibraryStore: FavoriteLibraryStore
    public let favoriteUpdateStore: FavoriteUpdateStore
    public let favoriteSyncRunStore: FavoriteSyncRunStore
    public let readingProgressStore: ReadingProgressStore
    /// Optional so test/preview compositions without a history database keep
    /// working; the app composition root always supplies one. Feeds the
    /// browsing-history page reached from the Mine tab.
    public let browsingHistoryStore: BrowsingHistoryStore?
    public let settingsStore: SettingsStore
    public let contentCoverStore: ContentCoverStore
    public let mangaDirectoryStore: MangaDirectoryStore
    /// Shared, single-instance cooldown state for the manga-directory search
    /// flow (mirrors `ForumDependencies`' own copy) — the smart-manga update
    /// check lane's `MangaDirectoryWorkflow` must share the same instance the
    /// reader uses, or the two would independently think a just-triggered
    /// forum search is still safe to repeat.
    public let mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState
    public let favoriteBackgroundImageStore: FavoriteBackgroundImageStore
    public let makeFavoriteRepository: @Sendable () async -> FavoriteRepository
    public let makeForumThreadReaderRepository: @Sendable () async -> ForumThreadReaderRepository
    public let makeThreadRouteResolver: @Sendable () async -> YamiboThreadRouteResolver
    public let makeMangaDirectoryRepository: @Sendable () async -> any MangaDirectoryRepository

    public init(
        localFavoriteLibraryStore: FavoriteLibraryStore,
        favoriteUpdateStore: FavoriteUpdateStore,
        favoriteSyncRunStore: FavoriteSyncRunStore,
        readingProgressStore: ReadingProgressStore,
        browsingHistoryStore: BrowsingHistoryStore? = nil,
        settingsStore: SettingsStore,
        contentCoverStore: ContentCoverStore,
        mangaDirectoryStore: MangaDirectoryStore,
        mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState,
        favoriteBackgroundImageStore: FavoriteBackgroundImageStore,
        makeFavoriteRepository: @escaping @Sendable () async -> FavoriteRepository,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> ForumThreadReaderRepository,
        makeThreadRouteResolver: @escaping @Sendable () async -> YamiboThreadRouteResolver,
        makeMangaDirectoryRepository: @escaping @Sendable () async -> any MangaDirectoryRepository
    ) {
        self.localFavoriteLibraryStore = localFavoriteLibraryStore
        self.favoriteUpdateStore = favoriteUpdateStore
        self.favoriteSyncRunStore = favoriteSyncRunStore
        self.readingProgressStore = readingProgressStore
        self.browsingHistoryStore = browsingHistoryStore
        self.settingsStore = settingsStore
        self.contentCoverStore = contentCoverStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.mangaDirectorySearchCooldownState = mangaDirectorySearchCooldownState
        self.favoriteBackgroundImageStore = favoriteBackgroundImageStore
        self.makeFavoriteRepository = makeFavoriteRepository
        self.makeForumThreadReaderRepository = makeForumThreadReaderRepository
        self.makeThreadRouteResolver = makeThreadRouteResolver
        self.makeMangaDirectoryRepository = makeMangaDirectoryRepository
    }
}
