import Foundation

// Frozen schema-1 decoder used only to rank offline cache conflicts. Optional
// fields mirror the defaults in the original decoder; no live page models.
extension MangaIdentityMigrationV1 {
    struct CachedSourcePage: Decodable {
        var thread: SourceThreadIdentity
        var title: String
        var posts: [SourcePost]
        var pageNavigation: SourcePageNavigation?
        var totalViews: Int?
        var totalReplies: Int?
        var forumID: String?
        var forumName: String?
        var formHash: String?
    }

    struct SourcePost: Decodable {
        var postID: String
        var floorText: String?
        var author: SourceUser
        var postedAtText: String?
        var lastEditedText: String?
        var contentHTML: String
        var contentText: String
        var contentBlocks: [SourceContentBlock]?
        var images: [SourcePostImage]?
        var poll: SourcePoll?
        var ratingBlock: SourceRatingBlock?
        var comments: [SourcePostComment]?
        var attachments: [SourceAttachmentBlock]?
        var isPinned: Bool?
        var manageActions: [SourceManageAction]?
    }

    struct SourcePostImage: Decodable {
        var url: String
        var altText: String?
    }

    struct SourceManageAction: Decodable {
        var title: String
        var url: URL
    }

    struct SourcePoll: Decodable {
        var title: String
        var endTimeText: String?
        var type: SourcePollType
        var status: SourcePollStatus
        var options: [SourcePollOption]
    }

    enum SourcePollType: String, Decodable {
        case singleChoice
        case multipleChoice
        case unknown
    }

    enum SourcePollStatus: String, Decodable {
        case notVoted
        case voted
        case closed
        case unknown
    }

    struct SourcePollOption: Decodable {
        var id: String
        var title: String
        var voteCount: Int?
        var percentage: Double?
        var isSelected: Bool
    }

    struct SourceRatingBlock: Decodable {
        var participantCount: Int?
        var totalScore: Int?
        var ratings: [SourceRating]
        var allRatingsURL: URL?
    }

    struct SourceRating: Decodable {
        var user: SourceUser
        var scoreText: String
        var reason: String?
    }

    struct SourcePostComment: Decodable {
        var id: String
        var author: SourceUser
        var postedAtText: String?
        var message: String
    }

    struct SourceContentBlock: Decodable {
        var id: String
        var kind: SourceContentBlockKind
    }

    indirect enum SourceContentBlockKind: Decodable {
        case text(SourceTextBlock)
        case image(SourceImageBlock)
        case attachment(SourceAttachmentBlock)
        case quote([SourceContentBlock])
        case indent([SourceContentBlock])
        case code(String)
        case horizontalRule
        case collapse(title: String?, contentBlocks: [SourceContentBlock])
        case locked(cost: Int?, contentBlocks: [SourceContentBlock])
        case table(rows: [[SourceTableCell]])
    }

    struct SourceTextBlock: Decodable {
        var text: String
        var alignment: SourceTextAlignment
        var links: [SourceTextLink]
        var styleRuns: [SourceTextStyleRun]
        var rubies: [SourceRubyText]
        var inlineImages: [SourceInlineImage]?
        var paragraphStyle: SourceParagraphStyle?
    }

    struct SourceParagraphStyle: Decodable {
        var lineHeight: Double?
        var lineHeightMultiple: Double?
        var firstLineIndentEm: Double?
        var firstLineIndentPixels: Double?
    }

    struct SourceInlineImage: Decodable {
        var start: Int
        var image: SourceImageBlock
    }

    enum SourceTextAlignment: String, Decodable {
        case start
        case left
        case center
        case right
    }

    struct SourceTextLink: Decodable {
        var start: Int
        var length: Int
        var url: URL
    }

    struct SourceTextStyleRun: Decodable {
        var start: Int
        var length: Int
        var style: SourceTextStyle
    }

    struct SourceRubyText: Decodable {
        var start: Int
        var length: Int
        var baseText: String
        var rubyText: String
    }

    struct SourceTextStyle: Decodable {
        var isBold: Bool
        var isItalic: Bool
        var isUnderline: Bool
        var isStrikethrough: Bool
        var foregroundHex: String?
        var backgroundHex: String?
        var relativeFontSize: Double?
        var fontFamily: String?
        var baseline: Int?
    }

    struct SourceImageBlock: Decodable {
        var url: URL
        var altText: String?
        var linkURL: URL?
        var isEmoticon: Bool
        var width: Double?
        var height: Double?
    }

    struct SourceAttachmentBlock: Decodable {
        var url: URL
        var iconURL: URL?
        var fileName: String
        var uploadInfo: String?
        var statInfo: String?
    }

    struct SourceTableCell: Decodable {
        var isHeader: Bool
        var blocks: [SourceContentBlock]
        var columnSpan: Int?
        var rowSpan: Int?
        var backgroundHex: String?
    }

    struct SourceThreadIdentity: Decodable {
        var tid: String
        var fid: String?
    }

    struct SourceUser: Decodable {
        var uid: String?
        var name: String
        var avatarURL: URL?
    }

    struct SourcePageNavigation: Decodable {
        var currentPage: Int
        var totalPages: Int?
    }
}
