import Foundation

public struct MangaDirectoryWorkflowConfiguration: Sendable {
    public var searchCooldownDuration: TimeInterval
    public var forcedSearchShortcutDuration: TimeInterval
    /// Board (fid) scoping directory search and tag-list row filtering:
    /// the launching thread's own board, stamped per launch from
    /// `MangaLaunchContext.forumID` (pluggable-reader-config decision #6).
    /// The "30" default exists for test/default construction convenience;
    /// production reader launches always overwrite it when
    /// `MangaReaderViewModel` builds its configuration, substituting "30"
    /// there for launches with no board context (likes, pre-forumID
    /// persisted routes) — the single UI-side R4 fallback point.
    public var searchForumID: String
    public var now: @Sendable () -> Date

    public init(
        searchCooldownDuration: TimeInterval = 20,
        forcedSearchShortcutDuration: TimeInterval = 5,
        searchForumID: String = "30",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.searchCooldownDuration = searchCooldownDuration
        self.forcedSearchShortcutDuration = forcedSearchShortcutDuration
        self.searchForumID = searchForumID
        self.now = now
    }
}

public actor MangaDirectorySearchCooldownState {
    private var deadline: Date?

    public init() {}

    public func cooldownExpiresAt(now: Date) -> Date? {
        guard let deadline else { return nil }
        if deadline <= now {
            self.deadline = nil
            return nil
        }
        return deadline
    }

    /// Atomically checks-and-arms within a single actor call: two concurrent
    /// callers (e.g. foreground + background monitor instances sharing this
    /// state) can never both observe "no active cooldown" and both proceed
    /// to fire a live search — the second one always sees the first's
    /// reservation, even before that first request has completed.
    public func reserveCooldown(now: Date, duration: TimeInterval) -> Date? {
        if let deadline, deadline > now {
            return deadline
        }
        deadline = now.addingTimeInterval(duration)
        return nil
    }

    public func clear() {
        deadline = nil
    }
}

public struct MangaDirectoryResolutionResult: Hashable, Sendable {
    public var directory: MangaDirectory
    public var shouldAutoUpdateAfterInitialLoad: Bool

    public init(directory: MangaDirectory, shouldAutoUpdateAfterInitialLoad: Bool) {
        self.directory = directory
        self.shouldAutoUpdateAfterInitialLoad = shouldAutoUpdateAfterInitialLoad
    }
}

public struct MangaDirectoryUpdateResult: Hashable, Sendable {
    public var directory: MangaDirectory
    public var searchPerformed: Bool
    public var shouldOfferForcedSearch: Bool
    public var cooldownExpiresAt: Date?

    public init(
        directory: MangaDirectory,
        searchPerformed: Bool,
        shouldOfferForcedSearch: Bool,
        cooldownExpiresAt: Date? = nil
    ) {
        self.directory = directory
        self.searchPerformed = searchPerformed
        self.shouldOfferForcedSearch = shouldOfferForcedSearch
        self.cooldownExpiresAt = cooldownExpiresAt
    }
}

public struct MangaDirectoryEditDraft: Hashable, Sendable {
    public var cleanBookName: String
    public var primaryKeyword: String
    public var secondaryKeyword: String

    public init(
        cleanBookName: String,
        primaryKeyword: String,
        secondaryKeyword: String
    ) {
        self.cleanBookName = cleanBookName
        self.primaryKeyword = primaryKeyword
        self.secondaryKeyword = secondaryKeyword
    }
}

public struct MangaDirectoryWorkflow: Sendable {
    private let repository: any MangaDirectoryRepository
    private let store: any MangaDirectoryPersisting
    private let configuration: MangaDirectoryWorkflowConfiguration
    private let searchCooldownState: MangaDirectorySearchCooldownState

    public init(
        repository: any MangaDirectoryRepository,
        store: any MangaDirectoryPersisting,
        configuration: MangaDirectoryWorkflowConfiguration = MangaDirectoryWorkflowConfiguration(),
        searchCooldownState: MangaDirectorySearchCooldownState = MangaDirectorySearchCooldownState()
    ) {
        self.repository = repository
        self.store = store
        self.configuration = configuration
        self.searchCooldownState = searchCooldownState
    }

    public func resolveInitialDirectory(
        context: MangaLaunchContext,
        projection: MangaReaderProjection
    ) async throws -> MangaDirectoryResolutionResult {
        if let directoryName = normalizedNonEmpty(context.directoryName),
           let existing = try await store.directory(named: directoryName) {
            return MangaDirectoryResolutionResult(
                directory: existing,
                shouldAutoUpdateAfterInitialLoad: shouldAutoUpdate(existing)
            )
        }

        if let existing = try await store.directory(containingTID: projection.tid) {
            return MangaDirectoryResolutionResult(
                directory: existing,
                shouldAutoUpdateAfterInitialLoad: shouldAutoUpdate(existing)
            )
        }

        let seed = try await repository.loadDirectorySeed(for: context.chapterTID)
        let directory = MangaDirectoryInitialization.directory(from: seed)
        try await store.saveDirectory(directory)
        return MangaDirectoryResolutionResult(
            directory: directory,
            shouldAutoUpdateAfterInitialLoad: shouldAutoUpdate(directory)
        )
    }

    public func updateDirectory(
        _ currentDirectory: MangaDirectory,
        currentTID: String?,
        isForcedSearch: Bool = false
    ) async throws -> MangaDirectoryUpdateResult {
        try Task.checkCancellation()

        let now = configuration.now()
        let latest = try await store.directory(named: currentDirectory.cleanBookName) ?? currentDirectory
        let keyword = searchKeyword(for: latest, currentTID: currentTID)
        // No fallback here: `searchForumID` is non-optional and already
        // resolved upstream (MangaReaderViewModel stamps it per launch,
        // substituting "30" only there — the single UI-side R4 point).
        let forumID = configuration.searchForumID

        var chapters: [MangaChapter]
        var searchPerformed = false
        var cooldownExpiresAt: Date?

        if latest.strategy == .tag, !isForcedSearch {
            let tagIDs = normalizedValues(latest.sourceKey.split(separator: ",").map(String.init))
            chapters = try await repository.loadTagDirectory(tagIDs: tagIDs, allowedForumID: forumID)
            try Task.checkCancellation()
            if chapters.isEmpty {
                searchPerformed = true
                let pendingCooldownExpiresAt = try await nextSearchCooldownDeadline(now: now)
                chapters = try await repository.searchDirectory(
                    keyword: keyword,
                    forumID: forumID
                )
                try Task.checkCancellation()
                cooldownExpiresAt = pendingCooldownExpiresAt
            }
        } else {
            searchPerformed = true
            let pendingCooldownExpiresAt = try await nextSearchCooldownDeadline(now: now)
            chapters = try await repository.searchDirectory(
                keyword: keyword,
                forumID: forumID
            )
            try Task.checkCancellation()
            cooldownExpiresAt = pendingCooldownExpiresAt
        }

        var updated = latest
        let existingChapters = latest.strategy == .tag
            ? MangaDirectoryChapterRetention.chaptersRetainedDuringTagRefresh(
                latest.chapters,
                incoming: chapters
            )
            : latest.chapters
        updated.chapters = MangaDirectoryMerge.mergeAndSort(existingChapters, chapters)
        updated.lastUpdatedAt = now
        if updated.strategy != .tag {
            updated.strategy = .searched
        }
        try await store.saveDirectory(updated)

        return MangaDirectoryUpdateResult(
            directory: updated,
            searchPerformed: searchPerformed,
            shouldOfferForcedSearch: !searchPerformed && updated.strategy == .tag,
            cooldownExpiresAt: cooldownExpiresAt
        )
    }

    /// Discards the locally cached directory — including manual corrections
    /// such as a renamed/reordered/deleted chapter list — and rebuilds it
    /// from the network exactly like a cold start: re-seeds from
    /// `seedTID`'s thread page, saves that minimal seed, then immediately
    /// runs a full `updateDirectory` pass so tag/search-derived chapters are
    /// fetched too (respecting the same cooldown gate any other update
    /// would). `cleanBookName` — the identity favorites/reading-progress/
    /// covers key off — is preserved even if the source page now derives a
    /// different name, so a reset never orphans data owned by other
    /// subsystems.
    public func resetDirectory(
        _ currentDirectory: MangaDirectory,
        seedTID: String
    ) async throws -> MangaDirectoryUpdateResult {
        try Task.checkCancellation()
        guard let resolvedSeedTID = normalizedNonEmpty(seedTID) else {
            throw YamiboError.persistenceFailed("Directory reset requires a chapter to reseed from")
        }

        let seed = try await repository.loadDirectorySeed(for: resolvedSeedTID)
        try Task.checkCancellation()

        var seeded = MangaDirectoryInitialization.directory(from: seed)
        seeded.cleanBookName = currentDirectory.cleanBookName
        try await store.saveDirectory(seeded)

        return try await updateDirectory(seeded, currentTID: resolvedSeedTID, isForcedSearch: false)
    }

    public func renameDirectory(
        _ currentDirectory: MangaDirectory,
        cleanBookName: String,
        searchKeyword: String
    ) async throws -> MangaDirectory {
        guard let resolvedName = normalizedNonEmpty(cleanBookName) else {
            throw YamiboError.persistenceFailed("Directory name is empty")
        }
        let resolvedKeyword = normalizedNonEmpty(searchKeyword)
        let now = configuration.now()
        let latest = try await store.directory(named: currentDirectory.cleanBookName) ?? currentDirectory

        if latest.cleanBookName == resolvedName {
            var updated = latest
            updated.searchKeyword = resolvedKeyword
            updated.lastUpdatedAt = now
            try await store.saveDirectory(updated)
            return updated
        }

        let target = try await store.directory(named: resolvedName)
        let merged = MangaDirectory(
            cleanBookName: resolvedName,
            strategy: target?.strategy ?? latest.strategy,
            sourceKey: target?.sourceKey ?? (latest.strategy == .tag ? latest.sourceKey : resolvedName),
            chapters: MangaDirectoryMerge.mergeAndSort(target?.chapters ?? [], latest.chapters),
            lastUpdatedAt: now,
            searchKeyword: resolvedKeyword
        )

        if let renamingStore = store as? any MangaDirectoryRenaming {
            try await renamingStore.renameDirectory(from: latest.cleanBookName, to: merged)
        } else {
            try await store.saveDirectory(merged)
            try await store.deleteDirectory(named: latest.cleanBookName)
        }
        return merged
    }

    public func deleteChapters(
        _ currentDirectory: MangaDirectory,
        tids: Set<String>
    ) async throws -> MangaDirectory {
        let targetTIDs = Set(tids.compactMap { normalizedNonEmpty($0) })
        guard !targetTIDs.isEmpty else { return currentDirectory }

        let latest = try await store.directory(named: currentDirectory.cleanBookName) ?? currentDirectory
        let remainingChapters = latest.chapters.filter { !targetTIDs.contains($0.tid) }
        guard remainingChapters.count != latest.chapters.count else {
            return latest
        }

        var updated = latest
        updated.chapters = remainingChapters
        updated.lastUpdatedAt = configuration.now()
        try await store.saveDirectory(updated)
        return updated
    }

    public func editDraft(
        for directory: MangaDirectory,
        currentTID: String?
    ) -> MangaDirectoryEditDraft {
        let cleanBookName = normalizedNonEmpty(directory.cleanBookName) ?? directory.cleanBookName
        if let searchKeyword = normalizedNonEmpty(directory.searchKeyword) {
            let strippedKeyword = searchKeyword
                .replacingOccurrences(of: cleanBookName, with: "", options: [.caseInsensitive])
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !strippedKeyword.isEmpty, strippedKeyword != searchKeyword {
                return MangaDirectoryEditDraft(
                    cleanBookName: cleanBookName,
                    primaryKeyword: strippedKeyword,
                    secondaryKeyword: cleanBookName
                )
            }
            return MangaDirectoryEditDraft(
                cleanBookName: cleanBookName,
                primaryKeyword: searchKeyword,
                secondaryKeyword: ""
            )
        }

        let seedTitle = currentTID.flatMap { tid in
            directory.chapters.first(where: { $0.tid == tid })?.rawTitle
        } ?? directory.chapters.last?.rawTitle ?? directory.cleanBookName
        return MangaDirectoryEditDraft(
            cleanBookName: cleanBookName,
            primaryKeyword: MangaTitleCleaner.extractAuthorPrefix(seedTitle),
            secondaryKeyword: cleanBookName
        )
    }

    public func cooldownExpiresAt() async -> Date? {
        await searchCooldownState.cooldownExpiresAt(now: configuration.now())
    }

    public static func searchKeyword(from draft: MangaDirectoryEditDraft) -> String {
        [draft.primaryKeyword, draft.secondaryKeyword]
            .compactMap { normalizedNonEmpty($0) }
            .joined(separator: " ")
    }

    private func shouldAutoUpdate(_ directory: MangaDirectory) -> Bool {
        directory.strategy == .tag && directory.lastUpdatedAt == nil
    }

    private func searchKeyword(for directory: MangaDirectory, currentTID: String?) -> String {
        if let searchKeyword = normalizedNonEmpty(directory.searchKeyword) {
            return searchKeyword
        }
        let seedTitle = currentTID.flatMap { tid in
            directory.chapters.first(where: { $0.tid == tid })?.rawTitle
        } ?? directory.cleanBookName
        return MangaTitleCleaner.searchKeyword(seedTitle)
    }

    /// Reserves the cooldown window before the network call, not after: this
    /// arms the gate even if the ensuing `searchDirectory` throws (including
    /// forum flood control), so a failed request still blocks the next
    /// attempt instead of leaving the gate open for it to repeat the same
    /// live request against a forum that just rate-limited us.
    private func nextSearchCooldownDeadline(now: Date) async throws -> Date {
        if let deadline = await searchCooldownState.reserveCooldown(now: now, duration: configuration.searchCooldownDuration) {
            let seconds = max(1, Int(ceil(deadline.timeIntervalSince(now))))
            throw YamiboError.searchCooldown(seconds: seconds)
        }

        return now.addingTimeInterval(configuration.searchCooldownDuration)
    }
}

enum MangaDirectoryChapterRetention {
    static func chaptersRetainedDuringTagRefresh(
        _ existing: [MangaChapter],
        incoming: [MangaChapter]
    ) -> [MangaChapter] {
        let incomingIDs = Set(incoming.map(\.tid))
        return existing.filter { chapter in
            incomingIDs.contains(chapter.tid) || titleLooksLikeMangaChapter(chapter.rawTitle)
        }
    }

    private static func titleLooksLikeMangaChapter(_ rawTitle: String) -> Bool {
        if MangaTitleCleaner.extractChapterNumber(rawTitle) > 0 {
            return true
        }
        return rawTitle.range(
            of: #"番外|特典|特别|特別|附录|附錄|SP|卷后|卷後|小剧场|小劇場|小漫画|小漫畫|最终话|最終話|最终回|最終回|大结局"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

public enum MangaDirectoryMerge {
    public static func mergeAndSort(
        _ existing: [MangaChapter],
        _ incoming: [MangaChapter]
    ) -> [MangaChapter] {
        var mergedByID: [String: MangaChapter] = [:]
        for chapter in existing + incoming {
            mergedByID[chapter.tid] = chapter
        }

        var sorted = mergedByID.values.sorted {
            ($0.tid.mangaDirectoryInt64OrZero, $0.publishTime ?? .distantPast, $0.rawTitle) <
                ($1.tid.mangaDirectoryInt64OrZero, $1.publishTime ?? .distantPast, $1.rawTitle)
        }

        var previousNumber = 0.0
        for index in sorted.indices {
            guard sorted[index].chapterNumber == 0 else {
                previousNumber = sorted[index].chapterNumber
                continue
            }

            let candidates = MangaTitleCleaner.extractAllPossibleNumbers(from: sorted[index].rawTitle)
            if let next = candidates.first(where: { $0 >= previousNumber }) {
                sorted[index].chapterNumber = next
                previousNumber = next
            } else if previousNumber > 0 {
                previousNumber += 0.1
                sorted[index].chapterNumber = previousNumber
            }
        }
        return sorted
    }
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
}

private func normalizedValues(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var normalized: [String] = []
    for value in values {
        guard let trimmed = normalizedNonEmpty(value),
              seen.insert(trimmed).inserted else {
            continue
        }
        normalized.append(trimmed)
    }
    return normalized
}

private extension String {
    var mangaDirectoryInt64OrZero: Int64 {
        Int64(self) ?? 0
    }
}
