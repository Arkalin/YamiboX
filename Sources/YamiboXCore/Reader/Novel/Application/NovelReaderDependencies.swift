import Foundation

/// Everything the novel reader feature UI (reader, download panel)
/// needs from the composition root.
public struct NovelReaderDependencies: Sendable {
    public let sessionStore: SessionStore
    public let settingsStore: SettingsStore
    public let readingProgressStore: ReadingProgressStore
    /// Shared with the other reader surfaces, including in test compositions.
    public let browsingHistoryStore: BrowsingHistoryStore
    public let browsingHistoryWorkflow: BrowsingHistoryWorkflow
    public let downloadStore: any DownloadStoring
    public let contentCoverStore: ContentCoverStore
    public let imagePipeline: any YamiboImageDataLoading
    public let makeNovelReaderRepository: @Sendable () async -> any NovelReadingPageRepository
    public let makeDownloadQueueExecutor: @Sendable () async -> DownloadQueueExecutor
    public let downloadQueue: DownloadQueueDependencies
    public let like: LikeDependencies

    public init(
        sessionStore: SessionStore,
        settingsStore: SettingsStore,
        readingProgressStore: ReadingProgressStore,
        browsingHistoryStore: BrowsingHistoryStore,
        browsingHistoryWorkflow: BrowsingHistoryWorkflow,
        downloadStore: any DownloadStoring,
        contentCoverStore: ContentCoverStore,
        makeNovelReaderRepository: @escaping @Sendable () async -> any NovelReadingPageRepository,
        makeChapterCommentsRepository: @escaping @Sendable () async -> any ReaderChapterCommentsLoading,
        makeDownloadQueueExecutor: @escaping @Sendable () async -> DownloadQueueExecutor,
        downloadQueue: DownloadQueueDependencies,
        like: LikeDependencies,
        imagePipeline: any YamiboImageDataLoading
    ) {
        self.sessionStore = sessionStore
        self.settingsStore = settingsStore
        self.readingProgressStore = readingProgressStore
        self.browsingHistoryStore = browsingHistoryStore
        self.browsingHistoryWorkflow = browsingHistoryWorkflow
        self.downloadStore = downloadStore
        self.contentCoverStore = contentCoverStore
        self.imagePipeline = imagePipeline
        self.makeNovelReaderRepository = makeNovelReaderRepository
        self.makeDownloadQueueExecutor = makeDownloadQueueExecutor
        self.downloadQueue = downloadQueue
        self.like = like
        makeChapterCommentsModule = { onChange in
            ReaderChapterCommentsModule(
                adapter: ReaderChapterCommentsModule.Adapter(
                    loadInitial: { target in
                        try await makeChapterCommentsRepository().loadChapterComments(for: target)
                    },
                    loadMore: { target, view in
                        try await makeChapterCommentsRepository().loadMoreChapterComments(for: target, view: view)
                    },
                    loadRatings: { target, request in
                        try await makeChapterCommentsRepository().loadRatingReasons(for: target, request: request)
                    }
                ),
                onChange: onChange
            )
        }
        makeDownloadOperationRepository = { [settingsStore, downloadStore, makeDownloadQueueExecutor] in
            NovelOfflineStoreReaderDownloadOperationAdapter(
                store: downloadStore,
                novelDownloadSettings: {
                    await settingsStore.load().novelDownload
                },
                continueDownloadQueue: {
                    try await makeDownloadQueueExecutor().continueQueue()
                }
            )
        }
    }

    /// Builds the chapter-comments module wired to the composition root's
    /// repository; the reader view model supplies only its state sink.
    public let makeChapterCommentsModule: @Sendable (
        _ onChange: @escaping @Sendable (ReaderChapterCommentsSnapshot) -> Void
    ) -> ReaderChapterCommentsModule

    /// Builds the downloads operation repository backed by the shared
    /// download store, settings, and download queue executor.
    public let makeDownloadOperationRepository: @Sendable () -> any NovelReaderDownloadOperationRepository

    @MainActor
    public func makeDownloadOperationModule() -> NovelReaderDownloadOperationModule {
        NovelReaderDownloadOperationModule()
    }
}
