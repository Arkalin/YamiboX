@preconcurrency import Foundation
@preconcurrency import GRDB

/// Composition root. Owns the infrastructure singletons, assembles each
/// feature's dependency package, and is referenced only by the app-entry
/// layer (`YamiboXApp`, `YamiboAppModel`, `RootTabView`,
/// `AppContinuityWorkflow`). Feature views and view models receive their
/// `*Dependencies` package instead of this context.
public final class YamiboAppContext: Sendable {
    private static let resettableUserDefaultsKeys = YamiboAppStorageKey.resettable

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
    let offlineCacheStore: any OfflineCacheStoring
    let forumCacheStore: ForumCacheStore
    public let imagePipeline: YamiboImagePipeline
    private let ordinaryImageCache: (any YamiboOrdinaryImageCacheClearing)?
    let httpCache: URLCache
    public let offlineCacheBackgroundDownloadTransport: OfflineCacheBackgroundDownloadTransport
    public let offlineCacheContinuedProcessingCoordinator: OfflineCacheContinuedProcessingCoordinator
    /// The single pool for `yamibox.sqlite`; every GRDB-backed store receives this instance.
    let databasePool: DatabasePool
    let session: URLSession
    private let offlineCacheQueueExecutorBox = OfflineCacheQueueExecutorBox()
    private nonisolated(unsafe) let uiDefaults: UserDefaults
    private let clearsWebDataOnReset: Bool
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
        offlineCacheStore: (any OfflineCacheStoring)? = nil,
        forumCacheStore: ForumCacheStore? = nil,
        ordinaryImageCache: (any YamiboOrdinaryImageCacheClearing)? = nil,
        offlineCacheBackgroundDownloadTransport: OfflineCacheBackgroundDownloadTransport? = nil,
        offlineCacheContinuedProcessingCoordinator: OfflineCacheContinuedProcessingCoordinator = OfflineCacheContinuedProcessingCoordinator(),
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
        self.uiDefaults = uiDefaults
        self.clearsWebDataOnReset = clearsWebDataOnReset
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
        let resolvedOfflineCacheStore = offlineCacheStore ?? OfflineCacheStore(
            databasePool: resolvedGRDBDatabasePool,
            baseDirectory: Self.prepareOfflineCacheDirectory(rootDirectory: resolvedGRDBRootDirectory)
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
            readingProgressStore: self.readingProgressStore
        )
        self.mangaDirectorySearchCooldownState = mangaDirectorySearchCooldownState
        self.mangaReaderProjectionStore = mangaReaderProjectionStore ?? MangaReaderProjectionStore(diskCacheStore: diskCacheStore)
        self.offlineCacheStore = resolvedOfflineCacheStore
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
            offlineImages: resolvedOfflineCacheStore
        )
        self.ordinaryImageCache = ordinaryImageCache
        self.httpCache = httpCache
        self.offlineCacheBackgroundDownloadTransport = offlineCacheBackgroundDownloadTransport ?? OfflineCacheBackgroundDownloadTransport(sessionStore: sessionStore)
        self.offlineCacheContinuedProcessingCoordinator = offlineCacheContinuedProcessingCoordinator
        self.session = session
        self.wafRecoverer = wafRecoverer
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
            mangaOfflineCacheStore: offlineCacheStore,
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
            settingsStore: settingsStore,
            contentCoverStore: contentCoverStore,
            mangaDirectoryStore: mangaDirectoryStore,
            novelDetailDependencies: novelDetailDependencies,
            mangaDetailDependencies: mangaDetailDependencies,
            makeForumRepository: { [self] in await makeForumRepository() },
            makeForumThreadReaderRepository: { [self] in await makeForumThreadReaderRepository() },
            makeUserSpaceRepository: { [self] in await makeUserSpaceRepository() },
            makeBlogReaderRepository: { [self] in await makeBlogReaderRepository() },
            makeFavoriteRepository: { [self] in await makeFavoriteRepository() },
            makeThreadRouteResolver: { [self] in await makeThreadRouteResolver() }
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
            offlineCacheStore: offlineCacheStore,
            contentCoverStore: contentCoverStore,
            makeProjectionLoader: { [self] in await makeMangaReaderProjectionLoader() },
            makeDirectoryRepository: { [self] in await makeMangaDirectoryRepository() },
            makeChapterCommentsRepository: { [self] in await makeReaderChapterCommentsRepository() },
            makeOfflineCacheQueueExecutor: { [self] in await makeOfflineCacheQueueExecutor() },
            makeForumThreadReaderRepository: { [self] in await makeForumThreadReaderRepository() },
            account: accountDependencies,
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
            offlineCacheStore: offlineCacheStore,
            contentCoverStore: contentCoverStore,
            makeNovelReaderRepository: { [self] in await makeNovelReaderRepository() },
            makeChapterCommentsRepository: { [self] in await makeReaderChapterCommentsRepository() },
            makeOfflineCacheQueueExecutor: { [self] in await makeOfflineCacheQueueExecutor() },
            account: accountDependencies,
            like: likeLibraryDependencies,
            imagePipeline: imagePipeline
        )
    }

    public var accountDependencies: AccountDependencies {
        AccountDependencies(
            sessionStore: sessionStore,
            profileStore: profileStore,
            messageUnreadWorkflow: messageUnreadWorkflow,
            checkInStore: checkInStore,
            mangaDirectoryStore: mangaDirectoryStore,
            offlineCacheStore: offlineCacheStore,
            makeAccountService: { [self] in makeAccountService() },
            makeCheckInService: { [self] in makeCheckInService() },
            makeOfflineCacheQueueExecutor: { [self] in await makeOfflineCacheQueueExecutor() },
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
            offlineCacheStore: offlineCacheStore,
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
            offlineCacheStore: offlineCacheStore,
            novelOfflineAutoRefreshEnabled: { [settingsStore] in
                await settingsStore.load().novelOfflineCache.isAutoRefreshEnabled
            },
            novelOfflineRetainsInlineImages: { [settingsStore] in
                await settingsStore.load().novelOfflineCache.retainsInlineImages
            }
        )
    }

    func makeReaderChapterCommentsRepository() async -> ReaderChapterCommentsRepository {
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
            offlineCacheStore: offlineCacheStore
        )
    }

    func makeMangaDirectoryRepository() async -> any MangaDirectoryRepository {
        YamiboMangaDirectoryRepository(client: await makeClient())
    }

    public func makeOfflineCacheQueueExecutor() async -> OfflineCacheQueueExecutor {
        let snapshot = try? await sessionStore.snapshot()
        let generation = snapshot?.generation ?? UUID()
        if let executor = await offlineCacheQueueExecutorBox.value(for: generation) {
            return executor
        }

        let executor = OfflineCacheQueueExecutor(
            store: offlineCacheStore,
            mangaCacheStore: offlineCacheStore,
            novelCacheStore: offlineCacheStore,
            readerProjectionLoader: await makeMangaReaderProjectionLoader(),
            novelSourcePageLoader: await makeNovelReaderRepository(),
            imageAcquirer: OfflineCacheImageAcquirer(
                imagePipeline: imagePipeline,
                backgroundTransport: offlineCacheBackgroundDownloadTransport
            ),
            runObserver: offlineCacheContinuedProcessingCoordinator,
            isSessionCurrent: { [sessionStore] in
                await sessionStore.isCurrentGeneration(generation)
            }
        )
        return await offlineCacheQueueExecutorBox.setIfEmpty(executor, generation: generation)
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
            transition: { [self] commit in try await transitionAccount(commit) }
        )
    }

    private enum AccountWebDataCleanup: Sendable { case session, all, none }

    private func transitionAccount(webDataCleanup: AccountWebDataCleanup = .session, _ commit: @escaping @Sendable (UUID) async throws -> Void) async throws {
        // A failed durable save must leave the old identity and its UI intact.
        try await accountTransitionLifecycle.willBegin()
        let token = try await sessionStore.beginIdentityTransition()
        do {
            try await webDAVSyncSettingsStore.syncCoordinator.reset { [self] in
                do {
                    await messageUnreadWorkflow.prepareForAccountChange()
                    try await offlineCacheQueueExecutorBox.invalidate()
                    try await accountTransitionLifecycle.willChange()
                    try await forumCacheStore.clearAccountCaches()
                    try Task.checkCancellation()
                    try await commit(token)
                } catch {
                    await finishAccountTransition(token, webDataCleanup: webDataCleanup)
                    throw error
                }
                await finishAccountTransition(token, webDataCleanup: webDataCleanup)
            }
        } catch {
            await sessionStore.endIdentityTransition(token)
            throw error
        }
    }

    private func finishAccountTransition(_ token: UUID, webDataCleanup: AccountWebDataCleanup) async {
        let state = await sessionStore.load()
        switch webDataCleanup {
        case .all:
            await clearWebData()
        case .session:
            for storage in [session.configuration.httpCookieStorage, HTTPCookieStorage.shared].compactMap({ $0 }) {
                for cookie in storage.cookies ?? [] where YamiboDomain.containsYamiboDomain(cookie.domain) {
                    storage.deleteCookie(cookie)
                }
            }
            httpCache.removeAllCachedResponses()
            await websiteDataClearer?.clearYamiboCookies()
        case .none:
            break
        }
        await accountTransitionLifecycle.didChange(state)
        await sessionStore.endIdentityTransition(token)
        await messageUnreadWorkflow.finishAccountChange()
        await accountTransitionLifecycle.didPublish()
    }

    func makeWebDAVSyncService() -> WebDAVSyncService {
        WebDAVSyncService(
            settingsStore: webDAVSyncSettingsStore,
            sessionStore: sessionStore,
            participants: [
                MangaDirectoryWebDAVParticipant(store: mangaDirectoryStore),
                FavoriteLibraryWebDAVParticipant(store: localFavoriteLibraryStore),
                ReadingProgressWebDAVParticipant(store: readingProgressStore),
                AppSettingsWebDAVParticipant(store: settingsStore),
                LikeLibraryWebDAVParticipant(store: likeStore),
                BookmarkLibraryWebDAVParticipant(store: bookmarkStore),
                ContentCoverWebDAVParticipant(store: contentCoverStore),
                BrowsingHistoryWebDAVParticipant(store: browsingHistoryStore),
            ],
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
        try await sessionStore.accountOperations.run { [self] in
            try await transitionAccount(webDataCleanup: clearsWebDataOnReset ? .all : .none) { [self] token in
                try await sessionStore.resetAllAccounts(token: token)
                if sessionStore.accountStore == nil { await profileStore.clear() }
                try await resetLocalApplicationData()
            }
        }
    }

    private func resetLocalApplicationData() async throws {
        for participant in AppDataResetParticipant.allCases {
            if participant == .sessionStore || participant == .profileStore || participant == .webData { continue }
            try await reset(participant)
        }
    }

    private func reset(_ participant: AppDataResetParticipant) async throws {
        switch participant {
        case .sessionStore: try await sessionStore.reset()
        case .profileStore: await profileStore.clear()
        case .checkInStore: await checkInStore.clearAll()
        case .settingsStore: try await settingsStore.reset()
        case .webDAVSyncSettingsStore: try await webDAVSyncSettingsStore.reset()
        case .readerResumeRouteStore: await readerResumeRouteStore.clear()
        case .localFavoriteLibraryStore: try await localFavoriteLibraryStore.clearAll()
        case .favoriteUpdateStore: try await favoriteUpdateStore.clearAll()
        case .favoriteSyncRunStore: try await favoriteSyncRunStore.clearAll()
        case .readingProgressStore: try await readingProgressStore.clearAll()
        case .browsingHistoryStore: try await browsingHistoryStore.clearAll()
        case .composerDraftStore: try await composerDraftStore.clearAll()
        case .contentCoverStore: try await contentCoverStore.clearAll()
        case .novelReaderCacheStore: try await novelReaderCacheStore.clearAll()
        case .mangaDirectoryStore: try await mangaDirectoryStore.clearAll()
        case .mangaDirectorySearchCooldownState: await mangaDirectorySearchCooldownState.clear()
        case .mangaReaderProjectionStore: try await mangaReaderProjectionStore.clearAll()
        case .offlineCacheStore: try await offlineCacheStore.clearAll()
        case .forumCacheStore: try await forumCacheStore.clearAll()
        case .favoriteBackgroundImageStore: try await favoriteBackgroundImageStore.deleteAll()
        case .ordinaryImageCache: await clearOrdinaryImageCache()
        case .localUIState: clearLocalUIState()
        case .webData:
            if clearsWebDataOnReset { await clearWebData() }
        case .likeStore: try await likeStore.clearAll()
        case .likeImageStore: try await likeImageStore.deleteAll()
        case .bookmarkStore: try await bookmarkStore.clearAll()
        }
    }

    private func clearLocalUIState() {
        Self.resettableUserDefaultsKeys.forEach { uiDefaults.removeObject(forKey: $0) }
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
    private static func prepareOfflineCacheDirectory(
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let directory = offlineCacheDirectory(rootDirectory: rootDirectory)
        do {
            try OfflineCacheStore.createBackupExcludedDirectory(at: directory, fileManager: fileManager)
        } catch {
            YamiboLog.persistence.error("Failed to prepare the backup-excluded offline cache directory: \(error)")
        }
        return directory
    }

    private static func offlineCacheDirectory(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("offline-cache", isDirectory: true)
    }

    @MainActor
    private func clearWebData() async {
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        httpCache.removeAllCachedResponses()
        await websiteDataClearer?.clearAllWebsiteData()
    }
}

private actor OfflineCacheQueueExecutorBox {
    private var values: [UUID: OfflineCacheQueueExecutor] = [:]

    func value(for generation: UUID) -> OfflineCacheQueueExecutor? { values[generation] }

    func invalidate() async throws {
        let executors = Array(values.values)
        values.removeAll()
        for executor in executors { try await executor.invalidateForAccountChange() }
    }

    func setIfEmpty(_ executor: OfflineCacheQueueExecutor, generation: UUID) -> OfflineCacheQueueExecutor {
        if let value = values[generation] {
            return value
        }
        values[generation] = executor
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
