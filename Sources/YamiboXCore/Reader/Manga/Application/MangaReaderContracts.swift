import Foundation

public enum MangaLaunchSource: String, Codable, Hashable, Sendable {
    case forum
    case favorites
    case resume
    case like
    case history
    case home
}

public struct MangaLaunchContext: Hashable, Identifiable, Sendable {
    public var originalThreadID: String
    public var chapterTID: String
    public var chapterView: Int
    public var displayTitle: String
    public var source: MangaLaunchSource
    public var initialPage: Int
    public var directoryName: String?
    public var directoryID: MangaDirectoryID?
    public var downloadFavoriteID: String?
    public var isPreview: Bool
    public var isSmartModeEnabled: Bool
    public var forumID: String?

    public var id: String {
        originalThreadID
    }

    public init(
        originalThreadID: String,
        chapterTID: String,
        displayTitle: String,
        source: MangaLaunchSource,
        chapterView: Int = 1,
        initialPage: Int = 0,
        directoryName: String? = nil,
        directoryID: MangaDirectoryID? = nil,
        downloadFavoriteID: String? = nil,
        isPreview: Bool = false,
        isSmartModeEnabled: Bool = true,
        forumID: String? = nil
    ) {
        self.originalThreadID = Self.normalizedThreadID(originalThreadID, field: "originalThreadID")
        self.chapterTID = Self.normalizedThreadID(chapterTID, field: "chapterTID")
        self.chapterView = max(1, chapterView)
        self.displayTitle = displayTitle
        self.source = source
        self.initialPage = max(0, initialPage)
        self.directoryName = directoryName
        self.directoryID = directoryID
        self.downloadFavoriteID = downloadFavoriteID?.nilIfBlank
        self.isPreview = isPreview
        self.isSmartModeEnabled = isSmartModeEnabled
        self.forumID = forumID?.nilIfBlank
    }

    private static func normalizedThreadID(_ value: String, field: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalized.isEmpty, "MangaLaunchContext requires \(field)")
        return normalized
    }
}

extension MangaLaunchContext: Codable {
    private enum CodingKeys: String, CodingKey {
        case originalThreadID
        case chapterTID
        case chapterView
        case displayTitle
        case source
        case initialPage
        case directoryName
        case directoryID
        case downloadFavoriteID
        case isPreview
        case isSmartModeEnabled
        case forumID
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originalThreadID, forKey: .originalThreadID)
        try container.encode(chapterTID, forKey: .chapterTID)
        try container.encode(chapterView, forKey: .chapterView)
        try container.encode(displayTitle, forKey: .displayTitle)
        try container.encode(source, forKey: .source)
        try container.encode(initialPage, forKey: .initialPage)
        try container.encodeIfPresent(directoryName, forKey: .directoryName)
        try container.encodeIfPresent(directoryID, forKey: .directoryID)
        try container.encodeIfPresent(downloadFavoriteID, forKey: .downloadFavoriteID)
        try container.encode(isPreview, forKey: .isPreview)
        try container.encode(isSmartModeEnabled, forKey: .isSmartModeEnabled)
        try container.encodeIfPresent(forumID, forKey: .forumID)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            originalThreadID: try container.decode(String.self, forKey: .originalThreadID),
            chapterTID: try container.decode(String.self, forKey: .chapterTID),
            displayTitle: try container.decode(String.self, forKey: .displayTitle),
            source: try container.decode(MangaLaunchSource.self, forKey: .source),
            chapterView: try container.decodeIfPresent(Int.self, forKey: .chapterView) ?? 1,
            initialPage: try container.decodeIfPresent(Int.self, forKey: .initialPage) ?? 0,
            directoryName: try container.decodeIfPresent(String.self, forKey: .directoryName),
            directoryID: try container.decodeIfPresent(MangaDirectoryID.self, forKey: .directoryID),
            downloadFavoriteID: try container.decodeIfPresent(String.self, forKey: .downloadFavoriteID),
            isPreview: try container.decodeIfPresent(Bool.self, forKey: .isPreview) ?? false,
            isSmartModeEnabled: try container.decodeIfPresent(Bool.self, forKey: .isSmartModeEnabled) ?? true,
            forumID: try container.decodeIfPresent(String.self, forKey: .forumID)
        )
    }
}
