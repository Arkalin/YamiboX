import Foundation

public enum BrowsingHistoryCategory: String, Codable, CaseIterable, Sendable {
    case normal
    case novel
    case manga
}

public struct BrowsingHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public var target: FavoriteContentTarget
    public var title: String
    public var forumID: String?
    public var authorID: String?
    /// Raw reader position: 1-based page for normal threads, 0-based page
    /// index within the current chapter for manga. Presentation normalizes.
    public var pageIndex: Int?
    public var pageCount: Int?
    public var chapterTitle: String?
    /// Directory-level (`.mangaTitle`) rows only: the chapter thread the row
    /// currently points at. Used for a new favorite's chapter anchor and
    /// mode-off routing, not the existing work's favorite membership.
    public var chapterThreadID: String?
    public var lastVisitTime: Date
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
        nilIfBlank
    }
}
