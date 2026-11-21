import Foundation
import UIKit
import YamiboXCore

@MainActor
final class FavoriteRemoteSyncSession: ObservableObject {
    typealias EngineRunner = @Sendable (
        _ snapshot: FavoriteRemoteSyncSnapshot,
        _ interruptionReason: @escaping @Sendable () -> FavoriteRemoteSyncWarning?,
        _ persist: @escaping @Sendable (FavoriteRemoteSyncSnapshot) async -> Void
    ) async -> FavoriteRemoteSyncSnapshot

    @Published private(set) var snapshot: FavoriteRemoteSyncSnapshot?
    private(set) var errorIdentity = UUID()
    @Published var errorMessage: String? {
        didSet { errorIdentity = UUID(); errorDetails = nil }
    }
    @Published var errorDetails: LoadFailureDetails?

    private let libraryStore: FavoriteLibraryStore
    private let runStore: FavoriteSyncRunStore
    private let contentCoverStore: ContentCoverStore
    private let mangaDirectoryStore: (any MangaDirectoryBatchReading)?
    private let settingsStore: SettingsStore?
    private let makeFavoriteRepository: @Sendable () async -> any FavoriteRemoteSyncOperating
    private let makeForumThreadReaderRepository: @Sendable () async -> any ThreadCoverPageResolving
    private let makeThreadRouteResolver: @Sendable () async -> YamiboThreadRouteResolver
    private let runnerOverride: EngineRunner?
    private let interruptionReasonBox = FavoriteSyncInterruptionReasonBox()
    private var terminalFailureDetails: LoadFailureDetails?

    private var syncTask: Task<Void, Never>?
    private var startTask: Task<String?, Never>?
    private var loadTask: Task<Void, Never>?
#if canImport(UIKit)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
#endif

    private final class StoreEntry {
        weak var session: FavoriteRemoteSyncSession?
        var isChangingAccount = false
    }

    private static var stores: [ObjectIdentifier: StoreEntry] = [:]

    static func shared(for dependencies: LibraryDependencies) -> FavoriteRemoteSyncSession {
        stores = stores.filter { $0.value.session != nil || $0.value.isChangingAccount }
        let key = ObjectIdentifier(dependencies.localFavoriteLibraryStore)
        let entry = stores[key] ?? StoreEntry()
        if let session = entry.session { return session }
        let session = Self(
            libraryStore: dependencies.localFavoriteLibraryStore,
            runStore: dependencies.favoriteSyncRunStore,
            contentCoverStore: dependencies.contentCoverStore,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            settingsStore: dependencies.settingsStore,
            makeFavoriteRepository: dependencies.makeFavoriteRepository,
            makeForumThreadReaderRepository: dependencies.makeForumThreadReaderRepository,
            makeThreadRouteResolver: dependencies.makeThreadRouteResolver
        )
        entry.session = session
        stores[key] = entry
        return session
    }

    static func cancelForAccountChange(libraryStore: FavoriteLibraryStore) async {
        let key = ObjectIdentifier(libraryStore)
        let entry = stores[key] ?? StoreEntry()
        entry.isChangingAccount = true
        stores[key] = entry
        guard let session = entry.session else { return }
        let start = session.startTask
        let run = session.syncTask
        let load = session.loadTask
        start?.cancel()
        run?.cancel()
        load?.cancel()
        await load?.value
        _ = await start?.value
        await run?.value
    }

    static func finishAccountChange(libraryStore: FavoriteLibraryStore) {
        let key = ObjectIdentifier(libraryStore)
        guard let entry = stores[key] else { return }
        entry.isChangingAccount = false
        if entry.session == nil { stores[key] = nil }
    }

    private var isChangingAccount: Bool {
        Self.stores[ObjectIdentifier(libraryStore)]?.isChangingAccount == true
    }

    init(
        libraryStore: FavoriteLibraryStore,
        runStore: FavoriteSyncRunStore,
        contentCoverStore: ContentCoverStore,
        mangaDirectoryStore: (any MangaDirectoryBatchReading)? = nil,
        settingsStore: SettingsStore? = nil,
        makeFavoriteRepository: @escaping @Sendable () async -> any FavoriteRemoteSyncOperating,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> any ThreadCoverPageResolving,
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
    }

    func load() async {
        guard !isChangingAccount, startTask == nil, syncTask == nil else { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { @MainActor in
            defer { loadTask = nil }
            let persisted = await runStore.latestSnapshot()
            guard !Task.isCancelled, !isChangingAccount else { return }
            let latest = await interruptedSnapshotIfNeeded(persisted)
            guard !Task.isCancelled, !isChangingAccount else { return }
            snapshot = latest
        }
        loadTask = task
        await task.value
    }

    @discardableResult
    func start(targetCategoryID: String) async -> String? {
        guard !isChangingAccount else { return nil }
        if let startTask { return await startTask.value }
        if syncTask != nil { return snapshot?.runID }

        let task = Task { @MainActor in
            defer { startTask = nil }
            await loadTask?.value
            return await beginRun(targetCategoryID: targetCategoryID)
        }
        startTask = task
        return await task.value
    }

    private func beginRun(targetCategoryID: String) async -> String? {
        guard !isChangingAccount, !Task.isCancelled else { return nil }
        let document = (try? await libraryStore.load()) ?? FavoriteLibraryDocument()
        guard !isChangingAccount, !Task.isCancelled else { return nil }
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
        guard !isChangingAccount, !Task.isCancelled else {
            snapshot = await interruptedSnapshotIfNeeded(
                startedSnapshot,
                reason: interruptionReasonBox.take() ?? .interrupted
            )
            endBackgroundTask()
            return nil
        }

        let runSnapshot = startedSnapshot
        syncTask = Task { @MainActor in
            await run(startSnapshot: runSnapshot)
        }
        return startedSnapshot.runID
    }

    @discardableResult
    func resume() async -> String? {
        guard let snapshot else { return nil }
        return await start(targetCategoryID: snapshot.targetCategoryID)
    }

    func interrupt() async {
        guard startTask != nil || syncTask != nil else { return }
        interruptionReasonBox.set(.interruptedByUser)
        startTask?.cancel()
        syncTask?.cancel()
    }

    func hideCard() async {
        guard var snapshot else { return }
        snapshot.isHiddenFromFavoritePage = true
        self.snapshot = snapshot
        await persistHiddenCard(runID: snapshot.runID)
    }

    private func run(startSnapshot: FavoriteRemoteSyncSnapshot) async {
        defer {
            endBackgroundTask()
            syncTask = nil
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

    private func applyEngineSnapshot(_ updated: FavoriteRemoteSyncSnapshot, appendingAfter previousCounts: FavoriteRemoteSyncEntryCounts? = nil) async {
        var merged = updated
        if let current = snapshot, current.runID == updated.runID {
            merged.isHiddenFromFavoritePage = current.isHiddenFromFavoritePage
        }
        await persistSnapshot(merged, appendingAfter: previousCounts)
        if let current = snapshot, current.runID == merged.runID,
           current.isHiddenFromFavoritePage && !merged.isHiddenFromFavoritePage {
            merged.isHiddenFromFavoritePage = true
            await persistHiddenCard(runID: merged.runID)
        }
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
                persistIncrementally: { [weak self] updated, previousCounts in
                    await self?.applyEngineSnapshot(updated, appendingAfter: previousCounts)
                },
                persist: persist
            )
        }
    }

    private func retainTerminalFailure(_ details: LoadFailureDetails, runID: String) {
        guard snapshot?.runID == runID else { return }
        terminalFailureDetails = details
    }

    private func interruptedSnapshotIfNeeded(
        _ snapshot: FavoriteRemoteSyncSnapshot?,
        reason: FavoriteRemoteSyncWarning = .taskLost
    ) async -> FavoriteRemoteSyncSnapshot? {
        guard var snapshot else { return nil }
        guard snapshot.status == .running else { return snapshot }
        snapshot.status = .interrupted
        snapshot.phase = .interrupted
        snapshot.finishedAt = snapshot.finishedAt ?? .now
        snapshot.updatedAt = .now
        snapshot.warnings.append(reason)
        snapshot.logEntries.append(reason == .taskLost ? .taskLost : .interrupted)
        await persistSnapshot(snapshot)
        return snapshot
    }

    private func persistSnapshot(_ snapshot: FavoriteRemoteSyncSnapshot, appendingAfter previousCounts: FavoriteRemoteSyncEntryCounts? = nil) async {
        let runStore = runStore
        do {
            try await Task {
                if let previousCounts {
                    try await runStore.saveAppending(snapshot, after: previousCounts)
                } else {
                    try await runStore.save(snapshot)
                }
            }.value
        } catch {
            YamiboLog.sync.error("Failed to persist favorite sync snapshot for run \(snapshot.runID): \(error.localizedDescription)")
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
        }
    }

    private func persistHiddenCard(runID: String) async {
        let runStore = runStore
        do {
            try await Task { try await runStore.hideCard(runID: runID) }.value
        } catch {
            YamiboLog.sync.error("Failed to persist favorite sync hidden card for run \(runID): \(error.localizedDescription)")
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
        }
    }

    @discardableResult
    private func beginBackgroundTask(runID: String) -> Bool {
#if canImport(UIKit)
        guard backgroundTaskID == .invalid else { return true }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "FavoriteRemoteSync") { [weak self] in
            Task { @MainActor in
                guard let self, self.snapshot?.runID == runID else { return }
                self.interruptionReasonBox.set(.backgroundExpired)
                self.startTask?.cancel()
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
