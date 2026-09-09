/// Ordered inventory of the composition root's reset participants. New
/// participants must supply both a reset operation and a seeded regression
/// fixture through exhaustive switches; reset never bypasses store APIs.
enum AppDataResetParticipant: String, CaseIterable, Sendable {
    case sessionStore
    case profileStore
    case checkInStore
    case settingsStore
    case webDAVSyncSettingsStore
    case readerResumeRouteStore
    case localFavoriteLibraryStore
    case favoriteUpdateStore
    case favoriteSyncRunStore
    case readingProgressStore
    case browsingHistoryStore
    case contentCoverStore
    case novelReaderCacheStore
    case mangaDirectoryStore
    case mangaDirectorySearchCooldownState
    case mangaReaderProjectionStore
    case offlineCacheStore
    case forumCacheStore
    case favoriteBackgroundImageStore
    case ordinaryImageCache
    case localUIState
    case webData
    case likeStore
    case likeImageStore
    case bookmarkStore
}
