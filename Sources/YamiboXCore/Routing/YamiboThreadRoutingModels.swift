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

public enum YamiboThreadReaderOverride: String, Codable, Hashable, Sendable {
    case plainThread
    case novel
    case manga

    var threadKind: YamiboThreadKind {
        switch self {
        case .plainThread:
            .regular
        case .novel:
            .novel
        case .manga:
            .manga
        }
    }
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
    public var readerOverride: YamiboThreadReaderOverride?
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
        readerOverride: YamiboThreadReaderOverride? = nil,
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
        self.readerOverride = readerOverride
        self.tapContext = tapContext
    }
}

public struct ThreadNovelLaunchContext: Codable, Hashable, Sendable {
    public var thread: ThreadIdentity
    public var title: String
    public var initialPage: Int
    public var targetPostID: String?
    public var authorID: String?
    public var isDiscussionView: Bool
    public var explicitReadingState: ThreadExplicitReadingState?

    public var loadsAllPosts: Bool { true }

    public init(
        thread: ThreadIdentity,
        title: String,
        initialPage: Int = 1,
        targetPostID: String? = nil,
        authorID: String? = nil,
        isDiscussionView: Bool = false,
        explicitReadingState: ThreadExplicitReadingState? = nil
    ) {
        self.thread = thread
        self.title = title.nilIfBlank ?? L10n.string("forum.default_title")
        self.initialPage = max(1, initialPage)
        self.targetPostID = targetPostID?.nilIfBlank
        self.authorID = authorID?.nilIfBlank
        self.isDiscussionView = isDiscussionView
        self.explicitReadingState = explicitReadingState
    }

    private enum CodingKeys: String, CodingKey {
        case thread
        case title
        case initialPage
        case targetPostID
        case authorID
        case isDiscussionView
        case explicitReadingState
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            thread: try container.decode(ThreadIdentity.self, forKey: .thread),
            title: try container.decode(String.self, forKey: .title),
            initialPage: try container.decodeIfPresent(Int.self, forKey: .initialPage) ?? 1,
            targetPostID: try container.decodeIfPresent(String.self, forKey: .targetPostID),
            authorID: try container.decodeIfPresent(String.self, forKey: .authorID),
            isDiscussionView: try container.decodeIfPresent(Bool.self, forKey: .isDiscussionView) ?? false,
            explicitReadingState: try container.decodeIfPresent(ThreadExplicitReadingState.self, forKey: .explicitReadingState)
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
    case mangaDirect(YamiboThreadRoutePayload)
    case thread(YamiboThreadRoutePayload)
    case webFallback(URL)
}

public struct YamiboThreadRouteResolution: Sendable {
    public let target: YamiboThreadRouteTarget
    public let preloadedPage: ForumThreadPage?

    init(_ target: YamiboThreadRouteTarget, preloadedPage: ForumThreadPage? = nil) {
        self.target = target
        self.preloadedPage = preloadedPage
    }
}
