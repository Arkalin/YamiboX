import Foundation

public enum LocalFavoriteLibrarySortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case organization
    case contentUpdatedAt
    case yamiboRemoteOrder
    case displayTitle
    case sourceGroup
    case lastReadAt

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .organization:
            L10n.string("favorites.sort.manual")
        case .contentUpdatedAt:
            L10n.string("favorites.sort.updated_at")
        case .yamiboRemoteOrder:
            L10n.string("favorites.sort.remote_order")
        case .displayTitle:
            L10n.string("favorites.sort.title")
        case .sourceGroup:
            L10n.string("favorites.source_group")
        case .lastReadAt:
            L10n.string("favorites.sort.recent_read")
        }
    }
}

/// One choosable source filter: a forum board, or items with an unknown
/// source. Forum boards compare by id only.
public enum LocalFavoriteSourceFilter: Hashable, Sendable {
    case forumBoard(id: String, label: String)
    case unknown

    public static func == (lhs: LocalFavoriteSourceFilter, rhs: LocalFavoriteSourceFilter) -> Bool {
        switch (lhs, rhs) {
        case let (.forumBoard(lhsID, _), .forumBoard(rhsID, _)):
            lhsID == rhsID
        case (.unknown, .unknown):
            true
        default:
            false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .forumBoard(id, _):
            hasher.combine("forumBoard")
            hasher.combine(id)
        case .unknown:
            hasher.combine("unknown")
        }
    }

    public var displayLabel: String {
        switch self {
        case let .forumBoard(id, label):
            label.isEmpty ? id : label
        case .unknown:
            L10n.string("favorites.source_group.unknown")
        }
    }

    /// Canonical filter bucket an item belongs to. `.mangaThread` favorites
    /// have no dedicated bucket (there is no "智能漫画" filter chip) — they
    /// fall through to the same `.forumBoard`/`.unknown` logic as every other
    /// item, regardless of their board's Smart Comic Mode state.
    public static func key(for item: FavoriteItem) -> LocalFavoriteSourceFilter {
        if let forumID = item.forumID ?? item.sourceGroup.forumID {
            return .forumBoard(id: forumID, label: item.forumName ?? item.sourceGroup.forumName ?? forumID)
        }
        return .unknown
    }

    public func matches(_ item: FavoriteItem) -> Bool {
        switch self {
        case let .forumBoard(id, _):
            return item.forumID == id || item.sourceGroup.forumID == id
        case .unknown:
            return LocalFavoriteSourceFilter.key(for: item) == .unknown
        }
    }
}

public struct LocalFavoriteLibraryQuery: Equatable, Sendable {
    public var categoryID: String?
    public var collectionID: String?
    /// Source filters to keep; empty means no source filtering (Android's
    /// forum filter is a multi-select).
    public var selectedSourceFilters: Set<LocalFavoriteSourceFilter>
    public var selectedTagIDs: Set<String>
    public var sortOrder: LocalFavoriteLibrarySortOrder
    public var sortsDescending: Bool
    public var searchText: String
    /// Non-nil only for a smart-comic card's "查看归档收藏" detail page: scopes
    /// the result to every individual mode-on `.mangaThread` favorite whose
    /// own `FavoriteCardProjection.resolvedTitle(item:mangaDirectory:
    /// isModeOnMangaThread:)` matches this value, replacing (not combining
    /// with) the normal category/collection membership filter — see
    /// `LocalFavoriteLibraryProjection.cards(in:query:...)`. Despite the
    /// property's name, this is NOT always a resolved `MangaDirectory`'s
    /// `cleanBookName` — it can equally be a locally-guessed
    /// `MangaTitleCleaner` cleanup for a favorite whose directory hasn't
    /// resolved yet (see `resolvedTitle`'s own doc comment), so a genuinely
    /// solitary favorite with no directory at all can still open its own
    /// correctly-scoped single-item detail page. This is identity-based
    /// (re-resolved fresh on every call), not a frozen snapshot of member
    /// ids, so a newly-favorited chapter of the same manga appears
    /// immediately without reopening the page.
    public var memberScopeCleanBookName: String?

    public init(
        categoryID: String? = nil,
        collectionID: String? = nil,
        selectedSourceFilters: Set<LocalFavoriteSourceFilter> = [],
        selectedTagIDs: Set<String> = [],
        sortOrder: LocalFavoriteLibrarySortOrder = .organization,
        sortsDescending: Bool = false,
        searchText: String = "",
        memberScopeCleanBookName: String? = nil
    ) {
        self.categoryID = categoryID
        self.collectionID = collectionID
        self.selectedSourceFilters = selectedSourceFilters
        self.selectedTagIDs = selectedTagIDs
        self.sortOrder = sortOrder
        self.sortsDescending = sortsDescending
        self.searchText = searchText
        self.memberScopeCleanBookName = memberScopeCleanBookName
    }
}

/// Aggregate stand-ins for the sort fields a collection has no value of its
/// own for, derived from its (filtered) member cards so a collection can be
/// merged into the same ordering as individual favorites.
public struct FavoriteCollectionSortSummary: Equatable, Sendable {
    public var latestUpdatedAt: Date?
    public var latestReadAt: Date?
    public var minRemoteOrder: Int?

    public init(latestUpdatedAt: Date? = nil, latestReadAt: Date? = nil, minRemoteOrder: Int? = nil) {
        self.latestUpdatedAt = latestUpdatedAt
        self.latestReadAt = latestReadAt
        self.minRemoteOrder = minRemoteOrder
    }

    public static func summarizing(_ cards: [FavoriteCardProjection]) -> FavoriteCollectionSortSummary {
        FavoriteCollectionSortSummary(
            latestUpdatedAt: cards.compactMap(\.lastUpdatedAt).max(),
            latestReadAt: cards.compactMap(\.recentReadingAt).max(),
            minRemoteOrder: cards.compactMap { $0.item.remoteMapping?.yamiboRemoteOrder }.min()
        )
    }
}

/// One row of the favorites list/grid once collections and individual
/// favorites are merged into a single ordering.
public enum FavoriteMixedEntry: Equatable, Identifiable, Sendable {
    case collection(LocalFavoriteCollection)
    case card(FavoriteCardProjection)

    public var id: String {
        switch self {
        case let .collection(collection):
            "collection-\(collection.id)"
        case let .card(card):
            "item-\(card.id)"
        }
    }
}

public struct FavoriteCardProjection: Equatable, Identifiable, Sendable {
    public var item: FavoriteItem
    public var sourceGroupLabel: String
    public var collectionNames: [String]
    public var tags: [FavoriteTag]
    public var recentReadingAt: Date?
    public var lastUpdatedAt: Date?
    public var progressPercent: Int?
    public var chapterPageProgress: String?
    public var coverURL: URL?
    /// Whether the user has forced the text placeholder cover for this
    /// target, suppressing `coverURL` even when a real cover resolves.
    public var textCoverForced: Bool

    /// Non-nil only when `item.target` (a `.mangaThread` favorite) resolved
    /// to a `MangaDirectory` — i.e. its board currently has Smart Comic Mode
    /// on (smart-comic-mode decision #5's 2026-07-08 addendum) and the
    /// chapter tid was found in a locally-known directory. Set regardless of
    /// whether any *other* favorite shares this directory yet: it backs the
    /// directory-level ("third level") progress match (decision #14) and is
    /// the identity a later phase's open handler / cover backfill should key
    /// off, independent of `mergedMembers`/`isMergedGroup`.
    ///
    /// `item.title`/`item.displayName` are deliberately left as `item`'s own
    /// (the representative member's real post title) rather than overwritten
    /// with `mangaDirectory?.cleanBookName` — `item` stays a genuine,
    /// individually valid `FavoriteItem` so any single-item affordance that
    /// still reads it directly keeps working. UI that wants the manga's own
    /// title for a resolved-directory card should prefer
    /// `mangaDirectory?.cleanBookName` over `item.resolvedDisplayTitle`.
    public var mangaDirectory: MangaDirectory? = nil

    /// Every `.mangaThread` favorite this card actually merges display for —
    /// non-nil (and always 2+ items) only once at least one *other*
    /// favorite shares `mangaDirectory` with `item`. `item` is always one of
    /// these members (the earliest-chapter one, chosen deterministically —
    /// see `LocalFavoriteLibraryProjection`'s grouping). `nil` here — even
    /// when `mangaDirectory` is set — means this card is still visually a
    /// lone favorite; a merge-badge/unfavorite-all confirmation should gate
    /// on this, not on `mangaDirectory` alone.
    public var mergedMembers: [FavoriteItem]? = nil

    public var isMergedGroup: Bool { mergedMembers != nil }

    /// Whether `item` is a `.mangaThread` favorite AND its board's Smart
    /// Comic Mode is currently on -- set at construction time,
    /// independent of whether `mangaDirectory` has actually been
    /// resolved yet (directory resolution is lazy, only triggered by
    /// actually opening a chapter in the reader; a mode-on favorite
    /// that's never been read has no directory yet, but its board is
    /// still mode-on). Backs `resolvedTitle`'s fallback below.
    public var isModeOnMangaThread: Bool = false

    /// The title to actually display for this card: the shared manga
    /// title once a directory has been resolved (merged or not); else,
    /// for a mode-on manga favorite whose directory just hasn't been
    /// resolved locally yet, a local best-effort
    /// `MangaTitleCleaner.cleanBookName` cleanup of the representative's
    /// own title, computed fresh here rather than baked into the stored
    /// item at sync time -- `FavoriteRemoteSyncSession`'s `.manga`/
    /// `.mangaDirect` cases both store the raw post title verbatim
    /// regardless of mode, precisely so this purely UI-layer cleanup stays
    /// the only place a cleaned title is ever produced, and the archive
    /// detail page can still tell distinct synced chapters apart by their
    /// original titles; else the representative member's own raw post
    /// title. `item.title` itself stays untouched either way (see
    /// `mangaDirectory`'s doc comment above) -- this is purely the
    /// UI-facing title.
    ///
    /// This is also the single source of truth for "does this card get the
    /// smart-card treatment" (sparkles badge; delete blocked in favor of
    /// "查看归档收藏"): every one of those UI gates reads `isModeOnMangaThread`
    /// (not `isMergedGroup`), precisely so a card that displays a cleaned
    /// book name here is never treated as an ordinary card elsewhere — it
    /// either shows the cleaned title AND gets the smart-card treatment, or
    /// shows the raw title and doesn't, never a mix of the two. Selection
    /// itself is NOT gated on this (2026-07-09 feature): a smart card is
    /// selectable and bulk-actionable exactly like any other card, expanded
    /// to every favorite archived under it at execution time (see
    /// `FavoriteLibraryOrganizer.expandedSelectionFavoriteIDs`) — delete is
    /// the one exception, which still requires "查看归档收藏".
    /// `cards(in:query:...)`'s member-scope filter (backing the "查看归档收藏"
    /// detail page) groups by this exact same computation too, via the
    /// static `resolvedTitle(item:mangaDirectory:isModeOnMangaThread:)`
    /// below, so a solitary favorite still on the local-clean fallback lands
    /// on its own correctly-scoped detail page.
    ///
    /// Stored (computed once by `card(for:...)` at construction time) rather
    /// than a computed property — this is compared twice per pair by the
    /// `.displayTitle` sort (`sorted(_:by:descending:)` below), and
    /// `MangaTitleCleaner.cleanBookName`'s regex passes made recomputing it
    /// on every comparison an O(N log N) hot path. See the `static
    /// resolvedTitle(item:mangaDirectory:isModeOnMangaThread:)` function
    /// below for the actual logic — this field just caches its result.
    public var resolvedTitle: String

    /// The shared implementation behind the `resolvedTitle` instance property
    /// above, extracted as a static function so `cards(in:query:...)`'s
    /// member-scope grouping can compute the same effective title for a raw
    /// candidate `FavoriteItem` before any `FavoriteCardProjection` exists to
    /// call the instance property on.
    public static func resolvedTitle(item: FavoriteItem, mangaDirectory: MangaDirectory?, isModeOnMangaThread: Bool) -> String {
        if let mangaDirectory {
            return mangaDirectory.cleanBookName
        }
        guard isModeOnMangaThread else {
            return item.resolvedDisplayTitle
        }
        let cleaned = MangaTitleCleaner.cleanBookName(item.resolvedDisplayTitle)
        return cleaned.isEmpty ? item.resolvedDisplayTitle : cleaned
    }

    /// The `content_cover` key this card's displayed cover reads AND every
    /// card-level cover action writes — the single authority keeping the two
    /// sides on the same row. A resolved-directory card (merged or a lone
    /// resolved favorite alike) uses the directory's shared
    /// `.smartManga(cleanBookName:)` key (smart-comic-mode decision #13/#16);
    /// every other card — normal/novel threads, mode-off manga favorites,
    /// mode-on ones with no locally-resolved directory yet, and the
    /// "查看归档收藏" page's deliberately non-smart member cards
    /// (`mangaDirectory` forced nil there) — uses its own per-favorite
    /// `.thread(tid:)` key. Deriving a card's cover reads or writes from
    /// anything else (e.g. `ContentCoverKey(target: item.target)` directly,
    /// which can only ever produce `.thread`) is how a smart card's
    /// text-cover toggle once wrote a row its own display never read.
    public var contentCoverKey: ContentCoverKey? {
        if let mangaDirectory {
            return .smartManga(cleanBookName: mangaDirectory.cleanBookName)
        }
        return ContentCoverKey(target: item.target)
    }

    /// Deliberately still `item.id` — the representative member's own real
    /// id — even for a merged card, *not* a synthetic directory-based id.
    /// The existing (unmodified by this phase) selection/bulk-action UI
    /// already reads `card.id` as a real `FavoriteItem.id` to look items up
    /// in `document.items` (`LocalFavoriteGridCard`/`LocalFavoriteListContent`
    /// pass `card.id` straight into `selection.toggleFavoriteSelection`,
    /// and `FavoriteLibraryOrganizer`'s bulk actions filter
    /// `document.items` by `favoriteIDs.contains($0.id)`) — a made-up id
    /// with no matching item would make a merged card's selection silently
    /// unpickable (pruned by `LocalFavoriteBrowseSession.prune` on the very
    /// next derive, since it'd never appear in `validFavoriteIDs`) with no
    /// corresponding Phase F work having happened yet to handle that. The
    /// cost is that this id can change if a new, earlier-chapter favorite
    /// later joins the group and displaces the current representative
    /// member — an occasional SwiftUI identity churn, not a correctness bug.
    public var id: String { item.id }
}

/// One `MangaDirectory` with every mode-on `.mangaThread` favorite currently
/// resolved to it — the same grouping `FavoriteCardProjection`'s merged
/// cards are built from, exposed standalone for callers (cover backfill)
/// that need the raw group rather than a display card.
public struct MangaDirectoryFavoriteGroup: Equatable, Sendable {
    public var directory: MangaDirectory
    /// Ordered to match `directory.chapters` (earliest first); `.first` is
    /// the earliest-chapter favorite, used as the cover-backfill anchor.
    public var members: [FavoriteItem]
}
