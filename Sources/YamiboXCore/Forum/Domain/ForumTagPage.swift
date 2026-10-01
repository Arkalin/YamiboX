import Foundation

/// Public Discuz tag browsing, separate from local favorite tags and tag administration.
public enum ForumTagTarget: Hashable, Sendable {
    case index
    case id(String)
    case name(String)

    public func url(page: Int = 1) -> URL {
        switch self {
        case .index: YamiboRoute.tagIndex.url
        case let .id(id): YamiboRoute.tag(id: id, page: page).url
        case let .name(name): YamiboRoute.tagNamed(name: name, page: page).url
        }
    }
}

public struct ForumTagSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
}

public struct ForumTagPage: Equatable, Sendable {
    public var tag: ForumTagSummary?
    public var tags: [ForumTagSummary]
    public var threads: [ForumThreadSummary]
    public var pageNavigation: ForumPageNavigation?

    public init(tag: ForumTagSummary? = nil, tags: [ForumTagSummary] = [], threads: [ForumThreadSummary] = [], pageNavigation: ForumPageNavigation? = nil) {
        self.tag = tag
        self.tags = tags
        self.threads = threads
        self.pageNavigation = pageNavigation
    }
}

public protocol ForumTagPageLoading: Sendable {
    func fetchTagPage(target: ForumTagTarget, page: Int) async throws -> ForumTagPage
}
