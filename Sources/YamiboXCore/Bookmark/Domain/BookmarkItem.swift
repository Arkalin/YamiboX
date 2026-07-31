import Foundation

/// A novel bookmark anchor in the same coordinate space as
/// `NovelResumePoint`: the position the viewport was showing when the user
/// tapped the bookmark button.
///
/// `chapterOrdinal` is stored (unlike `NovelTextLikeAnchor`, which omits it)
/// because bookmarks are ordered by a persisted `sortKey` computed at capture
/// time, and the directory ordinal is what disambiguates two posts sharing one
/// forum page. `view` and `resolvedAuthorID` are stored for the same reasons
/// `NovelTextLikeAnchor` documents: post-keyed chapter identities embed no page
/// number, and the projection disk cache is keyed by `(threadID, view,
/// authorID)`.
///
/// `chapterTitle` is a display snapshot for the bookmark list, captured
/// alongside the anchor so the list renders without a projection in hand.
public struct NovelBookmarkAnchor: Codable, Hashable, Sendable {
    /// Character radius within which an existing bookmark counts as "the same
    /// place" for the reader's toggle. Deliberately small: the agreed rule is
    /// "only the position tapping the button would land on right now counts as
    /// already-bookmarked", so scrolling away flips the button back to
    /// unmarked. Erring small can leave two adjacent bookmarks — visible and
    /// deletable in the panel — while erring large silently deletes a bookmark
    /// the user cannot see (nothing is drawn in the body text).
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

    /// True when `other` marks the same place this anchor would mark, under
    /// the toggle rule documented on `neighborhoodCharacterRadius`.
    public func marksSamePlace(as other: NovelBookmarkAnchor) -> Bool {
        guard chapterIdentity == other.chapterIdentity,
              textSegmentIdentity == other.textSegmentIdentity else {
            return false
        }
        return abs(displayedTextOffset - other.displayedTextOffset) <= Self.neighborhoodCharacterRadius
    }
}

/// A manga bookmark anchor: chapter `tid` plus the page's `localIndex`,
/// mirroring `MangaImageLikeAnchor`. Manga pages are discrete, so "the same
/// place" is exact page equality — no neighborhood radius is needed.
///
/// `forumID` carries the capturing reader's board context so opening the
/// bookmark can follow the board's *current* 阅读方式 configuration, exactly as
/// `MangaImageLikeAnchor.forumID` does.
public struct MangaBookmarkAnchor: Codable, Hashable, Sendable {
    public var chapterTID: String
    public var pageLocalIndex: Int
    /// The page's index across the whole work, straight off
    /// `MangaReaderPageProjection.globalIndex`. Manga needs no composite sort
    /// key the way novels do — this single number already *is* reading order.
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

/// A single user-placed position marker inside one work.
///
/// A bookmark is deliberately *not* a Like Item: it carries no content, its
/// upsert is an idempotent toggle keyed by position (one bookmark per place)
/// rather than "append, merging overlaps", and it stores no image bytes. It
/// also has nothing to do with the automatically-saved reading position —
/// closing a work always restores where you were, bookmarks exist only for
/// places the user chose to come back to.
///
/// `workKey` reuses `LikeWorkKey`: that type is already the app's work-identity
/// value (novel thread id / manga clean book name), independent of the Like
/// feature it is named after.
public struct BookmarkItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var workKey: LikeWorkKey
    public var anchor: BookmarkAnchorPayload
    /// Body-text snapshot taken at capture time (novels only; nil for manga,
    /// whose rows show 话名 + 页码 instead). Two purposes: the panel row needs
    /// something that distinguishes several bookmarks inside one chapter — a
    /// reflow reader has no stable page number to show — and the text doubles
    /// as a re-anchor fallback when the thread is edited and the stored
    /// offsets no longer land where they did.
    public var excerptText: String?
    /// Persisted linear position used for "book order" sorting, so the panel
    /// (and any cross-device list) never has to have a projection in hand to
    /// order rows. Mirrors what Apple Books stores as
    /// `ZPLLOCATIONRANGESTART`.
    public var sortKey: Int64
    public var createdAt: Date
    public var updatedAt: Date
    /// Soft-delete marker (WebDAV tombstone), same contract as
    /// `LikeItem.deletedAt`: deleting locally must not physically remove the
    /// row, or merging with a stale remote snapshot would resurrect it.
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        workKey: LikeWorkKey,
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
