import Foundation

public struct NovelBookmarkAnchor: Codable, Hashable, Sendable {
    public static let neighborhoodCharacterRadius = 40

    public var chapterIdentity: NovelChapterIdentity?
    public var textSegmentIdentity: NovelTextSegmentIdentity?
    public var displayedTextOffset: Int
    public var view: Int
    public var chapterOrdinal: Int
    public var chapterTitle: String?
    public var resolvedAuthorID: String?

    public init(
        chapterIdentity: NovelChapterIdentity?,
        textSegmentIdentity: NovelTextSegmentIdentity?,
        displayedTextOffset: Int,
        view: Int,
        chapterOrdinal: Int,
        chapterTitle: String? = nil,
        resolvedAuthorID: String? = nil
    ) {
        self.chapterIdentity = chapterIdentity
        self.textSegmentIdentity = textSegmentIdentity
        self.displayedTextOffset = max(0, displayedTextOffset)
        self.view = max(1, view)
        self.chapterOrdinal = max(0, chapterOrdinal)
        self.chapterTitle = chapterTitle
        self.resolvedAuthorID = resolvedAuthorID
    }

    public func marksSamePlace(as other: NovelBookmarkAnchor) -> Bool {
        guard chapterIdentity == other.chapterIdentity,
              textSegmentIdentity == other.textSegmentIdentity else {
            return false
        }
        return abs(displayedTextOffset - other.displayedTextOffset) <= Self.neighborhoodCharacterRadius
    }
}

public struct MangaBookmarkAnchor: Codable, Hashable, Sendable {
    public var chapterTID: String
    public var pageLocalIndex: Int
    public var globalPageIndex: Int
    public var chapterTitle: String?
    public var forumID: String?

    public init(
        chapterTID: String,
        pageLocalIndex: Int,
        globalPageIndex: Int,
        chapterTitle: String? = nil,
        forumID: String? = nil
    ) {
        self.chapterTID = chapterTID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pageLocalIndex = max(0, pageLocalIndex)
        self.globalPageIndex = max(0, globalPageIndex)
        self.chapterTitle = chapterTitle
        let trimmedForumID = forumID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.forumID = (trimmedForumID?.isEmpty ?? true) ? nil : trimmedForumID
    }

    public func marksSamePlace(as other: MangaBookmarkAnchor) -> Bool {
        chapterTID == other.chapterTID && pageLocalIndex == other.pageLocalIndex
    }
}

public enum BookmarkAnchorPayload: Codable, Hashable, Sendable {
    case novel(NovelBookmarkAnchor)
    case manga(MangaBookmarkAnchor)

    public func marksSamePlace(as other: BookmarkAnchorPayload) -> Bool {
        switch (self, other) {
        case let (.novel(lhs), .novel(rhs)):
            lhs.marksSamePlace(as: rhs)
        case let (.manga(lhs), .manga(rhs)):
            lhs.marksSamePlace(as: rhs)
        default:
            false
        }
    }
}

public struct BookmarkItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var workKey: ReadingWorkKey
    public var anchor: BookmarkAnchorPayload
    public var excerptText: String?
    public var sortKey: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        workKey: ReadingWorkKey,
        anchor: BookmarkAnchorPayload,
        excerptText: String? = nil,
        sortKey: Int64 = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.workKey = workKey
        self.anchor = anchor
        self.excerptText = excerptText
        self.sortKey = sortKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
