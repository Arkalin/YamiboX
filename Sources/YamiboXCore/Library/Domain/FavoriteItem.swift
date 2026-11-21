import Foundation

public struct FavoriteItem: Codable, Hashable, Identifiable, Sendable {
    public var target: FavoriteItemTarget
    public var title: String
    public var displayName: String?
    public var sourceGroup: FavoriteSourceGroup
    public var forumID: String?
    public var forumName: String?
    public var contentUpdatedAt: Date?
    private var contentDateVersion = 1
    public var remoteMapping: FavoriteRemoteMapping?
    public var locations: [FavoriteLocation]
    public var tagIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var locationsUpdatedAt: Date
    public var tagIDsUpdatedAt: Date
    public var displayNameUpdatedAt: Date
    public var remoteMappingUpdatedAt: Date

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
        updatedAt: Date = .now,
        locationsUpdatedAt: Date? = nil,
        tagIDsUpdatedAt: Date? = nil,
        displayNameUpdatedAt: Date? = nil,
        remoteMappingUpdatedAt: Date? = nil
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
        self.locationsUpdatedAt = locationsUpdatedAt ?? updatedAt
        self.tagIDsUpdatedAt = tagIDsUpdatedAt ?? updatedAt
        self.displayNameUpdatedAt = displayNameUpdatedAt ?? updatedAt
        self.remoteMappingUpdatedAt = remoteMappingUpdatedAt ?? updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case target, title, displayName, sourceGroup, forumID, forumName
        case contentUpdatedAt, remoteMapping, locations, tagIDs, createdAt, updatedAt
        case contentDateVersion
        case locationsUpdatedAt, tagIDsUpdatedAt, displayNameUpdatedAt, remoteMappingUpdatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(FavoriteItemTarget.self, forKey: .target)
        title = try container.decode(String.self, forKey: .title)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        sourceGroup = try container.decode(FavoriteSourceGroup.self, forKey: .sourceGroup)
        forumID = try container.decodeIfPresent(String.self, forKey: .forumID)
        forumName = try container.decodeIfPresent(String.self, forKey: .forumName)
        contentUpdatedAt = try container.decodeIfPresent(Int.self, forKey: .contentDateVersion) == 1
            ? container.decodeIfPresent(Date.self, forKey: .contentUpdatedAt) : nil
        remoteMapping = try container.decodeIfPresent(FavoriteRemoteMapping.self, forKey: .remoteMapping)
        locations = try container.decode([FavoriteLocation].self, forKey: .locations)
        tagIDs = try container.decode([String].self, forKey: .tagIDs)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        locationsUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .locationsUpdatedAt) ?? updatedAt
        tagIDsUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .tagIDsUpdatedAt) ?? updatedAt
        displayNameUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .displayNameUpdatedAt) ?? updatedAt
        remoteMappingUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .remoteMappingUpdatedAt) ?? updatedAt
    }

    public var resolvedDisplayTitle: String {
        displayName?.nilIfBlank ?? title
    }

    public var hasYamiboRemoteCandidate: Bool {
        remoteMapping != nil
    }

    static func normalizedLocations(_ locations: [FavoriteLocation]) -> [FavoriteLocation] {
        var seen: Set<FavoriteLocation> = []
        return locations.filter { seen.insert($0).inserted }
    }

    static func normalizedIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }

}
