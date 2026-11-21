import Foundation


public enum FavoriteContentUpdateDateResolver {
    public static func date(lastEditedText: String?, postedAtText: String?) -> Date? {
        DiscuzEditedDateParser.date(lastEditedText: lastEditedText, postedAtText: postedAtText)
    }

    public static func date(from text: String?) -> Date? {
        DiscuzEditedDateParser.date(from: text)
    }

    public static func publicationDate(of post: ForumThreadPost) -> Date? {
        post.postedAt ?? date(from: post.postedAtText)
    }

    public static func date(in page: ForumThreadPage, authorID: String? = nil) -> Date? {
        page.posts.filter { authorID == nil || $0.author.uid == authorID }.compactMap { post in
            [publicationDate(of: post), post.lastEditedAt ?? date(lastEditedText: post.lastEditedText, postedAtText: nil)]
                .compactMap { $0 }.max()
        }.max()
    }
}

public struct FavoriteThreadProbeResult: Hashable, Sendable {
    public var target: FavoriteItemTarget
    public var title: String
    public var sourceGroup: FavoriteSourceGroup
    public var forumID: String?
    public var forumName: String?
    public var coverURL: URL?
    public var contentUpdatedAt: Date?
    public var authorID: String?

    public init(
        target: FavoriteItemTarget,
        title: String,
        sourceGroup: FavoriteSourceGroup = .unknown,
        forumID: String? = nil,
        forumName: String? = nil,
        coverURL: URL? = nil,
        contentUpdatedAt: Date? = nil,
        authorID: String? = nil
    ) {
        self.target = target
        self.title = title
        let forumMetadata = FavoriteSourceGroup.normalizedForumMetadata(
            sourceGroup: sourceGroup,
            forumID: forumID,
            forumName: forumName
        )
        self.sourceGroup = forumMetadata.sourceGroup
        self.forumID = forumMetadata.forumID
        self.forumName = forumMetadata.forumName
        self.coverURL = coverURL
        self.contentUpdatedAt = contentUpdatedAt
        self.authorID = authorID
    }
}

enum FavoriteThreadImportFailure: Error, Equatable, Sendable {
    case probeFailed(String)
    case unsupportedTarget
}

public enum FavoriteItemOpenRoute: Equatable, Sendable {
    case nativeThread(threadID: String)
    case novelDetail(threadID: String)
    case mangaThread(threadID: String)
    case unsupported
}
