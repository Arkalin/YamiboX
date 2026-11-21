import Foundation

extension FavoriteUpdateCheckEngine {

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

    func mangaDirectoryGroups(in document: FavoriteLibraryDocument) async -> [MangaDirectoryCandidate] {
        guard let mangaDirectoryStore, let settingsStore else { return [] }
        let settings = await settingsStore.load()
        let eligibleItems: [(item: FavoriteItem, forumID: String)] = document.items.compactMap { item in
            guard item.target.kind == .mangaThread,
                  let forumID = item.forumID,
                  settings.isSmartComicModeEnabled(forumID: forumID) else { return nil }
            return (item, forumID)
        }
        guard !eligibleItems.isEmpty else { return [] }
        let tids = eligibleItems.map { $0.item.target.threadID }
        let resolved: [String: MangaDirectory]
        do {
            resolved = try await mangaDirectoryStore.directories(containingTIDs: tids)
        } catch {
            YamiboLog.sync.warning("Failed to batch-resolve manga directories for update checking: \(error.localizedDescription)")
            return []
        }
        guard !resolved.isEmpty else { return [] }

        var groupsByID: [MangaDirectoryID: MangaDirectoryCandidate] = [:]
        for (item, forumID) in eligibleItems.sorted(by: { $0.item.target.id < $1.item.target.id }) {
            guard let directory = resolved[item.target.threadID] else { continue }
            var group = groupsByID[directory.id] ?? MangaDirectoryCandidate(
                directory: directory,
                forumID: forumID,
                forumName: item.forumName,
                categoryIDs: []
            )
            group.categoryIDs.formUnion(item.locations.compactMap(\.categoryID))
            groupsByID[directory.id] = group
        }
        return groupsByID.values.sorted { $0.directory.cleanBookName < $1.directory.cleanBookName }
    }

    func checkMangaDirectoryGroups(
        _ groups: [MangaDirectoryCandidate],
        nonTagCheckCap: Int,
        runID: String,
        trackedTargets: inout [String: FavoriteUpdateTrackedTarget],
        events: inout FavoriteUpdateRunEventAccumulator
    ) async {
        guard !groups.isEmpty else { return }
        let existingByDirectoryID: [MangaDirectoryID: FavoriteUpdateTrackedTarget] = Dictionary(
            uniqueKeysWithValues: trackedTargets.values.compactMap { target in
                guard case let .mangaDirectory(directoryID) = target.target else { return nil }
                return (directoryID, target)
            }
        )

        let newGroups = groups.filter { existingByDirectoryID[$0.directory.id] == nil }
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
            guard let existing = existingByDirectoryID[group.directory.id] else { return nil }
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

    private func seedMangaDirectoryBaseline(
        _ group: MangaDirectoryCandidate,
        trackedTargets: inout [String: FavoriteUpdateTrackedTarget]
    ) {
        let target = FavoriteUpdateTrackedTarget(
            target: .mangaDirectory(directoryID: group.directory.id),
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

    private func checkMangaDirectoryUpdate(
        group: MangaDirectoryCandidate,
        existing: FavoriteUpdateTrackedTarget,
        trackedTargets: inout [String: FavoriteUpdateTrackedTarget],
        events: inout FavoriteUpdateRunEventAccumulator
    ) async -> MangaDirectoryCheckResult {
        guard let makeMangaDirectoryWorkflow else { return .skippedCircuitBreaker }
        var target = existing

        if target.consecutiveFailures >= Self.circuitBreakerThreshold,
           let lastCheckedAt = target.lastCheckedAt,
           Date.now.timeIntervalSince(lastCheckedAt) < Self.circuitBreakerCooldown {
            return .skippedCircuitBreaker
        }

        let workflow = await makeMangaDirectoryWorkflow(group.forumID)
        let representativeTID = group.directory.chapters.last?.tid

        do {
            let result = try await workflow.updateDirectory(group.directory, currentTID: representativeTID)
            let refreshedTIDs = Set(result.directory.chapters.map(\.tid))
            let newTIDs: Set<String>
            if let knownTIDs = target.knownChapterTIDs {
                newTIDs = refreshedTIDs.subtracting(knownTIDs)
                target.knownChapterTIDs = knownTIDs.union(refreshedTIDs)
            } else {
                newTIDs = []
                target.knownChapterTIDs = refreshedTIDs
            }
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

            let key = FavoriteUpdateTargetKey.mangaDirectory(directoryID: group.directory.id)
            let existingEvent = events.firstUndismissed(for: key)
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
            events.replaceUndismissed(with: event)
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
