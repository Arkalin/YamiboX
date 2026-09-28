import Foundation

/// Everything the Forum feature UI (home, boards, search, thread reader,
/// user space, messaging, blogs, in-app browser) needs from the composition
/// root. Cross-feature destination packages belong to ForumNavigationDependencies.
public struct ForumDependencies: Sendable {
    public var history: BrowsingHistoryDependencies {
        BrowsingHistoryDependencies(
            browsingHistoryStore: browsingHistoryStore,
            browsingHistoryWorkflow: browsingHistoryWorkflow,
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            settingsStore: settingsStore,
            contentCoverStore: contentCoverStore,
            mangaDirectoryStore: mangaDirectoryStore,
            makeFavoriteRepository: makeFavoriteRepository
        )
    }

    public let sessionStore: SessionStore
    public let profileStore: YamiboProfileStore
    public let messageUnreadWorkflow: MessageUnreadWorkflow
    public let localFavoriteLibraryStore: FavoriteLibraryStore
    public let readingProgressStore: ReadingProgressStore
    /// Shared with the other reader surfaces, including in test compositions.
    public let browsingHistoryStore: BrowsingHistoryStore
    public let browsingHistoryWorkflow: BrowsingHistoryWorkflow
    public let composerDraftStore: any ForumComposerDraftPersisting
    public let settingsStore: SettingsStore
    public let contentCoverStore: ContentCoverStore
    public let mangaDirectoryStore: any MangaDirectoryPersisting
    public let makeHomeRepository: @Sendable () async -> any ForumHomePageLoading
    public let makeBoardRepository: @Sendable () async -> any ForumBoardPageLoading
    public let makeSearchRepository: @Sendable () async -> any ForumSearchPageLoading
    public let makePageRepository: @Sendable () async -> any ForumPageLoading
    public let makeForumThreadReaderRepository: @Sendable () async -> any ForumThreadPageLoading
    public let makeUserSpaceRepository: @Sendable () async -> any ForumUserSpacePageLoading
    public let makeBlogReaderRepository: @Sendable () async -> any BlogReaderPageLoading
    public let makeFavoriteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating
    public let makeThreadRouteResolver: @Sendable () async -> YamiboThreadRouteResolver

    public init(
        sessionStore: SessionStore,
        profileStore: YamiboProfileStore,
        messageUnreadWorkflow: MessageUnreadWorkflow,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        readingProgressStore: ReadingProgressStore,
        browsingHistoryStore: BrowsingHistoryStore,
        browsingHistoryWorkflow: BrowsingHistoryWorkflow,
        composerDraftStore: any ForumComposerDraftPersisting,
        settingsStore: SettingsStore,
        contentCoverStore: ContentCoverStore,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        makeHomeRepository: @escaping @Sendable () async -> any ForumHomePageLoading,
        makeBoardRepository: @escaping @Sendable () async -> any ForumBoardPageLoading,
        makeSearchRepository: @escaping @Sendable () async -> any ForumSearchPageLoading,
        makePageRepository: @escaping @Sendable () async -> any ForumPageLoading,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> any ForumThreadPageLoading,
        makeUserSpaceRepository: @escaping @Sendable () async -> any ForumUserSpacePageLoading,
        makeBlogReaderRepository: @escaping @Sendable () async -> any BlogReaderPageLoading,
        makeFavoriteRepository: @escaping @Sendable () async -> any ForumThreadFavoriteRemoteOperating,
        makeThreadRouteResolver: @escaping @Sendable () async -> YamiboThreadRouteResolver
    ) {
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.messageUnreadWorkflow = messageUnreadWorkflow
        self.localFavoriteLibraryStore = localFavoriteLibraryStore
        self.readingProgressStore = readingProgressStore
        self.browsingHistoryStore = browsingHistoryStore
        self.browsingHistoryWorkflow = browsingHistoryWorkflow
        self.composerDraftStore = composerDraftStore
        self.settingsStore = settingsStore
        self.contentCoverStore = contentCoverStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.makeHomeRepository = makeHomeRepository
        self.makeBoardRepository = makeBoardRepository
        self.makeSearchRepository = makeSearchRepository
        self.makePageRepository = makePageRepository
        self.makeForumThreadReaderRepository = makeForumThreadReaderRepository
        self.makeUserSpaceRepository = makeUserSpaceRepository
        self.makeBlogReaderRepository = makeBlogReaderRepository
        self.makeFavoriteRepository = makeFavoriteRepository
        self.makeThreadRouteResolver = makeThreadRouteResolver
    }
}
