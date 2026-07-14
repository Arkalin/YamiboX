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

    public init(threadID: String, page: Int, pageCount: Int? = nil, anchorPostID: String? = nil) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "ThreadReadingPosition requires a Yamibo thread tid")
        self.threadID = normalizedThreadID
        self.page = max(1, page)
        self.pageCount = pageCount.map { max(1, $0) }
        self.anchorPostID = anchorPostID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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
}

public actor ProgressSyncModule {
    private let adapter: any ProgressSyncAdapter
    private let debounceNanoseconds: UInt64
    private var pendingTask: Task<Void, Never>?
    private var lastQueuedPosition: ProgressSyncPosition?
    private var lastSyncedPosition: ProgressSyncPosition?
    private var needsRetry = false

    public init(adapter: any ProgressSyncAdapter, debounceNanoseconds: UInt64 = 350_000_000) {
        self.adapter = adapter
        self.debounceNanoseconds = debounceNanoseconds
    }

    public func queue(_ position: ProgressSyncPosition) {
        guard position != lastQueuedPosition || needsRetry else { return }

        lastQueuedPosition = position
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
            lastQueuedPosition = latestPosition
        }

        guard let position = lastQueuedPosition else { return }
        try await saveIfNeeded(position)
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
        try await saveIfNeeded(position)
    }

    private func saveIfNeeded(_ position: ProgressSyncPosition) async throws {
        guard position != lastSyncedPosition || needsRetry else { return }

        do {
            switch position {
            case let .novel(position):
                try await adapter.saveNovelReadingPosition(position)
            case let .manga(position):
                try await adapter.saveMangaReadingPosition(position)
            case let .thread(position):
                try await adapter.saveThreadReadingPosition(position)
            }
            lastSyncedPosition = position
            lastQueuedPosition = position
            needsRetry = false
        } catch {
            needsRetry = true
            YamiboLog.sync.error("ProgressSyncModule failed to persist queued reading position; will retry on next queued update: \(error)")
            throw error
        }
    }
}

/// Persists debounced reading positions and, when a `BrowsingHistoryStore`
/// is attached, piggybacks a position refresh onto the matching history row
/// (browsing-history decision #5's "翻页更新" cadence — the same debounce
/// that paces progress writes paces history updates, no extra scheduling).
///
/// The history refresh is UPDATE-only and runs after the progress write; if
/// the surrounding Task is cancelled between the two, the history row just
/// keeps a slightly stale position until the next save — display metadata
/// only, never resume state (decision #4). Preview sessions never reach this
/// adapter at all: both readers gate their queue/flush calls on
/// `context.isPreview` before anything is enqueued.
public struct FavoriteLibraryProgressSyncAdapter: ProgressSyncAdapter {
    private let readingProgressStore: ReadingProgressStore
    private let browsingHistoryStore: BrowsingHistoryStore?

    public init(
        readingProgressStore: ReadingProgressStore,
        browsingHistoryStore: BrowsingHistoryStore? = nil
    ) {
        self.readingProgressStore = readingProgressStore
        self.browsingHistoryStore = browsingHistoryStore
    }

    public func saveNovelReadingPosition(_ position: NovelReadingPosition) async throws {
        _ = try await readingProgressStore.saveNovel(position)
        await browsingHistoryStore?.updatePosition(
            targetID: FavoriteContentTarget.novelThread(threadID: position.threadID).id,
            chapterTitle: position.chapterTitle
        )
    }

    public func saveMangaReadingPosition(_ position: MangaProgressReadingPosition) async throws {
        _ = try await readingProgressStore.saveManga(position)
        guard let browsingHistoryStore else { return }
        if position.isSmartModeEnabled {
            // Mirrors `ReadingProgressStore.saveManga`'s mode-on identity
            // derivation so the history row id lines up with the row the
            // manga reader recorded at open (browsing-history decision #2).
            let cleanBookName = position.directoryName ?? position.chapterTitle
            let target = FavoriteContentTarget(
                mangaID: position.mangaID ?? cleanBookName,
                mangaCleanBookName: cleanBookName
            )
            await browsingHistoryStore.updatePosition(
                targetID: target.id,
                pageIndex: position.pageIndex,
                pageCount: position.pageCount,
                chapterTitle: position.chapterTitle,
                chapterThreadID: position.chapterThreadID
            )
        } else {
            await browsingHistoryStore.updatePosition(
                targetID: FavoriteContentTarget.mangaThread(threadID: position.chapterThreadID).id,
                pageIndex: position.pageIndex,
                pageCount: position.pageCount,
                chapterTitle: position.chapterTitle
            )
        }
    }

    public func saveThreadReadingPosition(_ position: ThreadReadingPosition) async throws {
        _ = try await readingProgressStore.saveNormalThread(
            threadID: position.threadID,
            page: position.page,
            pageCount: position.pageCount,
            anchorPostID: position.anchorPostID
        )
        await browsingHistoryStore?.updatePosition(
            targetID: FavoriteContentTarget.normalThread(threadID: position.threadID).id,
            pageIndex: position.page,
            pageCount: position.pageCount
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
