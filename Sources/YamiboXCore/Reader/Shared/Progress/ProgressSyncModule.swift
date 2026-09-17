import Foundation

public struct NovelReadingPosition: Hashable, Sendable {
    public var threadID: String
    public var view: Int
    public var maxView: Int?
    public var chapterTitle: String?
    public var authorID: String?
    public var resumePoint: NovelResumePoint?
    public var documentSurfaceProgressPercent: Int?

    public init(
        threadID: String,
        view: Int,
        maxView: Int? = nil,
        chapterTitle: String? = nil,
        authorID: String? = nil,
        resumePoint: NovelResumePoint? = nil,
        documentSurfaceProgressPercent: Int? = nil
    ) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "NovelReadingPosition requires a Yamibo thread tid")
        self.threadID = normalizedThreadID
        self.view = max(1, view)
        self.maxView = maxView.map { max(self.view, $0) }
        self.chapterTitle = resumePoint?.chapterTitle ?? chapterTitle
        self.authorID = resumePoint?.authorID ?? authorID
        self.resumePoint = resumePoint
        self.documentSurfaceProgressPercent = documentSurfaceProgressPercent.map { min(max($0, 0), 100) }
    }
}

public struct MangaProgressReadingPosition: Hashable, Sendable {
    public var threadID: String
    public var chapterThreadID: String
    public var chapterView: Int
    public var chapterTitle: String
    public var pageIndex: Int
    public var pageCount: Int?
    public var mangaID: String?
    public var directoryName: String?
    /// Whether Smart Comic Mode is on for this chapter's board — threaded
    /// straight from `MangaLaunchContext.isSmartModeEnabled` (the reader
    /// never re-derives it). `ReadingProgressStore.saveManga` branches on
    /// this field (not on `directoryName != nil`) to decide whether to also
    /// upsert the directory-level `.mangaTitle` record, since a mode-off
    /// synthesized single-chapter pseudo-directory also produces a non-nil
    /// `directoryName` (smart-comic-mode design decision #15; see the Phase B
    /// warning in the design doc). Defaults to `true` to match
    /// `MangaLaunchContext`'s own default for pre-Phase-C call sites.
    public var isSmartModeEnabled: Bool

    public init(
        threadID: String? = nil,
        chapterThreadID: String,
        chapterView: Int = 1,
        chapterTitle: String,
        pageIndex: Int,
        pageCount: Int? = nil,
        mangaID: String? = nil,
        directoryName: String? = nil,
        isSmartModeEnabled: Bool = true
    ) {
        let normalizedChapterThreadID = chapterThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedChapterThreadID.isEmpty, "MangaProgressReadingPosition requires a Yamibo chapter tid")
        self.chapterThreadID = normalizedChapterThreadID
        self.threadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? normalizedChapterThreadID
        self.chapterView = max(1, chapterView)
        self.chapterTitle = chapterTitle
        self.pageIndex = max(0, pageIndex)
        self.pageCount = pageCount.map { max(1, $0) }
        self.mangaID = mangaID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.directoryName = directoryName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.isSmartModeEnabled = isSmartModeEnabled
    }
}

/// Normal-thread reading position (browsing-history decisions #6/#7): the
/// current page plus the topmost visible post's id as the floor-level anchor.
public struct ThreadReadingPosition: Hashable, Sendable {
    public var threadID: String
    public var page: Int
    public var pageCount: Int?
    public var anchorPostID: String?
    public var recordsBrowsingHistory: Bool

    public init(threadID: String, page: Int, pageCount: Int? = nil, anchorPostID: String? = nil, recordsBrowsingHistory: Bool = true) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "ThreadReadingPosition requires a Yamibo thread tid")
        self.threadID = normalizedThreadID
        self.page = max(1, page)
        self.pageCount = pageCount.map { max(1, $0) }
        self.anchorPostID = anchorPostID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.recordsBrowsingHistory = recordsBrowsingHistory
    }
}

public enum ProgressSyncPosition: Hashable, Sendable {
    case novel(NovelReadingPosition)
    case manga(MangaProgressReadingPosition)
    case thread(ThreadReadingPosition)
}

public protocol ProgressSyncAdapter: Sendable {
    func saveNovelReadingPosition(_ position: NovelReadingPosition) async throws
    func saveMangaReadingPosition(_ position: MangaProgressReadingPosition) async throws
    func saveThreadReadingPosition(_ position: ThreadReadingPosition) async throws
    func saveReadingPosition(_ position: ProgressSyncPosition, activityDate: Date) async throws
}

public extension ProgressSyncAdapter {
    func saveReadingPosition(_ position: ProgressSyncPosition, activityDate: Date) async throws {
        switch position {
        case let .novel(position): try await saveNovelReadingPosition(position)
        case let .manga(position): try await saveMangaReadingPosition(position)
        case let .thread(position): try await saveThreadReadingPosition(position)
        }
    }
}

public actor ProgressSyncModule {
    private let adapter: any ProgressSyncAdapter
    private let debounceNanoseconds: UInt64
    private var pendingTask: Task<Void, Never>?
    private var lastQueuedPosition: ProgressSyncPosition?
    private var lastQueuedActivityDate = Date.distantPast
    private var lastSyncedPosition: ProgressSyncPosition?
    private var lastSyncedActivityDate = Date.distantPast
    private var needsRetry = false

    public init(adapter: any ProgressSyncAdapter, debounceNanoseconds: UInt64 = 350_000_000) {
        self.adapter = adapter
        self.debounceNanoseconds = debounceNanoseconds
    }

    public func queue(_ position: ProgressSyncPosition) {
        guard position != lastQueuedPosition || needsRetry else { return }

        lastQueuedPosition = position
        lastQueuedActivityDate = .now
        pendingTask?.cancel()
        pendingTask = Task { [weak self, debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            try? await self?.flushQueuedPosition()
        }
    }

    public func flush(_ latestPosition: ProgressSyncPosition? = nil) async throws {
        pendingTask?.cancel()
        pendingTask = nil

        if let latestPosition {
            if latestPosition != lastQueuedPosition { lastQueuedActivityDate = .now }
            lastQueuedPosition = latestPosition
        }

        guard let position = lastQueuedPosition else { return }
        try await saveIfNeeded(position, activityDate: lastQueuedActivityDate)
    }

    public func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        lastQueuedPosition = nil
        needsRetry = false
    }

    private func flushQueuedPosition() async throws {
        pendingTask = nil
        guard let position = lastQueuedPosition else { return }
        try await saveIfNeeded(position, activityDate: lastQueuedActivityDate)
    }

    private func saveIfNeeded(_ position: ProgressSyncPosition, activityDate: Date) async throws {
        guard activityDate >= lastSyncedActivityDate else { return }
        guard position != lastSyncedPosition || needsRetry else { return }

        do {
            try await adapter.saveReadingPosition(position, activityDate: activityDate)
            if activityDate >= lastSyncedActivityDate {
                lastSyncedPosition = position
                lastSyncedActivityDate = activityDate
                needsRetry = false
            }
        } catch {
            if activityDate >= lastSyncedActivityDate { needsRetry = true }
            YamiboLog.sync.error("ProgressSyncModule failed to persist queued reading position; will retry on next queued update: \(error)")
            throw error
        }
    }
}

/// Resume positions remain mode-specific; timeline activity is routed through
/// the board-configured canonical identity. Preview sessions never enqueue.
public struct FavoriteLibraryProgressSyncAdapter: ProgressSyncAdapter {
    private let readingProgressStore: ReadingProgressStore
    private let browsingHistoryWorkflow: BrowsingHistoryWorkflow
    private let settingsStore: SettingsStore?

    public init(
        readingProgressStore: ReadingProgressStore,
        browsingHistoryWorkflow: BrowsingHistoryWorkflow,
        settingsStore: SettingsStore?
    ) {
        self.readingProgressStore = readingProgressStore
        self.browsingHistoryWorkflow = browsingHistoryWorkflow
        self.settingsStore = settingsStore
    }

    public func saveNovelReadingPosition(_ position: NovelReadingPosition) async throws {
        try await saveReadingPosition(.novel(position), activityDate: .now)
    }

    public func saveMangaReadingPosition(_ position: MangaProgressReadingPosition) async throws {
        try await saveReadingPosition(.manga(position), activityDate: .now)
    }

    public func saveThreadReadingPosition(_ position: ThreadReadingPosition) async throws {
        try await saveReadingPosition(.thread(position), activityDate: .now)
    }

    public func saveReadingPosition(_ position: ProgressSyncPosition, activityDate: Date) async throws {
        switch position {
        case let .novel(position):
            _ = try await readingProgressStore.saveNovel(position, date: activityDate, discardingOlderUpdate: true)
            await browsingHistoryWorkflow.refreshPosition(threadID: position.threadID, reader: .novel, date: activityDate)
        case let .manga(position):
            _ = try await readingProgressStore.saveManga(position, date: activityDate, discardingOlderUpdate: true)
            await browsingHistoryWorkflow.refreshPosition(threadID: position.chapterThreadID, reader: .manga, date: activityDate)
        case let .thread(position):
            // Read at write time, not enqueue time: a pending debounce or
            // exit flush must honor a setting changed while the reader is open.
            if await settingsStore?.load().readingProgress.savesNormalThreadProgress == true {
                _ = try await readingProgressStore.saveNormalThread(
                    threadID: position.threadID, page: position.page,
                    pageCount: position.pageCount, anchorPostID: position.anchorPostID,
                    date: activityDate, discardingOlderUpdate: true
                )
            }
            // Visits and activity remain independent of resume persistence.
            if position.recordsBrowsingHistory {
                await browsingHistoryWorkflow.refreshPosition(threadID: position.threadID, reader: .normal, date: activityDate)
            }
        }
    }
}
