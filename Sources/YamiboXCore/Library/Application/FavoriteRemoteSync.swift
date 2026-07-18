import Foundation

public struct YamiboRemoteFavoriteEntry: Hashable, Sendable {
    public var remoteFavoriteID: String
    public var threadID: String
    public var title: String?
    public var remoteOrder: Int

    public init(remoteFavoriteID: String, threadID: String, title: String? = nil, remoteOrder: Int = 0) {
        self.remoteFavoriteID = remoteFavoriteID
        self.threadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title
        self.remoteOrder = remoteOrder
    }
}

/// One page of the Yamibo remote favorite list.
public struct FavoriteYamiboRemotePage: Sendable {
    public var entries: [YamiboRemoteFavoriteEntry]
    public var currentPage: Int
    public var totalPages: Int

    public init(entries: [YamiboRemoteFavoriteEntry], currentPage: Int, totalPages: Int) {
        self.entries = entries
        self.currentPage = max(1, currentPage)
        self.totalPages = max(1, totalPages)
    }
}

/// Network operations the sync engine needs, injected as closures so the UI
/// layer can compose them from its repositories and tests can fake them.
public struct FavoriteYamiboSyncClient: Sendable {
    /// Fetches one page of the remote favorite list.
    public var fetchPage: @Sendable (_ page: Int) async throws -> FavoriteYamiboRemotePage
    /// Resolves a remote entry's thread into a favorite target with metadata
    /// (the entry carries the remote title as a resolution hint).
    /// Implementations are expected to record covers as a side effect.
    public var probe: @Sendable (_ entry: YamiboRemoteFavoriteEntry) async throws -> FavoriteThreadProbeResult
    /// Adds one thread to the Yamibo remote favorites.
    public var addFavorite: @Sendable (_ threadID: String) async throws -> Void

    public init(
        fetchPage: @escaping @Sendable (_ page: Int) async throws -> FavoriteYamiboRemotePage,
        probe: @escaping @Sendable (_ entry: YamiboRemoteFavoriteEntry) async throws -> FavoriteThreadProbeResult,
        addFavorite: @escaping @Sendable (_ threadID: String) async throws -> Void
    ) {
        self.fetchPage = fetchPage
        self.probe = probe
        self.addFavorite = addFavorite
    }
}

/// Five-phase Yamibo favorite sync engine (Android-parity semantics):
///
/// 1. preparing — validate the target category.
/// 2. fetching — page through the remote favorite list.
/// 3. importing — import remote-only threads; existing unmapped items gain the
///    target category location; already-mapped items only refresh the mapping.
/// 4. uploading — push every thread item of the target category that the
///    remote list lacks, including items the website side deleted: the local
///    library is the source of truth and sync converges to the union.
/// 5. reconciling — if anything uploaded, re-fetch the remote list and backfill
///    favorite IDs and ordering.
///
/// Sync never deletes on either side; deletions propagate only through the
/// explicit delete actions. Cancellation is cooperative: the engine finishes
/// the current network call, persists partial progress, and records the run as
/// interrupted.
public struct FavoriteYamiboSyncEngine: Sendable {
    private let libraryStore: FavoriteLibraryStore
    private let client: FavoriteYamiboSyncClient
    /// Backs the batched tid → directory lookup phase 3 uses for the
    /// "imported into an already-favorited manga directory" warning
    /// (smart-comic-mode Phase G, design decision #8's remote-sync half).
    /// Concrete type, not the `MangaDirectoryPersisting` existential — same
    /// reasoning as `FavoriteLibraryOrganizer`'s equivalent property: it
    /// rules out ever accidentally running the protocol's naive per-tid
    /// default implementation in production. `nil` (e.g. in engine tests that
    /// don't exercise this feature) simply disables the warning.
    private let mangaDirectoryStore: MangaDirectoryStore?
    /// Backs the per-item "is Smart Comic Mode on for this board" check the
    /// same warning needs. `nil` falls back to the factory-default
    /// `BoardReaderSettings()` (not an empty configuration), so the
    /// attribution warning stays functional in the default scenario.
    private let settingsStore: SettingsStore?

    public init(
        libraryStore: FavoriteLibraryStore,
        client: FavoriteYamiboSyncClient,
        mangaDirectoryStore: MangaDirectoryStore? = nil,
        settingsStore: SettingsStore? = nil
    ) {
        self.libraryStore = libraryStore
        self.client = client
        self.mangaDirectoryStore = mangaDirectoryStore
        self.settingsStore = settingsStore
    }

    /// Runs the five phases starting from `initial` (typically phase .queued).
    /// Every snapshot mutation is pushed through `persist`; the returned
    /// snapshot is terminal (completed, failed, or interrupted).
    public func run(
        snapshot initial: FavoriteRemoteSyncSnapshot,
        interruptionReason: @escaping @Sendable () -> FavoriteRemoteSyncWarning? = { nil },
        persist: @escaping @Sendable (FavoriteRemoteSyncSnapshot) async -> Void
    ) async -> FavoriteRemoteSyncSnapshot {
        var snapshot = initial
        var pendingOperations: [@Sendable (inout FavoriteLibraryDocument) -> Void] = []

        func commit(_ mutate: (inout FavoriteRemoteSyncSnapshot) -> Void) async {
            mutate(&snapshot)
            snapshot.updatedAt = .now
            await persist(snapshot)
        }

        /// Queues a mutation for replay onto a freshly-loaded document at save
        /// time, so a save never blindly overwrites edits the user made
        /// elsewhere while this run was fetching. Reach for `apply` (defined
        /// next to `workingDocument`) instead wherever possible — raw `record`
        /// is only for the import case whose first application must throw
        /// while its replay is tolerant.
        func record(_ operation: @escaping @Sendable (inout FavoriteLibraryDocument) -> Void) {
            pendingOperations.append(operation)
        }

        /// Replays every mutation this run has queued since the last save onto
        /// the current on-disk document and persists the merged result, all
        /// inside one store transaction — this is what keeps a long-running
        /// sync from clobbering concurrent local edits (deletes, moves, tag
        /// changes) with a stale in-memory snapshot.
        func saveDocumentIfDirty() async throws -> FavoriteLibraryDocument? {
            guard !pendingOperations.isEmpty else { return nil }
            let operations = pendingOperations
            let libraryStore = libraryStore
            // Unstructured task: interruption persists partial progress from
            // the cancelled task, and GRDB's async accesses honor Task
            // cancellation — the write must not inherit it.
            let merged = try await Task { () -> FavoriteLibraryDocument in
                try await libraryStore.update { fresh in
                    for operation in operations {
                        operation(&fresh)
                    }
                    return fresh
                }
            }.value
            pendingOperations.removeAll()
            return merged
        }

        do {
            // Phase 1: preparing
            try Task.checkCancellation()
            await commit { $0.phase = .preparing }
            var workingDocument = try await libraryStore.load()

            /// Single write path for this run's document mutations: applies
            /// the operation to the in-memory working copy and queues the
            /// same closure for the save-time replay. One closure feeding
            /// both copies is what keeps them from drifting — previously
            /// every mutation was written twice by hand, and forgetting
            /// either half meant "visible but never saved" (or the reverse).
            func apply(_ operation: @escaping @Sendable (inout FavoriteLibraryDocument) -> Void) {
                operation(&workingDocument)
                record(operation)
            }
            guard workingDocument.categories.contains(where: { $0.id == snapshot.targetCategoryID }) else {
                throw YamiboPersistenceError(context: L10n.string("favorites.sync.error.category_missing"))
            }
            let targetLocation = FavoriteLocation.category(snapshot.targetCategoryID)

            // Phase 2: fetching
            await commit { $0.phase = .fetching }
            var remoteEntries: [YamiboRemoteFavoriteEntry] = []
            var remoteThreadIDs: Set<String> = []
            var reportedPageCountChange = false
            var page = 1
            var totalPages: Int?
            while true {
                try Task.checkCancellation()
                let result = try await Self.fetchPageWithRetry(page, client: client)
                if let known = totalPages, known != result.totalPages, !reportedPageCountChange {
                    reportedPageCountChange = true
                    await commit { $0.warnings.append(.remotePageCountChanged) }
                }
                totalPages = result.totalPages
                var duplicateTitles: [String] = []
                for entry in result.entries {
                    guard remoteThreadIDs.insert(entry.threadID).inserted else {
                        duplicateTitles.append(Self.postLabel(threadID: entry.threadID, title: entry.title))
                        continue
                    }
                    var ordered = entry
                    ordered.remoteOrder = remoteEntries.count
                    remoteEntries.append(ordered)
                }
                let accumulated = remoteEntries.count
                let resolvedTotal = totalPages ?? page
                await commit { snapshot in
                    snapshot.currentPage = page
                    snapshot.totalPages = resolvedTotal
                    snapshot.scannedCount = accumulated
                    snapshot.logEntries.append(.fetchedPage(page: page, totalPages: resolvedTotal, accumulatedCount: accumulated))
                    for title in duplicateTitles {
                        snapshot.warnings.append(.duplicateRemoteEntry(title: title))
                    }
                }
                if page >= resolvedTotal || result.entries.isEmpty {
                    break
                }
                page += 1
            }

            // Phase 3: importing
            await commit { $0.phase = .importing }
            var skippedPathCounts: [(path: String, count: Int)] = []
            let importTotal = remoteEntries.count

            // Attribution detection setup (smart-comic-mode Phase G, design
            // decision #8's remote-sync half). Two pieces of state captured
            // once, up front, before any item in this run is imported:
            //
            // 1. `preImportMangaThreadFavoritesByTID` — a snapshot of every
            //    `.mangaThread` favorite already in the document *before this
            //    run imports anything*. Deliberately frozen here rather than
            //    re-read from `workingDocument` inside the loop below: if two
            //    sibling chapters both happen to be newly imported within
            //    this same run, neither existed "before this sync run started
            //    importing", so importing one must not trigger the warning
            //    for the other.
            // 2. `candidateDirectoriesByTID` — the tid → `MangaDirectory`
            //    lookup for every entry that isn't already a local favorite
            //    (i.e. every entry that will go through the fresh-import path
            //    below, whatever target kind it turns out to probe as). This
            //    is the single batched `directories(containingTIDs:)` round
            //    trip the design doc's "现算分组的性能要求" hard constraint
            //    requires — never one `directory(containingTID:)` call per
            //    item in the loop.
            var preImportMangaThreadFavoritesByTID: [String: FavoriteItem] = [:]
            for item in workingDocument.items where item.target.kind == .mangaThread {
                if let tid = item.target.threadID {
                    preImportMangaThreadFavoritesByTID[tid] = item
                }
            }
            let existingThreadIDs = Set(workingDocument.items.compactMap(\.target.threadID))
            let candidateThreadIDs = remoteEntries.map(\.threadID).filter { !existingThreadIDs.contains($0) }
            var candidateDirectoriesByTID: [String: MangaDirectory] = [:]
            if let mangaDirectoryStore, !candidateThreadIDs.isEmpty {
                do {
                    candidateDirectoriesByTID = try await mangaDirectoryStore.directories(containingTIDs: candidateThreadIDs)
                } catch is CancellationError {
                    // Don't swallow cancellation into a mere warning — let it
                    // propagate to the run's own cancellation handling below.
                    throw CancellationError()
                } catch {
                    YamiboLog.sync.warning("Failed to batch-resolve manga directories for sync attribution detection; this run will skip attribution warnings: \(error.localizedDescription)")
                }
            }
            let boardReaderSettings = await settingsStore?.load().boardReader ?? BoardReaderSettings()

            for (offset, entry) in remoteEntries.enumerated() {
                try Task.checkCancellation()
                let label = Self.postLabel(threadID: entry.threadID, title: entry.title)
                await commit { $0.logEntries.append(.importingItem(index: offset + 1, total: importTotal, title: label)) }

                if let existing = workingDocument.items.first(where: { $0.target.threadID == entry.threadID }) {
                    let alreadyMapped = existing.remoteMapping?.yamiboFavoriteID != nil
                    let existingTarget = existing.target
                    if !alreadyMapped {
                        apply { doc in doc.addLocation(targetLocation, to: existingTarget) }
                    }
                    apply { doc in
                        doc.updateRemoteMapping(
                            for: existingTarget,
                            yamiboFavoriteID: entry.remoteFavoriteID,
                            yamiboRemoteOrder: entry.remoteOrder
                        )
                    }
                    if alreadyMapped {
                        let path = Self.pathDescription(for: existing, in: workingDocument)
                        if let index = skippedPathCounts.firstIndex(where: { $0.path == path }) {
                            skippedPathCounts[index].count += 1
                        } else {
                            skippedPathCounts.append((path, 1))
                        }
                        await commit { $0.skippedCount += 1 }
                    } else {
                        await commit { $0.importedCount += 1 }
                    }
                    continue
                }

                do {
                    let probeResult = try await Self.probeWithRetry(entry, client: client)
                    guard !probeResult.sourceMetadataFetchFailed else {
                        // The thread's own detail page never resolved even
                        // after `threadMetadata()`'s retries, so forum/cover/
                        // content-updated metadata is unknown. This used to
                        // still import the item as a permanent "未知来源"
                        // placeholder with a warning; treat it the same as
                        // any other probe failure instead, so the item isn't
                        // kept in favorites and the next sync run retries it
                        // from scratch.
                        throw YamiboError.parsingFailed(context: entry.threadID)
                    }
                    let mapping = FavoriteRemoteMapping(
                        yamiboFavoriteID: entry.remoteFavoriteID,
                        yamiboRemoteOrder: entry.remoteOrder,
                        lastSeenAt: .now
                    )
                    // A manga chapter thread imports through the same generic
                    // path as any other thread now: `FavoriteItemTarget` has
                    // no merged-directory kind left to special-case (the old
                    // dedicated `importMangaChapterFavorite` mechanism was
                    // removed — see smart-comic-mode Phase A decision #3/#9).
                    let importedItem = try workingDocument.importThreadFavorite(
                        probeResult: probeResult,
                        location: targetLocation,
                        remoteMapping: mapping
                    )
                    record { doc in
                        do {
                            _ = try doc.importThreadFavorite(
                                probeResult: probeResult,
                                location: targetLocation,
                                remoteMapping: mapping
                            )
                        } catch {
                            YamiboLog.sync.error("Failed to replay thread favorite import for thread \(entry.threadID, privacy: .public) onto reloaded document: \(error)")
                        }
                    }
                    await commit { $0.importedCount += 1 }
                    // `importedItem.forumID` (not `probeResult.forumID`,
                    // which the manga probe path leaves nil) is read here
                    // because `FavoriteItem.init` resolves the real forumID
                    // from `sourceGroup` when the explicit parameter is nil —
                    // reading the item that actually landed in the document
                    // is correct regardless of which of the two carried it.
                    if importedItem.target.kind == .mangaThread,
                       let directory = candidateDirectoriesByTID[entry.threadID],
                       boardReaderSettings.isSmartComicModeEnabled(forumID: importedItem.forumID) {
                        // Check EVERY already-favorited sibling chapter, not just the
                        // first one encountered in chapter order (`manual_order`/`tid`,
                        // unrelated to which sibling is favorited or its board's mode) —
                        // a directory can span multiple boards, and the sibling that
                        // happens to sort first may have Smart Comic Mode off while a
                        // later sibling has it on and would actually merge on the
                        // Favorites page. Stopping at the first candidate risks a false
                        // negative (silently dropping a warning for a real merge).
                        let hasAttributedSibling = directory.chapters.contains { chapter in
                            guard chapter.tid != entry.threadID,
                                  let sibling = preImportMangaThreadFavoritesByTID[chapter.tid] else {
                                return false
                            }
                            return boardReaderSettings.isSmartComicModeEnabled(forumID: sibling.forumID)
                        }
                        if hasAttributedSibling {
                            await commit {
                                $0.warnings.append(.importedIntoExistingMangaDirectory(
                                    title: label,
                                    cleanBookName: directory.cleanBookName
                                ))
                            }
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error where Self.isRunFatal(error) {
                    throw error
                } catch {
                    let reason = Self.truncatedReason(from: error)
                    await commit { snapshot in
                        snapshot.failedCount += 1
                        snapshot.warnings.append(.importFailedItem(title: label, reason: reason))
                    }
                }
            }
            await commit { snapshot in
                for entry in skippedPathCounts {
                    snapshot.logEntries.append(.skippedSyncedItems(path: entry.path, count: entry.count))
                }
            }
            if let merged = try await saveDocumentIfDirty() {
                workingDocument = merged
            }

            // Phase 4: uploading
            let uploadCandidates = workingDocument.items.filter { item in
                item.locations.contains { $0.categoryID == snapshot.targetCategoryID }
                    && item.target.threadID.map { !remoteThreadIDs.contains($0) } == true
            }
            await commit { snapshot in
                snapshot.phase = .uploading
                snapshot.uploadTargetCount = uploadCandidates.count
                snapshot.logEntries.append(.uploading(targetCount: uploadCandidates.count))
            }
            if remoteEntries.isEmpty && !uploadCandidates.isEmpty {
                await commit { $0.warnings.append(.remoteFavoritesEmptyBeforeBulkUpload(count: uploadCandidates.count)) }
            }
            for (offset, item) in uploadCandidates.enumerated() {
                try Task.checkCancellation()
                guard let threadID = item.target.threadID else { continue }
                let label = Self.postLabel(threadID: threadID, title: item.resolvedDisplayTitle)
                do {
                    try await client.addFavorite(threadID)
                    await commit { snapshot in
                        snapshot.uploadedCount += 1
                        snapshot.logEntries.append(.uploadedItem(index: offset + 1, total: uploadCandidates.count, title: label))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error where Self.isRunFatal(error) {
                    throw error
                } catch {
                    let reason = Self.truncatedReason(from: error)
                    await commit { snapshot in
                        snapshot.failedCount += 1
                        snapshot.warnings.append(.uploadFailedItem(title: label, reason: reason))
                    }
                }
            }

            // Phase 5: reconciling
            if snapshot.uploadedCount > 0 {
                await commit { snapshot in
                    snapshot.phase = .reconciling
                    snapshot.logEntries.append(.reconciling)
                }
                do {
                    let allEntries = try await Self.fetchAllPages(client: client)
                    for entry in allEntries {
                        guard let target = workingDocument.items.first(where: { $0.target.threadID == entry.threadID })?.target else {
                            continue
                        }
                        apply { doc in
                            doc.updateRemoteMapping(
                                for: target,
                                yamiboFavoriteID: entry.remoteFavoriteID,
                                yamiboRemoteOrder: entry.remoteOrder
                            )
                        }
                    }
                    if let merged = try await saveDocumentIfDirty() {
                        workingDocument = merged
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let reason = Self.truncatedReason(from: error)
                    await commit { $0.warnings.append(.reconcileFailed(reason: reason)) }
                }
            }

            let importedCount = snapshot.importedCount
            let uploadedCount = snapshot.uploadedCount
            await commit { snapshot in
                snapshot.status = .completed
                snapshot.phase = .completed
                snapshot.finishedAt = .now
                snapshot.logEntries.append(.completed(importedCount: importedCount, uploadedCount: uploadedCount))
            }
        } catch let error where error.isTaskCancellation {
            do {
                _ = try await saveDocumentIfDirty()
            } catch let saveError {
                YamiboLog.sync.error("Failed to save queued favorite sync mutations after cancellation: \(saveError)")
            }
            let reason = interruptionReason() ?? .interrupted
            await commit { snapshot in
                snapshot.status = .interrupted
                snapshot.phase = .interrupted
                snapshot.finishedAt = .now
                snapshot.warnings.append(reason)
                snapshot.logEntries.append(.interrupted)
            }
        } catch {
            do {
                _ = try await saveDocumentIfDirty()
            } catch let saveError {
                YamiboLog.sync.error("Failed to save queued favorite sync mutations after run failure: \(saveError)")
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await commit { snapshot in
                snapshot.status = .failed
                snapshot.phase = .failed
                snapshot.finishedAt = .now
                snapshot.errorMessages.append(message)
                snapshot.logEntries.append(.failed)
            }
        }
        return snapshot
    }

    // MARK: - Helpers

    /// Shared retry loop for per-item network calls: cancellation always
    /// propagates immediately, run-fatal errors (auth loss, offline) abort
    /// the whole run, anything else retries and surfaces the last error.
    private static func withRetry<Value>(
        attempts: Int = 3,
        fallbackError: @autoclosure () -> any Error,
        _ operation: () async throws -> Value
    ) async throws -> Value {
        var lastError: (any Error)?
        for attempt in 1 ... max(1, attempts) {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error where isRunFatal(error) {
                throw error
            } catch {
                lastError = error
                if attempt < attempts {
                    try Task.checkCancellation()
                }
            }
        }
        throw lastError ?? fallbackError()
    }

    private static func probeWithRetry(
        _ entry: YamiboRemoteFavoriteEntry,
        client: FavoriteYamiboSyncClient,
        attempts: Int = 3
    ) async throws -> FavoriteThreadProbeResult {
        try await withRetry(
            attempts: attempts,
            fallbackError: YamiboError.parsingFailed(context: entry.threadID)
        ) {
            try await client.probe(entry)
        }
    }

    private static func fetchPageWithRetry(
        _ page: Int,
        client: FavoriteYamiboSyncClient,
        attempts: Int = 3
    ) async throws -> FavoriteYamiboRemotePage {
        try await withRetry(
            attempts: attempts,
            fallbackError: YamiboError.parsingFailed(context: "\(page)")
        ) {
            try await client.fetchPage(page)
        }
    }

    private static func fetchAllPages(client: FavoriteYamiboSyncClient) async throws -> [YamiboRemoteFavoriteEntry] {
        var entries: [YamiboRemoteFavoriteEntry] = []
        var seenThreadIDs: Set<String> = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let result = try await Self.fetchPageWithRetry(page, client: client)
            for entry in result.entries where seenThreadIDs.insert(entry.threadID).inserted {
                var ordered = entry
                ordered.remoteOrder = entries.count
                entries.append(ordered)
            }
            if page >= result.totalPages || result.entries.isEmpty {
                return entries
            }
            page += 1
        }
    }

    /// Errors that abort the whole run instead of failing one item, matching
    /// the Android reference (not logged in / site maintenance).
    private static func isRunFatal(_ error: any Error) -> Bool {
        // A missing add token was run-fatal before the favorites-domain split
        // moved it from `YamiboError` to `FavoriteActionError`: without a
        // formHash no subsequent add in this run can succeed either.
        if let favoriteError = error as? FavoriteActionError {
            switch favoriteError {
            case .missingFavoriteAddToken:
                return true
            default:
                return false
            }
        }
        guard let yamiboError = error as? YamiboError else { return false }
        switch yamiboError {
        case .notAuthenticated, .floodControl:
            return true
        default:
            return false
        }
    }

    private static func postLabel(threadID: String, title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "#\(threadID)" : "#\(threadID) \(trimmed)"
    }

    /// Primary organization path of an item, for the "already synced at" log.
    private static func pathDescription(for item: FavoriteItem, in document: FavoriteLibraryDocument) -> String {
        guard let location = item.locations.first else { return "" }
        let categoryName = document.categories.first { $0.id == location.categoryID }?.displayName ?? location.categoryID
        guard let collectionID = location.collectionID else { return categoryName }
        let collectionName = document.collections.first { $0.id == collectionID }?.name ?? collectionID
        return "\(categoryName)/\(collectionName)"
    }

    private static func truncatedReason(from error: any Error, maxCharacters: Int = 100) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let normalized = message
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard normalized.count > maxCharacters else { return normalized }
        return String(normalized.prefix(maxCharacters)) + "…"
    }
}

/// Shared cancellation detection for favorite background sessions.
public extension Error {
    var isTaskCancellation: Bool {
        if self is CancellationError {
            return true
        }
        if let urlError = self as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = self as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
