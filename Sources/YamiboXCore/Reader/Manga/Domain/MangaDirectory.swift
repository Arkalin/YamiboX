import Foundation

public enum MangaDirectoryStrategy: String, Codable, Hashable, Sendable {
    case tag
    case links
    case pendingSearch
    case searched
}

public struct MangaDirectory: Codable, Hashable, Sendable, Identifiable {
    public let id: MangaDirectoryID
    public var cleanBookName: String
    public var strategy: MangaDirectoryStrategy
    public var sourceKey: String
    public var chapters: [MangaChapter]
    public var lastUpdatedAt: Date?
    public var searchKeyword: String?

    public var favoriteIdentity: String { id.rawValue }

    /// Historical progress key, retained exclusively for the one-way importer.
    var legacyFavoriteIdentity: String {
        let normalizedSourceKey = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedSourceKey.isEmpty, normalizedSourceKey != cleanBookName {
            return "\(strategy.rawValue):\(normalizedSourceKey)"
        }
        if let firstTID = chapters.first?.tid.trimmingCharacters(in: .whitespacesAndNewlines), !firstTID.isEmpty {
            return "chapter:\(firstTID)"
        }
        return cleanBookName
    }

    public init(
        id: MangaDirectoryID = MangaDirectoryID(),
        cleanBookName: String,
        strategy: MangaDirectoryStrategy,
        sourceKey: String,
        chapters: [MangaChapter] = [],
        lastUpdatedAt: Date? = nil,
        searchKeyword: String? = nil
    ) {
        self.id = id
        self.cleanBookName = cleanBookName
        self.strategy = strategy
        self.sourceKey = sourceKey
        self.chapters = chapters
        self.lastUpdatedAt = lastUpdatedAt
        self.searchKeyword = searchKeyword
    }

    private enum CodingKeys: String, CodingKey {
        case id, cleanBookName, strategy, sourceKey, chapters, lastUpdatedAt, searchKeyword
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .cleanBookName)
        self.init(
            id: try values.decodeIfPresent(MangaDirectoryID.self, forKey: .id) ?? .legacy(name: name),
            cleanBookName: name,
            strategy: try values.decode(MangaDirectoryStrategy.self, forKey: .strategy),
            sourceKey: try values.decode(String.self, forKey: .sourceKey),
            chapters: try values.decode([MangaChapter].self, forKey: .chapters),
            lastUpdatedAt: try values.decodeIfPresent(Date.self, forKey: .lastUpdatedAt),
            searchKeyword: try values.decodeIfPresent(String.self, forKey: .searchKeyword)
        )
    }

    func reidentified(as id: MangaDirectoryID) -> Self {
        Self(id: id, cleanBookName: cleanBookName, strategy: strategy, sourceKey: sourceKey,
             chapters: chapters, lastUpdatedAt: lastUpdatedAt, searchKeyword: searchKeyword)
    }
}

/// Lightweight per-directory listing used by the settings storage-management
/// screen — chapter count instead of every chapter's full metadata.
public struct MangaDirectorySummary: Identifiable, Hashable, Sendable {
    public let id: MangaDirectoryID
    public var cleanBookName: String
    public var strategy: MangaDirectoryStrategy
    public var chapterCount: Int
    public var lastUpdatedAt: Date?

    public init(
        id: MangaDirectoryID,
        cleanBookName: String,
        strategy: MangaDirectoryStrategy,
        chapterCount: Int,
        lastUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.cleanBookName = cleanBookName
        self.strategy = strategy
        self.chapterCount = chapterCount
        self.lastUpdatedAt = lastUpdatedAt
    }
}
