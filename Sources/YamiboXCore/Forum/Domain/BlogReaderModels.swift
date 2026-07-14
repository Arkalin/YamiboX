import Foundation

public struct BlogReaderPage: Codable, Equatable, Sendable {
    public var blogID: String
    public var title: String
    public var author: BlogReaderUser
    public var postedAtText: String?
    public var contentHTML: String
    public var contentText: String
    public var viewCount: Int?
    public var replyCount: Int?
    public var collectURL: URL?
    public var shareURL: URL?
    public var inviteURL: URL?
    public var comments: [BlogReaderComment]
    public var pageNavigation: ForumPageNavigation?

    public init(
        blogID: String,
        title: String,
        author: BlogReaderUser,
        postedAtText: String? = nil,
        contentHTML: String,
        contentText: String,
        viewCount: Int? = nil,
        replyCount: Int? = nil,
        collectURL: URL? = nil,
        shareURL: URL? = nil,
        inviteURL: URL? = nil,
        comments: [BlogReaderComment] = [],
        pageNavigation: ForumPageNavigation? = nil
    ) {
        self.blogID = blogID
        self.title = title
        self.author = author
        self.postedAtText = postedAtText
        self.contentHTML = contentHTML
        self.contentText = contentText
        self.viewCount = viewCount
        self.replyCount = replyCount
        self.collectURL = collectURL
        self.shareURL = shareURL
        self.inviteURL = inviteURL
        self.comments = comments
        self.pageNavigation = pageNavigation
    }
}

public struct BlogReaderUser: Codable, Equatable, Hashable, Sendable {
    public var uid: String?
    public var name: String
    public var avatarURL: URL?

    public init(uid: String? = nil, name: String, avatarURL: URL? = nil) {
        self.uid = uid
        self.name = name
        self.avatarURL = avatarURL
    }
}

public struct BlogReaderComment: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var commentID: String?
    public var author: BlogReaderUser
    public var postedAtText: String?
    public var contentHTML: String
    public var contentText: String
    public var replyURL: URL?

    public var id: String {
        if let commentID {
            return commentID
        }
        return [author.uid, author.name, postedAtText, contentText].compactMap { $0 }.joined(separator: "|")
    }

    public init(
        commentID: String? = nil,
        author: BlogReaderUser,
        postedAtText: String? = nil,
        contentHTML: String,
        contentText: String,
        replyURL: URL? = nil
    ) {
        self.commentID = commentID
        self.author = author
        self.postedAtText = postedAtText
        self.contentHTML = contentHTML
        self.contentText = contentText
        self.replyURL = replyURL
    }
}
