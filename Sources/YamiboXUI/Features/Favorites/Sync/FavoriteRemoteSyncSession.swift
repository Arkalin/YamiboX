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
    @Published var errorMessage: String?

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

    private var syncTask: Task<Void, Never>?
#if canImport(UIKit)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
#endif

    private static var activeRunCancelHandlers: [String: () -> Void] = [:]

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
        if snapshot?.status == .running {
            return snapshot?.runID
        }

        // Display-name resolution only; the engine re-validates the category
        // against its own (throwing) load, so an empty fallback is safe here.
        let document = (try? await libraryStore.load()) ?? FavoriteLibraryDocument()
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
        let backgroundTaskAvailable = beginBackgroundTask(runID: startedSnapshot.runID)
        if !backgroundTaskAvailable {
            startedSnapshot.warnings.append(.backgroundUnavailable)
        }
        snapshot = startedSnapshot
        await persistSnapshot(startedSnapshot)

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
                return
            }
            await self.run(startSnapshot: runSnapshot)
        }
        Self.activeRunCancelHandlers[startedSnapshot.runID] = { [weak self] in
            self?.syncTask?.cancel()
        }
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
        return { snapshot, interruptionReason, persist in
            let repository = await makeFavoriteRepository()
            let resolver = await makeThreadRouteResolver()
            let coverRepository = await makeForumThreadReaderRepository()
            let formHashBox = FavoriteSyncFormHashBox()
            let client = FavoriteYamiboSyncClient(
                fetchPage: { page in
                    let result = try await repository.fetchFavoritesPage(page: page)
                    let entries = result.favorites.map { favorite in
                        YamiboRemoteFavoriteEntry(
                            remoteFavoriteID: favorite.remoteFavoriteID ?? favorite.id,
                            threadID: favorite.threadID,
                            title: favorite.title
                        )
                    }
                    return FavoriteYamiboRemotePage(
                        entries: entries,
                        currentPage: result.currentPage,
                        totalPages: result.totalPages
                    )
                },
                probe: { entry in
                    let result = try await Self.probeResult(
                        forThreadID: entry.threadID,
                        title: entry.title,
                        resolver: resolver,
                        coverRepository: coverRepository
                    )
                    if let coverURL = result.coverURL, let key = ContentCoverKey(target: result.target) {
                        do {
                            _ = try await contentCoverStore.setAutomaticCover(coverURL, for: key)
                        } catch {
                            YamiboLog.sync.warning("Failed to persist automatic cover during sync for thread \(entry.threadID): \(error.localizedDescription)")
                        }
                    }
                    return result
                },
                addFavorite: { threadID in
                    let formHash = try await formHashBox.formHash(repository: repository)
                    _ = try await repository.addThreadFavorite(
                        threadID: threadID,
                        formHash: formHash,
                        resolveRemoteFavorite: false
                    )
                }
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
                persist: persist
            )
        }
    }

    // MARK: - Snapshot state

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
            errorMessage = error.localizedDescription
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

    // MARK: - Thread probing

    private static func probeResult(
        forThreadID threadID: String,
        title: String?,
        resolver: YamiboThreadRouteResolver,
        coverRepository: ForumThreadReaderRepository
    ) async throws -> FavoriteThreadProbeResult {
        let url = YamiboRoute.threadByID(tid: threadID, page: 1, authorID: nil, reverse: false).url
        switch try await resolver.resolve(YamiboThreadRouteRequest(threadURL: url, title: title)) {
        case let .novel(payload):
            let metadata = await threadMetadata(
                thread: ThreadIdentity(tid: payload.thread.tid),
                title: payload.title,
                repository: coverRepository
            )
            return FavoriteThreadProbeResult(
                target: .novelThread(threadID: payload.thread.tid),
                title: payload.title,
                sourceGroup: metadata.sourceGroup,
                coverURL: metadata.coverURL,
                contentUpdatedAt: metadata.contentUpdatedAt,
                authorID: payload.authorID,
                sourceMetadataFetchFailed: metadata.fetchFailed
            )
        case let .manga(payload), let .mangaDirect(payload):
            // A manga chapter thread now imports as a plain `.mangaThread`
            // favorite of its own thread id — there is no merged-directory
            // identity to resolve here anymore (smart-comic-mode Phase A
            // decision #3/#9). Fetching the thread's own metadata (forum,
            // cover, content-updated-at) mirrors the `.novel`/`.thread` cases
            // above instead of the old dedicated no-metadata manga path.
            //
            // Classification into `.mangaThread` only depends on the board's
            // thread kind, never on the mode toggle (decision #4) — the
            // toggle only changes which UI a *live tap* routes to (through
            // `ForumMangaDetailView` vs. straight into the manga reader), not
            // how a *synced* favorite is classified. That's why `.manga` and
            // `.mangaDirect` — the resolver's only distinction between them
            // is whether the board's Smart Comic Mode happens to be on —
            // collapse into one shared case here.
            //
            // The stored title is always the post's own title verbatim,
            // regardless of mode, for the same reason: the mode-dependent
            // cleaned/shared book title is a pure UI-layer concern,
            // recomputed fresh on every read by
            // `FavoriteCardProjection.resolvedTitle` (via the same
            // `MangaTitleCleaner.cleanBookName`) whenever a favorite's
            // directory hasn't resolved yet — sync import baking a cleaned
            // title into the stored `FavoriteItem` here would only destroy
            // the original per-chapter title data with no corresponding
            // display benefit. That loss is exactly why this used to be a
            // bug for the mode-on `.manga` case: the archive detail page's
            // whole point is showing each archived member's own distinct raw
            // title so the user can tell chapters apart, and a cleaned title
            // collapses every synced chapter of the same manga down to one
            // indistinguishable generic book name. No merged-book identity,
            // no cleanBookName cleanup — same treatment `.mangaDirect` always
            // had, now shared by both mode states identically.
            let metadata = await threadMetadata(
                thread: ThreadIdentity(tid: payload.thread.tid),
                title: payload.title,
                repository: coverRepository
            )
            return FavoriteThreadProbeResult(
                target: .mangaThread(threadID: payload.thread.tid),
                title: payload.title,
                sourceGroup: metadata.sourceGroup,
                coverURL: metadata.coverURL,
                contentUpdatedAt: metadata.contentUpdatedAt,
                sourceMetadataFetchFailed: metadata.fetchFailed
            )
        case let .thread(payload):
            let metadata = await threadMetadata(
                thread: payload.thread,
                title: payload.title,
                repository: coverRepository
            )
            return FavoriteThreadProbeResult(
                target: .normalThread(threadID: payload.thread.tid),
                title: payload.title,
                sourceGroup: metadata.sourceGroup,
                coverURL: metadata.coverURL,
                contentUpdatedAt: metadata.contentUpdatedAt,
                sourceMetadataFetchFailed: metadata.fetchFailed
            )
        case let .webFallback(url):
            let canonicalURL = YamiboThreadURLCanonicalizer.canonicalThreadURL(from: url)
            guard let threadID = YamiboThreadURLCanonicalizer.threadID(from: canonicalURL) else {
                throw YamiboError.missingFavoriteThreadID
            }
            // Route the fallback through the routing payload so a missing or
            // blank title gets the same default as resolved `.thread` routes.
            let payload = YamiboThreadRoutePayload(
                thread: ThreadIdentity(tid: threadID),
                title: title ?? "",
                canonicalURL: canonicalURL,
                requestedURL: url
            )
            let metadata = await threadMetadata(
                thread: payload.thread,
                title: payload.title,
                repository: coverRepository
            )
            return FavoriteThreadProbeResult(
                target: .normalThread(threadID: threadID),
                title: payload.title,
                sourceGroup: metadata.sourceGroup,
                coverURL: metadata.coverURL,
                contentUpdatedAt: metadata.contentUpdatedAt,
                sourceMetadataFetchFailed: metadata.fetchFailed
            )
        }
    }

    private static func threadMetadata(
        thread: ThreadIdentity,
        title: String,
        repository: ForumThreadReaderRepository
    ) async -> (coverURL: URL?, sourceGroup: FavoriteSourceGroup, contentUpdatedAt: Date?, fetchFailed: Bool) {
        let cachedFirstPage = await repository.cachedThreadPage(thread: thread, title: title, authorID: nil, page: 1)
        let firstPage: ForumThreadPage?
        var fetchFailed = false
        if let cachedFirstPage {
            firstPage = cachedFirstPage
        } else {
            firstPage = await fetchThreadPageWithRetry(thread: thread, title: title, repository: repository)
            fetchFailed = firstPage == nil
        }
        let sourceGroup = sourceGroup(from: firstPage)
        let contentUpdatedAt = contentUpdatedAt(from: firstPage)
        let coverURL = await ThreadCoverResolver().resolve(
            thread: thread,
            title: title,
            repository: repository
        )
        return (coverURL, sourceGroup, contentUpdatedAt, fetchFailed)
    }

    private static func fetchThreadPageWithRetry(
        thread: ThreadIdentity,
        title: String,
        repository: ForumThreadReaderRepository,
        attempts: Int = 2
    ) async -> ForumThreadPage? {
        for attempt in 1 ... max(1, attempts) {
            do {
                return try await repository.fetchThreadPage(thread: thread, title: title, authorID: nil, page: 1)
            } catch {
                if attempt == attempts {
                    YamiboLog.sync.warning("Failed to fetch thread page for \(thread.tid) during sync probe after \(attempts) attempts, defaulting sourceGroup/contentUpdatedAt: \(error.localizedDescription)")
                }
            }
        }
        return nil
    }

    private static func contentUpdatedAt(from page: ForumThreadPage?) -> Date? {
        guard let firstPost = page?.posts.first else { return nil }
        return FavoriteContentUpdateDateResolver.date(
            lastEditedText: firstPost.lastEditedText,
            postedAtText: firstPost.postedAtText
        )
    }

    private static func sourceGroup(from page: ForumThreadPage?) -> FavoriteSourceGroup {
        guard let page else { return .unknown }
        let fid = page.forumID ?? page.thread.fid
        guard let fid, !fid.isEmpty else { return .unknown }
        return .forumBoard(id: fid, label: page.forumName ?? fid)
    }
}

/// Caches the Yamibo formHash for the duration of one sync run so bulk
/// uploads do not re-fetch the profile page per item.
private actor FavoriteSyncFormHashBox {
    private var cached: String?

    func formHash(repository: FavoriteRepository) async throws -> String {
        if let cached { return cached }
        let value = try await repository.currentFormHash()
        cached = value
        return value
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
