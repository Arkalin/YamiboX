import Foundation
import UIKit
import YamiboXCore

/// State machine for one Yamibo remote favorite sync run. The five-phase
/// engine (`FavoriteYamiboSyncEngine`) does the actual work; this session
/// owns task lifecycle, background-task extension, and snapshot persistence
/// through `FavoriteSyncRunStore`.
///
/// Library changes are written through the shared `FavoriteLibraryStore`,
/// whose change notification lets `FavoriteLibraryOrganizer` refresh itself;
/// this session never touches the organizer directly.
@MainActor
final class FavoriteRemoteSyncSession: ObservableObject {
    /// Runs the sync for one snapshot, reporting progress through the persist
    /// callback and returning the terminal snapshot. Tests inject a fake.
    typealias EngineRunner = @Sendable (
        _ snapshot: FavoriteRemoteSyncSnapshot,
        _ interruptionReason: @escaping @Sendable () -> FavoriteRemoteSyncWarning?,
        _ persist: @escaping @Sendable (FavoriteRemoteSyncSnapshot) async -> Void
    ) async -> FavoriteRemoteSyncSnapshot

    @Published private(set) var snapshot: FavoriteRemoteSyncSnapshot?
    @Published var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    @Published var errorDetails: LoadFailureDetails?

    private let libraryStore: FavoriteLibraryStore
    private let runStore: FavoriteSyncRunStore
    private let contentCoverStore: ContentCoverStore
    /// Backs the sync-time "imported into an already-favorited manga
    /// directory" warning (smart-comic-mode Phase G, design decision #8's
    /// remote-sync half). Concrete type, not the `MangaDirectoryPersisting`
    /// existential — mirrors `FavoriteLibraryOrganizer`'s equivalent
    /// property so production code can never accidentally fall onto the
    /// protocol's naive per-tid default implementation. `nil` (as in most
    /// existing tests, which don't exercise this feature) just disables it.
    private let mangaDirectoryStore: MangaDirectoryStore?
    /// Backs the per-item Smart Comic Mode board check the same warning
    /// needs.
    private let settingsStore: SettingsStore?
    private let makeFavoriteRepository: @Sendable () async -> FavoriteRepository
    private let makeForumThreadReaderRepository: @Sendable () async -> ForumThreadReaderRepository
    private let makeThreadRouteResolver: @Sendable () async -> YamiboThreadRouteResolver
    private let runnerOverride: EngineRunner?
    private let interruptionReasonBox = FavoriteSyncInterruptionReasonBox()
    private var terminalFailureDetails: LoadFailureDetails?

    private var syncTask: Task<Void, Never>?
    private var accountGeneration = UUID()
    private var isStarting = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
#if canImport(UIKit)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
#endif

    private static var activeRunCancelHandlers: [String: () -> Void] = [:]
    private static var activeRunWaitHandlers: [String: () async -> Void] = [:]
    private static var activeRunLibraries: [String: FavoriteLibraryStore] = [:]
    private static let instances = NSHashTable<FavoriteRemoteSyncSession>.weakObjects()

    static func cancelForAccountChange(libraryStore: FavoriteLibraryStore) async {
        let sessions = instances.allObjects.filter { $0.libraryStore === libraryStore }
        for session in sessions { session.accountGeneration = UUID() }
        let runs = activeRunLibraries.filter { $0.value === libraryStore }.map(\.key)
        let waits = runs.compactMap { activeRunWaitHandlers[$0] }
        for run in runs { activeRunCancelHandlers[run]?() }
        for session in sessions where session.isStarting {
            await withCheckedContinuation { session.startWaiters.append($0) }
        }
        for wait in waits { await wait() }
    }

    static func isRunActive(_ runID: String) -> Bool {
        activeRunCancelHandlers[runID] != nil
    }

    init(
        libraryStore: FavoriteLibraryStore,
        runStore: FavoriteSyncRunStore,
        contentCoverStore: ContentCoverStore,
        mangaDirectoryStore: MangaDirectoryStore? = nil,
        settingsStore: SettingsStore? = nil,
        makeFavoriteRepository: @escaping @Sendable () async -> FavoriteRepository,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> ForumThreadReaderRepository,
        makeThreadRouteResolver: @escaping @Sendable () async -> YamiboThreadRouteResolver,
        runnerOverride: EngineRunner? = nil
    ) {
        self.libraryStore = libraryStore
        self.runStore = runStore
        self.contentCoverStore = contentCoverStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.settingsStore = settingsStore
        self.makeFavoriteRepository = makeFavoriteRepository
        self.makeForumThreadReaderRepository = makeForumThreadReaderRepository
        self.makeThreadRouteResolver = makeThreadRouteResolver
        self.runnerOverride = runnerOverride
        Self.instances.add(self)
    }

    deinit {
        syncTask?.cancel()
    }

    /// Restores the persisted snapshot; a snapshot still marked running whose
    /// task no longer exists is downgraded to interrupted.
    func load() async {
        snapshot = await interruptedSnapshotIfNeeded(runStore.latestSnapshot())
    }

    @discardableResult
    func start(targetCategoryID: String) async -> String? {
        guard !isStarting else { return snapshot?.runID }
        if snapshot?.status == .running {
            return snapshot?.runID
        }
        isStarting = true
        let generation = accountGeneration
        defer {
            isStarting = false
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        // Display-name resolution only; the engine re-validates the category
        // against its own (throwing) load, so an empty fallback is safe here.
        let document = (try? await libraryStore.load()) ?? FavoriteLibraryDocument()
        guard generation == accountGeneration, !Task.isCancelled else { return nil }
        let categoryName = document.categories.first { $0.id == targetCategoryID }?.displayName
            ?? document.defaultCategory.displayName
        let now = Date()
        var startedSnapshot = FavoriteRemoteSyncSnapshot(
            status: .running,
            targetCategoryID: targetCategoryID,
            targetCategoryName: categoryName,
            phase: .queued,
            startedAt: now,
            updatedAt: now,
            logEntries: [.started(categoryName: categoryName)]
        )
        interruptionReasonBox.set(nil)
        terminalFailureDetails = nil
        errorMessage = nil
        let backgroundTaskAvailable = beginBackgroundTask(runID: startedSnapshot.runID)
        if !backgroundTaskAvailable {
            startedSnapshot.warnings.append(.backgroundUnavailable)
        }
        snapshot = startedSnapshot
        await persistSnapshot(startedSnapshot)
        guard generation == accountGeneration, !Task.isCancelled else {
            snapshot = await interruptedSnapshotIfNeeded(startedSnapshot)
            endBackgroundTask()
            return nil
        }

        syncTask?.cancel()
        let runSnapshot = startedSnapshot
        syncTask = Task { @MainActor [weak self] in
            // If `self` is already gone by the time this body runs, `run()`
            // never executes, so its `defer` never removes the entry
            // inserted just below — remove it here instead, or it orphans
            // `activeRunCancelHandlers` forever and `isRunActive` never
            // downgrades the stale "running" snapshot to interrupted.
            guard let self else {
                Self.activeRunCancelHandlers[runSnapshot.runID] = nil
                Self.activeRunWaitHandlers[runSnapshot.runID] = nil
                Self.activeRunLibraries[runSnapshot.runID] = nil
                return
            }
            await self.run(startSnapshot: runSnapshot)
        }
        Self.activeRunCancelHandlers[startedSnapshot.runID] = { [weak self] in
            self?.syncTask?.cancel()
        }
        let running = syncTask
        Self.activeRunWaitHandlers[startedSnapshot.runID] = { await running?.value }
        Self.activeRunLibraries[startedSnapshot.runID] = libraryStore
        return startedSnapshot.runID
    }

    @discardableResult
    func resume() async -> String? {
        guard let snapshot else { return nil }
        return await start(targetCategoryID: snapshot.targetCategoryID)
    }

    func interrupt() async {
        guard snapshot?.status == .running else { return }
        interruptionReasonBox.set(.interruptedByUser)
        syncTask?.cancel()
    }

    func hideCard() async {
        guard var snapshot else { return }
        snapshot.isHiddenFromFavoritePage = true
        self.snapshot = snapshot
        await persistSnapshot(snapshot)
    }

    // MARK: - Run

    private func run(startSnapshot: FavoriteRemoteSyncSnapshot) async {
        let runID = startSnapshot.runID
        defer {
            endBackgroundTask()
            Self.activeRunCancelHandlers[runID] = nil
            Self.activeRunWaitHandlers[runID] = nil
            Self.activeRunLibraries[runID] = nil
        }

        let runner = runnerOverride ?? makeEngineRunner()
        let interruptionReason: @Sendable () -> FavoriteRemoteSyncWarning? = { [interruptionReasonBox] in
            interruptionReasonBox.take()
        }
        let persist: @Sendable (FavoriteRemoteSyncSnapshot) async -> Void = { [weak self] updated in
            await self?.applyEngineSnapshot(updated)
        }
        let final = await runner(startSnapshot, interruptionReason, persist)
        switch final.status {
        case .completed:
            errorMessage = nil
        case .failed:
            errorMessage = final.errorMessages.last
            errorDetails = terminalFailureDetails
        case .running, .interrupted:
            break
        }
    }

    /// Merges an engine-produced snapshot with session-owned presentation
    /// state (card hiding), persists it, then publishes it. Persist-first
    /// keeps the published state from ever running ahead of the stored one.
    private func applyEngineSnapshot(_ updated: FavoriteRemoteSyncSnapshot) async {
        var merged = updated
        if let current = snapshot, current.runID == updated.runID {
            merged.isHiddenFromFavoritePage = current.isHiddenFromFavoritePage
        }
        await persistSnapshot(merged)
        snapshot = merged
    }

    private func makeEngineRunner() -> EngineRunner {
        let libraryStore = libraryStore
        let contentCoverStore = contentCoverStore
        let mangaDirectoryStore = mangaDirectoryStore
        let settingsStore = settingsStore
        let makeFavoriteRepository = makeFavoriteRepository
        let makeForumThreadReaderRepository = makeForumThreadReaderRepository
        let makeThreadRouteResolver = makeThreadRouteResolver
        return { [weak self] snapshot, interruptionReason, persist in
            let repository = await makeFavoriteRepository()
            let resolver = await makeThreadRouteResolver()
            let coverRepository = await makeForumThreadReaderRepository()
            let client = FavoriteYamiboSyncClient(
                repository: repository,
                resolver: resolver,
                coverRepository: coverRepository,
                contentCoverStore: contentCoverStore
            )
            let engine = FavoriteYamiboSyncEngine(
                libraryStore: libraryStore,
                client: client,
                mangaDirectoryStore: mangaDirectoryStore,
                settingsStore: settingsStore
            )
            return await engine.run(
                snapshot: snapshot,
                interruptionReason: interruptionReason,
                onFailure: { [weak self] details in
                    await self?.retainTerminalFailure(details, runID: snapshot.runID)
                },
                persist: persist
            )
        }
    }

    // MARK: - Snapshot state

    private func retainTerminalFailure(_ details: LoadFailureDetails, runID: String) {
        guard snapshot?.runID == runID else { return }
        terminalFailureDetails = details
    }

    private func interruptedSnapshotIfNeeded(_ snapshot: FavoriteRemoteSyncSnapshot?) async -> FavoriteRemoteSyncSnapshot? {
        guard var snapshot else { return nil }
        guard snapshot.status == .running else { return snapshot }
        guard !Self.isRunActive(snapshot.runID) else { return snapshot }
        snapshot.status = .interrupted
        snapshot.phase = .interrupted
        snapshot.finishedAt = snapshot.finishedAt ?? .now
        snapshot.updatedAt = .now
        snapshot.warnings.append(.taskLost)
        snapshot.logEntries.append(.taskLost)
        await persistSnapshot(snapshot)
        return snapshot
    }

    private func persistSnapshot(_ snapshot: FavoriteRemoteSyncSnapshot) async {
        // Unstructured task: the terminal snapshot of an interrupted run is
        // written from the cancelled sync task, and GRDB's async accesses
        // honor Task cancellation — the write must not inherit it.
        let runStore = runStore
        do {
            try await Task {
                try await runStore.save(snapshot)
            }.value
        } catch {
            YamiboLog.sync.error("Failed to persist favorite sync snapshot for run \(snapshot.runID): \(error.localizedDescription)")
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
        }
    }

    // MARK: - Background task

    @discardableResult
    private func beginBackgroundTask(runID: String) -> Bool {
#if canImport(UIKit)
        guard backgroundTaskID == .invalid else { return true }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "FavoriteRemoteSync") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.interruptionReasonBox.set(.backgroundExpired)
                self.syncTask?.cancel()
                self.endBackgroundTask()
            }
        }
        return backgroundTaskID != .invalid
#else
        return true
#endif
    }

    private func endBackgroundTask() {
#if canImport(UIKit)
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
#endif
    }
}

/// Thread-safe slot for the reason an in-flight run is being cancelled, read
/// by the engine when it observes the cancellation.
private final class FavoriteSyncInterruptionReasonBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: FavoriteRemoteSyncWarning?

    func set(_ new: FavoriteRemoteSyncWarning?) {
        lock.lock()
        reason = new
        lock.unlock()
    }

    func take() -> FavoriteRemoteSyncWarning? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }
}
