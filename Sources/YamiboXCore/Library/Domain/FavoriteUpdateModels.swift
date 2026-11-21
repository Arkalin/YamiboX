import Foundation

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

public enum FavoriteUpdateTargetKey: Codable, Hashable, Sendable {
    case favorite(FavoriteItemTarget)
    case mangaDirectory(directoryID: MangaDirectoryID)

    private static let mangaDirectoryIDPrefix = "manga-directory:"

    private enum CodingKeys: String, CodingKey { case favorite, mangaDirectory }
    private enum PayloadKeys: String, CodingKey { case _0, directoryID, cleanBookName }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.favorite) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .favorite)
            self = .favorite(try payload.decode(FavoriteItemTarget.self, forKey: ._0))
        } else {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .mangaDirectory)
            if let id = try payload.decodeIfPresent(MangaDirectoryID.self, forKey: .directoryID) {
                self = .mangaDirectory(directoryID: id)
            } else {
                self = .mangaDirectory(directoryID: .legacy(name: try payload.decode(String.self, forKey: .cleanBookName)))
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .favorite(target):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .favorite)
            try payload.encode(target, forKey: ._0)
        case let .mangaDirectory(id):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .mangaDirectory)
            try payload.encode(id, forKey: .directoryID)
        }
    }

    public var id: String {
        switch self {
        case let .favorite(target):
            target.id
        case let .mangaDirectory(directoryID):
            "\(Self.mangaDirectoryIDPrefix)\(directoryID.rawValue)"
        }
    }

    public static func mangaDirectoryID(fromID id: String) -> MangaDirectoryID? {
        guard id.hasPrefix(mangaDirectoryIDPrefix) else { return nil }
        return MangaDirectoryID(rawValue: String(id.dropFirst(mangaDirectoryIDPrefix.count)))
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
    public var knownChapterTIDs: Set<String>?
    public var baselineReady: Bool
    public var novelBaselineVersion: Int?
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
        novelBaselineVersion: Int? = nil,
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
        self.novelBaselineVersion = novelBaselineVersion
        self.lastCheckedAt = lastCheckedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.lastError = lastError
        self.consecutiveFailures = consecutiveFailures
    }
}

public enum FavoriteUpdateSummary: Codable, Hashable, Sendable {
    case newReplies(count: Int)
    case newPages(count: Int)
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
