import Foundation
import YamiboXCore

@MainActor
final class FavoriteUpdateMonitor: ObservableObject {
    @Published private(set) var snapshot: FavoriteUpdateRunSnapshot?
    @Published private(set) var events: [FavoriteUpdateEvent] = [] {
        didSet { eventsRevision &+= 1 }
    }
    private(set) var eventsRevision: UInt64 = 0
    @Published private(set) var fidFilters: [FavoriteUpdateFidFilter] = [] {
        didSet { scopeRevision &+= 1 }
    }
    @Published private(set) var categoryFilters: [FavoriteUpdateCategoryFilter] = [] {
        didSet { scopeRevision &+= 1 }
    }
    @Published private(set) var trackedTargets: [FavoriteUpdateTrackedTarget] = [] {
        didSet { scopeRevision &+= 1 }
    }
    private(set) var scopeRevision: UInt64 = 0
    private(set) var errorIdentity = UUID()
    @Published var errorMessage: String? {
        didSet { errorIdentity = UUID(); errorDetails = nil }
    }
    @Published var errorDetails: LoadFailureDetails?

    private let engine: FavoriteUpdateCheckEngine

    private static let sharedRunRegistry = FavoriteUpdateActiveRunRegistry.shared

    static func prepareForAccountChange(updateStore: FavoriteUpdateStore) async {
        await sharedRunRegistry.prepareForAccountChange(storeID: updateStore.changeID)
    }

    static func finishAccountChange(updateStore: FavoriteUpdateStore) {
        sharedRunRegistry.finishAccountChange(storeID: updateStore.changeID)
    }

    static func makeForLibrary(
        _ dependencies: LibraryDependencies,
        notifier: any FavoriteUpdateNotifying = UserNotificationFavoriteUpdateNotifier()
    ) -> FavoriteUpdateMonitor {
        FavoriteUpdateMonitor(
            updateStore: dependencies.favoriteUpdateStore,
            libraryStore: dependencies.localFavoriteLibraryStore,
            makeForumThreadReaderRepository: dependencies.makeForumThreadReaderRepository,
            settingsStore: dependencies.settingsStore,
            notifier: notifier,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            makeMangaDirectoryWorkflow: { searchForumID in
                MangaDirectoryWorkflow(
                    repository: await dependencies.makeMangaDirectoryRepository(),
                    store: dependencies.mangaDirectoryStore,
                    configuration: MangaDirectoryWorkflowConfiguration(searchForumID: searchForumID),
                    searchCooldownState: dependencies.mangaDirectorySearchCooldownState
                )
            }
        )
    }

    init(
        updateStore: FavoriteUpdateStore,
        libraryStore: FavoriteLibraryStore,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> any ForumThreadPageFetching,
        settingsStore: SettingsStore? = nil,
        notifier: (any FavoriteUpdateNotifying)? = nil,
        mangaDirectoryStore: (any MangaDirectoryBatchReading)? = nil,
        makeMangaDirectoryWorkflow: (@Sendable (_ searchForumID: String) async -> MangaDirectoryWorkflow)? = nil
    ) {
        engine = FavoriteUpdateCheckEngine(
            updateStore: updateStore,
            libraryStore: libraryStore,
            makeForumThreadReaderRepository: makeForumThreadReaderRepository,
            settingsStore: settingsStore,
            notifier: notifier,
            mangaDirectoryStore: mangaDirectoryStore,
            makeMangaDirectoryWorkflow: makeMangaDirectoryWorkflow,
            runRegistry: Self.sharedRunRegistry
        )
        engine.onStateChange = { [weak self] change in
            self?.publish(change)
        }
    }

    private func publish(_ change: FavoriteUpdateCheckEngine.StateChange) {
        switch change {
        case .snapshot:
            snapshot = engine.snapshot
        case .events:
            events = engine.events
        case .fidFilters:
            fidFilters = engine.fidFilters
        case .categoryFilters:
            categoryFilters = engine.categoryFilters
        case .trackedTargets:
            trackedTargets = engine.trackedTargets
        case .errorMessage:
            errorMessage = engine.errorMessage
            errorDetails = engine.errorDetails
        }
    }

    func load() async {
        await engine.load()
    }

    func reloadEventState() async {
        await engine.reloadEventState()
    }

    @discardableResult
    func startCheck(nonTagMangaDirectoryCheckCap: Int = 1) async -> String? {
        await engine.startCheck(nonTagMangaDirectoryCheckCap: nonTagMangaDirectoryCheckCap)
    }

    func interrupt() async {
        await engine.interrupt()
    }

    func interruptOwnedRun() async {
        await engine.interrupt(ifOwned: true)
    }

    @discardableResult
    func waitForCompletion() async -> FavoriteUpdateRunSnapshot? {
        await engine.waitForCompletion()
    }

    func configuredInterval() async -> FavoriteUpdateCheckInterval? {
        await engine.configuredInterval()
    }

    func setConfiguredInterval(_ interval: FavoriteUpdateCheckInterval) async {
        await engine.setConfiguredInterval(interval)
    }

    func configuredMangaInterval() async -> SmartMangaUpdateCheckInterval? {
        await engine.configuredMangaInterval()
    }

    func setConfiguredMangaInterval(_ interval: SmartMangaUpdateCheckInterval) async {
        await engine.setConfiguredMangaInterval(interval)
    }

    var hasRecentEvents: Bool {
        engine.hasRecentEvents
    }

    var hasRecentMangaDirectoryEvents: Bool {
        engine.hasRecentMangaDirectoryEvents
    }

    @discardableResult
    func startCheckIfDue(nonTagMangaDirectoryCheckCap: Int = 1) async -> Bool {
        await engine.startCheckIfDue(nonTagMangaDirectoryCheckCap: nonTagMangaDirectoryCheckCap)
    }

    func markEventRead(_ eventID: String) async {
        await engine.markEventRead(eventID)
    }

    func markEventsRead(_ eventIDs: Set<String>) async {
        await engine.markEventsRead(eventIDs)
    }

    func dismissEvent(_ eventID: String) async {
        await engine.dismissEvent(eventID)
    }

    func dismissAllEvents() async {
        await engine.dismissAllEvents()
    }

    func setFidFilter(_ fid: String, enabled: Bool) async {
        await engine.setFidFilter(fid, enabled: enabled)
    }

    func setCategoryFilter(_ categoryID: String, enabled: Bool) async {
        await engine.setCategoryFilter(categoryID, enabled: enabled)
    }

    func notificationsEnabled() async -> Bool {
        await engine.notificationsEnabled()
    }

    @discardableResult
    func setNotificationsEnabled(_ enabled: Bool) async -> Bool {
        await engine.setNotificationsEnabled(enabled)
    }

    func notificationsBlockedBySystem() async -> Bool {
        await engine.notificationsBlockedBySystem()
    }
}
