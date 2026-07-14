import Foundation

/// Everything the system settings feature UI needs from the composition
/// root, including the packages of the features it hosts as sub-screens
/// (favorite sync section, WebDAV sync sheet).
public struct SettingsDependencies: Sendable {
    public let sessionStore: SessionStore
    public let settingsStore: SettingsStore
    public let favoriteBackgroundImageStore: FavoriteBackgroundImageStore
    public let novelReaderCacheStore: NovelReaderProjectionStore
    public let mangaDirectoryStore: MangaDirectoryStore
    public let mangaReaderProjectionStore: MangaReaderProjectionStore
    public let forumCacheStore: ForumCacheStore
    public let contentCoverStore: ContentCoverStore
    public let checkInStore: YamiboCheckInStore
    public let favoriteUpdateStore: FavoriteUpdateStore
    public let offlineCacheStore: any OfflineCacheStoring
    public let clearOrdinaryImageCache: @Sendable () async -> Void
    public let resetApplicationData: @Sendable () async throws -> Void
    /// The favorite sync section drives the library feature's view model.
    public let library: LibraryDependencies
    public let webDAVSync: WebDAVSyncDependencies

    public init(
        sessionStore: SessionStore,
        settingsStore: SettingsStore,
        favoriteBackgroundImageStore: FavoriteBackgroundImageStore,
        novelReaderCacheStore: NovelReaderProjectionStore,
        mangaDirectoryStore: MangaDirectoryStore,
        mangaReaderProjectionStore: MangaReaderProjectionStore,
        forumCacheStore: ForumCacheStore,
        contentCoverStore: ContentCoverStore,
        checkInStore: YamiboCheckInStore,
        favoriteUpdateStore: FavoriteUpdateStore,
        offlineCacheStore: any OfflineCacheStoring,
        clearOrdinaryImageCache: @escaping @Sendable () async -> Void,
        resetApplicationData: @escaping @Sendable () async throws -> Void,
        library: LibraryDependencies,
        webDAVSync: WebDAVSyncDependencies
    ) {
        self.sessionStore = sessionStore
        self.settingsStore = settingsStore
        self.favoriteBackgroundImageStore = favoriteBackgroundImageStore
        self.novelReaderCacheStore = novelReaderCacheStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.mangaReaderProjectionStore = mangaReaderProjectionStore
        self.forumCacheStore = forumCacheStore
        self.contentCoverStore = contentCoverStore
        self.checkInStore = checkInStore
        self.favoriteUpdateStore = favoriteUpdateStore
        self.offlineCacheStore = offlineCacheStore
        self.clearOrdinaryImageCache = clearOrdinaryImageCache
        self.resetApplicationData = resetApplicationData
        self.library = library
        self.webDAVSync = webDAVSync
    }
}
