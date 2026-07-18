import Foundation

public enum FavoriteSourceGroup: Codable, Hashable, Sendable {
    case forumBoard(id: String, label: String)
    /// Renamed from `.mangaTitle` (smart-comic-mode design decision #9): the
    /// favorites-page display/sort grouping label for manga. No behavior
    /// change, pure rename (including its wire format — no shipped user data
    /// exists yet, see [[yamiboreader-no-data-compat]]).
    case smartManga(mangaID: String, cleanBookName: String)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case forumBoard
        case smartManga
        case unknown
    }

    private enum ForumBoardCodingKeys: String, CodingKey {
        case id
        case label
    }

    private enum SmartMangaCodingKeys: String, CodingKey {
        case mangaID
        case cleanBookName
    }

    public static func == (lhs: FavoriteSourceGroup, rhs: FavoriteSourceGroup) -> Bool {
        switch (lhs, rhs) {
        case let (.forumBoard(lhsID, _), .forumBoard(rhsID, _)):
            lhsID == rhsID
        case let (.smartManga(lhsID, _), .smartManga(rhsID, _)):
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
        case let .smartManga(mangaID, _):
            hasher.combine("smartManga")
            hasher.combine(mangaID)
        case .unknown:
            hasher.combine("unknown")
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.unknown) {
            self = .unknown
            return
        }
        if container.contains(.forumBoard) {
            let values = try container.nestedContainer(keyedBy: ForumBoardCodingKeys.self, forKey: .forumBoard)
            self = .forumBoard(
                id: try values.decode(String.self, forKey: .id),
                label: try values.decode(String.self, forKey: .label)
            )
            return
        }
        let values = try container.nestedContainer(keyedBy: SmartMangaCodingKeys.self, forKey: .smartManga)
        let cleanBookName = try values.decode(String.self, forKey: .cleanBookName)
        self = FavoriteSourceGroup.smartManga(
            mangaID: try values.decodeIfPresent(String.self, forKey: .mangaID) ?? cleanBookName,
            cleanBookName: cleanBookName
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .forumBoard(id, label):
            var values = container.nestedContainer(keyedBy: ForumBoardCodingKeys.self, forKey: .forumBoard)
            try values.encode(id, forKey: .id)
            try values.encode(label, forKey: .label)
        case let .smartManga(mangaID, cleanBookName):
            var values = container.nestedContainer(keyedBy: SmartMangaCodingKeys.self, forKey: .smartManga)
            try values.encode(mangaID, forKey: .mangaID)
            try values.encode(cleanBookName, forKey: .cleanBookName)
        case .unknown:
            _ = container.nestedContainer(keyedBy: SmartMangaCodingKeys.self, forKey: .unknown)
        }
    }

    public var forumID: String? {
        guard case let .forumBoard(id, _) = self else { return nil }
        return id.nilIfBlank
    }

    public var forumName: String? {
        guard case let .forumBoard(_, label) = self else { return nil }
        return label.nilIfBlank
    }

    static func normalizedForumMetadata(
        sourceGroup: FavoriteSourceGroup,
        forumID: String?,
        forumName: String?
    ) -> (sourceGroup: FavoriteSourceGroup, forumID: String?, forumName: String?) {
        let trimmedForumID = forumID?.nilIfBlank
        let trimmedForumName = forumName?.nilIfBlank
        switch sourceGroup {
        case let .forumBoard(id, label):
            let resolvedID = trimmedForumID ?? id.nilIfBlank
            let resolvedName = trimmedForumName ?? label.nilIfBlank
            guard let resolvedID else {
                return (.unknown, nil, nil)
            }
            return (.forumBoard(id: resolvedID, label: resolvedName ?? resolvedID), resolvedID, resolvedName)
        case let .smartManga(mangaID, cleanBookName):
            return (.smartManga(mangaID: mangaID, cleanBookName: cleanBookName), nil, nil)
        case .unknown:
            guard let trimmedForumID else {
                return (.unknown, nil, nil)
            }
            return (.forumBoard(id: trimmedForumID, label: trimmedForumName ?? trimmedForumID), trimmedForumID, trimmedForumName)
        }
    }
}

public extension FavoriteSourceGroup {
    static func smartManga(cleanBookName: String) -> FavoriteSourceGroup {
        let normalizedName = cleanBookName.trimmingCharacters(in: .whitespacesAndNewlines)
        return .smartManga(mangaID: normalizedName, cleanBookName: normalizedName)
    }
}
