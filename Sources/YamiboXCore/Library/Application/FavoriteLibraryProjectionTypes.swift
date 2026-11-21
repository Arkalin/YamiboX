import Foundation

public enum LocalFavoriteSourceFilter: Hashable, Sendable {
    case forumBoard(id: String, label: String)
    case unknown

    public static func == (lhs: LocalFavoriteSourceFilter, rhs: LocalFavoriteSourceFilter) -> Bool {
        switch (lhs, rhs) {
        case let (.forumBoard(lhsID, _), .forumBoard(rhsID, _)):
            lhsID == rhsID
        case (.unknown, .unknown):
            true
        default:
            false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .forumBoard(id, _):
            hasher.combine("forumBoard")
            hasher.combine(id)
        case .unknown:
            hasher.combine("unknown")
        }
    }

    public var displayLabel: String {
        switch self {
        case let .forumBoard(id, label):
            label.isEmpty ? id : label
        case .unknown:
            L10n.string("favorites.source_group.unknown")
        }
    }

    public static func key(for item: FavoriteItem) -> LocalFavoriteSourceFilter {
        if let forumID = item.forumID ?? item.sourceGroup.forumID {
            return .forumBoard(id: forumID, label: item.forumName ?? item.sourceGroup.forumName ?? forumID)
        }
        return .unknown
    }

    public func matches(_ item: FavoriteItem) -> Bool {
        switch self {
        case let .forumBoard(id, _):
            return item.forumID == id || item.sourceGroup.forumID == id
        case .unknown:
            return LocalFavoriteSourceFilter.key(for: item) == .unknown
        }
    }
}

public struct LocalFavoriteLibraryQuery: Equatable, Sendable {
    public var categoryID: String?
    public var collectionID: String?
    public var selectedSourceFilters: Set<LocalFavoriteSourceFilter>
    public var selectedTagIDs: Set<String>
    public var sortOrder: LocalFavoriteLibrarySortOrder
    public var sortsDescending: Bool
    public var searchText: String
    public var memberScopeGroupKey: String?

    public init(
        categoryID: String? = nil,
        collectionID: String? = nil,
        selectedSourceFilters: Set<LocalFavoriteSourceFilter> = [],
        selectedTagIDs: Set<String> = [],
        sortOrder: LocalFavoriteLibrarySortOrder = .organization,
        sortsDescending: Bool = false,
        searchText: String = "",
        memberScopeGroupKey: String? = nil
    ) {
        self.categoryID = categoryID
        self.collectionID = collectionID
        self.selectedSourceFilters = selectedSourceFilters
        self.selectedTagIDs = selectedTagIDs
        self.sortOrder = sortOrder
        self.sortsDescending = sortsDescending
        self.searchText = searchText
        self.memberScopeGroupKey = memberScopeGroupKey
    }
}

public struct FavoriteCollectionSortSummary: Equatable, Sendable {
    public var latestUpdatedAt: Date?
    public var latestReadAt: Date?
    public var minRemoteOrder: Int?

    public init(latestUpdatedAt: Date? = nil, latestReadAt: Date? = nil, minRemoteOrder: Int? = nil) {
        self.latestUpdatedAt = latestUpdatedAt
        self.latestReadAt = latestReadAt
        self.minRemoteOrder = minRemoteOrder
    }

    public static func summarizing(_ cards: [FavoriteCardProjection]) -> FavoriteCollectionSortSummary {
        FavoriteCollectionSortSummary(
            latestUpdatedAt: cards.compactMap(\.lastUpdatedAt).max(),
            latestReadAt: cards.compactMap(\.recentReadingAt).max(),
            minRemoteOrder: cards.compactMap { $0.item.remoteMapping?.yamiboRemoteOrder }.min()
        )
    }
}

public enum FavoriteMixedEntry: Equatable, Identifiable, Sendable {
    case collection(LocalFavoriteCollection)
    case card(FavoriteCardProjection)

    public var id: String {
        switch self {
        case let .collection(collection):
            "collection-\(collection.id)"
        case let .card(card):
            "item-\(card.id)"
        }
    }
}

public struct FavoriteCardProjection: Equatable, Identifiable, Sendable {
    public var item: FavoriteItem
    public var sourceGroupLabel: String
    public var collectionNames: [String]
    public var tags: [FavoriteTag]
    public var recentReadingAt: Date?
    public var lastUpdatedAt: Date?
    public var progressPercent: Int?
    public var chapterPageProgress: String?
    public var coverSource: YamiboImageSource?
    public var textCoverForced: Bool

    public var mangaDirectory: MangaDirectory? = nil

    public var mergedMembers: [FavoriteItem]? = nil

    public var isMergedGroup: Bool { mergedMembers != nil }

    public var isModeOnMangaThread: Bool = false

    public var resolvedTitle: String

    public static func resolvedTitle(item: FavoriteItem, mangaDirectory: MangaDirectory?, isModeOnMangaThread: Bool) -> String {
        if let mangaDirectory {
            return mangaDirectory.cleanBookName
        }
        guard isModeOnMangaThread else {
            return item.resolvedDisplayTitle
        }
        return resolvedSmartMangaTitle(item.resolvedDisplayTitle, directory: nil)
    }

    public static func resolvedSmartMangaTitle(_ title: String, directory: MangaDirectory?) -> String {
        if let directory { return directory.cleanBookName }
        let cleaned = MangaTitleCleaner.cleanBookName(title)
        return cleaned.isEmpty ? title : cleaned
    }

    public static func groupKey(item: FavoriteItem, mangaDirectory: MangaDirectory?) -> String {
        if let mangaDirectory { return mangaDirectory.id.rawValue }
        return "unresolved-title:" + resolvedTitle(item: item, mangaDirectory: nil, isModeOnMangaThread: true)
    }

    public var mangaGroupKey: String { Self.groupKey(item: item, mangaDirectory: mangaDirectory) }

    public var contentCoverKey: ContentCoverKey? {
        if let mangaDirectory {
            return .smartManga(directoryID: mangaDirectory.id)
        }
        return ContentCoverKey(target: item.target)
    }

    public var id: String { mangaDirectory?.id.rawValue ?? item.id }
}

public struct MangaDirectoryFavoriteGroup: Equatable, Sendable {
    public var directory: MangaDirectory
    public var members: [FavoriteItem]
}
