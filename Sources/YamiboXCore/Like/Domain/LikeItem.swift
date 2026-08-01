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

/// How a text Like Item paints over the body text.
///
/// Deliberately one mutually-exclusive enum rather than "a colour plus an
/// underline switch": changing style is the highest-frequency second action on
/// an annotation, and an exclusive model needs only a single row of dots to
/// change it, whereas an orthogonal model needs a two-dimensional control for
/// an expressiveness nobody asked for. Underline is a member here for the same
/// reason Apple Books makes it one.
///
/// `kind == .image` ignores this entirely — an image has no text to tint, and
/// borrowing the highlight palette as an image "tag" would blur what a colour
/// means.
public enum LikeStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case yellow
    case green
    case blue
    case pink
    case purple
    case underline

    /// Every pre-existing Like Item becomes this: the app only ever painted
    /// highlights in yellow before styles existed, so the migration is
    /// lossless by construction.
    public static let `default` = LikeStyle.yellow

    /// The colours, in the order the style capsule lays them out. Underline is
    /// not one of them — it is the seventh slot, past the divider.
    public static let colors: [LikeStyle] = [.yellow, .green, .blue, .pink, .purple]

    public var isUnderline: Bool { self == .underline }
}

/// A single point in a novel's linear reading flow: the segment it falls in
/// (a `NovelTextSegmentIdentity`-shaped string ending in "#text:N" or
/// "#image:N") plus a character offset within that segment.
public struct NovelLikeTextEndpoint: Codable, Hashable, Sendable {
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
/// Stored as two endpoints rather than one segment plus a character range, so
/// an annotation can span the illustration that splits one run of body text
/// into two segments. The TextKit layer needs nothing for this: the whole
/// projection is one contiguous document, and segments are only windows into
/// it — the single-segment restriction lived entirely in this type and the two
/// capture guards above it.
///
/// Both endpoints must sit in the same chapter; that is enforced at capture
/// time, not here, because nothing below this layer cares.
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

    /// Single-segment convenience — still the shape of almost every real
    /// annotation, and the shape every stored row had before this type gained
    /// a second endpoint.
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

    /// The character range, defined only while the annotation stays inside one
    /// segment. Callers that must work for spanning annotations use the two
    /// endpoints directly.
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
        // Pre-endpoint shape, still present in every row written before this
        // change and in every payload an old client re-exports.
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

        // Legacy row: one segment plus a range. Decoded rather than migrated in
        // SQL because the anchor is an opaque JSON blob to the store.
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
        // A client that predates endpoints reads these and nothing else, so a
        // single-segment annotation keeps round-tripping through it unharmed.
        //
        // A spanning one cannot be represented there at all: the two offsets
        // index different segments, so their difference is meaningless (and
        // usually negative, since a start deep in segment N is exactly what
        // makes a range spill into N+1). Omitting the keys is worse than a bad
        // length — an old client's decode requires both, so the whole payload
        // would fail. So it degrades to a minimum-length highlight anchored at
        // the correct start: visible, obviously truncated, and re-doable.
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
    /// The un-highlighted head of the clause the excerpt starts inside, so a
    /// list row can render "大概**有一二百人吧**…" the way Apple Books does
    /// instead of starting mid-thought at the highlight boundary.
    ///
    /// Local state, like `sortKey`: excluded from the WebDAV payload because it
    /// is derived from `anchor` plus chapter text this device sliced at capture
    /// time — a value from another device describes text this one can re-derive
    /// whenever it lays the chapter out. `nil` on items captured before the
    /// field existed (or synced in), which renders as "no context", never
    /// wrongly.
    public var excerptPrefix: String?
    /// The tail of the clause the excerpt ends inside — same contract as
    /// `excerptPrefix`, for the other end.
    public var excerptSuffix: String?
    public var sourceImageURL: URL?
    public var anchor: LikeAnchorPayload
    /// How this item paints over the text. Ignored for `kind == .image`.
    public var style: LikeStyle
    /// Book-order key, derived from `anchor` (and, once a reader session has
    /// resolved it, `chapterOrdinal`). Local state: excluded from the WebDAV
    /// payload because every device recomputes it from the anchor it already
    /// has, and the chapter ordinal is only knowable on a device that has laid
    /// the page out.
    public var sortKey: Int64
    /// The annotation's chapter position within its forum page, once known.
    /// nil until a reader session resolves it — until then the key still orders
    /// correctly except among several posts sharing one page.
    public var chapterOrdinal: Int?
    /// The user's note, if they wrote one.
    ///
    /// A field rather than its own table: a note cannot exist without the
    /// annotation it annotates, and one note per annotation keeps "does this
    /// have a note" a single predicate that the body-text badge, the list row
    /// and the panel filter can all share. Both text and image Like Items can
    /// carry one — "this page's art is off" is as real a note as a comment on a
    /// sentence.
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Soft-delete marker (WebDAV tombstone). `nil` for a live item; set when
    /// the item was deleted locally or by a merged remote snapshot.
    public var deletedAt: Date?

    /// True when the item carries a note worth showing. Whitespace-only notes
    /// are treated as absent so clearing the editor really removes the note.
    public var hasNote: Bool {
        guard let note else { return false }
        return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        id: String = UUID().uuidString,
        workKey: LikeWorkKey,
        kind: LikeItemKind,
        excerptText: String? = nil,
        excerptPrefix: String? = nil,
        excerptSuffix: String? = nil,
        sourceImageURL: URL? = nil,
        anchor: LikeAnchorPayload,
        style: LikeStyle = .default,
        note: String? = nil,
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
        case createdAt
        case updatedAt
        case deletedAt
    }

    /// Hand-written so fields added after the WebDAV payload shipped decode
    /// with a default instead of failing the whole payload. The Like Library
    /// payload version is deliberately NOT bumped for additive fields (an old
    /// client must keep syncing), which only works if both directions tolerate
    /// a missing key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.workKey = try container.decode(LikeWorkKey.self, forKey: .workKey)
        self.kind = try container.decode(LikeItemKind.self, forKey: .kind)
        self.excerptText = try container.decodeIfPresent(String.self, forKey: .excerptText)
        // Local-only, like `sortKey` below: never on the wire, and unlike the
        // sort key not recomputable here — the reader backfills them when it
        // next lays the chapter out with this item on it.
        self.excerptPrefix = nil
        self.excerptSuffix = nil
        self.sourceImageURL = try container.decodeIfPresent(URL.self, forKey: .sourceImageURL)
        self.anchor = try container.decode(LikeAnchorPayload.self, forKey: .anchor)
        self.style = try container.decodeIfPresent(LikeStyle.self, forKey: .style) ?? .default
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        // Derived locally from `anchor`; a value arriving over the wire would
        // be another device's, computed against a page this one may never have
        // laid out.
        self.sortKey = LikeSortKey.of(self.anchor, chapterOrdinal: nil)
        self.chapterOrdinal = nil
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
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
