import Foundation

public enum ReadingProgressKind: String, Codable, Hashable, Sendable {
    case novel
    case manga
    /// Normal forum threads (browsing-history decisions #6/#7): page +
    /// floor-level anchor, restored on every entrance (decision #8).
    case thread
}

public struct ThreadReadingProgressRecord: Codable, Hashable, Sendable {
    public var lastPage: Int
    public var pageCount: Int?
    /// Topmost visible post id when the reader last saved — the floor-level
    /// half of the resume position (the page is the coarse half).
    public var anchorPostID: String?

    public init(lastPage: Int = 1, pageCount: Int? = nil, anchorPostID: String? = nil) {
        self.lastPage = max(1, lastPage)
        self.pageCount = pageCount.map { max(1, $0) }
        let trimmedAnchor = anchorPostID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.anchorPostID = trimmedAnchor.isEmpty ? nil : trimmedAnchor
    }
}

public struct NovelReadingProgressRecord: Codable, Hashable, Sendable {
    public var lastView: Int
    public var lastChapter: String?
    public var authorID: String?
    public var novelResumePoint: NovelResumePoint?
    public var novelMaxView: Int?
    public var novelDocumentSurfaceProgressPercent: Int?

    public init(
        lastView: Int = 1,
        lastChapter: String? = nil,
        authorID: String? = nil,
        novelResumePoint: NovelResumePoint? = nil,
        novelMaxView: Int? = nil,
        novelDocumentSurfaceProgressPercent: Int? = nil
    ) {
        let resolvedView = max(1, novelResumePoint?.view ?? lastView)
        self.lastView = resolvedView
        self.lastChapter = novelResumePoint?.chapterTitle ?? lastChapter
        self.authorID = novelResumePoint?.authorID ?? authorID
        self.novelResumePoint = novelResumePoint
        self.novelMaxView = novelMaxView.map { max(resolvedView, $0) }
        self.novelDocumentSurfaceProgressPercent = novelDocumentSurfaceProgressPercent.map { min(max($0, 0), 100) }
    }
}

public struct MangaReadingProgressRecord: Codable, Hashable, Sendable {
    public var chapterThreadID: String
    public var chapterView: Int
    public var lastChapter: String
    public var mangaPageIndex: Int
    public var mangaPageCount: Int?

    public init(
        chapterThreadID: String,
        chapterView: Int = 1,
        lastChapter: String,
        mangaPageIndex: Int,
        mangaPageCount: Int? = nil
    ) {
        self.chapterThreadID = Self.normalizedChapterThreadID(chapterThreadID)
        self.lastChapter = lastChapter
        self.chapterView = max(1, chapterView)
        self.mangaPageIndex = max(0, mangaPageIndex)
        self.mangaPageCount = mangaPageCount.map { max(1, $0) }
    }

    private static func normalizedChapterThreadID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!trimmed.isEmpty, "MangaReadingProgressRecord requires a Yamibo chapter tid")
        return trimmed
    }
}

public struct ReadingProgressRecord: Codable, Hashable, Identifiable, Sendable {
    public var contentTarget: FavoriteContentTarget?
    public var threadID: String?
    public var kind: ReadingProgressKind
    public var updatedAt: Date
    public var lastReadAt: Date?
    public var novel: NovelReadingProgressRecord?
    public var manga: MangaReadingProgressRecord?
    public var thread: ThreadReadingProgressRecord?

    public var id: String {
        contentTarget?.id
            ?? threadID.map { "thread:\($0)" }
            ?? manga.map { "manga-chapter:\($0.chapterThreadID)" }
            ?? "\(kind.rawValue):unidentified"
    }

    public init(
        contentTarget: FavoriteContentTarget? = nil,
        threadID: String? = nil,
        kind: ReadingProgressKind,
        updatedAt: Date = .now,
        lastReadAt: Date? = nil,
        novel: NovelReadingProgressRecord? = nil,
        manga: MangaReadingProgressRecord? = nil,
        thread: ThreadReadingProgressRecord? = nil
    ) {
        self.contentTarget = contentTarget
        self.threadID = Self.normalizedThreadID(threadID) ?? contentTarget?.threadID
        self.kind = kind
        self.updatedAt = updatedAt
        self.lastReadAt = lastReadAt
        self.novel = novel
        self.manga = manga
        self.thread = thread
    }

    private static func normalizedThreadID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
