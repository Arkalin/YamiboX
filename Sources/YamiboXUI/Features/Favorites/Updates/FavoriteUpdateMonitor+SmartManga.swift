import Foundation
import YamiboXCore

extension FavoriteUpdateMonitor {

    // MARK: - Smart-manga directory check lane

    /// One or more favorited `.mangaThread` chapters that resolved to the
    /// same `MangaDirectory`, collapsed into a single check unit (design
    /// decision #4: detection is per-directory, not per-favorite).
    struct MangaDirectoryCandidate {
        var directory: MangaDirectory
        var forumID: String
        var forumName: String?
        var categoryIDs: Set<String>
    }

    enum MangaDirectoryCheckResult {
        case checked(detected: Int)
        case skippedCircuitBreaker
        case skippedCooldown
        case failed(String)
    }

    /// Gathers eligible `.mangaThread` favorites (mode ON for their own
    /// board, per `BoardReaderSettings.isSmartComicModeEnabled` — the
    /// authoritative gate, never inferred from a resolved directory or any
    /// other proxy signal) and batch-resolves their tids to directories in
    /// ONE query, then groups the resolved ones by `cleanBookName`. A
    /// favorite whose board is mode-off, or whose tid has no resolved
    /// directory yet, is silently excluded here — not tracked, not an
    /// error; this pipeline never triggers directory resolution itself.
    func mangaDirectoryGroups(in document: FavoriteLibraryDocument) async -> [MangaDirectoryCandidate] {
        guard let mangaDirectoryStore, let settingsStore else { return [] }
        let settings = await settingsStore.load()
        let eligibleItems: [(item: FavoriteItem, forumID: String)] = document.items.compactMap { item in
            guard item.target.kind == .mangaThread,
                  item.target.threadID != nil,
                  let forumID = item.forumID,
                  settings.isSmartComicModeEnabled(forumID: forumID) else { return nil }
            return (item, forumID)
        }
        guard !eligibleItems.isEmpty else { return [] }
        let tids = eligibleItems.compactMap { $0.item.target.threadID }
        let resolved: [String: MangaDirectory]
        do {
            resolved = try await mangaDirectoryStore.directories(containingTIDs: tids)
        } catch {
            YamiboLog.sync.warning("Failed to batch-resolve manga directories for update checking: \(error.localizedDescription)")
            return []
        }
        guard !resolved.isEmpty else { return [] }

        var groupsByName: [String: MangaDirectoryCandidate] = [:]
        for (item, forumID) in eligibleItems.sorted(by: { $0.item.target.id < $1.item.target.id }) {
            guard let tid = item.target.threadID, let directory = resolved[tid] else { continue }
            var group = groupsByName[directory.cleanBookName] ?? MangaDirectoryCandidate(
                directory: directory,
                forumID: forumID,
                forumName: item.forumName,
                categoryIDs: []
            )
            group.categoryIDs.formUnion(item.locations.compactMap(\.categoryID))
            groupsByName[directory.cleanBookName] = group
        }
        return groupsByName.values.sorted { $0.directory.cleanBookName < $1.directory.cleanBookName }
    }

    /// Seeds, then (for already-tracked, due groups) refreshes and diffs
    /// smart-manga directories. Ordering/capping (design point g/h): every
    /// never-seen-before group is seeded first (zero network cost, always
    /// allowed), then ALL due `.tag`-strategy groups run (cheap, no search
    /// cooldown in the common case), then up to `nonTagCheckCap` due
    /// non-`.tag`-strategy groups run oldest-`lastCheckedAt`-first. A
    /// cooldown/flood-control hit stops further groups of either kind for
    /// the rest of this run — the cooldown is global, so trying another
    /// would just fail again and waste the run's remaining budget.
    func checkMangaDirectoryGroups(
        _ groups: [MangaDirectoryCandidate],
        nonTagCheckCap: Int,
        runID: String,
        trackedTargets: inout [String: FavoriteUpdateTrackedTarget],
        events: inout [FavoriteUpdateEvent]
    ) async {
        guard !groups.isEmpty else { return }
        let existingByCleanBookName: [String: FavoriteUpdateTrackedTarget] = Dictionary(
            uniqueKeysWithValues: trackedTargets.values.compactMap { target in
                guard case let .mangaDirectory(cleanBookName) = target.target else { return nil }
                return (cleanBookName, target)
            }
        )

        let newGroups = groups.filter { existingByCleanBookName[$0.directory.cleanBookName] == nil }
        for group in newGroups {
            guard !Task.isCancelled else { return }
            seedMangaDirectoryBaseline(group, trackedTargets: &trackedTargets)
            await updateSnapshot(runID: runID) { snapshot in
                snapshot.totalCount += 1
                snapshot.completedCount += 1
            }
        }

        guard let interval = await smartMangaInterval(),
              let delay = interval.nextDelay(hasRecentEvents: hasRecentMangaDirectoryEvents) else {
            return
        }

        let dueExisting: [(group: MangaDirectoryCandidate, existing: FavoriteUpdateTrackedTarget)] = groups.compactMap { group in
            guard let existing = existingByCleanBookName[group.directory.cleanBookName] else { return nil }
            if let lastCheckedAt = existing.lastCheckedAt, Date.now.timeIntervalSince(lastCheckedAt) < delay {
                return nil
            }
            return (group, existing)
        }

        let tagDue = dueExisting.filter { $0.group.directory.strategy == .tag }
        let nonTagDue = dueExisting
            .filter { $0.group.directory.strategy != .tag }
            .sorted { ($0.existing.lastCheckedAt ?? .distantPast) < ($1.existing.lastCheckedAt ?? .distantPast) }

        for (group, existing) in tagDue {
            guard !Task.isCancelled else { return }
            await updateSnapshot(runID: runID) { snapshot in snapshot.totalCount += 1 }
            let result = await checkMangaDirectoryUpdate(
                group: group,
                existing: existing,
                trackedTargets: &trackedTargets,
                events: &events
            )
            await applyMangaDirectoryResult(result, runID: runID)
            if case .skippedCooldown = result {
                break
            }
        }

        var nonTagChecksPerformed = 0
        for (group, existing) in nonTagDue {
            guard !Task.isCancelled else { return }
            guard nonTagChecksPerformed < nonTagCheckCap else { break }
            nonTagChecksPerformed += 1
            await updateSnapshot(runID: runID) { snapshot in snapshot.totalCount += 1 }
            let result = await checkMangaDirectoryUpdate(
                group: group,
                existing: existing,
                trackedTargets: &trackedTargets,
                events: &events
            )
            await applyMangaDirectoryResult(result, runID: runID)
            if case .skippedCooldown = result {
                break
            }
        }
    }

    private func smartMangaInterval() async -> SmartMangaUpdateCheckInterval? {
        guard let settingsStore else { return nil }
        return await settingsStore.load().favorites.smartMangaUpdateCheckInterval
    }

    /// First sighting of a directory: baseline-only, zero network, no event
    /// (design point 6 — otherwise every already-read chapter would report
    /// as "new" the moment tracking starts).
    private func seedMangaDirectoryBaseline(
        _ group: MangaDirectoryCandidate,
        trackedTargets: inout [String: FavoriteUpdateTrackedTarget]
    ) {
        let target = FavoriteUpdateTrackedTarget(
            target: .mangaDirectory(cleanBookName: group.directory.cleanBookName),
            title: group.directory.cleanBookName,
            mode: .mangaDirectory,
            categoryIDs: group.categoryIDs,
            fid: group.forumID,
            forumName: group.forumName,
            knownChapterTIDs: Set(group.directory.chapters.map(\.tid)),
            baselineReady: true,
            lastCheckedAt: .now
        )
        trackedTargets[target.id] = target
    }

    private func applyMangaDirectoryResult(_ result: MangaDirectoryCheckResult, runID: String) async {
        switch result {
        case let .checked(detected):
            await updateSnapshot(runID: runID) { snapshot in
                snapshot.completedCount += 1
                snapshot.detectedCount += detected
            }
        case .skippedCircuitBreaker, .skippedCooldown:
            await updateSnapshot(runID: runID) { snapshot in snapshot.skippedCount += 1 }
        case let .failed(message):
            await updateSnapshot(runID: runID) { snapshot in
                snapshot.failedCount += 1
                snapshot.warningMessage = [snapshot.warningMessage, message].compactMap { $0 }.joined(separator: "\n")
            }
        }
    }

    /// Refreshes one directory's chapter list over the network and diffs the
    /// result against the tracked tid baseline. `YamiboError.searchCooldown`
    /// (the workflow's own client-side cooldown) and `.floodControl` (the
    /// forum's own flood-control page, detected downstream in the parser)
    /// are both an expected "not now" — never fed to the circuit breaker,
    /// never advancing the baseline. Any other error DOES feed the breaker,
    /// same as the thread-check lane.
    private func checkMangaDirectoryUpdate(
        group: MangaDirectoryCandidate,
        existing: FavoriteUpdateTrackedTarget,
        trackedTargets: inout [String: FavoriteUpdateTrackedTarget],
        events: inout [FavoriteUpdateEvent]
    ) async -> MangaDirectoryCheckResult {
        guard let makeMangaDirectoryWorkflow else { return .skippedCircuitBreaker }
        var target = existing

        if target.consecutiveFailures >= Self.circuitBreakerThreshold,
           let lastCheckedAt = target.lastCheckedAt,
           Date.now.timeIntervalSince(lastCheckedAt) < Self.circuitBreakerCooldown {
            return .skippedCircuitBreaker
        }

        let workflow = await makeMangaDirectoryWorkflow(group.forumID)
        // Seeds the search keyword from a real chapter title when the
        // directory has none yet — any favorited chapter in the group works,
        // so the most recently added one is as good a representative as any.
        let representativeTID = group.directory.chapters.last?.tid

        do {
            let result = try await workflow.updateDirectory(group.directory, currentTID: representativeTID)
            // `existing` is only ever produced by `seedMangaDirectoryBaseline`
            // or a prior pass through this same function, both of which
            // always set `knownChapterTIDs` — the `?? []` here just satisfies
            // the optional, it never actually triggers.
            let knownTIDs = target.knownChapterTIDs ?? []
            let refreshedTIDs = Set(result.directory.chapters.map(\.tid))
            let newTIDs = refreshedTIDs.subtracting(knownTIDs)

            target.knownChapterTIDs = knownTIDs.union(refreshedTIDs)
            target.baselineReady = true
            target.lastCheckedAt = .now
            target.lastError = nil
            target.consecutiveFailures = 0
            target.title = group.directory.cleanBookName
            target.fid = group.forumID
            target.forumName = group.forumName
            target.categoryIDs = group.categoryIDs

            guard !newTIDs.isEmpty else {
                trackedTargets[target.id] = target
                return .checked(detected: 0)
            }

            let key = FavoriteUpdateTargetKey.mangaDirectory(cleanBookName: group.directory.cleanBookName)
            let existingEvent = events.first { $0.target == key && $0.dismissedAt == nil }
            let summary = Self.mergedSummary(
                existing: existingEvent?.summary,
                new: .newChapters(count: newTIDs.count)
            )
            let event = FavoriteUpdateEvent(
                target: key,
                title: group.directory.cleanBookName,
                mode: .mangaDirectory,
                fid: group.forumID,
                forumName: group.forumName,
                summary: summary,
                detailIDs: newTIDs.sorted(),
                detectedAt: .now,
                ambiguous: false
            )
            events.removeAll { $0.target == event.target && $0.dismissedAt == nil }
            events.append(event)
            trackedTargets[target.id] = target
            await deliverNotificationIfEnabled(for: event, runEvents: events)
            return .checked(detected: 1)
        } catch {
            if case YamiboError.searchCooldown = error {
                YamiboLog.sync.info("Smart-manga directory check for \(group.directory.cleanBookName) hit search cooldown, deferring")
                return .skippedCooldown
            }
            if case YamiboError.floodControl = error {
                YamiboLog.sync.warning("Smart-manga directory check for \(group.directory.cleanBookName) hit forum flood control, deferring")
                return .skippedCooldown
            }
            YamiboLog.sync.warning("Smart-manga directory check failed for \(group.directory.cleanBookName): \(error.localizedDescription)")
            target.consecutiveFailures += 1
            target.lastError = error.localizedDescription
            target.lastCheckedAt = .now
            trackedTargets[target.id] = target
            return .failed(error.localizedDescription)
        }
    }
}
