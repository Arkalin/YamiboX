import Foundation

public enum LikeWorkKind: String, Codable, Hashable, Sendable, CaseIterable {
    case novel
    case manga
}

/// Identifies the work (novel thread or manga title) a Like Item belongs to,
/// independent of Favorite Library membership.
public struct LikeWorkKey: Codable, Hashable, Sendable {
    public var kind: LikeWorkKind
    public var id: String

    public init(kind: LikeWorkKind, id: String) {
        self.kind = kind
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func novel(threadID: String) -> LikeWorkKey {
        LikeWorkKey(kind: .novel, id: threadID)
    }

    public static func mangaTitle(cleanBookName: String) -> LikeWorkKey {
        LikeWorkKey(kind: .manga, id: cleanBookName)
    }

    /// Normal forum threads are not capture sources, so they have no Like
    /// work key. Nor is the per-thread `.mangaThread` reading-progress record
    /// (smart-comic-mode design decision #15): Like work keys for manga are
    /// keyed by the directory's `cleanBookName`, which a bare per-thread
    /// record doesn't carry — only the merged `.mangaTitle` record does.
    public init?(target: FavoriteContentTarget) {
        switch target {
        case let .novelThread(threadID):
            self = .novel(threadID: threadID)
        case let .mangaTitle(_, cleanBookName):
            self = .mangaTitle(cleanBookName: cleanBookName)
        case .normalThread, .mangaThread:
            return nil
        }
    }
}

public enum LikeItemKind: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case image
}

/// A single point in a novel's linear reading flow: the segment it falls in
/// (a `NovelTextSegmentIdentity`-shaped string ending in "#text:N" or
/// "#image:N") plus a character offset within that segment.
public struct NovelLikeTextEndpoint: Hashable, Sendable {
    public var segmentIdentity: String
    public var offset: Int

    public init(segmentIdentity: String, offset: Int) {
        self.segmentIdentity = segmentIdentity
        self.offset = max(0, offset)
    }
}

/// A text excerpt anchor in the persisted Novel Reading Position coordinate
/// space: chapter identity, segment identity, and displayed-text Character
/// offsets, confined to one text segment.
///
/// `view` (the forum page the segment lives on) is stored explicitly rather
/// than recovered from `chapterIdentity`, because most real content is
/// post-keyed (`NovelReaderProjectionBuilder.chapterIdentity` uses
/// `"post:<ownerPostID>#chapter:0"` whenever a post has a non-empty
/// `postID`, which is virtually always), and post-keyed identities embed no
/// page number at all. Guessing a fallback view (e.g. `1`) makes both
/// chapter-title lookups and jump-back navigation silently land on the wrong
/// page for almost every real like.
///
/// `resolvedAuthorID` is stored for the same "don't guess a cache key
/// dimension, record the real one" reason: `NovelReaderProjection` is always
/// cached keyed by `(threadID, view, authorID)`
/// (`NovelReaderProjectionStore.projectionCacheKey`), and — because
/// `NovelReaderProjectionBuilder.build` unconditionally stamps every
/// projection with a real, non-empty author ID — a lookup that omits it
/// (defaulting to the unfiltered/"all" namespace) can never match a real
/// disk-cache entry.
public struct NovelTextLikeAnchor: Codable, Hashable, Sendable {
    public var chapterIdentity: NovelChapterIdentity
    public var textSegmentIdentity: NovelTextSegmentIdentity
    public var range: NovelCharacterRange
    public var view: Int
    public var resolvedAuthorID: String?

    public init(
        chapterIdentity: NovelChapterIdentity,
        textSegmentIdentity: NovelTextSegmentIdentity,
        range: NovelCharacterRange,
        view: Int,
        resolvedAuthorID: String?
    ) {
        self.chapterIdentity = chapterIdentity
        self.textSegmentIdentity = textSegmentIdentity
        self.range = range
        self.view = max(1, view)
        self.resolvedAuthorID = resolvedAuthorID
    }

    var startEndpoint: NovelLikeTextEndpoint {
        NovelLikeTextEndpoint(segmentIdentity: textSegmentIdentity.rawValue, offset: range.location)
    }

    var endEndpoint: NovelLikeTextEndpoint {
        NovelLikeTextEndpoint(segmentIdentity: textSegmentIdentity.rawValue, offset: range.upperBound)
    }
}

/// A novel illustration anchor: images are a single point in the reading flow
/// rather than a Character range, identified by their image segment identity
/// ("<chapterIdentity>#image:N", mirroring `NovelTextSegmentIdentity`'s shape).
/// The source image URL lives on `LikeItem.sourceImageURL`, not here.
///
/// `view`/`resolvedAuthorID` are stored for the same reason as on
/// `NovelTextLikeAnchor` above.
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

/// A manga page image anchor: chapter `tid` plus the page's `localIndex`
/// within that chapter, mirroring `MangaReadingPosition`'s identity fields.
public struct MangaImageLikeAnchor: Codable, Hashable, Sendable {
    public var chapterTID: String
    public var pageLocalIndex: Int
    /// Board fid snapshot from the capturing reader's launch context, so
    /// opening the like can follow the board's *current* 阅读方式 configuration
    /// (pluggable-reader-config R11/R13) instead of assuming the capture-time
    /// mode. `nil` on rows captured before this field existed (and when the
    /// capturing reader itself had no board context): those open with the
    /// pre-R13 behavior — smart mode assumed on.
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

/// One liked excerpt: a text excerpt or an image captured from one owning
/// content target. Independent of Favorite Library membership.
public struct LikeItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var workKey: LikeWorkKey
    public var kind: LikeItemKind
    public var excerptText: String?
    public var sourceImageURL: URL?
    public var anchor: LikeAnchorPayload
    public var createdAt: Date
    public var updatedAt: Date
    /// Soft-delete marker (WebDAV tombstone). `nil` for a live item; set when
    /// the item was deleted locally or by a merged remote snapshot.
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        workKey: LikeWorkKey,
        kind: LikeItemKind,
        excerptText: String? = nil,
        sourceImageURL: URL? = nil,
        anchor: LikeAnchorPayload,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.workKey = workKey
        self.kind = kind
        self.excerptText = excerptText
        self.sourceImageURL = sourceImageURL
        self.anchor = anchor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A work-level row for the My Likes first level: one owning work plus its
/// like count and most recent like activity, used to order the works list.
public struct LikeWorkSummary: Hashable, Sendable {
    public var workKey: LikeWorkKey
    public var itemCount: Int
    public var lastLikedAt: Date

    public init(workKey: LikeWorkKey, itemCount: Int, lastLikedAt: Date) {
        self.workKey = workKey
        self.itemCount = itemCount
        self.lastLikedAt = lastLikedAt
    }
}
