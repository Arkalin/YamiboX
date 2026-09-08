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
    let ordinaryImageCache: any YamiboOrdinaryImageCacheClearing
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

    public init(
        sessionStore: SessionStore = SessionStore(),
        profileStore: YamiboProfileStore = YamiboProfileStore(),
        checkInStore: YamiboCheckInStore = YamiboCheckInStore(),
        settingsStore: SettingsStore = SettingsStore(),
        webDAVSyncSettingsStore: WebDAVSyncSettingsStore = WebDAVSyncSettingsStore(),
        readerResumeRouteStore: ReaderResumeRouteStore = ReaderResumeRouteStore(),
        localFavoriteLibraryStore: FavoriteLibraryStore? = nil,
        favoriteUpdateStore: FavoriteUpdateStore? = nil,
        favoriteSyncRunStore: FavoriteSyncRunStore? = nil,
        readingProgressStore: ReadingProgressStore? = nil,
        browsingHistoryStore: BrowsingHistoryStore? = nil,
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
        wafRecoverer: (any YamiboWAFChallengeRecovering)? = nil
    ) {
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
            UserSpaceRepository(client: YamiboClient(session: session, credentials: state.credentials))
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
        self.browsingHistoryStore = browsingHistoryStore ?? BrowsingHistoryStore(databasePool: resolvedGRDBDatabasePool)
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
            favoriteUpdateStore: resolvedFavoriteUpdateStore
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
        self.ordinaryImageCache = ordinaryImageCache ?? YamiboImageDataPipeline.shared
        self.offlineCacheBackgroundDownloadTransport = offlineCacheBackgroundDownloadTransport ?? OfflineCacheBackgroundDownloadTransport(sessionStore: sessionStore)
        self.offlineCacheContinuedProcessingCoordinator = offlineCacheContinuedProcessingCoordinator
        self.session = session
        self.wafRecoverer = wafRecoverer
        YamiboImagePipeline.shared.setOfflineImageProvider(resolvedOfflineCacheStore)
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
            like: likeLibraryDependencies
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
            like: likeLibraryDependencies
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
            makeOfflineCacheQueueExecutor: { [self] in await makeOfflineCacheQueueExecutor() }
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
            ordinaryImageCacheUsageBytes: { [ordinaryImageCache] in await ordinaryImageCache.totalDiskUsageBytes() },
            resetApplicationData: { [self] in try await resetApplicationData() },
            library: libraryDependencies,
            webDAVSync: webDAVSyncDependencies
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
        let sessionState = await sessionStore.load()
        return YamiboClient(
            session: session,
            credentials: sessionState.credentials,
            wafRecoverer: wafRecoverer
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
        ForumRepository(client: await makeClient(), cacheStore: forumCacheStore)
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
        if let executor = await offlineCacheQueueExecutorBox.value {
            return executor
        }

        let executor = OfflineCacheQueueExecutor(
            store: offlineCacheStore,
            mangaCacheStore: offlineCacheStore,
            novelCacheStore: offlineCacheStore,
            readerProjectionLoader: await makeMangaReaderProjectionLoader(),
            novelSourcePageLoader: await makeNovelReaderRepository(),
            imageAcquirer: OfflineCacheImageAcquirer(
                backgroundTransport: offlineCacheBackgroundDownloadTransport
            ),
            runObserver: offlineCacheContinuedProcessingCoordinator
        )
        return await offlineCacheQueueExecutorBox.setIfEmpty(executor)
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
            wafRecoverer: wafRecoverer
        )
    }

    func makeWebDAVSyncService() -> WebDAVSyncService {
        WebDAVSyncService(
            settingsStore: webDAVSyncSettingsStore,
            sessionStore: sessionStore,
            participants: [
                FavoriteLibraryWebDAVParticipant(store: localFavoriteLibraryStore),
                ReadingProgressWebDAVParticipant(store: readingProgressStore),
                AppSettingsWebDAVParticipant(store: settingsStore),
                LikeLibraryWebDAVParticipant(store: likeStore),
                BookmarkLibraryWebDAVParticipant(store: bookmarkStore),
                ContentCoverWebDAVParticipant(store: contentCoverStore),
            ],
            client: WebDAVClient(session: session)
        )
    }

    func clearOrdinaryImageCache() async {
        await ordinaryImageCache.removeAllCachedData()
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
        try await webDAVSyncSettingsStore.syncCoordinator.reset { [self] in
            try await resetLocalApplicationData()
        }
    }

    private func resetLocalApplicationData() async throws {
        try await sessionStore.reset()
        await profileStore.clear()
        await checkInStore.clearAll()
        try await settingsStore.reset()
        try await webDAVSyncSettingsStore.reset()
        await readerResumeRouteStore.clear()
        try await localFavoriteLibraryStore.clearAll()
        try await favoriteUpdateStore.clearAll()
        try await readingProgressStore.clearAll()
        try await browsingHistoryStore.clearAll()
        try await contentCoverStore.clearAll()
        try await novelReaderCacheStore.clearAll()
        try await mangaDirectoryStore.clearAll()
        await mangaDirectorySearchCooldownState.clear()
        try await mangaReaderProjectionStore.clearAll()
        try await offlineCacheStore.clearAll()
        try await forumCacheStore.clearAll()
        try await favoriteBackgroundImageStore.deleteAll()
        await clearOrdinaryImageCache()
        clearLocalUIState()
        if clearsWebDataOnReset {
            await clearWebData()
        }
        try await likeStore.clearAll()
        try await likeImageStore.deleteAll()
        try await bookmarkStore.clearAll()
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
        URLCache.shared.removeAllCachedResponses()
        await websiteDataClearer?.clearAllWebsiteData()
    }
}

private actor OfflineCacheQueueExecutorBox {
    var value: OfflineCacheQueueExecutor?

    func setIfEmpty(_ executor: OfflineCacheQueueExecutor) -> OfflineCacheQueueExecutor {
        if let value {
            return value
        }
        value = executor
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
