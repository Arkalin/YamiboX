import Foundation

/// Everything the account surface ("Mine" tab) needs from the composition
/// root: session/profile/check-in plus the download queue it manages.
public struct AccountDependencies: Sendable {
    public var downloadQueue: DownloadQueueDependencies {
        DownloadQueueDependencies(
            sessionStore: sessionStore,
            downloadStore: downloadStore,
            mangaDirectoryStore: mangaDirectoryStore,
            makeDownloadQueueExecutor: makeDownloadQueueExecutor
        )
    }

    public let sessionStore: SessionStore
    public let profileStore: YamiboProfileStore
    public let accountSwitcher: AccountSwitchCoordinator?
    public let messageUnreadWorkflow: MessageUnreadWorkflow
    public let checkInStore: YamiboCheckInStore
    public let mangaDirectoryStore: any MangaDirectoryPersisting
    public let downloadStore: any DownloadStoring
    public let imagePipeline: any YamiboImageDataLoading
    public let makeAccountService: @Sendable () -> YamiboAccountService
    public let makeCheckInService: @Sendable () -> any YamiboCheckInServicing
    public let makeDownloadQueueExecutor: @Sendable () async -> DownloadQueueExecutor

    public init(
        sessionStore: SessionStore,
        profileStore: YamiboProfileStore,
        messageUnreadWorkflow: MessageUnreadWorkflow,
        checkInStore: YamiboCheckInStore,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        downloadStore: any DownloadStoring,
        makeAccountService: @escaping @Sendable () -> YamiboAccountService,
        makeCheckInService: @escaping @Sendable () -> any YamiboCheckInServicing,
        makeDownloadQueueExecutor: @escaping @Sendable () async -> DownloadQueueExecutor,
        imagePipeline: (any YamiboImageDataLoading)? = nil,
        accountSwitcher: AccountSwitchCoordinator? = nil
    ) {
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.accountSwitcher = accountSwitcher
        self.messageUnreadWorkflow = messageUnreadWorkflow
        self.checkInStore = checkInStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.downloadStore = downloadStore
        self.imagePipeline = imagePipeline ?? YamiboImagePipeline(
            sessionStore: sessionStore,
            offlineImages: downloadStore
        )
        self.makeAccountService = makeAccountService
        self.makeCheckInService = makeCheckInService
        self.makeDownloadQueueExecutor = makeDownloadQueueExecutor
    }
}
