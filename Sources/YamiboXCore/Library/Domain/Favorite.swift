import Foundation

public struct Favorite: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var displayName: String?
    public var threadID: String
    public var remoteFavoriteID: String?
    public var mangaPageIndex: Int
    public var lastView: Int
    public var lastChapter: String?
    public var authorID: String?
    public var novelResumePoint: NovelResumePoint?
    public var novelMaxView: Int?
    public var novelDocumentSurfaceProgressPercent: Int?
    public var type: FavoriteType
    public var parentCollectionID: String?
    public var manualOrder: Int
    public var lastReadAt: Date?
    public var tagIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case displayName
        case threadID
        case remoteFavoriteID
        case mangaPageIndex = "lastPage"
        case lastView
        case lastChapter
        case authorID
        case novelResumePoint
        case novelMaxView
        case novelDocumentSurfaceProgressPercent
        case type
        case parentCollectionID
        case manualOrder
        case lastReadAt
        case tagIDs
    }

    public init(
        id: String? = nil,
        title: String,
        displayName: String? = nil,
        threadID: String,
        remoteFavoriteID: String? = nil,
        mangaPageIndex: Int = 0,
        lastView: Int = 1,
        lastChapter: String? = nil,
        authorID: String? = nil,
        novelResumePoint: NovelResumePoint? = nil,
        novelMaxView: Int? = nil,
        novelDocumentSurfaceProgressPercent: Int? = nil,
        type: FavoriteType = .unknown,
        parentCollectionID: String? = nil,
        manualOrder: Int = 0,
        lastReadAt: Date? = nil,
        tagIDs: [String] = []
    ) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "Favorite requires a Yamibo thread tid")
        self.id = id ?? remoteFavoriteID ?? "favorite:\(normalizedThreadID)"
        self.title = title
        self.displayName = displayName
        self.threadID = normalizedThreadID
        self.remoteFavoriteID = remoteFavoriteID
        self.mangaPageIndex = max(0, mangaPageIndex)
        self.lastView = lastView
        self.lastChapter = lastChapter
        self.authorID = authorID
        self.novelResumePoint = novelResumePoint
        self.novelMaxView = novelMaxView.map { max(1, $0) }
        self.novelDocumentSurfaceProgressPercent = novelDocumentSurfaceProgressPercent.map { min(max($0, 0), 100) }
        self.type = type
        self.parentCollectionID = parentCollectionID
        self.manualOrder = manualOrder
        self.lastReadAt = lastReadAt
        self.tagIDs = tagIDs
    }

    public var resolvedDisplayTitle: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? title : trimmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        threadID = try Self.decodeThreadID(from: container)
        remoteFavoriteID = try container.decodeIfPresent(String.self, forKey: .remoteFavoriteID)
        mangaPageIndex = max(0, try container.decodeIfPresent(Int.self, forKey: .mangaPageIndex) ?? 0)
        lastView = try container.decodeIfPresent(Int.self, forKey: .lastView) ?? 1
        lastChapter = try container.decodeIfPresent(String.self, forKey: .lastChapter)
        authorID = try container.decodeIfPresent(String.self, forKey: .authorID)
        novelResumePoint = try container.decodeIfPresent(NovelResumePoint.self, forKey: .novelResumePoint)
        novelMaxView = try container.decodeIfPresent(Int.self, forKey: .novelMaxView).map { max(1, $0) }
        novelDocumentSurfaceProgressPercent = try container.decodeIfPresent(
            Int.self,
            forKey: .novelDocumentSurfaceProgressPercent
        ).map { min(max($0, 0), 100) }
        type = try container.decodeIfPresent(FavoriteType.self, forKey: .type) ?? .unknown
        parentCollectionID = try container.decodeIfPresent(String.self, forKey: .parentCollectionID)
        manualOrder = try container.decodeIfPresent(Int.self, forKey: .manualOrder) ?? 0
        lastReadAt = try container.decodeIfPresent(Date.self, forKey: .lastReadAt)
        tagIDs = try container.decodeIfPresent([String].self, forKey: .tagIDs) ?? []
    }

    private static func decodeThreadID(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        let threadID = try container.decode(String.self, forKey: .threadID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .threadID,
                in: container,
                debugDescription: "Favorite requires threadID"
            )
        }
        return threadID
    }
}

public enum FavoriteType: Int, Codable, CaseIterable, Sendable {
    case unknown = 0
    case novel = 1
    case manga = 2
    case other = 3

    public var title: String {
        switch self {
        case .unknown: L10n.string("favorite_type.unknown")
        case .novel: L10n.string("favorite_type.novel")
        case .manga: L10n.string("favorite_type.manga")
        case .other: L10n.string("favorite_type.other")
        }
    }
}

public enum FavoriteTagColor: String, Codable, CaseIterable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink
    case gray
}

public struct FavoriteTag: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var color: FavoriteTagColor
    public var manualOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
        case manualOrder
        case createdAt
        case updatedAt
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        color: FavoriteTagColor,
        manualOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.manualOrder = manualOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decodeIfPresent(FavoriteTagColor.self, forKey: .color) ?? .gray
        manualOrder = try container.decodeIfPresent(Int.self, forKey: .manualOrder) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }
}
