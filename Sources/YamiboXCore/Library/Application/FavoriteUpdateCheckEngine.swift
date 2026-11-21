import Foundation

@MainActor
public final class FavoriteUpdateCheckEngine {

    public enum StateChange: Sendable {
        case snapshot
        case events
        case fidFilters
        case categoryFilters
        case trackedTargets
        case errorMessage
    }

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

    let updateStore: any FavoriteUpdateStatePersisting
    private let libraryStore: any FavoriteUpdateLibraryAccessing
    private let makeForumThreadReaderRepository: @Sendable () async -> any ForumThreadPageFetching
    let settingsStore: SettingsStore?
    let notifier: (any FavoriteUpdateNotifying)?
    let mangaDirectoryStore: (any MangaDirectoryBatchReading)?
    let makeMangaDirectoryWorkflow: (@Sendable (_ searchForumID: String) async -> MangaDirectoryWorkflow)?
    private let runRegistry: FavoriteUpdateActiveRunRegistry

    private var ownedRun: FavoriteUpdateActiveRunRegistry.Run?
    private var observedRun: FavoriteUpdateActiveRunRegistry.Run?
    private let observerID = UUID()
    var notificationBadgeSequence: UInt64 = 0
    private var storeUpdatesTask: Task<Void, Never>?
    private var finishingRunIDs: Set<String> = []

    private func isRunActive(_ runID: String) -> Bool {
        runRegistry.isActive(runID)
    }

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
            Task { [weak self] in await self?.reloadEventState() }
        }
        storeUpdatesTask = Task { @MainActor [weak self, store = updateStore] in
            for await changeID in store.changes() {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard changeID == store.changeID else {
                    continue
                }
                guard self.runRegistry.run(storeID: store.changeID) == nil else { continue }
                await self.reloadFromExternalChange()
            }
        }
    }

    isolated deinit {
        storeUpdatesTask?.cancel()
        runRegistry.removeObserver(storeID: updateStore.changeID, observerID: observerID)
    }

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

    public func reloadEventState() async {
        do {
            applyEventState(try await updateStore.loadState())
        } catch {
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
            let preparationError = (error as? YamiboPersistenceError)?.underlying ?? error
            let wasCancelled = LoadDiagnosticError.isCancellation(preparationError)
            var failed = run.snapshot
            failed.status = wasCancelled ? .interrupted : .failed
            failed.phase = failed.status == .interrupted ? .interrupted : .failed
            failed.finishedAt = .now
            failed.errorMessage = wasCancelled ? preparationError.localizedDescription : error.localizedDescription
            snapshot = failed
            reportError(error)
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
        guard await run.preparation?.value == true else { return }
        await updateSnapshot(runID: run.snapshot.runID) { snapshot in
            snapshot.status = .interrupted
            snapshot.phase = .interrupted
            snapshot.finishedAt = .now
            snapshot.progress = nil
        }
    }

    @discardableResult
    public func waitForCompletion() async -> FavoriteUpdateRunSnapshot? {
        guard let run = observedRun ?? runRegistry.run(storeID: updateStore.changeID) else { return nil }
        await run.driver?.value
        if snapshot?.runID == run.snapshot.runID { snapshot = run.snapshot }
        return run.snapshot
    }

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

    public var hasRecentEvents: Bool {
        events.contains { $0.detectedAt > Date.now.addingTimeInterval(-7 * 24 * 3600) }
    }

    public var hasRecentMangaDirectoryEvents: Bool {
        events.contains {
            $0.mode == .mangaDirectory && $0.detectedAt > Date.now.addingTimeInterval(-7 * 24 * 3600)
        }
    }

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
        if let last = snapshot, let finishedAt = last.finishedAt,
           Date.now.timeIntervalSince(finishedAt) < delay {
            return false
        }
        return await startCheck(nonTagMangaDirectoryCheckCap: nonTagMangaDirectoryCheckCap) != nil
    }

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

    private func runCheck(runID: String, nonTagMangaDirectoryCheckCap: Int) async {
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
        await cleanUpNotifications(forTargetIDs: [])
        await updateStore.endNotificationBadgeRun(runID: runID)
        guard var terminal = snapshot, terminal.runID == runID else { return }
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
        do {
            try await updateStore.saveRun(terminal)
        } catch {
            terminal.status = LoadDiagnosticError.isCancellation(error) ? .interrupted : .failed
            terminal.phase = terminal.status == .interrupted ? .interrupted : .failed
            terminal.errorMessage = terminalErrorMessage ?? error.localizedDescription
            reportError(error)
        }
        guard snapshot?.runID == runID else { return }
        snapshot = terminal
    }

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

    private static func candidates(in document: FavoriteLibraryDocument) -> [FavoriteItem] {
        document.items.filter { item in
            item.target.kind == .normalThread || item.target.kind == .novelThread
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

    private enum CheckResult {
        case checked(detected: Int)
        case skipped
        case offline
        case failed(String)
    }

    static let circuitBreakerThreshold = 5
    static let circuitBreakerCooldown: TimeInterval = 24 * 3600
    private static let currentNovelBaselineVersion = 1

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

        let content: FavoriteContentUpdateResolver.Snapshot
        do {
            content = try await contentUpdate(for: item)
            if let date = content.contentUpdatedAt {
                try await libraryStore.recordContentUpdate(for: item.target, contentUpdatedAt: date)
            }
        } catch {
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

        let page = content.latestPage
        await healUnknownSourceGroupIfNeeded(item: item, page: content.firstPage)

        let fingerprint = FavoriteUpdateFingerprint(page: page, contentUpdatedAt: content.contentUpdatedAt)
        if item.target.kind == .novelThread,
           target.novelBaselineVersion != Self.currentNovelBaselineVersion {
            target.knownLatestPostID = nil
            target.knownReplyCount = nil
            target.knownPageCount = nil
            target.lastUpdatedAt = nil
            target.baselineReady = false
            target.novelBaselineVersion = Self.currentNovelBaselineVersion
        }
        let previous = FavoriteUpdateFingerprint(target: target)

        target.knownLatestPostID = fingerprint.latestPostID ?? target.knownLatestPostID
        target.knownReplyCount = fingerprint.replyCount ?? target.knownReplyCount
        target.knownPageCount = fingerprint.pageCount ?? target.knownPageCount
        target.lastUpdatedAt = [target.lastUpdatedAt, content.contentUpdatedAt].compactMap { $0 }.max()
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

    private func contentUpdate(for item: FavoriteItem) async throws -> FavoriteContentUpdateResolver.Snapshot {
        let tid = item.target.threadID
        let repository = await makeForumThreadReaderRepository()
        try Task.checkCancellation()
        let fid: String? = if case let .forumBoard(id, _) = item.sourceGroup { id } else { nil }
        let thread = ThreadIdentity(tid: tid, fid: fid)
        return try await FavoriteContentUpdateResolver.resolve(
            thread: thread, title: item.resolvedDisplayTitle, kind: item.target.kind, repository: repository
        )
    }

}

private struct FavoriteUpdateFingerprint: Sendable {
    var latestPostID: String?
    var replyCount: Int?
    var pageCount: Int?
    var isReady: Bool
    var contentUpdatedAt: Date?

    init(page: ForumThreadPage, contentUpdatedAt: Date?) {
        latestPostID = page.posts.map(\.postID).last
        replyCount = page.totalReplies
        pageCount = page.pageNavigation?.totalPages
        isReady = latestPostID != nil || replyCount != nil || pageCount != nil
        self.contentUpdatedAt = contentUpdatedAt
    }

    init(target: FavoriteUpdateTrackedTarget) {
        latestPostID = target.knownLatestPostID
        replyCount = target.knownReplyCount
        pageCount = target.knownPageCount
        isReady = target.baselineReady
        contentUpdatedAt = target.lastUpdatedAt
    }

    func isNewer(than previous: FavoriteUpdateFingerprint) -> Bool {
        if let contentUpdatedAt, let previousDate = previous.contentUpdatedAt, contentUpdatedAt > previousDate {
            return true
        }
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
