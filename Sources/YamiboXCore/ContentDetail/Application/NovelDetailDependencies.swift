import Foundation

/// Stores and repository factories used by the novel detail feature.
public struct NovelDetailDependencies: Sendable {
    public let localFavoriteLibraryStore: FavoriteLibraryStore
    public let readingProgressStore: ReadingProgressStore
    public let settingsStore: SettingsStore
    public let contentCoverStore: ContentCoverStore
    public let makeFavoriteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating
    public let makeNovelReaderRepository: @Sendable () async -> any NovelDetailDocumentLoading
    public let makeForumThreadReaderRepository: @Sendable () async -> any NovelDetailThreadPageLoading

    public init(
        localFavoriteLibraryStore: FavoriteLibraryStore,
        readingProgressStore: ReadingProgressStore,
        settingsStore: SettingsStore,
        contentCoverStore: ContentCoverStore,
        makeFavoriteRepository: @escaping @Sendable () async -> any ForumThreadFavoriteRemoteOperating,
        makeNovelReaderRepository: @escaping @Sendable () async -> any NovelDetailDocumentLoading,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> any NovelDetailThreadPageLoading
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
