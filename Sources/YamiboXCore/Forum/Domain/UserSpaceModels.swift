import Foundation

public enum UserSpaceSection: String, CaseIterable, Codable, Hashable, Sendable {
    case space
    case threads
    case blogs
    case friends
}

public enum UserSpaceSubPage: String, CaseIterable, Codable, Hashable, Sendable {
    case profile
    case threads
    case replies
    case myBlogs
    case friendBlogs
    case viewAllBlogs
    case friends
    case online
    case visitors
    case traces
}

public enum UserSpaceViewAllBlogFilter: String, CaseIterable, Codable, Hashable, Sendable {
    case latest
    case hot
}

public enum UserSpaceFriendType: String, CaseIterable, Codable, Hashable, Sendable {
    case myFriend
    case onlineMember
    case myVisitor
    case myTrace
}

public enum MessageCenterTab: String, CaseIterable, Codable, Hashable, Sendable {
    case privateMessages
    case notices
}

public struct UserSpaceProfile: Codable, Equatable, Sendable {
    public var uid: String
    public var username: String
    public var userGroup: String?
    public var avatarURL: URL?
    public var avatarBackgroundURL: URL?
    public var signature: String?
    public var totalPoints: Int?
    public var points: Int?
    public var partner: Int?
    public var infoRows: [UserSpaceInfoRow]

    public init(
        uid: String,
        username: String,
        userGroup: String? = nil,
        avatarURL: URL? = nil,
        avatarBackgroundURL: URL? = nil,
        signature: String? = nil,
        totalPoints: Int? = nil,
        points: Int? = nil,
        partner: Int? = nil,
        infoRows: [UserSpaceInfoRow] = []
    ) {
        self.uid = uid
        self.username = username
        self.userGroup = userGroup
        self.avatarURL = avatarURL
        self.avatarBackgroundURL = avatarBackgroundURL
        self.signature = signature
        self.totalPoints = totalPoints
        self.points = points
        self.partner = partner
        self.infoRows = infoRows
    }
}

public struct UserSpaceInfoRow: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var label: String
    public var value: String
    public var url: URL?

    public var id: String { "\(label)|\(value)" }

    public init(label: String, value: String, url: URL? = nil) {
        self.label = label
        self.value = value
        self.url = url
    }
}

public struct UserSpaceThreadPage: Codable, Equatable, Sendable {
    public var threads: [ForumThreadSummary]
    public var pageNavigation: ForumPageNavigation?

    public init(threads: [ForumThreadSummary], pageNavigation: ForumPageNavigation? = nil) {
        self.threads = threads
        self.pageNavigation = pageNavigation
    }
}

public struct UserSpaceReplyPage: Codable, Equatable, Sendable {
    public var replies: [UserSpaceReplyGroup]
    public var pageNavigation: ForumPageNavigation?

    public init(replies: [UserSpaceReplyGroup], pageNavigation: ForumPageNavigation? = nil) {
        self.replies = replies
        self.pageNavigation = pageNavigation
    }
}

public struct UserSpaceReplyGroup: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var threadID: String
    public var threadTitle: String
    public var threadURL: URL
    public var excerpt: String?
    public var lastActivityText: String?

    public var id: String { threadID }

    public init(
        threadID: String,
        threadTitle: String,
        threadURL: URL,
        excerpt: String? = nil,
        lastActivityText: String? = nil
    ) {
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.threadURL = threadURL
        self.excerpt = excerpt
        self.lastActivityText = lastActivityText
    }
}

public struct UserSpaceBlogPage: Codable, Equatable, Sendable {
    public var blogs: [UserSpaceBlogSummary]
    public var pageNavigation: ForumPageNavigation?

    public init(blogs: [UserSpaceBlogSummary], pageNavigation: ForumPageNavigation? = nil) {
        self.blogs = blogs
        self.pageNavigation = pageNavigation
    }
}

public struct UserSpaceBlogSummary: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var blogID: String
    public var title: String
    public var url: URL
    public var authorName: String?
    public var authorID: String?
    public var excerpt: String?
    public var lastActivityText: String?
    public var replyCount: Int?
    public var viewCount: Int?

    public var id: String { blogID }

    public init(
        blogID: String,
        title: String,
        url: URL,
        authorName: String? = nil,
        authorID: String? = nil,
        excerpt: String? = nil,
        lastActivityText: String? = nil,
        replyCount: Int? = nil,
        viewCount: Int? = nil
    ) {
        self.blogID = blogID
        self.title = title
        self.url = url
        self.authorName = authorName
        self.authorID = authorID
        self.excerpt = excerpt
        self.lastActivityText = lastActivityText
        self.replyCount = replyCount
        self.viewCount = viewCount
    }
}

public struct UserSpaceFriendPage: Codable, Equatable, Sendable {
    public var friends: [UserSpaceFriendSummary]
    public var pageNavigation: ForumPageNavigation?

    public init(friends: [UserSpaceFriendSummary], pageNavigation: ForumPageNavigation? = nil) {
        self.friends = friends
        self.pageNavigation = pageNavigation
    }
}

public struct UserSpaceFriendSummary: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var uid: String
    public var name: String
    public var avatarURL: URL?
    public var detail: String?
    public var privateMessageURL: URL?
    public var deleteURL: URL?

    public var id: String { uid }

    public init(
        uid: String,
        name: String,
        avatarURL: URL? = nil,
        detail: String? = nil,
        privateMessageURL: URL? = nil,
        deleteURL: URL? = nil
    ) {
        self.uid = uid
        self.name = name
        self.avatarURL = avatarURL
        self.detail = detail
        self.privateMessageURL = privateMessageURL
        self.deleteURL = deleteURL
    }
}

public struct UserSpaceAddFriendForm: Codable, Equatable, Sendable {
    public var uid: String
    public var name: String?
    public var avatarURL: URL?
    public var formHash: String
    public var options: [UserSpaceAddFriendOption]

    public init(
        uid: String,
        name: String? = nil,
        avatarURL: URL? = nil,
        formHash: String,
        options: [UserSpaceAddFriendOption] = []
    ) {
        self.uid = uid
        self.name = name
        self.avatarURL = avatarURL
        self.formHash = formHash
        self.options = options.isEmpty ? [UserSpaceAddFriendOption(id: 1, name: L10n.string("user_space.default_friend_group"))] : options
    }
}

public struct UserSpaceAddFriendOption: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public struct UserSpacePrivateMessagePage: Codable, Equatable, Sendable {
    public var messages: [UserSpacePrivateMessageSummary]
    public var unreadCount: Int?
    public var pageNavigation: ForumPageNavigation?

    public init(
        messages: [UserSpacePrivateMessageSummary],
        unreadCount: Int? = nil,
        pageNavigation: ForumPageNavigation? = nil
    ) {
        self.messages = messages
        self.unreadCount = unreadCount
        self.pageNavigation = pageNavigation
    }
}

public struct UserSpacePrivateMessageSummary: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var uid: String
    public var name: String
    public var avatarURL: URL?
    public var title: String
    public var message: String
    public var timeText: String?
    public var unreadCount: Int?

    public var id: String {
        [uid, timeText, title, message].compactMap { $0 }.joined(separator: "|")
    }

    public init(
        uid: String,
        name: String,
        avatarURL: URL? = nil,
        title: String,
        message: String,
        timeText: String? = nil,
        unreadCount: Int? = nil
    ) {
        self.uid = uid
        self.name = name
        self.avatarURL = avatarURL
        self.title = title
        self.message = message
        self.timeText = timeText
        self.unreadCount = unreadCount
    }
}

public struct UserSpaceNoticePage: Codable, Equatable, Sendable {
    public var notices: [UserSpaceNoticeSummary]
    public var pageNavigation: ForumPageNavigation?

    public init(notices: [UserSpaceNoticeSummary], pageNavigation: ForumPageNavigation? = nil) {
        self.notices = notices
        self.pageNavigation = pageNavigation
    }
}

public struct UserSpaceNoticeSummary: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var noticeID: String
    public var avatarURL: URL?
    public var userID: String?
    public var contentHTML: String
    public var contentText: String
    public var quote: String?
    public var timeText: String?

    public var id: String { noticeID }

    public init(
        noticeID: String,
        avatarURL: URL? = nil,
        userID: String? = nil,
        contentHTML: String,
        contentText: String,
        quote: String? = nil,
        timeText: String? = nil
    ) {
        self.noticeID = noticeID
        self.avatarURL = avatarURL
        self.userID = userID
        self.contentHTML = contentHTML
        self.contentText = contentText
        self.quote = quote
        self.timeText = timeText
    }
}

public struct PrivateMessagePage: Codable, Equatable, Sendable {
    public var title: String
    public var privateMessageID: String
    public var toUID: String
    public var toName: String?
    public var formHash: String?
    public var messages: [PrivateMessage]
    public var pageNavigation: ForumPageNavigation?

    public init(
        title: String,
        privateMessageID: String,
        toUID: String,
        toName: String? = nil,
        formHash: String? = nil,
        messages: [PrivateMessage] = [],
        pageNavigation: ForumPageNavigation? = nil
    ) {
        self.title = title
        self.privateMessageID = privateMessageID
        self.toUID = toUID
        self.toName = toName
        self.formHash = formHash
        self.messages = messages
        self.pageNavigation = pageNavigation
    }
}

public struct PrivateMessage: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var messageID: String?
    public var kind: PrivateMessageKind
    public var author: PrivateMessageUser
    public var postedAtText: String?
    public var contentHTML: String
    public var contentText: String

    public var id: String {
        messageID ?? [
            kind.rawValue,
            author.uid ?? "",
            postedAtText ?? "",
            contentText
        ].joined(separator: "|")
    }

    public init(
        messageID: String? = nil,
        kind: PrivateMessageKind,
        author: PrivateMessageUser,
        postedAtText: String? = nil,
        contentHTML: String,
        contentText: String
    ) {
        self.messageID = messageID
        self.kind = kind
        self.author = author
        self.postedAtText = postedAtText
        self.contentHTML = contentHTML
        self.contentText = contentText
    }
}

public enum PrivateMessageKind: String, Codable, Equatable, Hashable, Sendable {
    case me
    case other
}

public struct PrivateMessageUser: Codable, Equatable, Hashable, Sendable {
    public var uid: String?
    public var name: String
    public var avatarURL: URL?

    public init(uid: String? = nil, name: String, avatarURL: URL? = nil) {
        self.uid = uid
        self.name = name
        self.avatarURL = avatarURL
    }
}
