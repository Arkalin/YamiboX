import Foundation

public struct YamiboRemoteFavoriteEntry: Hashable, Sendable {
    public var remoteFavoriteID: String?
    public var threadID: String
    public var title: String?
    public var remoteOrder: Int

    public init(remoteFavoriteID: String? = nil, threadID: String, title: String? = nil, remoteOrder: Int = 0) {
        self.remoteFavoriteID = FavoriteRemoteIdentity.normalizedID(remoteFavoriteID)
        self.threadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title
        self.remoteOrder = remoteOrder
    }
}

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

public struct FavoriteYamiboSyncClient: Sendable {
    public var fetchPage: @Sendable (_ page: Int) async throws -> FavoriteYamiboRemotePage
    public var probe: @Sendable (_ entry: YamiboRemoteFavoriteEntry) async throws -> FavoriteThreadProbeResult
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

public struct FavoriteYamiboSyncEngine: Sendable {
    private let libraryStore: FavoriteLibraryStore
    private let client: FavoriteYamiboSyncClient
    private let retryPolicy: FavoriteRemoteSyncRetryPolicy
    private let mangaDirectoryStore: (any MangaDirectoryBatchReading)?
    private let settingsStore: SettingsStore?

    public init(
        libraryStore: FavoriteLibraryStore,
        client: FavoriteYamiboSyncClient,
        mangaDirectoryStore: (any MangaDirectoryBatchReading)? = nil,
        settingsStore: SettingsStore? = nil
    ) {
        self.init(
            libraryStore: libraryStore, client: client,
            mangaDirectoryStore: mangaDirectoryStore, settingsStore: settingsStore,
            retryPolicy: FavoriteRemoteSyncRetryPolicy()
        )
    }

    init(
        libraryStore: FavoriteLibraryStore,
        client: FavoriteYamiboSyncClient,
        mangaDirectoryStore: (any MangaDirectoryBatchReading)? = nil,
        settingsStore: SettingsStore? = nil,
        retryPolicy: FavoriteRemoteSyncRetryPolicy
    ) {
        self.libraryStore = libraryStore
        self.client = client
        self.retryPolicy = retryPolicy
        self.mangaDirectoryStore = mangaDirectoryStore
        self.settingsStore = settingsStore
    }

    public func run(
        snapshot initial: FavoriteRemoteSyncSnapshot,
        interruptionReason: @escaping @Sendable () -> FavoriteRemoteSyncWarning? = { nil },
        onFailure: @escaping @Sendable (LoadFailureDetails) async -> Void = { _ in },
        persistIncrementally: (@Sendable (FavoriteRemoteSyncSnapshot, FavoriteRemoteSyncEntryCounts) async -> Void)? = nil,
        persist: @escaping @Sendable (FavoriteRemoteSyncSnapshot) async -> Void
    ) async -> FavoriteRemoteSyncSnapshot {
        var snapshot = initial
        var pendingOperations: [@Sendable (inout FavoriteLibraryDocument, inout FavoriteLibraryItemIndex) -> Void] = []

        func commit(_ mutate: (inout FavoriteRemoteSyncSnapshot) -> Void) async {
            let previousCounts = FavoriteRemoteSyncEntryCounts(snapshot)
            mutate(&snapshot)
            snapshot.updatedAt = .now
            if let persistIncrementally {
                await persistIncrementally(snapshot, previousCounts)
            } else {
                await persist(snapshot)
            }
        }

        func record(_ operation: @escaping @Sendable (inout FavoriteLibraryDocument, inout FavoriteLibraryItemIndex) -> Void) {
            pendingOperations.append(operation)
        }

        func saveDocumentIfDirty() async throws -> FavoriteLibraryDocument? {
            guard !pendingOperations.isEmpty else { return nil }
            let operations = pendingOperations
            let libraryStore = libraryStore
            let merged = try await Task { () -> FavoriteLibraryDocument in
                try await libraryStore.update { fresh in
                    var freshIndex = FavoriteLibraryItemIndex(fresh)
                    for operation in operations {
                        operation(&fresh, &freshIndex)
                    }
                    return fresh
                }
            }.value
            pendingOperations.removeAll()
            return merged
        }

        do {
            try Task.checkCancellation()
            await commit { $0.phase = .preparing }
            var workingDocument = try await libraryStore.load()
            var workingIndex = FavoriteLibraryItemIndex(workingDocument)

            func apply(_ operation: @escaping @Sendable (inout FavoriteLibraryDocument, inout FavoriteLibraryItemIndex) -> Void) {
                operation(&workingDocument, &workingIndex)
                record(operation)
            }
            guard workingDocument.categories.contains(where: { $0.id == snapshot.targetCategoryID }) else {
                throw YamiboPersistenceError(context: L10n.string("favorites.sync.error.category_missing"))
            }
            let targetLocation = FavoriteLocation.category(snapshot.targetCategoryID)

            await commit { $0.phase = .fetching }
            var remoteEntries: [YamiboRemoteFavoriteEntry] = []
            var remoteThreadIDs: Set<String> = []
            var reportedPageCountChange = false
            var page = 1
            var totalPages: Int?
            while true {
                try Task.checkCancellation()
                let result = try await retryPolicy.run { try await client.fetchPage(page) }
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

            await commit { $0.phase = .importing }
            var skippedPathCounts: [(path: String, count: Int)] = []
            let importTotal = remoteEntries.count

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
                } catch where Task.isCancelled || LoadDiagnosticError.isCancellation(error) {
                    throw error
                } catch {
                    YamiboLog.sync.warning("Failed to batch-resolve manga directories for sync attribution detection; this run will skip attribution warnings: \(error.localizedDescription)")
                }
            }
            let boardReaderSettings = await settingsStore?.load().boardReader ?? BoardReaderSettings()

            for (offset, entry) in remoteEntries.enumerated() {
                try Task.checkCancellation()
                let label = Self.postLabel(threadID: entry.threadID, title: entry.title)
                await commit { $0.logEntries.append(.importingItem(index: offset + 1, total: importTotal, title: label)) }

                if let position = workingIndex.firstPositionByThreadID[entry.threadID] {
                    let existing = workingDocument.items[position]
                    let alreadyMapped = FavoriteRemoteIdentity.normalizedID(existing.remoteMapping?.yamiboFavoriteID) != nil
                    let existingTarget = existing.target
                    if !alreadyMapped {
                        apply { doc, index in
                            guard let position = index.firstPositionByTargetID[existingTarget.id] else { return }
                            doc.addLocation(targetLocation, at: position)
                        }
                    }
                    apply { doc, index in
                        guard let position = index.firstPositionByTargetID[existingTarget.id] else { return }
                        doc.updateRemoteMapping(
                            at: position,
                            yamiboFavoriteID: FavoriteRemoteIdentity.normalizedID(entry.remoteFavoriteID),
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
                    let probeResult = try await retryPolicy.run { try await client.probe(entry) }
                    guard !probeResult.sourceMetadataFetchFailed else {
                        throw YamiboError.parsingFailed(context: entry.threadID)
                    }
                    let mapping = FavoriteRemoteMapping(
                        yamiboFavoriteID: FavoriteRemoteIdentity.normalizedID(entry.remoteFavoriteID),
                        yamiboRemoteOrder: entry.remoteOrder,
                        lastSeenAt: .now
                    )
                    let importedItem: FavoriteItem
                    do {
                        defer { workingIndex = FavoriteLibraryItemIndex(workingDocument) }
                        importedItem = try workingDocument.importThreadFavorite(
                            probeResult: probeResult,
                            location: targetLocation,
                            remoteMapping: mapping
                        )
                    }
                    record { doc, index in
                        defer { index = FavoriteLibraryItemIndex(doc) }
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
                    if importedItem.target.kind == .mangaThread,
                       let directory = candidateDirectoriesByTID[entry.threadID],
                       boardReaderSettings.isSmartComicModeEnabled(forumID: importedItem.forumID) {
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
                } catch where Task.isCancelled || LoadDiagnosticError.isCancellation(error) {
                    throw error
                } catch let error where FavoriteRemoteSyncRetryPolicy.isRunFatal(error) {
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
                workingIndex = FavoriteLibraryItemIndex(workingDocument)
            }

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
                } catch where Task.isCancelled || LoadDiagnosticError.isCancellation(error) {
                    throw error
                } catch let error where FavoriteRemoteSyncRetryPolicy.isRunFatal(error) {
                    throw error
                } catch {
                    let reason = Self.truncatedReason(from: error)
                    await commit { snapshot in
                        snapshot.failedCount += 1
                        snapshot.warnings.append(.uploadFailedItem(title: label, reason: reason))
                    }
                }
            }

            if snapshot.uploadedCount > 0 {
                await commit { snapshot in
                    snapshot.phase = .reconciling
                    snapshot.logEntries.append(.reconciling)
                }
                do {
                    let allEntries = try await fetchAllPages()
                    for entry in allEntries {
                        guard let position = workingIndex.firstPositionByThreadID[entry.threadID] else {
                            continue
                        }
                        let target = workingDocument.items[position].target
                        apply { doc, index in
                            guard let position = index.firstPositionByTargetID[target.id] else { return }
                            doc.updateRemoteMapping(
                                at: position,
                                yamiboFavoriteID: FavoriteRemoteIdentity.normalizedID(entry.remoteFavoriteID),
                                yamiboRemoteOrder: entry.remoteOrder
                            )
                        }
                    }
                    if let merged = try await saveDocumentIfDirty() {
                        workingDocument = merged
                        workingIndex = FavoriteLibraryItemIndex(workingDocument)
                    }
                } catch where Task.isCancelled || LoadDiagnosticError.isCancellation(error) {
                    throw error
                } catch let error where FavoriteRemoteSyncRetryPolicy.isRunFatal(error) {
                    throw error
                } catch {
                    let reason = Self.truncatedReason(from: error)
                    await commit { $0.warnings.append(.reconcileFailed(reason: reason)) }
                }
            }

            try Task.checkCancellation()
            let importedCount = snapshot.importedCount
            let uploadedCount = snapshot.uploadedCount
            await commit { snapshot in
                snapshot.status = .completed
                snapshot.phase = .completed
                snapshot.finishedAt = .now
                snapshot.logEntries.append(.completed(importedCount: importedCount, uploadedCount: uploadedCount))
            }
        } catch where Task.isCancelled || LoadDiagnosticError.isCancellation(error) {
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
            await onFailure(LoadFailureDetails(error: error))
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

    private func fetchAllPages() async throws -> [YamiboRemoteFavoriteEntry] {
        var entries: [YamiboRemoteFavoriteEntry] = []
        var seenThreadIDs: Set<String> = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let result = try await retryPolicy.run { try await client.fetchPage(page) }
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

    private static func postLabel(threadID: String, title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "#\(threadID)" : "#\(threadID) \(trimmed)"
    }

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
