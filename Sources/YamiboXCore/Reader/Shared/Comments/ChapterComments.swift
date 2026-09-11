import Foundation

public enum ChapterCommentSource: String, Codable, Hashable, Sendable {
    case postComment
    case ratingReason
    case reply

    public var displayLabel: String {
        switch self {
        case .postComment:
            L10n.string("reader.comment_source.post_comment")
        case .ratingReason:
            L10n.string("reader.comment_source.rating_reason")
        case .reply:
            L10n.string("reader.comment_source.others_post")
        }
    }
}

public struct ChapterComment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var source: ChapterCommentSource
    public var authorName: String
    public var authorUID: String?
    public var authorAvatarURL: URL?
    public var metadata: String?
    public var body: String
    /// Optional display content for comments with smileys; `body` stays plain text.
    public var bodyBlocks: [ForumThreadTextBlock]?
    /// Ordered text and photo blocks; absent in older comments and text-only content.
    public var contentBlocks: [ForumThreadContentBlock]?
    public var postID: String?

    public init(
        id: String,
        source: ChapterCommentSource,
        authorName: String,
        metadata: String? = nil,
        body: String,
        postID: String? = nil,
        bodyBlocks: [ForumThreadTextBlock]? = nil,
        authorUID: String? = nil,
        authorAvatarURL: URL? = nil,
        contentBlocks: [ForumThreadContentBlock]? = nil
    ) {
        self.id = id
        self.source = source
        self.authorName = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authorUID = Self.nilIfEmpty(authorUID?.trimmingCharacters(in: .whitespacesAndNewlines))
        self.authorAvatarURL = authorAvatarURL
        self.metadata = Self.nilIfEmpty(metadata?.trimmingCharacters(in: .whitespacesAndNewlines))
        self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bodyBlocks = bodyBlocks
        self.contentBlocks = contentBlocks
        self.postID = Self.nilIfEmpty(postID?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    public func originalPostURL(threadID: String) -> URL? {
        YamiboRoute.findPostURL(threadID: threadID, postID: postID)
    }
}

public struct ChapterCommentsPage: Codable, Hashable, Sendable {
    public var target: ReaderChapterCommentTarget
    public var comments: [ChapterComment]
    public var isBoundaryClosed: Bool
    public var nextView: Int?
    /// Only fresh, unfiltered pages can prove that a reply belongs to this section.
    public var isThreadEndConfirmed: Bool?

    public init(
        target: ReaderChapterCommentTarget,
        comments: [ChapterComment],
        isBoundaryClosed: Bool,
        nextView: Int? = nil,
        isThreadEndConfirmed: Bool? = nil
    ) {
        self.target = target
        self.comments = comments
        self.isBoundaryClosed = isBoundaryClosed
        self.nextView = nextView
        self.isThreadEndConfirmed = isThreadEndConfirmed
    }
}
