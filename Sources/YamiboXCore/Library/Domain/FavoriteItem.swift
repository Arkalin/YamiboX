import Foundation

public struct FavoriteItem: Codable, Hashable, Identifiable, Sendable {
    public var target: FavoriteItemTarget
    public var title: String
    public var displayName: String?
    public var sourceGroup: FavoriteSourceGroup
    public var forumID: String?
    public var forumName: String?
    public var contentUpdatedAt: Date?
    public var remoteMapping: FavoriteRemoteMapping?
    public var locations: [FavoriteLocation]
    public var tagIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { target.id }

    public init(
        target: FavoriteItemTarget,
        title: String,
        displayName: String? = nil,
        sourceGroup: FavoriteSourceGroup = .unknown,
        forumID: String? = nil,
        forumName: String? = nil,
        contentUpdatedAt: Date? = nil,
        remoteMapping: FavoriteRemoteMapping? = nil,
        locations: [FavoriteLocation],
        tagIDs: [String] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) throws {
        let normalizedLocations = Self.normalizedLocations(locations)
        guard !normalizedLocations.isEmpty else {
            throw YamiboPersistenceError(context: L10n.string("favorite_library.item_requires_location"))
        }
        self.target = target
        self.title = title
        self.displayName = displayName?.nilIfBlank
        let forumMetadata = FavoriteSourceGroup.normalizedForumMetadata(sourceGroup: sourceGroup, forumID: forumID, forumName: forumName)
        self.sourceGroup = forumMetadata.sourceGroup
        self.forumID = forumMetadata.forumID
        self.forumName = forumMetadata.forumName
        self.contentUpdatedAt = contentUpdatedAt
        self.remoteMapping = remoteMapping
        self.locations = normalizedLocations
        self.tagIDs = Self.normalizedIDs(tagIDs)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var resolvedDisplayTitle: String {
        displayName?.nilIfBlank ?? title
    }

    /// Whether this item plausibly has a Yamibo-website counterpart worth a
    /// remote delete attempt: a usable mapped favorite id, or a mapping whose
    /// id never resolved but whose thread id still allows a favorites-list
    /// lookup. The single source of truth shared by the remote deleter and
    /// the delete flow's "also remove from Yamibo?" decision gate — keep the
    /// two from ever diverging again.
    public var hasYamiboRemoteCandidate: Bool {
        if let remoteFavoriteID = remoteMapping?.yamiboFavoriteID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteFavoriteID.isEmpty {
            return true
        }
        return remoteMapping != nil && target.threadID != nil
    }

    static func normalizedLocations(_ locations: [FavoriteLocation]) -> [FavoriteLocation] {
        var seen: Set<String> = []
        return locations.filter { seen.insert($0.id).inserted }
    }

    static func normalizedIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }

}
