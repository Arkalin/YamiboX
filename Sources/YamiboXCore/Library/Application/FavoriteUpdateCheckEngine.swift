import Foundation

/// State machine for favorite update detection: walks tracked threads,
/// compares fingerprints against the stored baseline, and records update
/// events plus per-forum and per-category filters.
///
/// This is the check-run engine proper — network fetching, fingerprint
/// comparison, circuit breaking, offline handling, run persistence, and
/// notification delivery. The UI layer's `FavoriteUpdateMonitor` is only a
/// thin `ObservableObject` republishing this engine's state; every field
/// change is surfaced synchronously through `onStateChange` so the published
/// snapshot timing is identical to when the monitor owned this logic.
@MainActor
public final class FavoriteUpdateCheckEngine {

    /// Which piece of engine state just changed. Delivered synchronously,
    /// once per assignment, in assignment order — the UI mirror relies on
    /// this to reproduce the exact `@Published` update cadence the monitor
    /// had when it owned the state directly.
    public enum StateChange: Sendable {
        case snapshot
        case events
        case fidFilters
        case categoryFilters
        case trackedTargets
        case errorMessage
    }

    /// Synchronous per-field change hook for the UI snapshot publisher.
    public var onStateChange: ((StateChange) -> Void)?

    public private(set) var snapshot: FavoriteUpdateRunSnapshot? {
        didSet {
            onStateChange?(.snapshot)
            if let ownedRun, snapshot?.runID == ownedRun.snapshot.runID, let snapshot {
                runRegistry.publish(snapshot, for: ownedRun)
            }
        }
    }
    public private(set) var events: [FavoriteUpdateEvent] = [] {
        didSet { onStateChange?(.events) }
    }
    public private(set) var fidFilters: [FavoriteUpdateFidFilter] = [] {
        didSet { onStateChange?(.fidFilters) }
    }
    public private(set) var categoryFilters: [FavoriteUpdateCategoryFilter] = [] {
        didSet { onStateChange?(.categoryFilters) }
    }
    /// The authoritative per-target category scope, keyed by
    /// `FavoriteUpdateTargetKey`. UI category-filter matching for a
    /// `.mangaDirectory` event must read this rather than guessing from
    /// `FavoriteItem.target.id` equality (that lookup is `.favorite`-only by
    /// construction — a directory event's target id never matches one).
    public private(set) var trackedTargets: [FavoriteUpdateTrackedTarget] = [] {
        didSet { onStateChange?(.trackedTargets) }
    }
    public private(set) var errorMessage: String? {
        didSet { onStateChange?(.errorMessage) }
    }
    public private(set) var errorDetails: LoadFailureDetails?

    func reportError(_ error: any Error) {
        guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
        errorDetails = LoadFailureDetails(error: error)
        errorMessage = error.localizedDescription
    }

    // Lane extensions (+SmartManga, +Notifications) share these members.
    let updateStore: any FavoriteUpdateStatePersisting
    private let libraryStore: any FavoriteUpdateLibraryAccessing
    private let makeForumThreadReaderRepository: @Sendable () async -> any ForumThreadPageFetching
    let settingsStore: SettingsStore?
    let notifier: (any FavoriteUpdateNotifying)?
    /// Batched tid -> directory resolution for the smart-manga check lane.
    /// `nil` makes that lane a no-op. The reader must explicitly implement
    /// batched lookup; checking needs no directory mutation or observation.
    let mangaDirectoryStore: (any MangaDirectoryBatchReading)?
    /// Builds a fresh `MangaDirectoryWorkflow` scoped to one directory
    /// group's board (`searchForumID`), mirroring `makeForumThreadReaderRepository`'s
    /// "construct fresh per call so session state stays current" shape. `nil`
    /// makes the smart-manga check lane a no-op even if `mangaDirectoryStore`
    /// is set (seeding still runs — only network refresh needs a workflow).
    let makeMangaDirectoryWorkflow: (@Sendable (_ searchForumID: String) async -> MangaDirectoryWorkflow)?
    private let runRegistry: FavoriteUpdateActiveRunRegistry

    private var ownedRun: FavoriteUpdateActiveRunRegistry.Run?
    private var observedRun: FavoriteUpdateActiveRunRegistry.Run?
    private let observerID = UUID()
    // The badge fast path requires a gap-free delivery sequence within a run.
    var notificationBadgeSequence: UInt64 = 0
    private var storeUpdatesTask: Task<Void, Never>?
    private var finishingRunIDs: Set<String> = []

    private func isRunActive(_ runID: String) -> Bool {
        runRegistry.isActive(runID)
    }

    /// Runs are shared by store.changeID, including their preparation and completion.
    /// A separate injected registry can isolate an independent composition.
    public init(
        updateStore: any FavoriteUpdateStatePersisting,
        libraryStore: any FavoriteUpdateLibraryAccessing,
        makeForumThreadReaderRepository: @escaping @Sendable () async -> any ForumThreadPageFetching,
        settingsStore: SettingsStore? = nil,
        notifier: (any FavoriteUpdateNotifying)? = nil,
        mangaDirectoryStore: (any MangaDirectoryBatchReading)? = nil,
        makeMangaDirectoryWorkflow: (@Sendable (_ searchForumID: String) async -> MangaDirectoryWorkflow)? = nil,
        runRegistry: FavoriteUpdateActiveRunRegistry = .shared
    ) {
        self.updateStore = updateStore
        self.libraryStore = libraryStore
        self.makeForumThreadReaderRepository = makeForumThreadReaderRepository
        self.settingsStore = settingsStore
        self.notifier = notifier
        self.mangaDirectoryStore = mangaDirectoryStore
        self.makeMangaDirectoryWorkflow = makeMangaDirectoryWorkflow
        self.runRegistry = runRegistry
        runRegistry.observe(storeID: updateStore.changeID, observerID: observerID) { [weak self] incoming in
            guard let self, ownedRun?.snapshot.runID != incoming.runID else { return }
            snapshot = incoming
        } onFinished: { [weak self] incoming in
            guard let self, ownedRun?.snapshot.runID != incoming.runID else { return }
            // Results can commit after interrupt published its early terminal
            // snapshot. Reload once when the shared driver actually finishes.
            Task { [weak self] in await self?.reloadEventState() }
        }
        storeUpdatesTask = Task { @MainActor [weak self, store = updateStore] in
            for await changeID in store.changes() {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                // The per-instance stream already only carries this store's
                // changeID; the guard stays as the explicit statement of the
                // "changes from the exact instance driving this engine" rule.
                guard changeID == store.changeID else {
                    continue
                }
                // Shared progress comes directly from the registry. Avoid
                // hydrating the full event state in every observing engine
                // for each progress write; the driver's finish callback
                // refreshes observers once after results have committed.
                // Outside a run, store changes still refresh the full state.
                guard self.runRegistry.run(storeID: store.changeID) == nil else { continue }
                await self.reloadFromExternalChange()
            }
        }
    }

    isolated deinit {
        storeUpdatesTask?.cancel()
        runRegistry.removeObserver(storeID: updateStore.changeID, observerID: observerID)
    }

    /// Reloads the persisted run, events, and filters. A run still marked
    /// running whose task no longer exists is downgraded to interrupted.
    public func load() async {
        do {
            let previous = snapshot
            let latest = try await fetchLatestRunDowngradingIfOrphaned()
            if let run = runRegistry.run(storeID: updateStore.changeID) {
                snapshot = run.snapshot
            } else if snapshot == previous {
                snapshot = latest
            }
        } catch {
            reportError(error)
            return
        }
        await reloadEventState()
    }

    /// Applies a store change observed via `changes()`. The stream
    /// consumer can fall arbitrarily far behind under scheduler contention
    /// (including this instance's own writes from the run that just finished).
    /// `load()` re-validates immediately before publishing that no new run has
    /// started on this instance while the store read was in flight —
    /// applying a stale read at that point would regress the visible
    /// snapshot back to the old run's runID and silently break the new
    /// run's own updateSnapshot(runID:) calls, which compare against
    /// self.snapshot.runID and no-op on a mismatch.
    private func reloadFromExternalChange() async {
        await load()
    }

    private func fetchLatestRunDowngradingIfOrphaned() async throws -> FavoriteUpdateRunSnapshot? {
        var latest = try await updateStore.latestRun()
        if var loaded = latest, loaded.status == .running, !isRunActive(loaded.runID) {
            loaded.status = .interrupted
            loaded.phase = .interrupted
            loaded.finishedAt = loaded.finishedAt ?? .now
            loaded.updatedAt = .now
            loaded.progress = nil
            try await updateStore.saveRun(loaded)
            latest = loaded
        }
        return latest
    }

    /// Refreshes events and filters from the store. Kept separate from the
    /// snapshot so a run can publish fresh event state before its terminal
    /// status becomes observable.
    public func reloadEventState() async {
        do {
            applyEventState(try await updateStore.loadState())
        } catch {
            // Retain the last good snapshot; a failed read is not an empty library.
            reportError(error)
        }
    }

    private func applyEventState(_ state: FavoriteUpdateStoreState) {
        events = state.events
            .filter { $0.dismissedAt == nil }
            .sorted { lhs, rhs in
                if lhs.detectedAt != rhs.detectedAt { return lhs.detectedAt > rhs.detectedAt }
                return lhs.id > rhs.id
            }
        fidFilters = state.fidFilters.sorted { lhs, rhs in
            if lhs.forumName != rhs.forumName { return lhs.forumName < rhs.forumName }
            return lhs.fid < rhs.fid
        }
        categoryFilters = state.categoryFilters.sorted { lhs, rhs in
            if lhs.categoryName != rhs.categoryName { return lhs.categoryName < rhs.categoryName }
            return lhs.categoryID < rhs.categoryID
        }
        trackedTargets = state.trackedTargets
    }

    /// - Parameter nonTagMangaDirectoryCheckCap: Ceiling on how many
    ///   NON-tag-strategy smart-manga directory groups (the ones whose
    ///   refresh always risks the forum's search flood-control) this run
    ///   will attempt a network refresh for; tag-strategy groups are
    ///   unbounded (cheap, no search cooldown in the common case). Callers
    ///   should pass a small number for background-triggered runs and a
    ///   larger one for foreground/manual runs — this type has no opinion on
    ///   which, it only enforces whatever cap it's given.
    @discardableResult
    public func startCheck(nonTagMangaDirectoryCheckCap: Int = 1) async -> String? {
        guard !Task.isCancelled else { return nil }
        if let run = runRegistry.run(storeID: updateStore.changeID) {
            return await join(run)
        }
        let now = Date()
        let startedSnapshot = FavoriteUpdateRunSnapshot(
            status: .running, phase: .preparing, startedAt: now, updatedAt: now
        )
        guard let run = runRegistry.begin(storeID: updateStore.changeID, snapshot: startedSnapshot) else { return nil }
        ownedRun = run
        observedRun = run
        snapshot = startedSnapshot
        notificationBadgeSequence = 0
        // Install both tasks before the first await. A joining caller can wait
        // even while the initial durable running row is still being written.
        let preparation = Task { @MainActor [self] in
            await prepareRun(run)
        }
        run.preparation = preparation
        run.driver = Task { @MainActor [self, runRegistry] in
            if await preparation.value {
                await runCheck(runID: run.snapshot.runID, nonTagMangaDirectoryCheckCap: nonTagMangaDirectoryCheckCap)
            }
            runRegistry.finish(run)
            if ownedRun === run { ownedRun = nil }
        }
        run.interrupt = { [weak self, weak run] in
            guard let self, let run, ownedRun === run else { return }
            await interruptOwnedRun(run)
        }
        return await join(run)
    }

    private func join(_ run: FavoriteUpdateActiveRunRegistry.Run) async -> String? {
        observedRun = run
        snapshot = run.snapshot
        guard await run.preparation?.value == true else { return nil }
        return run.snapshot.runID
    }

    private func prepareRun(_ run: FavoriteUpdateActiveRunRegistry.Run) async -> Bool {
        do {
            try Task.checkCancellation()
            try await updateStore.saveRun(run.snapshot)
            try Task.checkCancellation()
            return true
        } catch {
            YamiboLog.persistence.error("Failed to prepare favorite update run \(run.snapshot.runID): \(error.localizedDescription)")
            guard ownedRun === run else { return false }
            // This store preserves GRDB's CancellationError under its
            // persistence wrapper. Classify that source locally; a cancelled
            // caller alone must never hide a genuine SQL/encoding failure.
            let preparationError = (error as? YamiboPersistenceError)?.underlying ?? error
            let wasCancelled = LoadDiagnosticError.isCancellation(preparationError)
            var failed = run.snapshot
            failed.status = wasCancelled ? .interrupted : .failed
            failed.phase = failed.status == .interrupted ? .interrupted : .failed
            failed.finishedAt = .now
            failed.errorMessage = wasCancelled ? preparationError.localizedDescription : error.localizedDescription
            snapshot = failed
            reportError(error)
            // A cancelled preparation may already have persisted .running.
            // Stamp its terminal result without inheriting that cancellation.
            if wasCancelled {
                let interrupted = failed
                await Task { @MainActor [self] in
                    do {
                        try await updateStore.saveRun(interrupted)
                    } catch {
                        guard ownedRun === run else { return }
                        var terminalFailure = interrupted
                        terminalFailure.status = .failed
                        terminalFailure.phase = .failed
                        terminalFailure.updatedAt = .now
                        terminalFailure.errorMessage = error.localizedDescription
                        reportError(error)
                        snapshot = terminalFailure
                    }
                }.value
            }
            return false
        }
    }

    /// Manual interruption can control the shared run shown by this monitor.
    /// Background expiration only has authority over a run this engine started.
    public func interrupt(ifOwned: Bool = false) async {
        guard let run = runRegistry.run(storeID: updateStore.changeID) ?? observedRun else { return }
        if ifOwned, ownedRun !== run { return }
        await run.interrupt?()
    }

    private func interruptOwnedRun(_ run: FavoriteUpdateActiveRunRegistry.Run) async {
        guard ownedRun === run, snapshot?.status == .running,
              !finishingRunIDs.contains(run.snapshot.runID) else { return }
        run.preparation?.cancel()
        run.driver?.cancel()
        // During preparation its cancellation stamps the terminal state after
        // the initial write joins. Do not race another write against that row.
        guard await run.preparation?.value == true else { return }
        await updateSnapshot(runID: run.snapshot.runID) { snapshot in
            snapshot.status = .interrupted
            snapshot.phase = .interrupted
            snapshot.finishedAt = .now
            snapshot.progress = nil
        }
    }

    /// Joins the admitted run, including preparation and terminal persistence.
    /// The receipt remains valid if another engine has already begun a new run.
    @discardableResult
    public func waitForCompletion() async -> FavoriteUpdateRunSnapshot? {
        guard let run = observedRun ?? runRegistry.run(storeID: updateStore.changeID) else { return nil }
        await run.driver?.value
        if snapshot?.runID == run.snapshot.runID { snapshot = run.snapshot }
        return run.snapshot
    }

    /// Configured automatic check interval, or nil without a settings store.
    public func configuredInterval() async -> FavoriteUpdateCheckInterval? {
        guard let settingsStore else { return nil }
        return await settingsStore.load().favorites.updateCheckInterval
    }

    public func setConfiguredInterval(_ interval: FavoriteUpdateCheckInterval) async {
        guard let settingsStore else { return }
        do {
            try await settingsStore.update { $0.favorites.updateCheckInterval = interval }
        } catch {
            YamiboLog.persistence.error("Failed to persist favorite update check interval: \(error.localizedDescription)")
        }
    }

    /// Configured smart-manga chapter check interval, or nil without a
    /// settings store — the UI-facing counterpart of `smartMangaInterval()`
    /// (which the check run itself reads).
    public func configuredMangaInterval() async -> SmartMangaUpdateCheckInterval? {
        guard let settingsStore else { return nil }
        return await settingsStore.load().favorites.smartMangaUpdateCheckInterval
    }

    public func setConfiguredMangaInterval(_ interval: SmartMangaUpdateCheckInterval) async {
        guard let settingsStore else { return }
        do {
            try await settingsStore.update { $0.favorites.smartMangaUpdateCheckInterval = interval }
        } catch {
            YamiboLog.persistence.error("Failed to persist smart-manga update check interval: \(error.localizedDescription)")
        }
    }

    /// Whether recent events keep arriving; drives the smart interval.
    public var hasRecentEvents: Bool {
        events.contains { $0.detectedAt > Date.now.addingTimeInterval(-7 * 24 * 3600) }
    }

    /// Smart-manga-only counterpart of `hasRecentEvents`, driving
    /// `SmartMangaUpdateCheckInterval.smart`'s adaptive cadence
    /// independently of thread-check activity.
    public var hasRecentMangaDirectoryEvents: Bool {
        events.contains {
            $0.mode == .mangaDirectory && $0.detectedAt > Date.now.addingTimeInterval(-7 * 24 * 3600)
        }
    }

    /// Starts a check when the configured interval has elapsed since the last
    /// completed run — the foreground catch-up half of automatic checking
    /// (BGAppRefreshTask timing is only best-effort).
    /// Gating stays keyed on the thread-check interval only (unchanged from
    /// before smart-manga checking existed): a whole run always attempts
    /// both lanes, but whether a run happens automatically at all is still
    /// decided by `favorites.updateCheckInterval`. `smartMangaUpdateCheckInterval`
    /// only decides which *individual directory groups* are due once a run
    /// is already underway (see `checkMangaDirectoryGroups`) — it does not
    /// independently trigger runs. This is a deliberate scope boundary, not
    /// an oversight: unifying the two into an OR-gate here would make
    /// `smartMangaUpdateCheckInterval`'s non-off default silently start
    /// automatic background activity for every user, including those who
    /// have never touched smart manga and still have the thread-check
    /// interval at its `.off` default. Flagged for product-decision
    /// confirmation before the next phase wires a background trigger.
    @discardableResult
    public func startCheckIfDue(nonTagMangaDirectoryCheckCap: Int = 1) async -> Bool {
        guard let interval = await configuredInterval(),
              let delay = interval.nextDelay(hasRecentEvents: hasRecentEvents) else {
            return false
        }
        if let run = runRegistry.run(storeID: updateStore.changeID) {
            return await join(run) != nil
        }
        guard snapshot?.status != .running else { return false }
        // Throttle on elapsed time regardless of how the last run ended: a
        // failed or interrupted run (e.g. the background task's execution
        // budget expired mid-check) must not bypass the interval and trigger
        // a brand-new full check on every single foreground catch-up.
        if let last = snapshot, let finishedAt = last.finishedAt,
           Date.now.timeIntervalSince(finishedAt) < delay {
            return false
        }
        return await startCheck(nonTagMangaDirectoryCheckCap: nonTagMangaDirectoryCheckCap) != nil
    }

    // MARK: - Events and filters

    public func markEventRead(_ eventID: String) async {
        await markEventsRead([eventID])
    }

    public func markEventsRead(_ eventIDs: Set<String>) async {
        guard !eventIDs.isEmpty else { return }
        let targetIDs = events.filter { eventIDs.contains($0.id) }.map(\.target.id)
        do {
            try await updateStore.markEventsRead(eventIDs, date: .now)
            await load()
            await cleanUpNotifications(forTargetIDs: targetIDs)
        } catch {
            YamiboLog.persistence.error("Failed to mark favorite updates read: \(error.localizedDescription)")
            reportError(error)
        }
    }

    public func dismissEvent(_ eventID: String) async {
        let targetIDs = events.filter { $0.id == eventID }.map(\.target.id)
        do {
            try await updateStore.dismissEvent(eventID, date: .now)
            await load()
            await cleanUpNotifications(forTargetIDs: targetIDs)
        } catch {
            YamiboLog.persistence.error("Failed to dismiss favorite update event \(eventID): \(error.localizedDescription)")
            reportError(error)
        }
    }

    public func dismissAllEvents() async {
        let targetIDs = events.map(\.target.id)
        do {
            try await updateStore.dismissAllEvents(date: .now)
            await load()
            await cleanUpNotifications(forTargetIDs: targetIDs)
        } catch {
            YamiboLog.persistence.error("Failed to dismiss all favorite update events: \(error.localizedDescription)")
            reportError(error)
        }
    }

    public func setFidFilter(_ fid: String, enabled: Bool) async {
        do {
            try await updateStore.setFidEnabled(fid, enabled: enabled, date: .now)
            await load()
        } catch {
            YamiboLog.persistence.error("Failed to toggle favorite update forum filter \(fid): \(error.localizedDescription)")
            reportError(error)
        }
    }

    public func setCategoryFilter(_ categoryID: String, enabled: Bool) async {
        do {
            try await updateStore.setCategoryEnabled(categoryID, enabled: enabled, date: .now)
            await load()
        } catch {
            YamiboLog.persistence.error("Failed to toggle favorite update category filter \(categoryID): \(error.localizedDescription)")
            reportError(error)
        }
    }

    // MARK: - Check run

    private func runCheck(runID: String, nonTagMangaDirectoryCheckCap: Int) async {
        // Accumulated in memory across the whole loop and committed to
        // `updateStore` at most once (`commitCheckResults`, on every exit
        // path below) instead of per favorite — see that method's doc.
        var trackedTargets: [String: FavoriteUpdateTrackedTarget] = [:]
        var events = FavoriteUpdateRunEventAccumulator()
        do {
            try Task.checkCancellation()
            let document = try await libraryStore.load()
            try Task.checkCancellation()
            let candidates = Self.candidates(in: document)
            try await refreshFilters(candidates: candidates, document: document)
            let scopedCandidates = try await scopedCandidates(candidates)
            try await replaceTrackedTargetsIfNeeded(candidates)
            let mangaGroups = await mangaDirectoryGroups(in: document)
            await updateSnapshot(runID: runID) { snapshot in
                snapshot.phase = .checking
                snapshot.totalCount = scopedCandidates.count
                snapshot.progress = .loadedTargets(count: scopedCandidates.count)
            }

            let initialState = try await updateStore.loadState()
            trackedTargets = Dictionary(uniqueKeysWithValues: initialState.trackedTargets.map { ($0.id, $0) })
            events = FavoriteUpdateRunEventAccumulator(initialState.events)

            var detectedCount = 0
            for (index, item) in scopedCandidates.enumerated() {
                try Task.checkCancellation()
                await updateSnapshot(runID: runID) { snapshot in
                    snapshot.progress = .checking(
                        index: index + 1,
                        total: scopedCandidates.count,
                        title: item.resolvedDisplayTitle
                    )
                }
                let result = await checkUpdate(for: item, trackedTargets: &trackedTargets, events: &events)
                switch result {
                case let .checked(detected):
                    detectedCount += detected
                    await updateSnapshot(runID: runID) { snapshot in
                        snapshot.completedCount += 1
                        snapshot.detectedCount = detectedCount
                    }
                case .skipped:
                    await updateSnapshot(runID: runID) { snapshot in
                        snapshot.skippedCount += 1
                    }
                case let .failed(message):
                    await updateSnapshot(runID: runID) { snapshot in
                        snapshot.failedCount += 1
                        snapshot.warningMessage = [snapshot.warningMessage, message].compactMap { $0 }.joined(separator: "\n")
                    }
                case .offline:
                    // The network is down, not this one target — every
                    // remaining candidate would fail the exact same way, so
                    // stop the run here instead of grinding through the rest.
                    // Nothing about this counts toward any target's
                    // `consecutiveFailures` circuit breaker; the next due
                    // check (foreground catch-up or background refresh)
                    // retries the whole scope from scratch.
                    await finishRun(
                        runID: runID,
                        trackedTargets: trackedTargets,
                        events: events,
                        status: .failed,
                        errorMessage: YamiboError.offline.localizedDescription
                    )
                    return
                }
            }

            try Task.checkCancellation()
            await checkMangaDirectoryGroups(
                mangaGroups,
                nonTagCheckCap: nonTagMangaDirectoryCheckCap,
                runID: runID,
                trackedTargets: &trackedTargets,
                events: &events
            )
            try Task.checkCancellation()

            await finishRun(runID: runID, trackedTargets: trackedTargets, events: events, status: .completed)
        } catch {
            if error.isTaskCancellation {
                // interrupt() may have already written the terminal state for
                // this exact run — its cancellation races with a network fetch
                // that doesn't observe Task cancellation and runs to
                // completion regardless; finishRun's only-if-still-running
                // guard keeps it from re-terminating (which would duplicate
                // the warning/log entry and push finishedAt later than when
                // the user actually interrupted).
                await finishRun(
                    runID: runID,
                    trackedTargets: trackedTargets,
                    events: events,
                    status: .interrupted,
                    onlyIfStillRunning: true
                )
                return
            }
            YamiboLog.sync.error("Favorite update check run \(runID) failed: \(error.localizedDescription)")
            reportError(error)
            await finishRun(
                runID: runID,
                trackedTargets: trackedTargets,
                events: events,
                status: .failed,
                errorMessage: error.localizedDescription
            )
        }
    }

    /// One terminal-state write shared by every exit path of `runCheck`:
    /// commit the run's accumulated results, refresh the published event
    /// state, and stamp the snapshot's terminal status/phase.
    private func finishRun(
        runID: String,
        trackedTargets: [String: FavoriteUpdateTrackedTarget],
        events: FavoriteUpdateRunEventAccumulator,
        status: FavoriteUpdateRunStatus,
        errorMessage: String? = nil,
        onlyIfStillRunning: Bool = false
    ) async {
        guard finishingRunIDs.insert(runID).inserted else { return }
        defer { finishingRunIDs.remove(runID) }
        // Terminal persistence must finish even when the network driver was
        // cancelled, or is cancelled while this write is suspended. This
        // unstructured task has a fresh cancellation state; the driver still
        // joins it before the registry releases this run or changes accounts.
        // Only the bounded commit/cleanup runs here, never more network work.
        await Task { @MainActor [self] in
            await persistFinishedRun(
                runID: runID, trackedTargets: trackedTargets, events: events,
                status: status, errorMessage: errorMessage,
                onlyIfStillRunning: onlyIfStillRunning
            )
        }.value
    }

    private func persistFinishedRun(
        runID: String,
        trackedTargets: [String: FavoriteUpdateTrackedTarget],
        events: FavoriteUpdateRunEventAccumulator,
        status: FavoriteUpdateRunStatus,
        errorMessage: String?,
        onlyIfStillRunning: Bool
    ) async {
        var terminalStatus = status
        var terminalErrorMessage = errorMessage
        do {
            try await commitCheckResults(trackedTargets: trackedTargets, events: events)
        } catch {
            terminalStatus = LoadDiagnosticError.isCancellation(error) ? .interrupted : .failed
            terminalErrorMessage = error.localizedDescription
            reportError(error)
        }
        await reloadEventState()
        // Reading during a run can update the badge before its newly detected
        // events are committed. Reconcile once those events are durable.
        await cleanUpNotifications(forTargetIDs: [])
        await updateStore.endNotificationBadgeRun(runID: runID)
        guard var terminal = snapshot, terminal.runID == runID else { return }
        // An interrupted run may still fail to persist its results. Surface that
        // failure, but don't otherwise restamp an already-terminated run.
        let preserveEarlyTerminal = onlyIfStillRunning && terminal.status != .running && terminalStatus != .failed
        if !preserveEarlyTerminal {
            let phase: FavoriteUpdateRunPhase = switch terminalStatus {
            case .completed: .completed
            case .interrupted: .interrupted
            case .canceled: .canceled
            case .failed, .running: .failed
            }
            terminal.status = terminalStatus
            terminal.phase = phase
            terminal.finishedAt = .now
            terminal.updatedAt = .now
            terminal.progress = nil
            if let terminalErrorMessage { terminal.errorMessage = terminalErrorMessage }
        }
        // Preserve interrupt's original timestamp, but ensure its early
        // terminal row is durable even if that caller's write was cancelled.
        do {
            try await updateStore.saveRun(terminal)
        } catch {
            // Never publish completion until both results and terminal status
            // are durable. A failed write must also leave manual retry available.
            terminal.status = LoadDiagnosticError.isCancellation(error) ? .interrupted : .failed
            terminal.phase = terminal.status == .interrupted ? .interrupted : .failed
            terminal.errorMessage = terminalErrorMessage ?? error.localizedDescription
            reportError(error)
        }
        guard snapshot?.runID == runID else { return }
        snapshot = terminal
    }

    /// Applies this run's accumulated tracked-target/event changes to the
    /// store in one write — a merge on the store side, so read/dismiss marks
    /// the user applied while this run was in flight survive the commit
    /// instead of being rolled back by the run's stale start-of-run snapshot.
    /// A no-op before `trackedTargets` is ever seeded (an early throw from
    /// `libraryStore.load()`/`refreshFilters`/`replaceTrackedTargetsIfNeeded`)
    /// so it never writes an empty first-run result over existing state.
    private func commitCheckResults(
        trackedTargets: [String: FavoriteUpdateTrackedTarget],
        events: FavoriteUpdateRunEventAccumulator
    ) async throws {
        guard !trackedTargets.isEmpty else { return }
        try await updateStore.applyCheckRunResults(trackedTargets: Array(trackedTargets.values), events: events.materialize())
    }

    func updateSnapshot(
        runID: String? = nil,
        mutate: (inout FavoriteUpdateRunSnapshot) -> Void
    ) async {
        guard var snapshot else { return }
        if let runID, snapshot.runID != runID { return }
        mutate(&snapshot)
        snapshot.updatedAt = .now
        self.snapshot = snapshot
        do {
            try await updateStore.saveRun(snapshot)
        } catch {
            YamiboLog.persistence.error("Failed to persist favorite update run snapshot \(snapshot.runID): \(error.localizedDescription)")
            reportError(error)
        }
    }

    // MARK: - Candidates

    private static func candidates(in document: FavoriteLibraryDocument) -> [FavoriteItem] {
        document.items.filter { item in
            item.target.threadID != nil && (item.target.kind == .normalThread || item.target.kind == .novelThread)
        }
    }

    private func refreshFilters(candidates: [FavoriteItem], document: FavoriteLibraryDocument) async throws {
        let now = Date()
        let categoryNames = Dictionary(uniqueKeysWithValues: document.categories.map { ($0.id, $0.displayName) })
        var categoryCounts: [String: Int] = [:]
        var fidCounts: [FavoriteSourceGroup: Int] = [:]
        for item in candidates {
            for categoryID in Set(item.locations.compactMap(\.categoryID)) {
                categoryCounts[categoryID, default: 0] += 1
            }
            fidCounts[item.sourceGroup, default: 0] += 1
        }
        let categoryFilters = categoryCounts.map { categoryID, count in
            FavoriteUpdateCategoryFilter(
                categoryID: categoryID,
                categoryName: categoryNames[categoryID] ?? categoryID,
                itemCount: count,
                updatedAt: now
            )
        }
        let fidFilters = fidCounts.compactMap { sourceGroup, count -> FavoriteUpdateFidFilter? in
            guard case let .forumBoard(id, label) = sourceGroup else { return nil }
            return FavoriteUpdateFidFilter(fid: id, forumName: label, itemCount: count, updatedAt: now)
        }
        try await updateStore.replaceFilters(
            fidFilters: fidFilters.sorted { $0.fid < $1.fid },
            categoryFilters: categoryFilters.sorted { $0.categoryID < $1.categoryID }
        )
    }

    private func scopedCandidates(_ candidates: [FavoriteItem]) async throws -> [FavoriteItem] {
        let state = try await updateStore.loadState()
        let enabledFids = Set(state.fidFilters.filter(\.enabled).map(\.fid))
        let disabledFidsExist = state.fidFilters.contains { !$0.enabled }
        let enabledCategories = Set(state.categoryFilters.filter(\.enabled).map(\.categoryID))
        let disabledCategoriesExist = state.categoryFilters.contains { !$0.enabled }
        return candidates.filter { item in
            // The fid filter only ever gets a row for items whose forum
            // actually resolved (see refreshFilters); an item stuck at
            // .unknown has no filter row it could be re-enabled through, so
            // disabling some OTHER forum must not silently exclude it too.
            let fidMatches: Bool
            if disabledFidsExist, case let .forumBoard(id, _) = item.sourceGroup {
                fidMatches = enabledFids.contains(id)
            } else {
                fidMatches = true
            }
            let categoryMatches = !disabledCategoriesExist || !Set(item.locations.compactMap(\.categoryID)).isDisjoint(with: enabledCategories)
            return fidMatches && categoryMatches
        }
    }

    private func replaceTrackedTargetsIfNeeded(_ candidates: [FavoriteItem]) async throws {
        let state = try await updateStore.loadState()
        // `.mangaDirectory` tracked targets aren't keyed by any
        // `FavoriteItemTarget` in `candidates` (they're per-directory, not
        // per-favorite) — carry them through untouched instead of letting
        // this thread-lane-only replace wipe them out.
        let mangaDirectoryTargets = state.trackedTargets.filter {
            if case .mangaDirectory = $0.target { true } else { false }
        }
        let existingByID = Dictionary(uniqueKeysWithValues: state.trackedTargets.map { ($0.id, $0) })
        let targets = candidates.map { item -> FavoriteUpdateTrackedTarget in
            var existing = existingByID[item.target.id] ?? FavoriteUpdateTrackedTarget(
                target: .favorite(item.target),
                title: item.resolvedDisplayTitle,
                mode: FavoriteUpdateTargetMode(kind: item.target.kind)
            )
            existing.title = item.resolvedDisplayTitle
            existing.mode = FavoriteUpdateTargetMode(kind: item.target.kind)
            existing.categoryIDs = Set(item.locations.compactMap(\.categoryID))
            if case let .forumBoard(id, label) = item.sourceGroup {
                existing.fid = id
                existing.forumName = label
            }
            return existing
        }
        try await updateStore.replaceTrackedTargets(targets + mangaDirectoryTargets)
    }

    // MARK: - Single item check

    private enum CheckResult {
        case checked(detected: Int)
        case skipped
        case offline
        case failed(String)
    }

    /// After this many consecutive failed check attempts, a target backs off
    /// to being retried at most once per `circuitBreakerCooldown` instead of
    /// on every single run — otherwise a permanently broken target (deleted
    /// thread, moved board) gets re-fetched forever with no end in sight.
    static let circuitBreakerThreshold = 5
    static let circuitBreakerCooldown: TimeInterval = 24 * 3600

    private func checkUpdate(
        for item: FavoriteItem,
        trackedTargets: inout [String: FavoriteUpdateTrackedTarget],
        events: inout FavoriteUpdateRunEventAccumulator
    ) async -> CheckResult {
        var target = trackedTargets[item.target.id] ?? FavoriteUpdateTrackedTarget(
            target: .favorite(item.target),
            title: item.resolvedDisplayTitle,
            mode: FavoriteUpdateTargetMode(kind: item.target.kind)
        )

        if target.consecutiveFailures >= Self.circuitBreakerThreshold,
           let lastCheckedAt = target.lastCheckedAt,
           Date.now.timeIntervalSince(lastCheckedAt) < Self.circuitBreakerCooldown {
            return .skipped
        }

        let page: ForumThreadPage
        do {
            page = try await threadPage(for: item, knownPageCount: target.knownPageCount)
        } catch {
            // The network being unreachable is not this target's fault, and
            // every other candidate would fail identically — don't burn a
            // circuit-breaker strike or touch its stored baseline on it, and
            // let the caller decide to abort the whole run instead of
            // grinding through every remaining candidate the same way.
            if YamiboNetworkErrorPolicy.isOffline(error) {
                return .offline
            }
            YamiboLog.sync.warning("Failed to fetch thread page for favorite update check on \(item.target.id): \(error.localizedDescription)")
            target.consecutiveFailures += 1
            target.lastError = error.localizedDescription
            target.lastCheckedAt = .now
            trackedTargets[item.target.id] = target
            return .failed(error.localizedDescription)
        }

        await healUnknownSourceGroupIfNeeded(item: item, page: page)

        let fingerprint = FavoriteUpdateFingerprint(page: page)
        let previous = FavoriteUpdateFingerprint(target: target)

        // Only advance fields this fetch actually produced a value for — a
        // transient parse miss on one field must not erase a previously
        // known-good baseline, which would otherwise silently and
        // permanently break future comparisons for that field (the next
        // good fetch would compare against nil instead of the real prior
        // value, masking whatever changed in between).
        target.knownLatestPostID = fingerprint.latestPostID ?? target.knownLatestPostID
        target.knownReplyCount = fingerprint.replyCount ?? target.knownReplyCount
        target.knownPageCount = fingerprint.pageCount ?? target.knownPageCount
        target.baselineReady = true
        target.lastCheckedAt = .now
        target.lastError = nil
        target.consecutiveFailures = 0
        if let forumID = page.forumID ?? page.thread.fid {
            target.fid = forumID
        }
        if let forumName = page.forumName {
            target.forumName = forumName
        }

        guard previous.isReady, fingerprint.isNewer(than: previous) else {
            trackedTargets[item.target.id] = target
            return .checked(detected: 0)
        }

        let existingEvent = events.firstUndismissed(for: .favorite(item.target))
        let summary = Self.mergedSummary(
            existing: existingEvent?.summary,
            new: FavoriteUpdateFingerprint.summary(from: previous, to: fingerprint)
        )
        let event = FavoriteUpdateEvent(
            target: .favorite(item.target),
            title: item.resolvedDisplayTitle,
            mode: FavoriteUpdateTargetMode(kind: item.target.kind),
            fid: target.fid,
            forumName: target.forumName,
            summary: summary,
            detailIDs: fingerprint.latestPostID.map { [$0] } ?? [],
            detectedAt: .now,
            ambiguous: fingerprint.latestPostID == nil
        )
        events.replaceUndismissed(with: event)
        trackedTargets[item.target.id] = target
        await deliverNotificationIfEnabled(for: event, runEvents: events)
        return .checked(detected: 1)
    }

    /// Accumulates a newly detected delta onto an existing undismissed event
    /// for the same target instead of replacing it outright, so a user who
    /// misses several check cycles in a row sees the true accumulated total
    /// rather than only the most recent cycle's delta.
    static func mergedSummary(existing: FavoriteUpdateSummary?, new: FavoriteUpdateSummary) -> FavoriteUpdateSummary {
        guard let existing else { return new }
        switch (existing, new) {
        case let (.newReplies(a), .newReplies(b)):
            return .newReplies(count: a + b)
        case let (.newPages(a), .newPages(b)):
            return .newPages(count: a + b)
        case let (.newChapters(a), .newChapters(b)):
            return .newChapters(count: a + b)
        default:
            return new
        }
    }

    /// Writes a resolved forum id/name back onto the favorite's own source
    /// group once a check successfully fetches its thread — items that never
    /// resolved a forum at add-time would otherwise stay `.unknown` forever,
    /// since nothing else in the app re-probes an already-favorited item.
    private func healUnknownSourceGroupIfNeeded(item: FavoriteItem, page: ForumThreadPage) async {
        guard item.sourceGroup == .unknown, let forumID = page.forumID ?? page.thread.fid else { return }
        do {
            try await libraryStore.healUnknownSourceGroup(
                for: item.target, forumID: forumID, forumName: page.forumName
            )
        } catch {
            guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
            YamiboLog.persistence.error("Failed to heal favorite source group for target \(item.target.id): \(error.localizedDescription)")
        }
    }

    private func threadPage(for item: FavoriteItem, knownPageCount: Int?) async throws -> ForumThreadPage {
        guard let tid = item.target.threadID else {
            throw FavoriteActionError.missingFavoriteThreadID
        }
        let repository = await makeForumThreadReaderRepository()
        try Task.checkCancellation()
        let fid: String? = if case let .forumBoard(id, _) = item.sourceGroup { id } else { nil }
        let thread = ThreadIdentity(tid: tid, fid: fid)
        let context = ThreadNovelLaunchContext(thread: thread, title: item.resolvedDisplayTitle)
        // New replies land on the last page — fetching the previously
        // known last page (falling back to page 1 for a first-ever
        // check) is what lets latestPostID track the thread's actual
        // newest content instead of freezing at whatever was on page 1
        // forever once the thread grows past one page.
        let page = max(1, knownPageCount ?? 1)
        return try await repository.fetchThreadPage(context: context, page: page, authorID: nil, reverse: false)
    }

}

/// Compact comparison key for detecting thread updates between check runs.
private struct FavoriteUpdateFingerprint: Sendable {
    var latestPostID: String?
    var replyCount: Int?
    var pageCount: Int?
    var isReady: Bool

    init(page: ForumThreadPage) {
        latestPostID = page.posts.map(\.postID).last
        replyCount = page.totalReplies
        pageCount = page.pageNavigation?.totalPages
        isReady = latestPostID != nil || replyCount != nil || pageCount != nil
    }

    init(target: FavoriteUpdateTrackedTarget) {
        latestPostID = target.knownLatestPostID
        replyCount = target.knownReplyCount
        pageCount = target.knownPageCount
        isReady = target.baselineReady
    }

    func isNewer(than previous: FavoriteUpdateFingerprint) -> Bool {
        if let replyCount, let previousReplyCount = previous.replyCount, replyCount > previousReplyCount {
            return true
        }
        if let pageCount, let previousPageCount = previous.pageCount, pageCount > previousPageCount {
            return true
        }
        if let latestPostID, latestPostID != previous.latestPostID {
            return true
        }
        return false
    }

    static func summary(from previous: FavoriteUpdateFingerprint, to current: FavoriteUpdateFingerprint) -> FavoriteUpdateSummary {
        if let replyCount = current.replyCount, let previousReplyCount = previous.replyCount, replyCount > previousReplyCount {
            return .newReplies(count: replyCount - previousReplyCount)
        }
        if let pageCount = current.pageCount, let previousPageCount = previous.pageCount, pageCount > previousPageCount {
            return .newPages(count: pageCount - previousPageCount)
        }
        return .changed
    }
}
