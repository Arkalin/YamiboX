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
    /// Last time *any* field changed — used for same-side duplicate
    /// degradation (`FavoriteLibraryWebDAVMerger.newerItem`,
    /// `FavoriteLibraryDocument.normalizedItems`) and general "last edited"
    /// display, not for cross-device conflict resolution: `locations`,
    /// `tagIDs`, `displayName`, and `remoteMapping` each merge independently
    /// by their own dedicated clock below, so two concurrent edits to
    /// different fields on different devices don't clobber each other.
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
        case locationsUpdatedAt, tagIDsUpdatedAt, displayNameUpdatedAt, remoteMappingUpdatedAt
    }

    /// Hand-written rather than synthesized so items persisted before these
    /// four per-field clocks existed keep decoding: each falls back to the
    /// item's own `updatedAt`, i.e. "assume every field was last touched
    /// whenever anything last was" — the same tolerant-decode precedent as
    /// `FavoriteLibraryDocument`'s deletion tombstones. Deliberately doesn't
    /// re-run the throwing initializer's non-empty-locations validation,
    /// matching every other type in this domain: Codable decoding bypasses
    /// normalization/validation, which only runs at deliberate
    /// (re)construction points.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(FavoriteItemTarget.self, forKey: .target)
        title = try container.decode(String.self, forKey: .title)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        sourceGroup = try container.decode(FavoriteSourceGroup.self, forKey: .sourceGroup)
        forumID = try container.decodeIfPresent(String.self, forKey: .forumID)
        forumName = try container.decodeIfPresent(String.self, forKey: .forumName)
        contentUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .contentUpdatedAt)
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
