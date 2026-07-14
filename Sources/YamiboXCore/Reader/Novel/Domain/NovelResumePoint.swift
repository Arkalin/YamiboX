import Foundation

public struct NovelResumePoint: Codable, Hashable, Sendable {
    public static let schemaVersion = 3

    public var view: Int
    public var chapterIdentity: NovelChapterIdentity?
    public var textSegmentIdentity: NovelTextSegmentIdentity?
    public var displayedTextOffset: Int
    public var chapterOrdinal: Int
    public var chapterTitle: String?
    public var segmentProgress: Double
    public var authorID: String?
    public var readingModeHint: ReaderReadingMode

    public init(
        view: Int,
        chapterIdentity: NovelChapterIdentity? = nil,
        textSegmentIdentity: NovelTextSegmentIdentity? = nil,
        displayedTextOffset: Int,
        chapterOrdinal: Int,
        chapterTitle: String? = nil,
        segmentProgress: Double,
        authorID: String? = nil,
        readingModeHint: ReaderReadingMode
    ) {
        self.view = max(1, view)
        self.chapterIdentity = chapterIdentity
        self.textSegmentIdentity = textSegmentIdentity
        self.displayedTextOffset = max(0, displayedTextOffset)
        self.chapterOrdinal = max(0, chapterOrdinal)
        self.chapterTitle = chapterTitle
        self.segmentProgress = min(max(segmentProgress, 0), 1)
        self.authorID = authorID
        self.readingModeHint = readingModeHint
    }
}

extension NovelResumePoint {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case view
        case chapterIdentity
        case textSegmentIdentity
        case displayedTextOffset
        case chapterOrdinal
        case chapterTitle
        case segmentProgress
        case authorID
        case readingModeHint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [CodingKeys.schemaVersion],
                    debugDescription: "Unsupported novel resume point schema version \(schemaVersion)."
                )
            )
        }
        self.init(
            view: try container.decode(Int.self, forKey: .view),
            chapterIdentity: try container.decodeIfPresent(NovelChapterIdentity.self, forKey: .chapterIdentity),
            textSegmentIdentity: try container.decodeIfPresent(NovelTextSegmentIdentity.self, forKey: .textSegmentIdentity),
            displayedTextOffset: try container.decode(Int.self, forKey: .displayedTextOffset),
            chapterOrdinal: try container.decode(Int.self, forKey: .chapterOrdinal),
            chapterTitle: try container.decodeIfPresent(String.self, forKey: .chapterTitle),
            segmentProgress: try container.decode(Double.self, forKey: .segmentProgress),
            authorID: try container.decodeIfPresent(String.self, forKey: .authorID),
            readingModeHint: try container.decode(ReaderReadingMode.self, forKey: .readingModeHint)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(view, forKey: .view)
        try container.encodeIfPresent(chapterIdentity, forKey: .chapterIdentity)
        try container.encodeIfPresent(textSegmentIdentity, forKey: .textSegmentIdentity)
        try container.encode(displayedTextOffset, forKey: .displayedTextOffset)
        try container.encode(chapterOrdinal, forKey: .chapterOrdinal)
        try container.encodeIfPresent(chapterTitle, forKey: .chapterTitle)
        try container.encode(segmentProgress, forKey: .segmentProgress)
        try container.encodeIfPresent(authorID, forKey: .authorID)
        try container.encode(readingModeHint, forKey: .readingModeHint)
    }
}
