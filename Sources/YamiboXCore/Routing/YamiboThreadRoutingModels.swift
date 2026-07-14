import Foundation

public enum YamiboThreadKind: String, Codable, Hashable, Sendable {
    case novel
    case manga
    case regular
    case unknown
}

public struct ThreadIdentity: Codable, Hashable, Sendable {
    public var tid: String
    public var fid: String?

    public init(tid: String, fid: String? = nil) {
        self.tid = tid.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fid = fid?.nilIfBlank
    }
}

public struct YamiboThreadTapContext: Codable, Hashable, Sendable {
    public var containingFid: String?

    public init(containingFid: String? = nil) {
        self.containingFid = containingFid?.nilIfBlank
    }
}

public enum YamiboThreadRouteIntent: String, Codable, Hashable, Sendable {
    case contentRoute
    case nativeThreadReader
}

public struct YamiboThreadRouteRequest: Codable, Hashable, Sendable {
    public var threadURL: URL
    public var threadID: String?
    public var title: String?
    public var authorID: String?
    public var threadFid: String?
    public var targetPostID: String?
    public var knownThreadKind: YamiboThreadKind?
    public var intent: YamiboThreadRouteIntent
    public var tapContext: YamiboThreadTapContext

    public init(
        threadURL: URL,
        threadID: String? = nil,
        title: String? = nil,
        authorID: String? = nil,
        threadFid: String? = nil,
        targetPostID: String? = nil,
        knownThreadKind: YamiboThreadKind? = nil,
        intent: YamiboThreadRouteIntent = .contentRoute,
        tapContext: YamiboThreadTapContext = YamiboThreadTapContext()
    ) {
        self.threadURL = threadURL
        self.threadID = threadID?.nilIfBlank
        self.title = title?.nilIfBlank
        self.authorID = authorID?.nilIfBlank
        self.threadFid = threadFid?.nilIfBlank
        self.targetPostID = targetPostID?.nilIfBlank
        self.knownThreadKind = knownThreadKind
        self.intent = intent
        self.tapContext = tapContext
    }
}

public struct NovelDetailLaunchContext: Codable, Hashable, Sendable {
    public var thread: ThreadIdentity
    public var title: String
    public var authorID: String?

    public init(thread: ThreadIdentity, title: String, authorID: String? = nil) {
        self.thread = thread
        self.title = title.nilIfBlank ?? L10n.string("reader.title")
        self.authorID = authorID?.nilIfBlank
    }
}

public struct MangaDetailLaunchContext: Codable, Hashable, Sendable {
    public var thread: ThreadIdentity
    public var title: String
    public var focusedChapterTID: String?
    public var directoryNameHint: String?

    public init(
        thread: ThreadIdentity,
        title: String,
        focusedChapterTID: String? = nil,
        directoryNameHint: String? = nil
    ) {
        self.thread = thread
        self.title = title.nilIfBlank ?? L10n.string("manga.reader.title")
        self.focusedChapterTID = focusedChapterTID?.nilIfBlank
        self.directoryNameHint = directoryNameHint?.nilIfBlank
    }
}

public struct ThreadNovelLaunchContext: Codable, Hashable, Sendable {
    public var thread: ThreadIdentity
    public var title: String
    public var initialPage: Int
    public var targetPostID: String?
    public var authorID: String?
    /// True when this reader session is a novel/manga detail page's
    /// "查看讨论" companion view: it shares the work's tid, so it must not
    /// produce its own browsing-history row — the work's main-form row is
    /// the only history entry for that tid (browsing-history decision #14).
    /// Anchor reading progress is still written and restored as usual.
    public var isDiscussionView: Bool

    public var loadsAllPosts: Bool { true }

    public init(
        thread: ThreadIdentity,
        title: String,
        initialPage: Int = 1,
        targetPostID: String? = nil,
        authorID: String? = nil,
        isDiscussionView: Bool = false
    ) {
        self.thread = thread
        self.title = title.nilIfBlank ?? L10n.string("forum.default_title")
        self.initialPage = max(1, initialPage)
        self.targetPostID = targetPostID?.nilIfBlank
        self.authorID = authorID?.nilIfBlank
        self.isDiscussionView = isDiscussionView
    }

    private enum CodingKeys: String, CodingKey {
        case thread
        case title
        case initialPage
        case targetPostID
        case authorID
        case isDiscussionView
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            thread: try container.decode(ThreadIdentity.self, forKey: .thread),
            title: try container.decode(String.self, forKey: .title),
            initialPage: try container.decodeIfPresent(Int.self, forKey: .initialPage) ?? 1,
            targetPostID: try container.decodeIfPresent(String.self, forKey: .targetPostID),
            authorID: try container.decodeIfPresent(String.self, forKey: .authorID),
            isDiscussionView: try container.decodeIfPresent(Bool.self, forKey: .isDiscussionView) ?? false
        )
    }
}

public struct YamiboThreadRoutePayload: Hashable, Sendable {
    public var thread: ThreadIdentity
    public var title: String
    public var authorID: String?
    public var canonicalURL: URL
    public var requestedURL: URL
    public var initialPage: Int
    public var targetPostID: String?

    public init(
        thread: ThreadIdentity,
        title: String,
        authorID: String? = nil,
        canonicalURL: URL,
        requestedURL: URL,
        initialPage: Int = 1,
        targetPostID: String? = nil
    ) {
        self.thread = thread
        self.title = title.nilIfBlank ?? L10n.string("forum.default_title")
        self.authorID = authorID?.nilIfBlank
        self.canonicalURL = canonicalURL
        self.requestedURL = requestedURL
        self.initialPage = max(1, initialPage)
        self.targetPostID = targetPostID?.nilIfBlank
    }
}

public enum YamiboThreadRouteTarget: Hashable, Sendable {
    case novel(YamiboThreadRoutePayload)
    case manga(YamiboThreadRoutePayload)
    /// Same classification as `.manga` (still a thread on a board the user
    /// configured as manga in `BoardReaderSettings`), but the board's Smart
    /// Comic Mode bit is off, so the caller should open the manga reader
    /// directly for this one thread instead of routing through
    /// `ForumMangaDetailView`.
    case mangaDirect(YamiboThreadRoutePayload)
    case thread(YamiboThreadRoutePayload)
    case webFallback(URL)
}
