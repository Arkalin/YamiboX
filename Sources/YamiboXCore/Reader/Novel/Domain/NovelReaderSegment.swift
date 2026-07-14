import Foundation

public enum NovelReaderSegment: Hashable, Sendable {
    case text(String, chapterTitle: String?)
    case image(URL, chapterTitle: String?)

    public var chapterTitle: String? {
        switch self {
        case let .text(_, chapterTitle), let .image(_, chapterTitle):
            return chapterTitle
        }
    }
}

extension NovelReaderSegment: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case imageURL
        case chapterTitle
    }

    private enum Kind: String, Codable {
        case text
        case image
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text, chapterTitle):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(chapterTitle, forKey: .chapterTitle)
        case let .image(url, chapterTitle):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(url, forKey: .imageURL)
            try container.encodeIfPresent(chapterTitle, forKey: .chapterTitle)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(
                try container.decode(String.self, forKey: .text),
                chapterTitle: try container.decodeIfPresent(String.self, forKey: .chapterTitle)
            )
        case .image:
            self = .image(
                try container.decode(URL.self, forKey: .imageURL),
                chapterTitle: try container.decodeIfPresent(String.self, forKey: .chapterTitle)
            )
        }
    }
}

public struct NovelReaderSegmentSource: Codable, Hashable, Sendable {
    public var ownerPostID: String?
    public var isAuthorReplyToOther: Bool

    public init(ownerPostID: String? = nil, isAuthorReplyToOther: Bool = false) {
        self.ownerPostID = ownerPostID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.ownerPostID?.isEmpty == true {
            self.ownerPostID = nil
        }
        self.isAuthorReplyToOther = isAuthorReplyToOther
    }
}

public struct NovelChapterIdentity: Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct NovelTextSegmentIdentity: Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct NovelCharacterRange: Codable, Hashable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    public var upperBound: Int {
        location + length
    }
}

public enum NovelInlineTextStyle: String, Codable, Hashable, Sendable {
    case bold
}

public struct NovelInlineTextStyleRange: Codable, Hashable, Sendable {
    public var style: NovelInlineTextStyle
    public var range: NovelCharacterRange

    public init(style: NovelInlineTextStyle, range: NovelCharacterRange) {
        self.style = style
        self.range = range
    }
}

public enum NovelBlockTextStyle: String, Codable, Hashable, Sendable {
    case quote
}

public struct NovelBlockTextStyleRange: Codable, Hashable, Sendable {
    public var style: NovelBlockTextStyle
    public var range: NovelCharacterRange

    public init(style: NovelBlockTextStyle, range: NovelCharacterRange) {
        self.style = style
        self.range = range
    }
}

public struct NovelReaderSegmentSemantics: Codable, Hashable, Sendable {
    public var chapterIdentity: NovelChapterIdentity?
    public var textSegmentIdentity: NovelTextSegmentIdentity?
    public var chapterTitleRange: NovelCharacterRange?
    public var inlineTextStyles: [NovelInlineTextStyleRange]
    public var blockTextStyles: [NovelBlockTextStyleRange]

    public init(
        chapterIdentity: NovelChapterIdentity? = nil,
        textSegmentIdentity: NovelTextSegmentIdentity? = nil,
        chapterTitleRange: NovelCharacterRange? = nil,
        inlineTextStyles: [NovelInlineTextStyleRange] = [],
        blockTextStyles: [NovelBlockTextStyleRange] = []
    ) {
        self.chapterIdentity = chapterIdentity
        self.textSegmentIdentity = textSegmentIdentity
        self.chapterTitleRange = chapterTitleRange
        self.inlineTextStyles = inlineTextStyles
        self.blockTextStyles = blockTextStyles
    }
}
