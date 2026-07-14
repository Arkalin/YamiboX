import Foundation

/// Everything the account surface ("Mine" tab) needs from the composition
/// root: session/profile/check-in plus the offline cache queue it manages.
/// The readers embed this package for their cache queue sheets.
public struct AccountDependencies: Sendable {
    public let sessionStore: SessionStore
    public let profileStore: YamiboProfileStore
    public let checkInStore: YamiboCheckInStore
    public let mangaDirectoryStore: any MangaDirectoryPersisting
    public let offlineCacheStore: any OfflineCacheStoring
    public let makeAccountService: @Sendable () -> YamiboAccountService
    public let makeCheckInService: @Sendable () -> any YamiboCheckInServicing
    public let makeOfflineCacheQueueExecutor: @Sendable () async -> OfflineCacheQueueExecutor

    public init(
        sessionStore: SessionStore,
        profileStore: YamiboProfileStore,
        checkInStore: YamiboCheckInStore,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        offlineCacheStore: any OfflineCacheStoring,
        makeAccountService: @escaping @Sendable () -> YamiboAccountService,
        makeCheckInService: @escaping @Sendable () -> any YamiboCheckInServicing,
        makeOfflineCacheQueueExecutor: @escaping @Sendable () async -> OfflineCacheQueueExecutor
    ) {
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.checkInStore = checkInStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.offlineCacheStore = offlineCacheStore
        self.makeAccountService = makeAccountService
        self.makeCheckInService = makeCheckInService
        self.makeOfflineCacheQueueExecutor = makeOfflineCacheQueueExecutor
    }
}
