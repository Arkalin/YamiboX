import Foundation

/// Everything the novel reader feature UI (reader, offline cache panel)
/// needs from the composition root.
public struct NovelReaderDependencies: Sendable {
    public let sessionStore: SessionStore
    public let settingsStore: SettingsStore
    public let readingProgressStore: ReadingProgressStore
    /// Optional so test/preview compositions without a history database keep
    /// working; the app composition root always supplies one.
    public let browsingHistoryStore: BrowsingHistoryStore?
    public let offlineCacheStore: any OfflineCacheStoring
    public let contentCoverStore: ContentCoverStore
    public let makeNovelReaderRepository: @Sendable () async -> NovelReaderRepository
    public let makeOfflineCacheQueueExecutor: @Sendable () async -> OfflineCacheQueueExecutor
    /// The cache panel embeds the account feature's offline queue view model.
    public let account: AccountDependencies
    public let like: LikeDependencies

    public init(
        sessionStore: SessionStore,
        settingsStore: SettingsStore,
        readingProgressStore: ReadingProgressStore,
        browsingHistoryStore: BrowsingHistoryStore? = nil,
        offlineCacheStore: any OfflineCacheStoring,
        contentCoverStore: ContentCoverStore,
        makeNovelReaderRepository: @escaping @Sendable () async -> NovelReaderRepository,
        makeChapterCommentsRepository: @escaping @Sendable () async -> ReaderChapterCommentsRepository,
        makeOfflineCacheQueueExecutor: @escaping @Sendable () async -> OfflineCacheQueueExecutor,
        account: AccountDependencies,
        like: LikeDependencies
    ) {
        self.sessionStore = sessionStore
        self.settingsStore = settingsStore
        self.readingProgressStore = readingProgressStore
        self.browsingHistoryStore = browsingHistoryStore
        self.offlineCacheStore = offlineCacheStore
        self.contentCoverStore = contentCoverStore
        self.makeNovelReaderRepository = makeNovelReaderRepository
        self.makeOfflineCacheQueueExecutor = makeOfflineCacheQueueExecutor
        self.account = account
        self.like = like
        makeChapterCommentsModule = { onChange in
            ReaderChapterCommentsModule(
                adapter: ReaderChapterCommentsModule.Adapter(
                    loadInitial: { target in
                        try await makeChapterCommentsRepository().loadChapterComments(for: target)
                    },
                    loadMore: { target, view in
                        try await makeChapterCommentsRepository().loadMoreChapterComments(for: target, view: view)
                    }
                ),
                onChange: onChange
            )
        }
        makeCacheOperationRepository = { [settingsStore, offlineCacheStore, makeOfflineCacheQueueExecutor] in
            NovelOfflineStoreReaderCacheOperationAdapter(
                store: offlineCacheStore,
                novelOfflineCacheSettings: {
                    await settingsStore.load().novelOfflineCache
                },
                continueOfflineCacheQueue: {
                    try await makeOfflineCacheQueueExecutor().continueQueue()
                }
            )
        }
    }

    /// Builds the chapter-comments module wired to the composition root's
    /// repository; the reader view model supplies only its state sink.
    public let makeChapterCommentsModule: @Sendable (
        _ onChange: @escaping @Sendable (ReaderChapterCommentsSnapshot) -> Void
    ) -> ReaderChapterCommentsModule

    /// Builds the offline-cache operation repository backed by the shared
    /// offline cache store, settings, and download queue executor.
    public let makeCacheOperationRepository: @Sendable () -> any NovelReaderCacheOperationRepository

    @MainActor
    public func makeCacheOperationModule() -> NovelReaderCacheOperationModule {
        NovelReaderCacheOperationModule()
    }
}
