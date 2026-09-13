import Foundation

/// Serializes activity and configuration changes across all reader surfaces.
/// Database compare-and-swap also protects against deletes outside this actor.
public actor BrowsingHistoryWorkflow {
    private let store: BrowsingHistoryStore
    private let settingsStore: SettingsStore
    private let progressStore: ReadingProgressStore
    private let directoryStore: any MangaDirectoryPersisting
    private let resolveForumIDs: @Sendable ([String]) async -> [String: String]
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        store: BrowsingHistoryStore,
        settingsStore: SettingsStore,
        progressStore: ReadingProgressStore,
        directoryStore: any MangaDirectoryPersisting,
        resolveForumIDs: @escaping @Sendable ([String]) async -> [String: String] = { _ in [:] }
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.progressStore = progressStore
        self.directoryStore = directoryStore
        self.resolveForumIDs = resolveForumIDs
    }

    public func recordVisit(_ visit: BrowsingHistoryVisit) async throws {
        await acquire()
        defer { release() }
        _ = try await reconcile(visit: visit, mayCreate: true)
    }

    public func updateActivity(_ visit: BrowsingHistoryVisit) async throws {
        await acquire()
        defer { release() }
        _ = try await reconcile(visit: visit, mayCreate: false)
    }

    /// Progress saves have no authority to create a timeline row. Source
    /// metadata comes from the existing visit; all position fields come from
    /// the canonical target's independent progress record.
    public func refreshPosition(threadID: String, reader: BrowsingHistoryCategory, title: String = "", date: Date = .now) async {
        do {
            try await updateActivity(BrowsingHistoryVisit(threadID: threadID, title: title, reader: reader, date: date))
        } catch {
            YamiboLog.persistence.warning("Failed to refresh canonical browsing history: \(error)")
        }
    }

    public func snapshot() async throws -> BrowsingHistorySnapshot {
        await acquire()
        defer { release() }
        return try await reconcile()
    }

    public func delete(_ entry: BrowsingHistoryEntry) async throws {
        await acquire()
        defer { release() }
        let snapshot = try await reconcile()
        if let current = snapshot.entries.first(where: {
            $0.id == entry.id || (entry.lastVisitedThreadID != nil && $0.lastVisitedThreadID == entry.lastVisitedThreadID)
        }) {
            try await store.delete(id: current.id)
        } else if let tid = entry.lastVisitedThreadID,
                  let directory = try await directoryStore.directory(containingTID: tid) {
            let target = FavoriteContentTarget(mangaID: directory.favoriteIdentity, mangaCleanBookName: directory.cleanBookName)
            if snapshot.entries.contains(where: { $0.target == target }) {
                try await store.delete(id: target.id)
            }
        }
    }

    /// Owned by the application runtime, independently of the visible reader.
    public func observeChanges() async {
        let settingsChanges = settingsStore.changes()
        let directoryChanges = directoryStore.changes()
        do { _ = try await snapshot() } catch {
            if !LoadDiagnosticError.isCancellation(error) {
                YamiboLog.persistence.warning("Failed to initialize canonical browsing history: \(error)")
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for stream in [settingsChanges, directoryChanges] {
                group.addTask { [weak self] in
                    for await _ in stream {
                        guard !Task.isCancelled else { return }
                        do { _ = try await self?.snapshot() } catch {
                            if !LoadDiagnosticError.isCancellation(error) {
                                YamiboLog.persistence.warning("Failed to normalize browsing history: \(error)")
                            }
                        }
                    }
                }
            }
        }
    }

    private func acquire() async {
        if !isBusy { isBusy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { isBusy = false } else { waiters.removeFirst().resume() }
    }

    private func reconcile(visit: BrowsingHistoryVisit? = nil, mayCreate: Bool = false) async throws -> BrowsingHistorySnapshot {
        var mayCreate = mayCreate
        var pendingVisit = visit
        while true {
            try Task.checkCancellation()
            let original = try await store.snapshotEntries()
            let settings = await settingsStore.load().boardReader
            let tids = Array(Set(original.compactMap(\.lastVisitedThreadID) + [pendingVisit?.threadID].compactMap { $0 }))
            let storedDirectories = try await directoryStore.directories(containingTIDs: tids)
            var directories = storedDirectories
            if let directory = pendingVisit?.directory,
               let tid = pendingVisit?.threadID,
               directory.chapters.contains(where: { $0.tid == tid }), directories[tid] == nil {
                for chapter in directory.chapters where directories[chapter.tid] == nil {
                    directories[chapter.tid] = directory
                }
            }
            let unknownTIDs = original.filter { $0.forumID == nil }.compactMap(\.lastVisitedThreadID)
                + (pendingVisit?.forumID == nil ? [pendingVisit?.threadID].compactMap { $0 } : [])
            let forumIDs = await resolveForumIDs(Array(Set(unknownTIDs)))
            let progress = Dictionary(uniqueKeysWithValues: await progressStore.loadAll().map { ($0.id, $0) })
            var normalized = original.map {
                Self.canonical($0, settings: settings, directories: directories, forumIDs: forumIDs, progress: progress)
            }
            var visitTargetID: String?
            if let visit = pendingVisit, !visit.threadID.isEmpty {
                let directoryTarget = directories[visit.threadID].map {
                    FavoriteContentTarget(mangaID: $0.favoriteIdentity, mangaCleanBookName: $0.cleanBookName)
                }
                let ordered = normalized.sorted(by: BrowsingHistoryStore.newestFirst)
                let direct = ordered.first { $0.target.threadID == visit.threadID || $0.lastVisitedThreadID == visit.threadID }
                let sourceForumID = visit.forumID ?? direct?.forumID ?? forumIDs[visit.threadID]
                let mayJoinDirectory = sourceForumID == nil || settings.isSmartComicModeEnabled(forumID: sourceForumID)
                let existing = direct ?? (mayJoinDirectory ? ordered.first { directoryTarget != nil && $0.target == directoryTarget } : nil)
                if mayCreate || existing != nil {
                    let fallbackTarget: FavoriteContentTarget
                    switch visit.reader {
                    case .normal: fallbackTarget = .normalThread(threadID: visit.threadID)
                    case .novel: fallbackTarget = .novelThread(threadID: visit.threadID)
                    case .manga: fallbackTarget = .mangaThread(threadID: visit.threadID)
                    }
                    if visit.date >= (existing?.lastVisitTime ?? .distantPast) {
                        let title = visit.title.browsingHistoryTrimmedNonEmpty
                            ?? (existing?.lastVisitedThreadID == visit.threadID ? existing?.lastVisitedThreadTitle : nil)
                            ?? directories[visit.threadID]?.chapters.first(where: { $0.tid == visit.threadID })?.rawTitle
                            ?? existing?.lastVisitedThreadTitle ?? visit.threadID
                        let incoming = BrowsingHistoryEntry(
                            target: existing?.target ?? fallbackTarget,
                            title: existing?.target.kind == .mangaTitle ? existing?.title ?? title : title,
                            forumID: visit.forumID ?? existing?.forumID ?? forumIDs[visit.threadID],
                            authorID: visit.authorID ?? existing?.authorID,
                            lastVisitTime: visit.date,
                            lastVisitedThreadID: visit.threadID,
                            lastVisitedThreadTitle: title
                        )
                        if let existing { normalized.removeAll { $0.id == existing.id } }
                        let canonical = Self.canonical(incoming, settings: settings, directories: directories, forumIDs: forumIDs, progress: progress)
                        guard try await store.canRecord(visit, targetID: canonical.id) else {
                            pendingVisit = nil
                            mayCreate = false
                            continue
                        }
                        visitTargetID = canonical.id
                        normalized.append(canonical)
                    }
                    // If a concurrent delete invalidates this snapshot, an
                    // existing visit must not be recreated by the retry.
                    if existing != nil { mayCreate = false }
                }
            }
            var byID: [String: BrowsingHistoryEntry] = [:]
            for entry in normalized.sorted(by: BrowsingHistoryStore.newestFirst) where byID[entry.id] == nil {
                byID[entry.id] = entry
            }
            let entries = Array(byID.values).sorted(by: BrowsingHistoryStore.newestFirst)
            guard settings == (await settingsStore.load()).boardReader,
                  storedDirectories == (try await directoryStore.directories(containingTIDs: tids)) else { continue }
            guard try await store.applyCanonicalEntries(entries, replacing: original, visit: pendingVisit, visitTargetID: visitTargetID) else { continue }
            // A settings save can race the database await. Finish normalizing
            // before exposing a snapshot; do not replay the activity timestamp.
            pendingVisit = nil
            mayCreate = false
            guard settings == (await settingsStore.load()).boardReader,
                  storedDirectories == (try await directoryStore.directories(containingTIDs: tids)) else { continue }
            return BrowsingHistorySnapshot(entries: Array(entries.prefix(BrowsingHistoryStore.maxEntryCount)), boardReader: settings)
        }
    }

    private static func canonical(
        _ entry: BrowsingHistoryEntry, settings: BoardReaderSettings,
        directories: [String: MangaDirectory], forumIDs: [String: String],
        progress: [String: ReadingProgressRecord]
    ) -> BrowsingHistoryEntry {
        guard let tid = entry.lastVisitedThreadID else { return entry }
        var result = entry
        result.forumID = entry.forumID ?? forumIDs[tid]
        let mode: BrowsingHistoryCategory
        if result.forumID == nil { mode = entry.category } else {
            switch settings.entry(forumID: result.forumID)?.mode {
            case .novel: mode = .novel
            case .manga: mode = .manga
            case .normal, nil: mode = .normal
            }
        }
        result.title = entry.lastVisitedThreadTitle ?? entry.title
        switch mode {
        case .normal: result.target = .normalThread(threadID: tid)
        case .novel: result.target = .novelThread(threadID: tid)
        case .manga:
            if settings.isSmartComicModeEnabled(forumID: result.forumID), let directory = directories[tid] {
                result.target = FavoriteContentTarget(mangaID: directory.favoriteIdentity, mangaCleanBookName: directory.cleanBookName)
                result.title = directory.cleanBookName
            } else if entry.target.kind == .mangaTitle,
                      result.forumID == nil || settings.isSmartComicModeEnabled(forumID: result.forumID) {
                result.target = entry.target
                result.title = entry.title
            } else {
                result.target = .mangaThread(threadID: tid)
            }
        }
        result.pageIndex = nil
        result.pageCount = nil
        result.chapterTitle = nil
        result.chapterThreadID = result.target.kind == .mangaTitle ? tid : nil
        let position = progress[result.id]
        switch mode {
        case .normal:
            result.pageIndex = position?.thread?.lastPage
            result.pageCount = position?.thread?.pageCount
        case .novel:
            result.chapterTitle = position?.novel?.novelResumePoint?.chapterTitle ?? position?.novel?.lastChapter
            result.authorID = position?.novel?.authorID ?? entry.authorID
        case .manga:
            result.pageIndex = position?.manga?.mangaPageIndex
            result.pageCount = position?.manga?.mangaPageCount
            result.chapterTitle = position?.manga?.lastChapter
            if result.target.kind == .mangaTitle {
                result.chapterThreadID = position?.manga?.chapterThreadID ?? tid
            }
        }
        return result
    }
}
