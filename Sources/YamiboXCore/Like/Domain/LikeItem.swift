import Foundation

public typealias LikeWorkKind = ReadingWorkKind
public typealias LikeWorkKey = ReadingWorkKey

public enum LikeItemKind: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case image
}

public enum LikeStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case yellow
    case green
    case blue
    case pink
    case purple
    case underline

    public static let `default` = LikeStyle.yellow

    public static let colors: [LikeStyle] = [.yellow, .green, .blue, .pink, .purple]

    public var isUnderline: Bool { self == .underline }
}

public struct NovelLikeTextEndpoint: Codable, Hashable, Sendable {
    public var segmentIdentity: String
    public var offset: Int

    public init(segmentIdentity: String, offset: Int) {
        self.segmentIdentity = segmentIdentity
        self.offset = max(0, offset)
    }
}

public struct NovelTextLikeAnchor: Codable, Hashable, Sendable {
    public var chapterIdentity: NovelChapterIdentity
    public var start: NovelLikeTextEndpoint
    public var end: NovelLikeTextEndpoint
    public var view: Int
    public var resolvedAuthorID: String?

    public init(
        chapterIdentity: NovelChapterIdentity,
        start: NovelLikeTextEndpoint,
        end: NovelLikeTextEndpoint,
        view: Int,
        resolvedAuthorID: String?
    ) {
        self.chapterIdentity = chapterIdentity
        self.start = start
        self.end = end
        self.view = max(1, view)
        self.resolvedAuthorID = resolvedAuthorID
    }

    public init(
        chapterIdentity: NovelChapterIdentity,
        textSegmentIdentity: NovelTextSegmentIdentity,
        range: NovelCharacterRange,
        view: Int,
        resolvedAuthorID: String?
    ) {
        self.init(
            chapterIdentity: chapterIdentity,
            start: NovelLikeTextEndpoint(segmentIdentity: textSegmentIdentity.rawValue, offset: range.location),
            end: NovelLikeTextEndpoint(segmentIdentity: textSegmentIdentity.rawValue, offset: range.upperBound),
            view: view,
            resolvedAuthorID: resolvedAuthorID
        )
    }

    public var startSegmentIdentity: NovelTextSegmentIdentity {
        NovelTextSegmentIdentity(rawValue: start.segmentIdentity)
    }

    public var endSegmentIdentity: NovelTextSegmentIdentity {
        NovelTextSegmentIdentity(rawValue: end.segmentIdentity)
    }

    public var spansMultipleSegments: Bool {
        start.segmentIdentity != end.segmentIdentity
    }

    public var singleSegmentRange: NovelCharacterRange? {
        guard !spansMultipleSegments else { return nil }
        return NovelCharacterRange(location: start.offset, length: max(0, end.offset - start.offset))
    }

    var startEndpoint: NovelLikeTextEndpoint { start }

    var endEndpoint: NovelLikeTextEndpoint { end }
}

extension NovelTextLikeAnchor {
    private enum CodingKeys: String, CodingKey {
        case chapterIdentity
        case start
        case end
        case view
        case resolvedAuthorID
        case textSegmentIdentity
        case range
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.chapterIdentity = try container.decode(NovelChapterIdentity.self, forKey: .chapterIdentity)
        self.view = max(1, try container.decode(Int.self, forKey: .view))
        self.resolvedAuthorID = try container.decodeIfPresent(String.self, forKey: .resolvedAuthorID)

        if let start = try container.decodeIfPresent(NovelLikeTextEndpoint.self, forKey: .start),
           let end = try container.decodeIfPresent(NovelLikeTextEndpoint.self, forKey: .end) {
            self.start = start
            self.end = end
            return
        }

        let segment = try container.decode(NovelTextSegmentIdentity.self, forKey: .textSegmentIdentity)
        let range = try container.decode(NovelCharacterRange.self, forKey: .range)
        self.start = NovelLikeTextEndpoint(segmentIdentity: segment.rawValue, offset: range.location)
        self.end = NovelLikeTextEndpoint(segmentIdentity: segment.rawValue, offset: range.upperBound)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chapterIdentity, forKey: .chapterIdentity)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(view, forKey: .view)
        try container.encodeIfPresent(resolvedAuthorID, forKey: .resolvedAuthorID)
        try container.encode(startSegmentIdentity, forKey: .textSegmentIdentity)
        let legacyLength = spansMultipleSegments
            ? 1
            : max(1, end.offset - start.offset)
        try container.encode(
            NovelCharacterRange(location: start.offset, length: legacyLength),
            forKey: .range
        )
    }
}

public struct NovelImageLikeAnchor: Codable, Hashable, Sendable {
    public var chapterIdentity: NovelChapterIdentity
    public var imageSegmentIdentity: String
    public var view: Int
    public var resolvedAuthorID: String?

    public init(
        chapterIdentity: NovelChapterIdentity,
        imageSegmentIdentity: String,
        view: Int,
        resolvedAuthorID: String?
    ) {
        self.chapterIdentity = chapterIdentity
        self.imageSegmentIdentity = imageSegmentIdentity
        self.view = max(1, view)
        self.resolvedAuthorID = resolvedAuthorID
    }
}

public struct MangaImageLikeAnchor: Codable, Hashable, Sendable {
    public var chapterTID: String
    public var pageLocalIndex: Int
    public var forumID: String?

    public init(chapterTID: String, pageLocalIndex: Int, forumID: String? = nil) {
        self.chapterTID = chapterTID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pageLocalIndex = max(0, pageLocalIndex)
        let trimmedForumID = forumID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.forumID = (trimmedForumID?.isEmpty ?? true) ? nil : trimmedForumID
    }
}

public enum LikeAnchorPayload: Codable, Hashable, Sendable {
    case novelText(NovelTextLikeAnchor)
    case novelImage(NovelImageLikeAnchor)
    case mangaImage(MangaImageLikeAnchor)
}

public struct LikeItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var workKey: ReadingWorkKey
    public var kind: LikeItemKind
    public var excerptText: String?
    public var excerptPrefix: String?
    public var excerptSuffix: String?
    public var sourceImageURL: URL?
    public var anchor: LikeAnchorPayload
    public var style: LikeStyle
    public var sortKey: Int64
    public var chapterOrdinal: Int?
    public var note: String?
    public var chapterTitle: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public var hasNote: Bool {
        guard let note else { return false }
        return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        id: String = UUID().uuidString,
        workKey: ReadingWorkKey,
        kind: LikeItemKind,
        excerptText: String? = nil,
        excerptPrefix: String? = nil,
        excerptSuffix: String? = nil,
        sourceImageURL: URL? = nil,
        anchor: LikeAnchorPayload,
        style: LikeStyle = .default,
        note: String? = nil,
        chapterTitle: String? = nil,
        sortKey: Int64 = 0,
        chapterOrdinal: Int? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.workKey = workKey
        self.kind = kind
        self.excerptText = excerptText
        self.excerptPrefix = excerptPrefix
        self.excerptSuffix = excerptSuffix
        self.sourceImageURL = sourceImageURL
        self.anchor = anchor
        self.style = style
        self.note = note
        self.chapterTitle = Self.normalizedChapterTitle(chapterTitle)
        self.sortKey = sortKey
        self.chapterOrdinal = chapterOrdinal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

extension LikeItem {
    private enum CodingKeys: String, CodingKey {
        case id
        case workKey
        case kind
        case excerptText
        case sourceImageURL
        case anchor
        case style
        case note
        case chapterTitle
        case createdAt
        case updatedAt
        case deletedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.workKey = try container.decode(ReadingWorkKey.self, forKey: .workKey)
        self.kind = try container.decode(LikeItemKind.self, forKey: .kind)
        self.excerptText = try container.decodeIfPresent(String.self, forKey: .excerptText)
        self.excerptPrefix = nil
        self.excerptSuffix = nil
        self.sourceImageURL = try container.decodeIfPresent(URL.self, forKey: .sourceImageURL)
        self.anchor = try container.decode(LikeAnchorPayload.self, forKey: .anchor)
        self.style = try container.decodeIfPresent(LikeStyle.self, forKey: .style) ?? .default
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        self.chapterTitle = Self.normalizedChapterTitle(try container.decodeIfPresent(String.self, forKey: .chapterTitle))
        self.sortKey = LikeSortKey.of(self.anchor, chapterOrdinal: nil)
        self.chapterOrdinal = nil
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    static func normalizedChapterTitle(_ value: String?) -> String? {
        guard let title = value?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        return title
    }

    func fillingChapterTitle(from other: LikeItem) -> LikeItem {
        guard workKey == other.workKey, anchor == other.anchor,
              Self.normalizedChapterTitle(chapterTitle) == nil else { return self }
        var filled = self
        filled.chapterTitle = Self.normalizedChapterTitle(other.chapterTitle)
        return filled
    }
}

public struct LikeWorkSummary: Hashable, Sendable {
    public var workKey: ReadingWorkKey
    public var itemCount: Int
    public var lastLikedAt: Date

    public init(workKey: ReadingWorkKey, itemCount: Int, lastLikedAt: Date) {
        self.workKey = workKey
        self.itemCount = itemCount
        self.lastLikedAt = lastLikedAt
    }
}
