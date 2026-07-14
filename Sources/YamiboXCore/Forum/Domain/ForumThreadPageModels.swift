import Foundation

public struct ForumThreadPage: Codable, Equatable, Sendable {
    public var thread: ThreadIdentity
    public var title: String
    public var posts: [ForumThreadPost]
    public var pageNavigation: ForumPageNavigation?
    public var totalViews: Int?
    public var totalReplies: Int?
    public var forumID: String?
    public var forumName: String?
    public var formHash: String?

    public init(
        thread: ThreadIdentity,
        title: String,
        posts: [ForumThreadPost],
        pageNavigation: ForumPageNavigation? = nil,
        totalViews: Int? = nil,
        totalReplies: Int? = nil,
        forumID: String? = nil,
        forumName: String? = nil,
        formHash: String? = nil
    ) {
        self.thread = thread
        self.title = title
        self.posts = posts
        self.pageNavigation = pageNavigation
        self.totalViews = totalViews
        self.totalReplies = totalReplies
        self.forumID = forumID?.nilIfBlank
        self.forumName = forumName?.nilIfBlank
        self.formHash = formHash?.nilIfBlank
    }
}

public struct ForumThreadPost: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var postID: String
    public var floorText: String?
    public var author: BlogReaderUser
    public var postedAtText: String?
    public var lastEditedText: String?
    public var contentHTML: String
    public var contentText: String
    public var contentBlocks: [ForumThreadContentBlock]
    public var images: [ForumThreadPostImage]
    public var poll: ForumThreadPoll?
    public var ratingBlock: ForumThreadRatingBlock?
    public var comments: [ForumThreadPostComment]
    public var attachments: [ForumThreadAttachmentBlock]
    public var isPinned: Bool
    public var manageActions: [ForumThreadManageAction]

    public var id: String { postID }

    private enum CodingKeys: String, CodingKey {
        case postID
        case floorText
        case author
        case postedAtText
        case lastEditedText
        case contentHTML
        case contentText
        case contentBlocks
        case images
        case poll
        case ratingBlock
        case comments
        case attachments
        case isPinned
        case manageActions
    }

    public init(
        postID: String,
        floorText: String? = nil,
        author: BlogReaderUser,
        postedAtText: String? = nil,
        lastEditedText: String? = nil,
        contentHTML: String,
        contentText: String,
        contentBlocks: [ForumThreadContentBlock] = [],
        images: [ForumThreadPostImage] = [],
        poll: ForumThreadPoll? = nil,
        ratingBlock: ForumThreadRatingBlock? = nil,
        comments: [ForumThreadPostComment] = [],
        attachments: [ForumThreadAttachmentBlock] = [],
        isPinned: Bool = false,
        manageActions: [ForumThreadManageAction] = []
    ) {
        self.postID = postID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.floorText = floorText?.nilIfBlank
        self.author = author
        self.postedAtText = postedAtText?.nilIfBlank
        self.lastEditedText = lastEditedText?.nilIfBlank
        self.contentHTML = contentHTML
        self.contentText = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contentBlocks = contentBlocks
        self.images = images
        self.poll = poll
        self.ratingBlock = ratingBlock
        self.comments = comments
        self.attachments = attachments
        self.isPinned = isPinned
        self.manageActions = manageActions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            postID: try container.decode(String.self, forKey: .postID),
            floorText: try container.decodeIfPresent(String.self, forKey: .floorText),
            author: try container.decode(BlogReaderUser.self, forKey: .author),
            postedAtText: try container.decodeIfPresent(String.self, forKey: .postedAtText),
            lastEditedText: try container.decodeIfPresent(String.self, forKey: .lastEditedText),
            contentHTML: try container.decode(String.self, forKey: .contentHTML),
            contentText: try container.decode(String.self, forKey: .contentText),
            contentBlocks: try container.decodeIfPresent([ForumThreadContentBlock].self, forKey: .contentBlocks) ?? [],
            images: try container.decodeIfPresent([ForumThreadPostImage].self, forKey: .images) ?? [],
            poll: try container.decodeIfPresent(ForumThreadPoll.self, forKey: .poll),
            ratingBlock: try container.decodeIfPresent(ForumThreadRatingBlock.self, forKey: .ratingBlock),
            comments: try container.decodeIfPresent([ForumThreadPostComment].self, forKey: .comments) ?? [],
            attachments: try container.decodeIfPresent([ForumThreadAttachmentBlock].self, forKey: .attachments) ?? [],
            isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
            manageActions: try container.decodeIfPresent([ForumThreadManageAction].self, forKey: .manageActions) ?? []
        )
    }
}

public struct ForumThreadPostImage: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var url: String
    public var altText: String?

    public var id: String {
        "\(url)\u{1F}\(altText ?? "")"
    }

    public init(url: String, altText: String? = nil) {
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.altText = altText?.nilIfBlank
    }
}

public struct ForumThreadManageAction: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var title: String
    public var url: URL

    public var id: String {
        "\(title)\u{1F}\(url.absoluteString)"
    }

    public init(title: String, url: URL) {
        self.title = title.nilIfBlank ?? url.absoluteString
        self.url = url
    }
}

public struct ForumThreadPoll: Codable, Equatable, Hashable, Sendable {
    public var title: String
    public var endTimeText: String?
    public var type: ForumThreadPollType
    public var status: ForumThreadPollStatus
    public var options: [ForumThreadPollOption]

    public init(
        title: String,
        endTimeText: String? = nil,
        type: ForumThreadPollType = .unknown,
        status: ForumThreadPollStatus = .unknown,
        options: [ForumThreadPollOption]
    ) {
        self.title = title.nilIfBlank ?? L10n.string("forum.thread.poll")
        self.endTimeText = endTimeText?.nilIfBlank
        self.type = type
        self.status = status
        self.options = options
    }
}

public enum ForumThreadPollType: String, Codable, Equatable, Hashable, Sendable {
    case singleChoice
    case multipleChoice
    case unknown
}

public enum ForumThreadPollStatus: String, Codable, Equatable, Hashable, Sendable {
    case notVoted
    case voted
    case closed
    case unknown
}

public struct ForumThreadPollOption: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var voteCount: Int?
    public var percentage: Double?
    public var isSelected: Bool

    public init(
        id: String,
        title: String,
        voteCount: Int? = nil,
        percentage: Double? = nil,
        isSelected: Bool = false
    ) {
        self.id = id.nilIfBlank ?? title
        self.title = title.nilIfBlank ?? id
        self.voteCount = voteCount
        self.percentage = percentage
        self.isSelected = isSelected
    }
}

public struct ForumThreadRatingBlock: Codable, Equatable, Hashable, Sendable {
    public var participantCount: Int?
    public var totalScore: Int?
    public var ratings: [ForumThreadRating]
    public var allRatingsURL: URL?

    public init(
        participantCount: Int? = nil,
        totalScore: Int? = nil,
        ratings: [ForumThreadRating],
        allRatingsURL: URL? = nil
    ) {
        self.participantCount = participantCount
        self.totalScore = totalScore
        self.ratings = ratings
        self.allRatingsURL = allRatingsURL
    }
}

public struct ForumThreadRating: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var user: BlogReaderUser
    public var scoreText: String
    public var reason: String?

    public var id: String {
        [user.uid ?? user.name, scoreText, reason ?? ""].joined(separator: "\u{1F}")
    }

    public init(user: BlogReaderUser, scoreText: String, reason: String? = nil) {
        self.user = user
        self.scoreText = scoreText.nilIfBlank ?? "0"
        self.reason = reason?.nilIfBlank
    }
}

public struct ForumThreadRatingResultsPage: Codable, Equatable, Hashable, Sendable {
    public var ratings: [ForumThreadRating]
    public var totalScore: Int?

    public init(ratings: [ForumThreadRating], totalScore: Int? = nil) {
        self.ratings = ratings
        self.totalScore = totalScore
    }
}

public struct ForumThreadRateOptionsPage: Codable, Equatable, Hashable, Sendable {
    public var availableScores: [Int]
    public var defaultReasons: [String]

    public init(availableScores: [Int], defaultReasons: [String]) {
        self.availableScores = availableScores
        self.defaultReasons = defaultReasons
    }
}

public struct ForumThreadPollVotersPage: Codable, Equatable, Hashable, Sendable {
    public var threadID: String
    public var selectedOptionID: String?
    public var pollOptions: [ForumThreadPollVoterOption]
    public var voters: [BlogReaderUser]
    public var pageNavigation: ForumPageNavigation?

    public init(
        threadID: String,
        selectedOptionID: String? = nil,
        pollOptions: [ForumThreadPollVoterOption],
        voters: [BlogReaderUser],
        pageNavigation: ForumPageNavigation? = nil
    ) {
        self.threadID = threadID
        self.selectedOptionID = selectedOptionID?.nilIfBlank
        self.pollOptions = pollOptions
        self.voters = voters
        self.pageNavigation = pageNavigation
    }
}

public struct ForumThreadPollVoterOption: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id.nilIfBlank ?? name
        self.name = name.nilIfBlank ?? id
    }
}

public struct ForumThreadPostComment: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var author: BlogReaderUser
    public var postedAtText: String?
    public var message: String

    public init(
        id: String,
        author: BlogReaderUser,
        postedAtText: String? = nil,
        message: String
    ) {
        self.id = id.nilIfBlank ?? [author.uid ?? author.name, message].joined(separator: "\u{1F}")
        self.author = author
        self.postedAtText = postedAtText?.nilIfBlank
        self.message = message.nilIfBlank ?? ""
    }
}

public struct ForumThreadContentBlock: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: ForumThreadContentBlockKind

    public init(id: String, kind: ForumThreadContentBlockKind) {
        self.id = id
        self.kind = kind
    }
}

public indirect enum ForumThreadContentBlockKind: Codable, Equatable, Hashable, Sendable {
    case text(ForumThreadTextBlock)
    case image(ForumThreadImageBlock)
    case attachment(ForumThreadAttachmentBlock)
    case quote([ForumThreadContentBlock])
    case code(String)
    case horizontalRule
    case collapse(title: String?, contentBlocks: [ForumThreadContentBlock])
    case locked(cost: Int?, contentBlocks: [ForumThreadContentBlock])
    case table(rows: [[ForumThreadTableCell]])
}

public struct ForumThreadTextBlock: Codable, Equatable, Hashable, Sendable {
    public var text: String
    public var alignment: ForumThreadTextAlignment
    public var links: [ForumThreadTextLink]
    public var styleRuns: [ForumThreadTextStyleRun]
    public var rubies: [ForumThreadRubyText]

    public init(
        text: String,
        alignment: ForumThreadTextAlignment = .start,
        links: [ForumThreadTextLink] = [],
        styleRuns: [ForumThreadTextStyleRun] = [],
        rubies: [ForumThreadRubyText] = []
    ) {
        self.text = text
        self.alignment = alignment
        self.links = links
        self.styleRuns = styleRuns
        self.rubies = rubies
    }
}

public enum ForumThreadTextAlignment: String, Codable, Equatable, Hashable, Sendable {
    case start
    case left
    case center
    case right
}

public struct ForumThreadTextLink: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var start: Int
    public var length: Int
    public var url: URL

    public var id: String {
        "\(start)-\(length)-\(url.absoluteString)"
    }

    public init(start: Int, length: Int, url: URL) {
        self.start = start
        self.length = length
        self.url = url
    }
}

public struct ForumThreadTextStyleRun: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var start: Int
    public var length: Int
    public var style: ForumThreadTextStyle

    public var id: String {
        "\(start)-\(length)-\(style)"
    }

    public init(start: Int, length: Int, style: ForumThreadTextStyle) {
        self.start = start
        self.length = length
        self.style = style
    }
}

public struct ForumThreadRubyText: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var start: Int
    public var length: Int
    public var baseText: String
    public var rubyText: String

    public var id: String {
        "\(start)-\(length)-\(baseText)-\(rubyText)"
    }

    public init(
        start: Int,
        length: Int,
        baseText: String,
        rubyText: String
    ) {
        self.start = start
        self.length = length
        self.baseText = baseText
        self.rubyText = rubyText
    }
}

public struct ForumThreadTextStyle: Codable, Equatable, Hashable, Sendable {
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderline: Bool
    public var isStrikethrough: Bool
    public var foregroundHex: String?
    public var backgroundHex: String?
    public var relativeFontSize: Double?

    public init(
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        isStrikethrough: Bool = false,
        foregroundHex: String? = nil,
        backgroundHex: String? = nil,
        relativeFontSize: Double? = nil
    ) {
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isStrikethrough = isStrikethrough
        self.foregroundHex = foregroundHex?.nilIfBlank
        self.backgroundHex = backgroundHex?.nilIfBlank
        self.relativeFontSize = relativeFontSize
    }

    public var isEmpty: Bool {
        !isBold
            && !isItalic
            && !isUnderline
            && !isStrikethrough
            && foregroundHex == nil
            && backgroundHex == nil
            && relativeFontSize == nil
    }
}

public struct ForumThreadImageBlock: Codable, Equatable, Hashable, Sendable {
    public var url: URL
    public var altText: String?
    public var linkURL: URL?
    public var isEmoticon: Bool

    public init(url: URL, altText: String? = nil, linkURL: URL? = nil, isEmoticon: Bool = false) {
        self.url = url
        self.altText = altText?.nilIfBlank
        self.linkURL = linkURL
        self.isEmoticon = isEmoticon
    }
}

public struct ForumThreadAttachmentBlock: Codable, Equatable, Hashable, Sendable {
    public var url: URL
    public var iconURL: URL?
    public var fileName: String
    public var uploadInfo: String?
    public var statInfo: String?

    public init(
        url: URL,
        iconURL: URL? = nil,
        fileName: String,
        uploadInfo: String? = nil,
        statInfo: String? = nil
    ) {
        self.url = url
        self.iconURL = iconURL
        self.fileName = fileName.nilIfBlank ?? url.absoluteString
        self.uploadInfo = uploadInfo?.nilIfBlank
        self.statInfo = statInfo?.nilIfBlank
    }
}

public struct ForumThreadTableCell: Codable, Equatable, Hashable, Sendable {
    public var isHeader: Bool
    public var blocks: [ForumThreadContentBlock]

    public init(isHeader: Bool = false, blocks: [ForumThreadContentBlock]) {
        self.isHeader = isHeader
        self.blocks = blocks
    }
}
