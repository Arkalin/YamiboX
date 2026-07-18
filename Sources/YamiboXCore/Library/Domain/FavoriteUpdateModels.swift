import Foundation

/// Descriptive label mirroring the tracked target's kind.
/// `.normalThread`/`.novelThread`/`.mangaThread` map 1:1 from
/// `FavoriteItemTargetKind` via `init(kind:)` so a favorite is never
/// mislabeled. `.mangaThread` is still unreached at runtime:
/// per-favorite update checking's candidate filter
/// (`FavoriteUpdateMonitor.candidates(in:)`) excludes `.mangaThread`
/// favorites entirely — the case is kept only for kind-parity so
/// `init(kind:)` stays a total mapping.
///
/// `.mangaDirectory` is a DIFFERENT thing, added for smart-manga chapter
/// checking: it labels a *directory-level* tracked target/event, which has
/// no single favorite kind to map from (multiple `.mangaThread` favorites
/// that resolve to the same `MangaDirectory` collapse into one). It is only
/// ever constructed directly (never via `init(kind:)`) and paired with
/// `FavoriteUpdateTargetKey.mangaDirectory`.
public enum FavoriteUpdateTargetMode: String, Codable, Hashable, Sendable {
    case normalThread
    case novelThread
    case mangaThread
    case mangaDirectory

    public init(kind: FavoriteItemTargetKind) {
        switch kind {
        case .normalThread:
            self = .normalThread
        case .novelThread:
            self = .novelThread
        case .mangaThread:
            self = .mangaThread
        }
    }
}

/// Identifies what a tracked target / event is about. Thread-mode checking
/// (`.normalThread`/`.novelThread` favorites) keys off the individual
/// favorite's own `FavoriteItemTarget`. Smart-manga chapter checking keys
/// off the `MangaDirectory` itself (`cleanBookName`) instead: multiple
/// favorited chapters that resolve to the same directory collapse into ONE
/// tracked target / ONE potential event, mirroring how the favorites page
/// already merges them into one card (see design decision #4 in the
/// smart-manga update-check plan).
public enum FavoriteUpdateTargetKey: Codable, Hashable, Sendable {
    case favorite(FavoriteItemTarget)
    case mangaDirectory(cleanBookName: String)

    private static let mangaDirectoryIDPrefix = "manga-directory:"

    public var id: String {
        switch self {
        case let .favorite(target):
            target.id
        case let .mangaDirectory(cleanBookName):
            "\(Self.mangaDirectoryIDPrefix)\(cleanBookName)"
        }
    }

    /// Reverses `.mangaDirectory(cleanBookName:).id` for callers (e.g.
    /// notification tap-routing) that only have the persisted id string, not
    /// the original enum case. Returns nil for a `.favorite` id, never
    /// guesses — the single source of truth for the prefix stays `id` above.
    public static func mangaDirectoryCleanBookName(fromID id: String) -> String? {
        guard id.hasPrefix(mangaDirectoryIDPrefix) else { return nil }
        return String(id.dropFirst(mangaDirectoryIDPrefix.count))
    }
}

public enum FavoriteUpdateRunStatus: String, Codable, Hashable, Sendable {
    case running
    case interrupted
    case failed
    case completed
    case canceled
}

public enum FavoriteUpdateRunPhase: String, Codable, Hashable, Sendable {
    case preparing
    case checking
    case interrupted
    case failed
    case completed
    case canceled
}

/// Transient progress detail for a running update check, beyond what
/// `FavoriteUpdateRunPhase` conveys. The presentation layer maps these to
/// localized text; the model never stores display copy.
public enum FavoriteUpdateRunProgress: Codable, Hashable, Sendable {
    case loadedTargets(count: Int)
    case checking(index: Int, total: Int, title: String)
}

public struct FavoriteUpdateRunSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var runID: String
    public var status: FavoriteUpdateRunStatus
    public var phase: FavoriteUpdateRunPhase
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    public var totalCount: Int
    public var completedCount: Int
    public var skippedCount: Int
    public var failedCount: Int
    public var detectedCount: Int
    public var progress: FavoriteUpdateRunProgress?
    /// Raw error descriptions from failed operations; unlike `progress` these
    /// carry free-form error text, not display copy.
    public var warningMessage: String?
    public var errorMessage: String?

    public var id: String { runID }

    public init(
        runID: String = UUID().uuidString,
        status: FavoriteUpdateRunStatus = .running,
        phase: FavoriteUpdateRunPhase = .preparing,
        startedAt: Date = .now,
        updatedAt: Date = .now,
        finishedAt: Date? = nil,
        totalCount: Int = 0,
        completedCount: Int = 0,
        skippedCount: Int = 0,
        failedCount: Int = 0,
        detectedCount: Int = 0,
        progress: FavoriteUpdateRunProgress? = nil,
        warningMessage: String? = nil,
        errorMessage: String? = nil
    ) {
        self.runID = runID
        self.status = status
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.totalCount = totalCount
        self.completedCount = completedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.detectedCount = detectedCount
        self.progress = progress
        self.warningMessage = warningMessage
        self.errorMessage = errorMessage
    }
}

public struct FavoriteUpdateTrackedTarget: Codable, Hashable, Identifiable, Sendable {
    public var target: FavoriteUpdateTargetKey
    public var title: String
    public var mode: FavoriteUpdateTargetMode
    public var categoryIDs: Set<String>
    public var fid: String?
    public var forumName: String?
    public var knownLatestPostID: String?
    public var knownReplyCount: Int?
    public var knownPageCount: Int?
    /// Chapter-tid baseline for `.mangaDirectory` targets only — always nil
    /// for thread-mode targets. Monotonic: only ever grows (set union), even
    /// though `MangaDirectoryWorkflow.updateDirectory`'s own retention logic
    /// can prune stale chapters from the directory's stored list independent
    /// of this baseline — shrinking the baseline in lockstep with that
    /// pruning would make a pruned-then-reappearing chapter falsely
    /// re-report as new.
    public var knownChapterTIDs: Set<String>?
    public var baselineReady: Bool
    public var lastCheckedAt: Date?
    public var lastUpdatedAt: Date?
    public var lastError: String?
    public var consecutiveFailures: Int

    public var id: String { target.id }

    public init(
        target: FavoriteUpdateTargetKey,
        title: String,
        mode: FavoriteUpdateTargetMode,
        categoryIDs: Set<String> = [],
        fid: String? = nil,
        forumName: String? = nil,
        knownLatestPostID: String? = nil,
        knownReplyCount: Int? = nil,
        knownPageCount: Int? = nil,
        knownChapterTIDs: Set<String>? = nil,
        baselineReady: Bool = false,
        lastCheckedAt: Date? = nil,
        lastUpdatedAt: Date? = nil,
        lastError: String? = nil,
        consecutiveFailures: Int = 0
    ) {
        self.target = target
        self.title = title
        self.mode = mode
        self.categoryIDs = categoryIDs
        self.fid = fid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.forumName = forumName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.knownLatestPostID = knownLatestPostID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.knownReplyCount = knownReplyCount
        self.knownPageCount = knownPageCount
        self.knownChapterTIDs = knownChapterTIDs
        self.baselineReady = baselineReady
        self.lastCheckedAt = lastCheckedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.lastError = lastError
        self.consecutiveFailures = consecutiveFailures
    }
}

/// What changed for a tracked favorite between two update checks.
public enum FavoriteUpdateSummary: Codable, Hashable, Sendable {
    case newReplies(count: Int)
    case newPages(count: Int)
    /// New chapter-thread tids found for a `.mangaDirectory` target — the
    /// directory-mode counterpart of `.newReplies`/`.newPages`.
    case newChapters(count: Int)
    case changed
}

public struct FavoriteUpdateEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var target: FavoriteUpdateTargetKey
    public var title: String
    public var mode: FavoriteUpdateTargetMode
    public var fid: String?
    public var forumName: String?
    public var summary: FavoriteUpdateSummary
    public var detailIDs: [String]
    public var detectedAt: Date
    public var readAt: Date?
    public var dismissedAt: Date?
    public var ambiguous: Bool

    public init(
        id: String = UUID().uuidString,
        target: FavoriteUpdateTargetKey,
        title: String,
        mode: FavoriteUpdateTargetMode,
        fid: String? = nil,
        forumName: String? = nil,
        summary: FavoriteUpdateSummary,
        detailIDs: [String] = [],
        detectedAt: Date = .now,
        readAt: Date? = nil,
        dismissedAt: Date? = nil,
        ambiguous: Bool = false
    ) {
        self.id = id
        self.target = target
        self.title = title
        self.mode = mode
        self.fid = fid
        self.forumName = forumName
        self.summary = summary
        self.detailIDs = detailIDs
        self.detectedAt = detectedAt
        self.readAt = readAt
        self.dismissedAt = dismissedAt
        self.ambiguous = ambiguous
    }
}

public struct FavoriteUpdateFidFilter: Codable, Hashable, Identifiable, Sendable {
    public var fid: String
    public var forumName: String
    public var enabled: Bool
    public var itemCount: Int
    public var updatedAt: Date

    public var id: String { fid }

    public init(fid: String, forumName: String, enabled: Bool = true, itemCount: Int = 0, updatedAt: Date = .now) {
        self.fid = fid
        self.forumName = forumName
        self.enabled = enabled
        self.itemCount = itemCount
        self.updatedAt = updatedAt
    }
}

public struct FavoriteUpdateCategoryFilter: Codable, Hashable, Identifiable, Sendable {
    public var categoryID: String
    public var categoryName: String
    public var enabled: Bool
    public var itemCount: Int
    public var updatedAt: Date

    public var id: String { categoryID }

    public init(categoryID: String, categoryName: String, enabled: Bool = true, itemCount: Int = 0, updatedAt: Date = .now) {
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.enabled = enabled
        self.itemCount = itemCount
        self.updatedAt = updatedAt
    }
}

public struct FavoriteUpdateStoreState: Codable, Hashable, Sendable {
    public var trackedTargets: [FavoriteUpdateTrackedTarget]
    public var events: [FavoriteUpdateEvent]
    public var runs: [FavoriteUpdateRunSnapshot]
    public var fidFilters: [FavoriteUpdateFidFilter]
    public var categoryFilters: [FavoriteUpdateCategoryFilter]

    public init(
        trackedTargets: [FavoriteUpdateTrackedTarget] = [],
        events: [FavoriteUpdateEvent] = [],
        runs: [FavoriteUpdateRunSnapshot] = [],
        fidFilters: [FavoriteUpdateFidFilter] = [],
        categoryFilters: [FavoriteUpdateCategoryFilter] = []
    ) {
        self.trackedTargets = trackedTargets
        self.events = events
        self.runs = runs
        self.fidFilters = fidFilters
        self.categoryFilters = categoryFilters
    }
}
