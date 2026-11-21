import Foundation

public typealias FavoriteBackgroundSettings = CustomBackgroundSettings

public enum FavoriteLibraryLayoutMode: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case fixedGrid
    case staggered
    case rowCard
    case rowCardText

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fixedGrid:
            L10n.string("favorites.layout.fixed_grid")
        case .staggered:
            L10n.string("favorites.layout.staggered")
        case .rowCard:
            L10n.string("favorites.layout.row_card")
        case .rowCardText:
            L10n.string("favorites.layout.row_card_text")
        }
    }

    public var systemImageName: String {
        switch self {
        case .fixedGrid:
            "square.grid.2x2"
        case .staggered:
            "rectangle.3.offgrid"
        case .rowCard:
            "list.bullet.rectangle.portrait"
        case .rowCardText:
            "list.bullet"
        }
    }
}

public enum FavoriteRemoteSyncTaskStatus: String, Codable, Hashable, Sendable {
    case running
    case completed
    case failed
    case interrupted
}

public enum FavoriteRemoteSyncPhase: String, Codable, Hashable, Sendable {
    case queued
    case preparing
    case fetching
    case importing
    case uploading
    case reconciling
    case completed
    case failed
    case interrupted
}

public enum FavoriteRemoteSyncLogEntry: Codable, Hashable, Sendable {
    case started(categoryName: String)
    case fetchedPage(page: Int, totalPages: Int, accumulatedCount: Int)
    case importingItem(index: Int, total: Int, title: String)
    case skippedSyncedItems(path: String, count: Int)
    case uploading(targetCount: Int)
    case uploadedItem(index: Int, total: Int, title: String)
    case reconciling
    case completed(importedCount: Int, uploadedCount: Int)
    case failed
    case interrupted
    case taskLost
}

/// Semantic warnings surfaced by a remote favorite sync run. Item-level
/// failures carry a truncated reason string; run-fatal errors go to
/// `FavoriteRemoteSyncSnapshot.errorMessages` instead.
public enum FavoriteRemoteSyncWarning: Codable, Hashable, Sendable {
    case interruptedByUser
    case interrupted
    case taskLost
    case backgroundExpired
    case backgroundUnavailable
    case remotePageCountChanged
    case duplicateRemoteEntry(title: String)
    case importFailedItem(title: String, reason: String)
    case uploadFailedItem(title: String, reason: String)
    case reconcileFailed(reason: String)
    case remoteFavoritesEmptyBeforeBulkUpload(count: Int)
    case importedIntoExistingMangaDirectory(title: String, cleanBookName: String)
}

public struct FavoriteRemoteSyncSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var runID: String
    public var status: FavoriteRemoteSyncTaskStatus
    public var targetCategoryID: String
    public var targetCategoryName: String
    public var phase: FavoriteRemoteSyncPhase
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    public var currentPage: Int?
    public var totalPages: Int?
    /// Remote entries accumulated across fetched pages.
    public var scannedCount: Int
    /// Newly imported items plus existing items that gained the target
    /// category location.
    public var importedCount: Int
    /// Remote entries whose local item was already mapped; nothing to do.
    public var skippedCount: Int
    public var uploadTargetCount: Int
    public var uploadedCount: Int
    public var failedCount: Int
    public var logEntries: [FavoriteRemoteSyncLogEntry]
    public var warnings: [FavoriteRemoteSyncWarning]
    /// Raw error descriptions from failed operations; unlike logs and
    /// warnings these carry free-form error text, not display copy.
    public var errorMessages: [String]
    public var isHiddenFromFavoritePage: Bool

    public var id: String { runID }

    public init(
        runID: String = UUID().uuidString,
        status: FavoriteRemoteSyncTaskStatus = .running,
        targetCategoryID: String,
        targetCategoryName: String,
        phase: FavoriteRemoteSyncPhase,
        startedAt: Date = .now,
        updatedAt: Date = .now,
        finishedAt: Date? = nil,
        currentPage: Int? = nil,
        totalPages: Int? = nil,
        scannedCount: Int = 0,
        importedCount: Int = 0,
        skippedCount: Int = 0,
        uploadTargetCount: Int = 0,
        uploadedCount: Int = 0,
        failedCount: Int = 0,
        logEntries: [FavoriteRemoteSyncLogEntry] = [],
        warnings: [FavoriteRemoteSyncWarning] = [],
        errorMessages: [String] = [],
        isHiddenFromFavoritePage: Bool = false
    ) {
        self.runID = runID
        self.status = status
        self.targetCategoryID = targetCategoryID
        self.targetCategoryName = targetCategoryName
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.currentPage = currentPage
        self.totalPages = totalPages
        self.scannedCount = scannedCount
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.uploadTargetCount = uploadTargetCount
        self.uploadedCount = uploadedCount
        self.failedCount = failedCount
        self.logEntries = logEntries
        self.warnings = warnings
        self.errorMessages = errorMessages
        self.isHiddenFromFavoritePage = isHiddenFromFavoritePage
    }
}

public struct FavoriteRemoteSyncEntryCounts: Equatable, Sendable {
    public let logs: Int
    public let warnings: Int
    public let errors: Int

    public init(_ snapshot: FavoriteRemoteSyncSnapshot) {
        logs = snapshot.logEntries.count
        warnings = snapshot.warnings.count
        errors = snapshot.errorMessages.count
    }
}

public enum FavoriteUpdateCheckInterval: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case off
    case sixHours
    case twelveHours
    case day
    case threeDays
    case week
    case smart

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: L10n.string("favorites.updates.interval.off")
        case .sixHours: L10n.string("favorites.updates.interval.six_hours")
        case .twelveHours: L10n.string("favorites.updates.interval.twelve_hours")
        case .day: L10n.string("favorites.updates.interval.day")
        case .threeDays: L10n.string("favorites.updates.interval.three_days")
        case .week: L10n.string("favorites.updates.interval.week")
        case .smart: L10n.string("favorites.updates.interval.smart")
        }
    }

    public func nextDelay(hasRecentEvents: Bool) -> TimeInterval? {
        switch self {
        case .off: nil
        case .sixHours: 6 * 3600
        case .twelveHours: 12 * 3600
        case .day: 24 * 3600
        case .threeDays: 3 * 24 * 3600
        case .week: 7 * 24 * 3600
        case .smart: hasRecentEvents ? 12 * 3600 : 48 * 3600
        }
    }
}

public enum SmartMangaUpdateCheckInterval: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case off
    case day
    case threeDays
    case week
    case smart

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: L10n.string("favorites.updates.manga_interval.off")
        case .day: L10n.string("favorites.updates.manga_interval.day")
        case .threeDays: L10n.string("favorites.updates.manga_interval.three_days")
        case .week: L10n.string("favorites.updates.manga_interval.week")
        case .smart: L10n.string("favorites.updates.manga_interval.smart")
        }
    }

    public func nextDelay(hasRecentEvents: Bool) -> TimeInterval? {
        switch self {
        case .off: nil
        case .day: 24 * 3600
        case .threeDays: 3 * 24 * 3600
        case .week: 7 * 24 * 3600
        case .smart: hasRecentEvents ? 24 * 3600 : 3 * 24 * 3600
        }
    }
}

public enum FavoriteItemTapAction: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case detail
    case read

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .detail: L10n.string("settings.favorite_item_tap_action.detail")
        case .read: L10n.string("settings.favorite_item_tap_action.read")
        }
    }
}

public struct FavoriteLibrarySettings: Codable, Hashable, Sendable {
    public static let minimumGridCardScale = 0.7
    public static let maximumGridCardScale = 2.5
    public static let defaultGridCardScale = 1.0

    public static func clampGridCardScale(_ value: Double) -> Double {
        guard value.isFinite else { return defaultGridCardScale }
        return min(maximumGridCardScale, max(minimumGridCardScale, value))
    }

    public var background: FavoriteBackgroundSettings
    public var layoutMode: FavoriteLibraryLayoutMode
    /// Card-width multiplier for the fixed-grid and staggered layouts,
    /// adjustable on iPad only (pinch on the favorites page, or the slider in
    /// Settings → Favorites → Appearance). iPhone always renders at 1.0 —
    /// the layouts ignore this value there — so a synced/restored settings
    /// blob from an iPad can never squeeze or blow up the iPhone grid.
    public var gridCardScale: Double
    public var sortOrder: LocalFavoriteLibrarySortOrder
    public var sortDescending: Bool
    public var selectedCategoryID: String?
    public var selectedCollectionID: String?
    public var showsCategoryCounts: Bool
    public var itemTapAction: FavoriteItemTapAction
    public var collapsesSections: Bool
    /// Whether adding a favorite asks about pushing it to Yamibo; once the
    /// user picks "remember", this turns off and `addSyncDefault` applies.
    public var addSyncPromptEnabled: Bool
    public var addSyncDefault: Bool
    /// Same pair for the delete flow's "also remove from Yamibo" question.
    public var removeRemotePromptEnabled: Bool
    public var removeRemoteDefault: Bool
    public var updateCheckInterval: FavoriteUpdateCheckInterval
    /// Whether detected favorite updates are delivered as local system
    /// notifications. Off by default; enabling it prompts for notification
    /// permission, so the toggle only ever turns on after a grant.
    public var updateNotificationsEnabled: Bool
    public var smartMangaUpdateCheckInterval: SmartMangaUpdateCheckInterval
    public var smartMangaBulkDeleteEnabled: Bool
    public var smartMangaBadgeEnabled: Bool

    public init(
        background: FavoriteBackgroundSettings = .init(),
        layoutMode: FavoriteLibraryLayoutMode = .rowCard,
        gridCardScale: Double = FavoriteLibrarySettings.defaultGridCardScale,
        sortOrder: LocalFavoriteLibrarySortOrder = .organization,
        sortDescending: Bool = false,
        selectedCategoryID: String? = nil,
        selectedCollectionID: String? = nil,
        showsCategoryCounts: Bool = true,
        collapsesSections: Bool = false,
        addSyncPromptEnabled: Bool = true,
        addSyncDefault: Bool = true,
        removeRemotePromptEnabled: Bool = true,
        removeRemoteDefault: Bool = false,
        updateCheckInterval: FavoriteUpdateCheckInterval = .off,
        updateNotificationsEnabled: Bool = false,
        smartMangaUpdateCheckInterval: SmartMangaUpdateCheckInterval = .threeDays,
        smartMangaBulkDeleteEnabled: Bool = true,
        smartMangaBadgeEnabled: Bool = true,
        itemTapAction: FavoriteItemTapAction = .detail
    ) {
        self.background = background
        self.layoutMode = layoutMode
        self.gridCardScale = Self.clampGridCardScale(gridCardScale)
        self.sortOrder = sortOrder
        self.sortDescending = sortDescending
        self.selectedCategoryID = Self.normalizedID(selectedCategoryID)
        self.selectedCollectionID = Self.normalizedID(selectedCollectionID)
        self.showsCategoryCounts = showsCategoryCounts
        self.itemTapAction = itemTapAction
        self.collapsesSections = collapsesSections
        self.addSyncPromptEnabled = addSyncPromptEnabled
        self.addSyncDefault = addSyncDefault
        self.removeRemotePromptEnabled = removeRemotePromptEnabled
        self.removeRemoteDefault = removeRemoteDefault
        self.updateCheckInterval = updateCheckInterval
        self.updateNotificationsEnabled = updateNotificationsEnabled
        self.smartMangaUpdateCheckInterval = smartMangaUpdateCheckInterval
        self.smartMangaBulkDeleteEnabled = smartMangaBulkDeleteEnabled
        self.smartMangaBadgeEnabled = smartMangaBadgeEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            background: try container.decodeIfPresent(FavoriteBackgroundSettings.self, forKey: .background) ?? .init(),
            layoutMode: try container.decodeIfPresent(FavoriteLibraryLayoutMode.self, forKey: .layoutMode) ?? .rowCard,
            gridCardScale: try container.decodeIfPresent(Double.self, forKey: .gridCardScale) ?? Self.defaultGridCardScale,
            sortOrder: try container.decodeIfPresent(LocalFavoriteLibrarySortOrder.self, forKey: .sortOrder) ?? .organization,
            sortDescending: try container.decodeIfPresent(Bool.self, forKey: .sortDescending) ?? false,
            selectedCategoryID: try container.decodeIfPresent(String.self, forKey: .selectedCategoryID),
            selectedCollectionID: try container.decodeIfPresent(String.self, forKey: .selectedCollectionID),
            showsCategoryCounts: try container.decodeIfPresent(Bool.self, forKey: .showsCategoryCounts) ?? true,
            collapsesSections: try container.decodeIfPresent(Bool.self, forKey: .collapsesSections) ?? false,
            addSyncPromptEnabled: try container.decodeIfPresent(Bool.self, forKey: .addSyncPromptEnabled) ?? true,
            addSyncDefault: try container.decodeIfPresent(Bool.self, forKey: .addSyncDefault) ?? true,
            removeRemotePromptEnabled: try container.decodeIfPresent(Bool.self, forKey: .removeRemotePromptEnabled) ?? true,
            removeRemoteDefault: try container.decodeIfPresent(Bool.self, forKey: .removeRemoteDefault) ?? false,
            updateCheckInterval: try container.decodeIfPresent(FavoriteUpdateCheckInterval.self, forKey: .updateCheckInterval) ?? .off,
            updateNotificationsEnabled: try container.decodeIfPresent(Bool.self, forKey: .updateNotificationsEnabled) ?? false,
            smartMangaUpdateCheckInterval: try container.decodeIfPresent(SmartMangaUpdateCheckInterval.self, forKey: .smartMangaUpdateCheckInterval) ?? .threeDays,
            smartMangaBulkDeleteEnabled: try container.decodeIfPresent(Bool.self, forKey: .smartMangaBulkDeleteEnabled) ?? true,
            smartMangaBadgeEnabled: try container.decodeIfPresent(Bool.self, forKey: .smartMangaBadgeEnabled) ?? true,
            itemTapAction: try container.decodeIfPresent(FavoriteItemTapAction.self, forKey: .itemTapAction) ?? .detail
        )
    }

    private static func normalizedID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public typealias FavoriteBackgroundLayout = CustomBackgroundLayout
public typealias FavoriteBackgroundRenderedFrame = CustomBackgroundRenderedFrame
public typealias FavoriteBackgroundImageStore = CustomBackgroundImageStore
public typealias FavoriteBackgroundImageProcessor = CustomBackgroundImageProcessor
