import Foundation

/// Coarse content category for the history page's filter chips. Both manga
/// identities (`.mangaThread` single-thread rows and `.mangaTitle`
/// directory-level rows) collapse into `.manga` — the chip filters by what
/// the user read, not by how the row is keyed.
public enum BrowsingHistoryCategory: String, Codable, CaseIterable, Sendable {
    case normal
    case novel
    case manga
}

/// One row of the browsing-history timeline (`browsing_history` table).
///
/// Display-only by design (browsing-history decision #4): the row carries
/// everything the history page needs to render offline (title, position
/// text, timestamps), but resume positions live in `reading_progress` —
/// deleting a history row never touches resume state.
///
/// Identity follows the board's configured reader, not the reader used for
/// the visit. Smart manga uses its confirmed directory identity; other
/// modes use one identity per thread.
public struct BrowsingHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public var target: FavoriteContentTarget
    public var title: String
    public var forumID: String?
    public var authorID: String?
    /// Raw reader position: 1-based page for normal threads, 0-based page
    /// index within the current chapter for manga. Presentation normalizes.
    public var pageIndex: Int?
    public var pageCount: Int?
    /// Novel: last-read chapter title. Manga: current chapter title.
    public var chapterTitle: String?
    /// Directory-level (`.mangaTitle`) rows only: the chapter thread the row
    /// currently points at — the favorite heart acts on it (decision #11)
    /// and mode-off click routing opens it (PRD implementation notes).
    public var chapterThreadID: String?
    public var lastVisitTime: Date
    /// Actual browsing source, independent of the canonical reader's resume position.
    public var lastVisitedThreadID: String?
    public var lastVisitedThreadTitle: String?

    public var id: String { target.id }

    public var category: BrowsingHistoryCategory {
        switch target.kind {
        case .normalThread:
            .normal
        case .novelThread:
            .novel
        case .mangaTitle, .mangaThread:
            .manga
        }
    }

    /// Known but unconfigured boards use the plain reader. Only unknown
    /// board ownership falls back to the stored identity.
    public func category(boardReader: BoardReaderSettings) -> BrowsingHistoryCategory {
        switch boardReader.entry(forumID: forumID)?.mode {
        case .normal:
            .normal
        case .novel:
            .novel
        case .manga:
            .manga
        case nil:
            forumID == nil ? category : .normal
        }
    }

    public init(
        target: FavoriteContentTarget,
        title: String,
        forumID: String? = nil,
        authorID: String? = nil,
        pageIndex: Int? = nil,
        pageCount: Int? = nil,
        chapterTitle: String? = nil,
        chapterThreadID: String? = nil,
        lastVisitTime: Date = .now,
        lastVisitedThreadID: String? = nil,
        lastVisitedThreadTitle: String? = nil
    ) {
        self.target = target
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmedTitle.isEmpty ? (target.threadID ?? target.mangaCleanBookName ?? target.id) : trimmedTitle
        self.forumID = forumID?.browsingHistoryTrimmedNonEmpty
        self.authorID = authorID?.browsingHistoryTrimmedNonEmpty
        self.pageIndex = pageIndex.map { max(0, $0) }
        self.pageCount = pageCount.map { max(1, $0) }
        self.chapterTitle = chapterTitle?.browsingHistoryTrimmedNonEmpty
        self.chapterThreadID = chapterThreadID?.browsingHistoryTrimmedNonEmpty
        self.lastVisitTime = lastVisitTime
        self.lastVisitedThreadID = lastVisitedThreadID?.browsingHistoryTrimmedNonEmpty ?? target.threadID ?? self.chapterThreadID
        self.lastVisitedThreadTitle = lastVisitedThreadTitle?.browsingHistoryTrimmedNonEmpty ?? self.title
    }
}

extension String {
    var browsingHistoryTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
