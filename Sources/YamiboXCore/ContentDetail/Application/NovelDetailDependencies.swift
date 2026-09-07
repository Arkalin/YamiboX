import Foundation

/// Stores and repository factories used by the novel detail feature.
public struct NovelDetailDependencies: Sendable {
    public let localFavoriteLibraryStore: FavoriteLibraryStore
    public let readingProgressStore: ReadingProgressStore
    public let settingsStore: SettingsStore
    public let contentCoverStore: ContentCoverStore
    public let makeFavoriteRepository: @Sendable () async -> FavoriteRepository
    public let makeNovelReaderRepository: @Sendable () async -> NovelReaderRepository
    public let makeForumThreadReaderRepository: @Sendable () async -> ForumThreadReaderRepository

    public init(
        localFavoriteLibraryStore: FavoriteLibraryStore,
        readingProgressStore: ReadingProgressStore,
        settingsStore: SettingsStore,
        contentCoverStore: ContentCoverStore,
        makeFavoriteRepository: @escaping @Sendable () async -> FavoriteRepository,
        makeNovelReaderRepository: @escaping @Sendable () async -> NovelReaderRepository,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> ForumThreadReaderRepository
    ) {
        self.localFavoriteLibraryStore = localFavoriteLibraryStore
        self.readingProgressStore = readingProgressStore
        self.settingsStore = settingsStore
        self.contentCoverStore = contentCoverStore
        self.makeFavoriteRepository = makeFavoriteRepository
        self.makeNovelReaderRepository = makeNovelReaderRepository
        self.makeForumThreadReaderRepository = makeForumThreadReaderRepository
    }
}
