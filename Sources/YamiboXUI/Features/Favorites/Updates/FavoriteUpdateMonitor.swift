import Foundation
import YamiboXCore

/// Thin UI-facing snapshot publisher over `FavoriteUpdateCheckEngine`.
///
/// The check-run engine — network fetching, fingerprint comparison, circuit
/// breaking, offline handling, run persistence, and notification delivery —
/// lives in `YamiboXCore.FavoriteUpdateCheckEngine`. This type only republishes
/// the engine's state as `@Published` properties for SwiftUI observation and
/// forwards every trigger to the engine; it holds no domain logic of its own.
@MainActor
final class FavoriteUpdateMonitor: ObservableObject {
    @Published private(set) var snapshot: FavoriteUpdateRunSnapshot?
    @Published private(set) var events: [FavoriteUpdateEvent] = []
    @Published private(set) var fidFilters: [FavoriteUpdateFidFilter] = []
    @Published private(set) var categoryFilters: [FavoriteUpdateCategoryFilter] = []
    /// The authoritative per-target category scope, keyed by
    /// `FavoriteUpdateTargetKey`. UI category-filter matching for a
    /// `.mangaDirectory` event must read this rather than guessing from
    /// `FavoriteItem.target.id` equality (that lookup is `.favorite`-only by
    /// construction — a directory event's target id never matches one).
    @Published private(set) var trackedTargets: [FavoriteUpdateTrackedTarget] = []
    /// Mirrors the engine's error state, but stays independently settable so
    /// a view can clear a shown alert (`errorMessage = nil`) without that
    /// clear being resurrected by unrelated engine state changes — the engine
    /// only pushes this field when it actually writes a new error.
    @Published var errorMessage: String?

    private let engine: FavoriteUpdateCheckEngine

    /// Process-wide run-liveness registry shared by every monitor instance
    /// (favorites tab, settings page, background refresh task). This is the
    /// composition point all `FavoriteUpdateMonitor` construction sites flow
    /// through, so sharing the registry here preserves the original
    /// cross-instance orphan-detection semantics that the old
    /// `static var activeRunIDs` provided — while the mutable state itself
    /// now lives as plain instance state inside the registry/engine.
    private static let sharedRunRegistry = FavoriteUpdateActiveRunRegistry()

    init(
        updateStore: FavoriteUpdateStore,
        libraryStore: FavoriteLibraryStore,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> ForumThreadReaderRepository,
        settingsStore: SettingsStore? = nil,
        notifier: (any FavoriteUpdateNotifying)? = nil,
        pageFetcher: ((FavoriteItem) async throws -> ForumThreadPage)? = nil,
        mangaDirectoryStore: (any MangaDirectoryPersisting)? = nil,
        makeMangaDirectoryWorkflow: (@Sendable (_ searchForumID: String) async -> MangaDirectoryWorkflow)? = nil
    ) {
        engine = FavoriteUpdateCheckEngine(
            updateStore: updateStore,
            libraryStore: libraryStore,
            makeForumThreadReaderRepository: makeForumThreadReaderRepository,
            settingsStore: settingsStore,
            notifier: notifier,
            pageFetcher: pageFetcher,
            mangaDirectoryStore: mangaDirectoryStore,
            makeMangaDirectoryWorkflow: makeMangaDirectoryWorkflow,
            runRegistry: Self.sharedRunRegistry
        )
        engine.onStateChange = { [weak self] change in
            self?.publish(change)
        }
    }

    /// Copies the changed engine field into its `@Published` mirror. Called
    /// synchronously, once per engine assignment, so views observe state at
    /// exactly the same moments as when the monitor owned the state directly.
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
        }
    }

    // MARK: - Engine delegation

    /// Reloads the persisted run, events, and filters. A run still marked
    /// running whose task no longer exists is downgraded to interrupted.
    func load() async {
        await engine.load()
    }

    /// Refreshes events and filters from the store.
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

    /// Waits for an in-flight check to finish (background refresh completion).
    func waitForCompletion() async {
        await engine.waitForCompletion()
    }

    /// Configured automatic check interval, or nil without a settings store.
    func configuredInterval() async -> FavoriteUpdateCheckInterval? {
        await engine.configuredInterval()
    }

    func setConfiguredInterval(_ interval: FavoriteUpdateCheckInterval) async {
        await engine.setConfiguredInterval(interval)
    }

    /// Configured smart-manga chapter check interval, or nil without a
    /// settings store.
    func configuredMangaInterval() async -> SmartMangaUpdateCheckInterval? {
        await engine.configuredMangaInterval()
    }

    func setConfiguredMangaInterval(_ interval: SmartMangaUpdateCheckInterval) async {
        await engine.setConfiguredMangaInterval(interval)
    }

    /// Whether recent events keep arriving; drives the smart interval.
    var hasRecentEvents: Bool {
        engine.hasRecentEvents
    }

    /// Smart-manga-only counterpart of `hasRecentEvents`.
    var hasRecentMangaDirectoryEvents: Bool {
        engine.hasRecentMangaDirectoryEvents
    }

    /// Starts a check when the configured interval has elapsed since the last
    /// completed run — the foreground catch-up half of automatic checking.
    @discardableResult
    func startCheckIfDue(nonTagMangaDirectoryCheckCap: Int = 1) async -> Bool {
        await engine.startCheckIfDue(nonTagMangaDirectoryCheckCap: nonTagMangaDirectoryCheckCap)
    }

    // MARK: - Events and filters

    func markEventRead(_ eventID: String) async {
        await engine.markEventRead(eventID)
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

    // MARK: - Update notifications

    /// Whether detected updates are delivered as local notifications.
    func notificationsEnabled() async -> Bool {
        await engine.notificationsEnabled()
    }

    /// Persists the notification toggle and returns the effective value.
    @discardableResult
    func setNotificationsEnabled(_ enabled: Bool) async -> Bool {
        await engine.setNotificationsEnabled(enabled)
    }

    /// True when the user's toggle is on but the system permission has since
    /// been revoked — deliveries are silently skipped in that state.
    func notificationsBlockedBySystem() async -> Bool {
        await engine.notificationsBlockedBySystem()
    }
}
