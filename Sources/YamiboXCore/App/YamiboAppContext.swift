@preconcurrency import Foundation
@preconcurrency import GRDB

/// Composition root. Owns the infrastructure singletons, assembles each
/// feature's dependency package, and is referenced only by the app-entry
/// layer (`YamiboXApp`, `YamiboAppModel`, `RootTabView`,
/// `AppContinuityWorkflow`). Feature views and view models receive their
/// `*Dependencies` package instead of this context.
public final class YamiboAppContext: Sendable {
    /// The app opens storage before constructing stores so migration failures can be
    /// shown and retried without exposing a partially upgraded runtime.
    public static func prepareDownloadStorage() throws -> DatabasePool {
        try YamiboDatabase.openPool()
    }

    let sessionStore: SessionStore
    let profileStore: YamiboProfileStore
    let checkInStore: YamiboCheckInStore
    /// Public for change-ID observation in the app-entry layer.
    public let settingsStore: SettingsStore
    let webDAVSyncSettingsStore: WebDAVSyncSettingsStore
    let readerResumeRouteStore: ReaderResumeRouteStore
    /// Public for change-ID observation in the app-entry layer.
    public let localFavoriteLibraryStore: FavoriteLibraryStore
    let favoriteUpdateStore: FavoriteUpdateStore
    let favoriteSyncRunStore: FavoriteSyncRunStore
    /// Public for change-ID observation in the app-entry layer.
    public let readingProgressStore: ReadingProgressStore
    let browsingHistoryStore: BrowsingHistoryStore
    let composerDraftStore: ForumComposerDraftStore
    public let browsingHistoryWorkflow: BrowsingHistoryWorkflow
    public let messageUnreadWorkflow: MessageUnreadWorkflow
    /// Public for change-ID observation in the app-entry layer.
    public let contentCoverStore: ContentCoverStore
    let novelReaderCacheStore: NovelReaderProjectionStore
    let favoriteBackgroundImageStore: FavoriteBackgroundImageStore
    private let likeStore: LikeStore
    private let likeImageStore: LikeImageStore
    private let bookmarkStore: BookmarkStore
    let mangaDirectoryStore: MangaDirectoryStore
    let mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState
    let mangaReaderProjectionStore: MangaReaderProjectionStore
    let downloadStore: any DownloadStoring
    let forumCacheStore: ForumCacheStore
    public let imagePipeline: YamiboImagePipeline
    private let ordinaryImageCache: (any YamiboOrdinaryImageCacheClearing)?
    let httpCache: URLCache
    public let downloadBackgroundDownloadTransport: DownloadBackgroundTransport
    private let downloadRunObserver: (any DownloadQueueRunObserving)?
    /// The single pool for `yamibox.sqlite`; every GRDB-backed store receives this instance.
    let databasePool: DatabasePool
    let session: URLSession
    private let downloadQueueExecutorBox: DownloadQueueExecutorBox
    private let accountTransitionWorkflow: AccountTransitionWorkflow
    private let dataResetWorkflow: AppDataResetWorkflow
    private let websiteDataClearer: (any WebsiteDataClearing)?
    private let wafRecoverer: (any YamiboWAFChallengeRecovering)?
    public let accountTransitionLifecycle = AccountTransitionLifecycle()

    public init(
        sessionStore: SessionStore = SessionStore(),
        profileStore: YamiboProfileStore? = nil,
        checkInStore: YamiboCheckInStore = YamiboCheckInStore(),
        settingsStore: SettingsStore = SettingsStore(),
        webDAVSyncSettingsStore: WebDAVSyncSettingsStore = WebDAVSyncSettingsStore(),
        readerResumeRouteStore: ReaderResumeRouteStore = ReaderResumeRouteStore(),
        localFavoriteLibraryStore: FavoriteLibraryStore? = nil,
        favoriteUpdateStore: FavoriteUpdateStore? = nil,
        favoriteSyncRunStore: FavoriteSyncRunStore? = nil,
        readingProgressStore: ReadingProgressStore? = nil,
        browsingHistoryStore: BrowsingHistoryStore? = nil,
        composerDraftStore: ForumComposerDraftStore? = nil,
        contentCoverStore: ContentCoverStore? = nil,
        novelReaderCacheStore: NovelReaderProjectionStore? = nil,
        favoriteBackgroundImageStore: FavoriteBackgroundImageStore? = nil,
        likeStore: LikeStore? = nil,
        likeImageStore: LikeImageStore? = nil,
        bookmarkStore: BookmarkStore? = nil,
        mangaDirectoryStore: MangaDirectoryStore? = nil,
        mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState = MangaDirectorySearchCooldownState(),
        mangaReaderProjectionStore: MangaReaderProjectionStore? = nil,
        downloadStore: (any DownloadStoring)? = nil,
        forumCacheStore: ForumCacheStore? = nil,
        ordinaryImageCache: (any YamiboOrdinaryImageCacheClearing)? = nil,
        downloadBackgroundDownloadTransport: DownloadBackgroundTransport? = nil,
        downloadRunObserver: (any DownloadQueueRunObserving)? = nil,
        databasePool: DatabasePool? = nil,
        grdbRootDirectory: URL? = nil,
        cachesRootDirectory: URL? = nil,
        uiDefaults: UserDefaults = .standard,
        clearsWebDataOnReset: Bool = true,
        websiteDataClearer: (any WebsiteDataClearing)? = nil,
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        imageSession: URLSession = YamiboNetworkConfiguration.makeImageSession(),
        wafRecoverer: (any YamiboWAFChallengeRecovering)? = nil,
        httpCache: URLCache = .shared
    ) {
        // Recover the diagnostic ring and retire old share snapshots off the UI thread.
        Task { _ = try? await NetworkLogStore.shared.usageBytes() }
        let queueExecutors = DownloadQueueExecutorBox()
        self.downloadQueueExecutorBox = queueExecutors
        nonisolated(unsafe) let profileDefaults = uiDefaults
        let profileStore = profileStore ?? sessionStore.accountStore.map { YamiboProfileStore(accountStore: $0) }
            ?? YamiboProfileStore(defaults: profileDefaults)
        let resolvedGRDBRootDirectory = grdbRootDirectory ?? YamiboDatabase.defaultRootDirectory()
        let resolvedCachesRootDirectory = cachesRootDirectory ?? YamiboDatabase.defaultCacheRootDirectory()
        let resolvedGRDBDatabasePool = databasePool ?? Self.openGRDBDatabase(rootDirectory: resolvedGRDBRootDirectory)
        self.databasePool = resolvedGRDBDatabasePool
        let diskCacheStore = DiskCacheStore(
            writer: resolvedGRDBDatabasePool,
            rootDirectory: resolvedCachesRootDirectory
        )
        self.websiteDataClearer = websiteDataClearer
        self.sessionStore = sessionStore
        self.messageUnreadWorkflow = MessageUnreadWorkflow(sessionStore: sessionStore) { state in
            UserSpaceRepository(client: YamiboClient(session: session, credentials: state.credentials, handlesCookies: false))
        }
        self.profileStore = profileStore
        self.checkInStore = checkInStore
        self.settingsStore = settingsStore
        self.webDAVSyncSettingsStore = webDAVSyncSettingsStore
        self.readerResumeRouteStore = readerResumeRouteStore
        let resolvedDownloadStore = downloadStore ?? DownloadStore(
            databasePool: resolvedGRDBDatabasePool,
            baseDirectory: Self.prepareDownloadDirectory(rootDirectory: resolvedGRDBRootDirectory)
        )
        self.localFavoriteLibraryStore = localFavoriteLibraryStore ?? FavoriteLibraryStore(databasePool: resolvedGRDBDatabasePool)
        let resolvedFavoriteUpdateStore = favoriteUpdateStore ?? FavoriteUpdateStore(databasePool: resolvedGRDBDatabasePool)
        self.favoriteUpdateStore = resolvedFavoriteUpdateStore
        self.favoriteSyncRunStore = favoriteSyncRunStore ?? FavoriteSyncRunStore(databasePool: resolvedGRDBDatabasePool)
        self.readingProgressStore = readingProgressStore ?? ReadingProgressStore(databasePool: resolvedGRDBDatabasePool)
        self.browsingHistoryStore = browsingHistoryStore ?? BrowsingHistoryStore(databasePool: resolvedGRDBDatabasePool, syncSettingsStore: webDAVSyncSettingsStore)
        self.composerDraftStore = composerDraftStore ?? ForumComposerDraftStore(databasePool: resolvedGRDBDatabasePool, baseDirectory: resolvedGRDBRootDirectory.appendingPathComponent("composer-drafts", isDirectory: true))
        self.contentCoverStore = contentCoverStore ?? ContentCoverStore(databasePool: resolvedGRDBDatabasePool)
        self.novelReaderCacheStore = novelReaderCacheStore ?? NovelReaderProjectionStore(
            diskCacheStore: diskCacheStore
        )
        self.favoriteBackgroundImageStore = favoriteBackgroundImageStore ?? FavoriteBackgroundImageStore(
            baseDirectory: Self.favoriteBackgroundDirectory(rootDirectory: resolvedGRDBRootDirectory)
        )
        self.likeStore = likeStore ?? LikeStore(databasePool: resolvedGRDBDatabasePool)
        self.likeImageStore = likeImageStore ?? LikeImageStore(
            baseDirectory: Self.likeImagesDirectory(rootDirectory: resolvedGRDBRootDirectory)
        )
        self.bookmarkStore = bookmarkStore ?? BookmarkStore(databasePool: resolvedGRDBDatabasePool)
        self.mangaDirectoryStore = mangaDirectoryStore ?? MangaDirectoryStore(
            databasePool: resolvedGRDBDatabasePool,
            syncSettingsStore: webDAVSyncSettingsStore,
            favoriteUpdateStore: resolvedFavoriteUpdateStore,
            readingProgressStore: self.readingProgressStore,
            prepareIdentityChange: { [weak queueExecutors] in try await queueExecutors?.prepareIdentityChange() },
            finishIdentityChange: { [weak queueExecutors] in await queueExecutors?.finishIdentityChange() },
            identityChangeCommitted: { [likes = self.likeStore, bookmarks = self.bookmarkStore, covers = self.contentCoverStore, history = self.browsingHistoryStore] in
                likes.notifyIdentityMigrationCommitted()
                bookmarks.notifyIdentityMigrationCommitted()
                covers.notifyIdentityMigrationCommitted()
                history.notifyIdentityMigrationCommitted()
                resolvedDownloadStore.notifyIdentityMigrationCommitted()
            }
        )
        self.mangaDirectorySearchCooldownState = mangaDirectorySearchCooldownState
        self.mangaReaderProjectionStore = mangaReaderProjectionStore ?? MangaReaderProjectionStore(diskCacheStore: diskCacheStore)
        self.downloadStore = resolvedDownloadStore
        self.forumCacheStore = forumCacheStore ?? ForumCacheStore(
            diskCacheStore: diskCacheStore
        )
        let historyLibraryStore = self.localFavoriteLibraryStore
        let historyForumCache = self.forumCacheStore
        self.browsingHistoryWorkflow = BrowsingHistoryWorkflow(
            store: self.browsingHistoryStore,
            settingsStore: settingsStore,
            progressStore: self.readingProgressStore,
            directoryStore: self.mangaDirectoryStore,
            resolveForumIDs: { tids in
                guard !tids.isEmpty else { return [:] }
                let items = (try? await historyLibraryStore.load())?.items ?? []
                var result: [String: String] = [:]
                for tid in tids {
                    if let fid = items.first(where: { $0.target.threadID == tid && $0.forumID != nil })?.forumID {
                        result[tid] = fid
                    } else if let page = await historyForumCache.loadThreadPage(thread: ThreadIdentity(tid: tid), allowExpired: true) {
                        result[tid] = page.forumID ?? page.thread.fid
                    }
                }
                return result
            }
        )
        self.imagePipeline = YamiboImagePipeline(
            engine: Self.makeImageDataPipeline(cachesRootDirectory: cachesRootDirectory),
            sessionStore: sessionStore,
            imageSession: imageSession,
            offlineImages: resolvedDownloadStore
        )
        self.ordinaryImageCache = ordinaryImageCache
        self.httpCache = httpCache
        self.downloadBackgroundDownloadTransport = downloadBackgroundDownloadTransport ?? DownloadBackgroundTransport(sessionStore: sessionStore)
        self.downloadRunObserver = downloadRunObserver
        self.session = session
        self.wafRecoverer = wafRecoverer
        let webDataCleaner = AccountWebDataCleaner(session: session, httpCache: httpCache, websiteDataClearer: websiteDataClearer)
        let accountTransitionWorkflow = AccountTransitionWorkflow(
            sessionStore: sessionStore,
            syncCoordinator: webDAVSyncSettingsStore.syncCoordinator,
            lifecycle: accountTransitionLifecycle,
            unread: messageUnreadWorkflow,
            stopDownload: { try await queueExecutors.invalidate() },
            clearAccountCaches: { [store = self.forumCacheStore] in try await store.clearAccountCaches() },
            clearWebData: { await webDataCleaner.clear($0) }
        )
        self.accountTransitionWorkflow = accountTransitionWorkflow
        self.dataResetWorkflow = AppDataResetWorkflow(
            sessionStore: sessionStore,
            profileStore: profileStore,
            transition: accountTransitionWorkflow,
            webDataCleanup: clearsWebDataOnReset ? .all : .none,
            steps: [
                .init("checkIn") { await checkInStore.clearAll() },
                .init("settings") { try await settingsStore.reset() },
                .init("webDAVSettings") { try await webDAVSyncSettingsStore.resetWithinAccountTransition() },
                .init("readerResume") { await readerResumeRouteStore.clear() },
                .init("favorites") { [store = self.localFavoriteLibraryStore] in try await store.clearAll() },
                .init("favoriteUpdates") { [store = self.favoriteUpdateStore] in try await store.clearAll() },
                .init("favoriteSyncRuns") { [store = self.favoriteSyncRunStore] in try await store.clearAll() },
                .init("readingProgress") { [store = self.readingProgressStore] in try await store.clearAll() },
                .init("browsingHistory") { [store = self.browsingHistoryStore] in try await store.clearAll() },
                .init("composerDrafts") { [store = self.composerDraftStore] in try await store.clearAll() },
                .init("contentCovers") { [store = self.contentCoverStore] in try await store.clearAll() },
                .init("novelProjections") { [store = self.novelReaderCacheStore] in try await store.clearAll() },
                .init("mangaDirectories") { [store = self.mangaDirectoryStore] in try await store.clearAll() },
                .init("mangaSearchCooldown") { await mangaDirectorySearchCooldownState.clear() },
                .init("mangaProjections") { [store = self.mangaReaderProjectionStore] in try await store.clearAll() },
                .init("download") { try await resolvedDownloadStore.clearAll() },
                .init("forumCache") { [store = self.forumCacheStore] in try await store.clearAll() },
                .init("favoriteBackgrounds") { [store = self.favoriteBackgroundImageStore] in try await store.deleteAll() },
                .init("ordinaryImageCache") { [pipeline = self.imagePipeline] in
                    await pipeline.clearCache()
                    await ordinaryImageCache?.removeAllCachedData()
                },
                .init("localUIState") {
                    YamiboAppStorageKey.resettable.forEach { profileDefaults.removeObject(forKey: $0) }
                },
                .init("likes") { [store = self.likeStore] in try await store.clearAll() },
                .init("likeImages") { [store = self.likeImageStore] in try await store.deleteAll() },
                .init("bookmarks") { [store = self.bookmarkStore] in try await store.clearAll() },
                .init("networkLogs") { try await NetworkLogStore.shared.clear() },
            ]
        )
    }

    // MARK: - Feature dependency packages

    public var novelDetailDependencies: NovelDetailDependencies {
        NovelDetailDependencies(
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            settingsStore: settingsStore,
            contentCoverStore: contentCoverStore,
            makeFavoriteRepository: { [self] in await makeFavoriteRepository() },
            makeNovelReaderRepository: { [self] in await makeNovelReaderRepository() },
            makeForumThreadReaderRepository: { [self] in await makeForumThreadReaderRepository() }
        )
    }

    public var mangaDetailDependencies: MangaDetailDependencies {
        MangaDetailDependencies(
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            settingsStore: settingsStore,
            contentCoverStore: contentCoverStore,
            mangaDirectoryStore: mangaDirectoryStore,
            mangaDirectorySearchCooldownState: mangaDirectorySearchCooldownState,
            mangaDownloadStore: downloadStore,
            makeFavoriteRepository: { [self] in await makeFavoriteRepository() },
            makeForumThreadReaderRepository: { [self] in await makeForumThreadReaderRepository() },
            makeMangaReaderProjectionLoader: { [self] in await makeMangaReaderProjectionLoader() },
            makeMangaDirectoryRepository: { [self] in await makeMangaDirectoryRepository() }
        )
    }

    public var forumDependencies: ForumDependencies {
        ForumDependencies(
            sessionStore: sessionStore,
            profileStore: profileStore,
            messageUnreadWorkflow: messageUnreadWorkflow,
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            browsingHistoryStore: browsingHistoryStore,
            browsingHistoryWorkflow: browsingHistoryWorkflow,
            composerDraftStore: composerDraftStore,
            attachmentDownloadStore: downloadStore,
            makeDownloadQueueExecutor: { [self] in await makeDownloadQueueExecutor() },
            settingsStore: settingsStore,
            contentCoverStore: contentCoverStore,
            mangaDirectoryStore: mangaDirectoryStore,
            makeHomeRepository: { [self] in await makeForumRepository() },
            makeBoardRepository: { [self] in await makeForumRepository() },
            makeSearchRepository: { [self] in await makeForumRepository() },
            makePageRepository: { [self] in await makeForumRepository().pageRepository() },
            makeForumThreadReaderRepository: { [self] in await makeForumThreadReaderRepository() },
            makeUserSpaceRepository: { [self] in await makeUserSpaceRepository() },
            makeBlogReaderRepository: { [self] in await makeBlogReaderRepository() },
            makeFavoriteRepository: { [self] in await makeFavoriteRepository() },
            makeThreadRouteResolver: { [self] in await makeThreadRouteResolver() }
        )
    }

    public var forumNavigationDependencies: ForumNavigationDependencies {
        ForumNavigationDependencies(
            forum: forumDependencies,
            destinations: ForumDestinationDependencies(
                novelDetail: novelDetailDependencies,
                mangaDetail: mangaDetailDependencies,
                novelReader: novelReaderDependencies,
                mangaReader: mangaReaderDependencies
            )
        )
    }

    public var libraryDependencies: LibraryDependencies {
        LibraryDependencies(
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            favoriteUpdateStore: favoriteUpdateStore,
            favoriteSyncRunStore: favoriteSyncRunStore,
            readingProgressStore: readingProgressStore,
            browsingHistoryStore: browsingHistoryStore,
            browsingHistoryWorkflow: browsingHistoryWorkflow,
            settingsStore: settingsStore,
            contentCoverStore: contentCoverStore,
            mangaDirectoryStore: mangaDirectoryStore,
            mangaDirectorySearchCooldownState: mangaDirectorySearchCooldownState,
            favoriteBackgroundImageStore: favoriteBackgroundImageStore,
            makeFavoriteRepository: { [self] in await makeFavoriteRepository() },
            makeForumThreadReaderRepository: { [self] in await makeForumThreadReaderRepository() },
            makeThreadRouteResolver: { [self] in await makeThreadRouteResolver() },
            makeMangaDirectoryRepository: { [self] in await makeMangaDirectoryRepository() }
        )
    }

    public var mangaReaderDependencies: MangaReaderDependencies {
        MangaReaderDependencies(
            settingsStore: settingsStore,
            readingProgressStore: readingProgressStore,
            browsingHistoryStore: browsingHistoryStore,
            browsingHistoryWorkflow: browsingHistoryWorkflow,
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            mangaDirectoryStore: mangaDirectoryStore,
            mangaDirectorySearchCooldownState: mangaDirectorySearchCooldownState,
            downloadStore: downloadStore,
            contentCoverStore: contentCoverStore,
            makeProjectionLoader: { [self] in await makeMangaReaderProjectionLoader() },
            makeDirectoryRepository: { [self] in await makeMangaDirectoryRepository() },
            makeChapterCommentsRepository: { [self] in await makeReaderChapterCommentsRepository() },
            makeDownloadQueueExecutor: { [self] in await makeDownloadQueueExecutor() },
            makeForumThreadReaderRepository: { [self] in await makeForumThreadReaderRepository() },
            downloadQueue: downloadQueueDependencies,
            like: likeLibraryDependencies,
            imagePipeline: imagePipeline
        )
    }

    public var novelReaderDependencies: NovelReaderDependencies {
        NovelReaderDependencies(
            sessionStore: sessionStore,
            settingsStore: settingsStore,
            readingProgressStore: readingProgressStore,
            browsingHistoryStore: browsingHistoryStore,
            browsingHistoryWorkflow: browsingHistoryWorkflow,
            downloadStore: downloadStore,
            contentCoverStore: contentCoverStore,
            makeNovelReaderRepository: { [self] in await makeNovelReaderRepository() },
            makeChapterCommentsRepository: { [self] in await makeReaderChapterCommentsRepository() },
            makeDownloadQueueExecutor: { [self] in await makeDownloadQueueExecutor() },
            downloadQueue: downloadQueueDependencies,
            like: likeLibraryDependencies,
            imagePipeline: imagePipeline
        )
    }

    public var downloadQueueDependencies: DownloadQueueDependencies {
        DownloadQueueDependencies(
            sessionStore: sessionStore,
            downloadStore: downloadStore,
            mangaDirectoryStore: mangaDirectoryStore,
            makeDownloadQueueExecutor: { [self] in await makeDownloadQueueExecutor() }
        )
    }

    public var accountDependencies: AccountDependencies {
        AccountDependencies(
            sessionStore: sessionStore,
            profileStore: profileStore,
            messageUnreadWorkflow: messageUnreadWorkflow,
            checkInStore: checkInStore,
            mangaDirectoryStore: mangaDirectoryStore,
            downloadStore: downloadStore,
            makeAccountService: { [self] in makeAccountService() },
            makeCheckInService: { [self] in makeCheckInService() },
            makeDownloadQueueExecutor: { [self] in await makeDownloadQueueExecutor() },
            imagePipeline: imagePipeline,
            accountSwitcher: accountSwitcher
        )
    }

    public var settingsDependencies: SettingsDependencies {
        SettingsDependencies(
            sessionStore: sessionStore,
            settingsStore: settingsStore,
            favoriteBackgroundImageStore: favoriteBackgroundImageStore,
            novelReaderCacheStore: novelReaderCacheStore,
            mangaDirectoryStore: mangaDirectoryStore,
            mangaReaderProjectionStore: mangaReaderProjectionStore,
            forumCacheStore: forumCacheStore,
            contentCoverStore: contentCoverStore,
            checkInStore: checkInStore,
            favoriteUpdateStore: favoriteUpdateStore,
            downloadStore: downloadStore,
            downloadQueue: downloadQueueDependencies,
            clearOrdinaryImageCache: { [self] in await clearOrdinaryImageCache() },
            ordinaryImageCacheUsageBytes: { [imagePipeline, ordinaryImageCache] in
                let dataBytes = await imagePipeline.totalDiskUsageBytes()
                let additionalBytes = await ordinaryImageCache?.totalDiskUsageBytes() ?? 0
                return dataBytes + additionalBytes
            },
            resetApplicationData: { [self] in try await resetApplicationData() },
            library: libraryDependencies,
            webDAVSync: webDAVSyncDependencies,
            httpCache: httpCache
        )
    }

    public var webDAVSyncDependencies: WebDAVSyncDependencies {
        WebDAVSyncDependencies(
            settingsStore: webDAVSyncSettingsStore,
            makeSyncService: { [self] in makeWebDAVSyncService() }
        )
    }

    /// Shared by Mine's My Likes feature and both readers' capture services,
    /// so there's a single package shape instead of one per consumer.
    public var likeLibraryDependencies: LikeDependencies {
        LikeDependencies(
            likeStore: likeStore,
            likeImageStore: likeImageStore,
            bookmarkStore: bookmarkStore,
            mangaDirectoryStore: mangaDirectoryStore,
            novelReaderCacheStore: novelReaderCacheStore
        )
    }

    // MARK: - Factories

    private func makeClient() async -> YamiboClient {
        let snapshot = try? await sessionStore.snapshot()
        return YamiboClient(
            session: session,
            credentials: (snapshot?.session ?? SessionState()).credentials,
            wafRecoverer: wafRecoverer,
            handlesCookies: false,
            validateSession: { [sessionStore] in
                guard let snapshot, await sessionStore.isCurrentGeneration(snapshot.generation) else { throw CancellationError() }
            }
        )
    }

    func makeFavoriteRepository() async -> FavoriteRepository {
        FavoriteRepository(client: await makeClient())
    }

    func makeNovelReaderRepository() async -> NovelReaderRepository {
        NovelReaderRepository(
            client: await makeClient(),
            cacheStore: novelReaderCacheStore,
            forumCacheStore: forumCacheStore,
            downloadStore: downloadStore,
            novelOfflineAutoRefreshEnabled: { [settingsStore] in
                await settingsStore.load().novelDownload.isAutoRefreshEnabled
            },
            novelOfflineRetainsInlineImages: { [settingsStore] in
                await settingsStore.load().novelDownload.retainsInlineImages
            }
        )
    }

    func makeReaderChapterCommentsRepository() async -> any ReaderChapterCommentsLoading {
        ReaderChapterCommentsRepository(client: await makeClient())
    }

    func makeThreadRouteResolver() async -> YamiboThreadRouteResolver {
        YamiboThreadRouteResolver(client: await makeClient(), settingsStore: settingsStore)
    }

    func makeForumThreadReaderRepository() async -> ForumThreadReaderRepository {
        ForumThreadReaderRepository(client: await makeClient(), cacheStore: forumCacheStore)
    }

    func makeForumRepository() async -> ForumRepository {
        ForumRepository(client: await makeClient(), cacheStore: forumCacheStore,
                        accountGeneration: await forumCacheStore.accountGeneration)
    }

    func makeUserSpaceRepository() async -> UserSpaceRepository {
        UserSpaceRepository(client: await makeClient())
    }

    func makeBlogReaderRepository() async -> BlogReaderRepository {
        BlogReaderRepository(client: await makeClient())
    }

    func makeMangaReaderProjectionLoader() async -> any MangaReaderProjectionSnapshotLoading {
        MangaReaderProjectionLoader(
            client: await makeClient(),
            projectionStore: mangaReaderProjectionStore,
            forumCacheStore: forumCacheStore,
            downloadStore: downloadStore
        )
    }

    func makeMangaDirectoryRepository() async -> any MangaDirectoryRepository {
        YamiboMangaDirectoryRepository(client: await makeClient())
    }

    public func makeDownloadQueueExecutor() async -> DownloadQueueExecutor {
        let snapshot = try? await sessionStore.snapshot()
        let generation = snapshot?.generation ?? UUID()
        if let executor = await downloadQueueExecutorBox.value(for: generation) {
            return executor
        }

        let executor = DownloadQueueExecutor(
            store: downloadStore,
            mangaDownloadStore: downloadStore,
            novelDownloadStore: downloadStore,
            readerProjectionLoader: await makeMangaReaderProjectionLoader(),
            novelSourcePageLoader: await makeNovelReaderRepository(),
            imageAcquirer: DownloadImageAcquirer(
                imagePipeline: imagePipeline,
                backgroundTransport: downloadBackgroundDownloadTransport
            ),
            attachmentWorkProcessor: ForumAttachmentDownloadProcessor(store: downloadStore, client: await makeClient()),
            runObserver: downloadRunObserver,
            isSessionCurrent: { [sessionStore] in
                await sessionStore.isCurrentGeneration(generation)
            }
        )
        return await downloadQueueExecutorBox.setIfEmpty(executor, generation: generation) { [sessionStore] in
            await sessionStore.isCurrentGeneration(generation)
        }
    }

    public func makeCheckInService() -> any YamiboCheckInServicing {
        YamiboCheckInService(
            sessionStore: sessionStore,
            checkInStore: checkInStore,
            settingsStore: settingsStore,
            session: session,
            wafRecoverer: wafRecoverer
        )
    }

    func makeAccountService() -> YamiboAccountService {
        YamiboAccountService(
            session: session,
            sessionStore: sessionStore,
            profileStore: profileStore,
            websiteDataClearer: websiteDataClearer,
            wafRecoverer: wafRecoverer,
            coordinatedSignOut: { [self] in try await accountSwitcher.signOut() },
            coordinatedInvalidation: { [self] generation in
                try await accountSwitcher.invalidateCurrent(expectedGeneration: generation)
            }
        )
    }

    public var accountSwitcher: AccountSwitchCoordinator {
        AccountSwitchCoordinator(
            sessionStore: sessionStore,
            profileStore: profileStore,
            makeService: { [self] in makeAccountService() },
            transition: { [accountTransitionWorkflow] commit in try await accountTransitionWorkflow.run(commit) }
        )
    }

    /// A dataset cannot join synchronization without registering its local change source.
    var webDAVDatasets: [AppWebDAVDataset] {
        [
            .init(
                participant: MangaDirectoryWebDAVParticipant(store: mangaDirectoryStore).applyingMangaIdentity(using: mangaDirectoryStore),
                changeID: mangaDirectoryStore.changeID,
                changes: { [mangaDirectoryStore] in mangaDirectoryStore.changes() }
            ),
            .init(
                participant: FavoriteLibraryWebDAVParticipant(store: localFavoriteLibraryStore).applyingMangaIdentity(using: mangaDirectoryStore),
                changeID: localFavoriteLibraryStore.changeID,
                changes: { [localFavoriteLibraryStore] in localFavoriteLibraryStore.changes() }
            ),
            .init(
                participant: ReadingProgressWebDAVParticipant(store: readingProgressStore).applyingMangaIdentity(using: mangaDirectoryStore),
                changeID: readingProgressStore.changeID,
                changes: { [readingProgressStore] in readingProgressStore.changes() }
            ),
            .init(
                participant: AppSettingsWebDAVParticipant(store: settingsStore),
                changeID: settingsStore.changeID,
                changes: { [settingsStore] in settingsStore.changes() }
            ),
            .init(
                participant: LikeLibraryWebDAVParticipant(store: likeStore).applyingMangaIdentity(using: mangaDirectoryStore),
                changeID: likeStore.changeID,
                changes: { [likeStore] in likeStore.changes() }
            ),
            .init(
                participant: BookmarkLibraryWebDAVParticipant(store: bookmarkStore).applyingMangaIdentity(using: mangaDirectoryStore),
                changeID: bookmarkStore.changeID,
                changes: { [bookmarkStore] in bookmarkStore.changes() }
            ),
            .init(
                participant: ContentCoverWebDAVParticipant(store: contentCoverStore).applyingMangaIdentity(using: mangaDirectoryStore),
                changeID: contentCoverStore.changeID,
                changes: { [contentCoverStore] in contentCoverStore.changes() }
            ),
            .init(
                participant: BrowsingHistoryWebDAVParticipant(store: browsingHistoryStore).applyingMangaIdentity(using: mangaDirectoryStore),
                changeID: browsingHistoryStore.changeID,
                changes: { [browsingHistoryStore] in browsingHistoryStore.changes() }
            ),
        ]
    }

    func makeWebDAVSyncService() -> WebDAVSyncService {
        WebDAVSyncService(
            settingsStore: webDAVSyncSettingsStore,
            sessionStore: sessionStore,
            participants: webDAVDatasets.map(\.participant),
            migrations: [MangaIdentityWebDAVMigration(settingsStore: webDAVSyncSettingsStore)],
            client: WebDAVClient(session: session)
        )
    }

    func clearOrdinaryImageCache() async {
        await imagePipeline.clearCache()
        await ordinaryImageCache?.removeAllCachedData()
    }

    private static func makeImageDataPipeline(cachesRootDirectory: URL?) -> YamiboImageDataPipeline {
        guard let cachesRootDirectory else { return YamiboImageDataPipeline() }
        return YamiboImageDataPipeline(
            dataCacheDirectory: cachesRootDirectory.appendingPathComponent("ordinary-image-cache", isDirectory: true)
        )
    }

    public func bootstrap(
        onProgress: @Sendable (AppBootstrapPhase) async -> Void = { _ in }
    ) async -> YamiboBootstrapState {
        await onProgress(.loadingSession)
        let session = await sessionStore.load()
        await onProgress(.loadingProfile)
        let profile = await profileStore.load()
        await onProgress(.loadingSettings)
        let settings = await settingsStore.load()
        await onProgress(.loadingFavorites)
        // Startup snapshot for first paint only — every writer re-reads
        // the store, so this fallback can never leak into a save.
        let localFavoriteLibrary = (try? await localFavoriteLibraryStore.load()) ?? FavoriteLibraryDocument()
        return YamiboBootstrapState(
            session: session,
            profile: profile,
            settings: settings,
            localFavoriteLibrary: localFavoriteLibrary
        )
    }

    func resetApplicationData() async throws {
        try await dataResetWorkflow.run()
    }

    private static func openGRDBDatabase(rootDirectory: URL) -> DatabasePool {
        do {
            return try YamiboDatabase.openPool(rootDirectory: rootDirectory)
        } catch {
            fatalError("Failed to open Yamibo app database: \(error)")
        }
    }

    private static func favoriteBackgroundDirectory(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("favorite-background", isDirectory: true)
    }

    private static func likeImagesDirectory(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("like-images", isDirectory: true)
    }

    /// Offline chapters are user-requested downloads: they must stay out of
    /// iCloud/iTunes backups yet — unlike `Library/Caches` content — must never
    /// be purged by the system, hence Application Support + the backup
    /// exclusion marker. The marker stays scoped to this directory; the rest of
    /// the root (yamibox.sqlite, favorite-background, like-images) is user data
    /// that participates in backups. Idempotent; failures are logged because
    /// the store lazily recreates the directory on first write anyway.
    private static func prepareDownloadDirectory(
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let directory = downloadDirectory(rootDirectory: rootDirectory)
        do {
            try DownloadStore.createBackupExcludedDirectory(at: directory, fileManager: fileManager)
        } catch {
            YamiboLog.persistence.error("Failed to prepare the backup-excluded download directory: \(error)")
        }
        return directory
    }

    private static func downloadDirectory(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("downloads", isDirectory: true)
    }

}

private actor DownloadQueueExecutorBox {
    private var values: [UUID: DownloadQueueExecutor] = [:]
    private var identityChangeDepth = 0
    private var isInvalidating = false

    func prepareIdentityChange() async throws {
        identityChangeDepth += 1
        guard identityChangeDepth == 1 else { return }
        do {
            for executor in Array(values.values) { try await executor.suspendForIdentityChange() }
        } catch {
            identityChangeDepth = 0
            for executor in Array(values.values) { await executor.finishIdentityChange() }
            throw error
        }
    }

    func finishIdentityChange() async {
        guard identityChangeDepth > 0 else { return }
        identityChangeDepth -= 1
        guard identityChangeDepth == 0 else { return }
        for executor in Array(values.values) { await executor.finishIdentityChange() }
    }

    func value(for generation: UUID) -> DownloadQueueExecutor? { values[generation] }

    func invalidate() async throws {
        isInvalidating = true
        defer { isInvalidating = false }
        let executors = values
        var failure: (any Error)?
        // Keep retiring executors visible until their writers have joined, so
        // a concurrent identity migration cannot overlook an old account run.
        for (generation, executor) in executors {
            do { try await executor.invalidateForAccountChange() }
            catch { if failure == nil { failure = error } }
            values.removeValue(forKey: generation)
        }
        if let failure { throw failure }
    }

    func setIfEmpty(
        _ executor: DownloadQueueExecutor,
        generation: UUID,
        isCurrent: @Sendable () async -> Bool
    ) async -> DownloadQueueExecutor {
        guard await isCurrent(), !isInvalidating else {
            await executor.rejectBeforeUse()
            return executor
        }
        if let value = values[generation] {
            return value
        }
        values[generation] = executor
        if identityChangeDepth > 0 {
            do { try await executor.suspendForIdentityChange() }
            catch { YamiboLog.download.error("Could not suspend new queue executor: \(error)") }
        }
        return executor
    }
}

public struct YamiboBootstrapState: Sendable {
    public let session: SessionState
    public let profile: YamiboProfile?
    public let settings: AppSettings
    public let localFavoriteLibrary: FavoriteLibraryDocument

    public init(
        session: SessionState,
        profile: YamiboProfile?,
        settings: AppSettings,
        localFavoriteLibrary: FavoriteLibraryDocument = FavoriteLibraryDocument()
    ) {
        self.session = session
        self.profile = profile
        self.settings = settings
        self.localFavoriteLibrary = localFavoriteLibrary
    }
}
