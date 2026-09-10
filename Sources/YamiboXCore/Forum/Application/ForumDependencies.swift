import Foundation

/// Everything the Forum feature UI (home, boards, search, thread reader,
/// user space, messaging, blogs, in-app browser) needs from the composition
/// root, plus dependency packages for the detail destinations it opens.
public struct ForumDependencies: Sendable {
    public let sessionStore: SessionStore
    public let profileStore: YamiboProfileStore
    public let messageUnreadWorkflow: MessageUnreadWorkflow?
    public let localFavoriteLibraryStore: FavoriteLibraryStore
    public let readingProgressStore: ReadingProgressStore
    /// Optional so test/preview compositions without a history database keep
    /// working; the app composition root always supplies one.
    public let browsingHistoryStore: BrowsingHistoryStore?
    public let browsingHistoryWorkflow: BrowsingHistoryWorkflow?
    public let settingsStore: SettingsStore
    public let contentCoverStore: ContentCoverStore
    public let mangaDirectoryStore: any MangaDirectoryPersisting
    public let novelDetailDependencies: NovelDetailDependencies
    public let mangaDetailDependencies: MangaDetailDependencies
    public let makeForumRepository: @Sendable () async -> ForumRepository
    public let makePageRepository: @Sendable () async -> ForumPageRepository
    public let makeForumThreadReaderRepository: @Sendable () async -> ForumThreadReaderRepository
    public let makeUserSpaceRepository: @Sendable () async -> UserSpaceRepository
    public let makeBlogReaderRepository: @Sendable () async -> BlogReaderRepository
    public let makeFavoriteRepository: @Sendable () async -> FavoriteRepository
    public let makeThreadRouteResolver: @Sendable () async -> YamiboThreadRouteResolver

    public init(
        sessionStore: SessionStore,
        profileStore: YamiboProfileStore,
        messageUnreadWorkflow: MessageUnreadWorkflow? = nil,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        readingProgressStore: ReadingProgressStore,
        browsingHistoryStore: BrowsingHistoryStore? = nil,
        browsingHistoryWorkflow: BrowsingHistoryWorkflow? = nil,
        settingsStore: SettingsStore,
        contentCoverStore: ContentCoverStore,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        novelDetailDependencies: NovelDetailDependencies,
        mangaDetailDependencies: MangaDetailDependencies,
        makeForumRepository: @escaping @Sendable () async -> ForumRepository,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> ForumThreadReaderRepository,
        makeUserSpaceRepository: @escaping @Sendable () async -> UserSpaceRepository,
        makeBlogReaderRepository: @escaping @Sendable () async -> BlogReaderRepository,
        makeFavoriteRepository: @escaping @Sendable () async -> FavoriteRepository,
        makeThreadRouteResolver: @escaping @Sendable () async -> YamiboThreadRouteResolver
    ) {
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.messageUnreadWorkflow = messageUnreadWorkflow
        self.localFavoriteLibraryStore = localFavoriteLibraryStore
        self.readingProgressStore = readingProgressStore
        self.browsingHistoryStore = browsingHistoryStore
        self.browsingHistoryWorkflow = browsingHistoryWorkflow
        self.settingsStore = settingsStore
        self.contentCoverStore = contentCoverStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.novelDetailDependencies = novelDetailDependencies
        self.mangaDetailDependencies = mangaDetailDependencies
        self.makeForumRepository = makeForumRepository
        self.makePageRepository = {
            let repository = await makeForumRepository()
            return await repository.pageRepository()
        }
        self.makeForumThreadReaderRepository = makeForumThreadReaderRepository
        self.makeUserSpaceRepository = makeUserSpaceRepository
        self.makeBlogReaderRepository = makeBlogReaderRepository
        self.makeFavoriteRepository = makeFavoriteRepository
        self.makeThreadRouteResolver = makeThreadRouteResolver
    }
}
