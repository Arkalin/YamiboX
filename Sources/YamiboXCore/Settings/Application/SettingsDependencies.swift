import Foundation

/// Everything the system settings feature UI needs from the composition
/// root, including the packages of the features it hosts as sub-screens
/// (favorite sync section, WebDAV sync sheet).
public struct SettingsDependencies: Sendable {
    public let sessionStore: SessionStore
    public let blacklist: ForumBlacklistWorkflow
    public let settingsStore: SettingsStore
    public let favoriteBackgroundImageStore: FavoriteBackgroundImageStore
    public let launchBackgroundImageStore: CustomBackgroundImageStore
    public let favoriteBackgroundPersistence: CustomBackgroundPersistence
    public let launchBackgroundPersistence: CustomBackgroundPersistence
    public let novelReaderCacheStore: NovelReaderProjectionStore
    public let mangaDirectoryStore: MangaDirectoryStore
    public let mangaReaderProjectionStore: MangaReaderProjectionStore
    public let forumCacheStore: ForumCacheStore
    public let contentCoverStore: ContentCoverStore
    public let checkInStore: YamiboCheckInStore
    public let favoriteUpdateStore: FavoriteUpdateStore
    public let downloadStore: any DownloadStoring
    public let downloadQueue: DownloadQueueDependencies
    public let clearOrdinaryImageCache: @Sendable () async -> Void
    public let ordinaryImageCacheUsageBytes: @Sendable () async -> Int
    public let httpCache: URLCache
    public let networkLogStore: NetworkLogStore
    public let resetApplicationData: @Sendable () async throws -> Void
    /// The favorite sync section drives the library feature's view model.
    public let library: LibraryDependencies
    public let webDAVSync: WebDAVSyncDependencies

    public init(
        sessionStore: SessionStore,
        blacklist: ForumBlacklistWorkflow,
        settingsStore: SettingsStore,
        favoriteBackgroundImageStore: FavoriteBackgroundImageStore,
        launchBackgroundImageStore: CustomBackgroundImageStore,
        favoriteBackgroundPersistence: CustomBackgroundPersistence,
        launchBackgroundPersistence: CustomBackgroundPersistence,
        novelReaderCacheStore: NovelReaderProjectionStore,
        mangaDirectoryStore: MangaDirectoryStore,
        mangaReaderProjectionStore: MangaReaderProjectionStore,
        forumCacheStore: ForumCacheStore,
        contentCoverStore: ContentCoverStore,
        checkInStore: YamiboCheckInStore,
        favoriteUpdateStore: FavoriteUpdateStore,
        downloadStore: any DownloadStoring,
        downloadQueue: DownloadQueueDependencies,
        clearOrdinaryImageCache: @escaping @Sendable () async -> Void,
        ordinaryImageCacheUsageBytes: @escaping @Sendable () async -> Int,
        resetApplicationData: @escaping @Sendable () async throws -> Void,
        library: LibraryDependencies,
        webDAVSync: WebDAVSyncDependencies,
        httpCache: URLCache = .shared,
        networkLogStore: NetworkLogStore = .shared
    ) {
        self.sessionStore = sessionStore
        self.blacklist = blacklist
        self.settingsStore = settingsStore
        self.favoriteBackgroundImageStore = favoriteBackgroundImageStore
        self.launchBackgroundImageStore = launchBackgroundImageStore
        self.favoriteBackgroundPersistence = favoriteBackgroundPersistence
        self.launchBackgroundPersistence = launchBackgroundPersistence
        self.novelReaderCacheStore = novelReaderCacheStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.mangaReaderProjectionStore = mangaReaderProjectionStore
        self.forumCacheStore = forumCacheStore
        self.contentCoverStore = contentCoverStore
        self.checkInStore = checkInStore
        self.favoriteUpdateStore = favoriteUpdateStore
        self.downloadStore = downloadStore
        self.downloadQueue = downloadQueue
        self.clearOrdinaryImageCache = clearOrdinaryImageCache
        self.ordinaryImageCacheUsageBytes = ordinaryImageCacheUsageBytes
        self.httpCache = httpCache
        self.networkLogStore = networkLogStore
        self.resetApplicationData = resetApplicationData
        self.library = library
        self.webDAVSync = webDAVSync
    }
}
