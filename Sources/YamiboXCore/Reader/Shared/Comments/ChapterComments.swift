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
    public var replyReference: ForumPostReplyReference?
    public var postedAt: String?
    public var isThreadAuthor: Bool?
    public var quoteBlocks: [ForumThreadContentBlock]?
    public var isFiltered: Bool?

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
        contentBlocks: [ForumThreadContentBlock]? = nil,
        replyReference: ForumPostReplyReference? = nil,
        postedAt: String? = nil,
        isThreadAuthor: Bool? = nil,
        quoteBlocks: [ForumThreadContentBlock]? = nil
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
        self.replyReference = replyReference
        self.postedAt = postedAt
        self.isThreadAuthor = isThreadAuthor
        self.quoteBlocks = quoteBlocks
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
    public var pendingRatings: [ChapterCommentRatingRequest]?
    public var needsInitialRetry: Bool?

    public var isComplete: Bool {
        (isBoundaryClosed || isThreadEndConfirmed == true) && nextView == nil
            && (pendingRatings ?? []).isEmpty && needsInitialRetry != true
    }

    public var discussions: [ChapterCommentDiscussion] {
        ChapterCommentDiscussion.group(comments, target: target)
    }

    mutating func append(_ page: Self) {
        var indexes = Dictionary(uniqueKeysWithValues: comments.enumerated().map { ($0.element.id, $0.offset) })
        for comment in page.comments {
            if let index = indexes[comment.id] { comments[index] = comment }
            else { indexes[comment.id] = comments.count; comments.append(comment) }
        }
        let known = Set(pendingRatings ?? [])
        pendingRatings = (pendingRatings ?? []) + (page.pendingRatings ?? []).filter { !known.contains($0) }
        isBoundaryClosed = page.isBoundaryClosed
        nextView = page.isBoundaryClosed ? nil : page.nextView
        isThreadEndConfirmed = page.isThreadEndConfirmed
    }

    mutating func replaceRatings(_ ratings: [ChapterComment], request: ChapterCommentRatingRequest) {
        let previews = comments.filter { $0.source == .ratingReason && $0.postID == request.postID }
        let insertion = comments.firstIndex { $0.source == .ratingReason && $0.postID == request.postID }
            ?? comments.lastIndex { $0.postID == request.postID }.map { $0 + 1 } ?? comments.count
        let enriched = ratings.map { value in
            var rating = value
            let matches = previews.filter { $0.authorName == rating.authorName }
            if matches.count == 1, let preview = matches.first {
                rating.authorAvatarURL = rating.authorAvatarURL ?? preview.authorAvatarURL
                rating.authorUID = rating.authorUID ?? preview.authorUID
                rating.isThreadAuthor = rating.isThreadAuthor ?? preview.isThreadAuthor
            }
            return rating
        }
        comments.removeAll { $0.source == .ratingReason && $0.postID == request.postID }
        comments.insert(contentsOf: enriched, at: min(insertion, comments.count))
        pendingRatings?.removeAll { $0 == request }
    }

    public init(
        target: ReaderChapterCommentTarget,
        comments: [ChapterComment],
        isBoundaryClosed: Bool,
        nextView: Int? = nil,
        isThreadEndConfirmed: Bool? = nil,
        pendingRatings: [ChapterCommentRatingRequest]? = nil,
        needsInitialRetry: Bool? = nil
    ) {
        self.target = target
        self.comments = comments
        self.isBoundaryClosed = isBoundaryClosed
        self.nextView = nextView
        self.isThreadEndConfirmed = isThreadEndConfirmed
        self.pendingRatings = pendingRatings
        self.needsInitialRetry = needsInitialRetry
    }
}

public struct ChapterCommentRatingRequest: Codable, Hashable, Sendable {
    public var postID: String
    public var url: URL

    public init(postID: String, url: URL) {
        self.postID = postID
        self.url = url
    }
}

public struct ChapterCommentReply: Hashable, Identifiable, Sendable {
    public var comment: ChapterComment
    public var replyingToName: String?
    public var parentCommentID: String
    public var conversationRootID: String
    public var id: String { comment.id }
}

public struct ChapterCommentConversation: Hashable, Identifiable, Sendable {
    public var root: ChapterComment
    public var replies: [ChapterCommentReply]
    public var id: String { root.id }

    public func filtering(visibleIDs: Set<String>) -> Self? {
        var result = self
        result.replies.removeAll { !visibleIDs.contains($0.id) }
        guard visibleIDs.contains(root.id) || !result.replies.isEmpty else { return nil }
        if !visibleIDs.contains(root.id) { result.root = root.filteredPlaceholder }
        return result
    }
}

private extension ChapterComment {
    var filteredPlaceholder: Self {
        var result = self
        result.isFiltered = true
        result.body = ""
        result.bodyBlocks = nil
        result.contentBlocks = nil
        result.quoteBlocks = nil
        return result
    }
}

public struct ChapterCommentDiscussion: Hashable, Identifiable, Sendable {
    public var root: ChapterComment
    public var replies: [ChapterCommentReply]
    public var conversations: [ChapterCommentConversation] = []
    public var id: String { root.id }

    public func filtering(visibleIDs: Set<String>) -> Self? {
        var result = self
        result.replies.removeAll { !visibleIDs.contains($0.id) }
        result.conversations = conversations.compactMap { $0.filtering(visibleIDs: visibleIDs) }
        guard visibleIDs.contains(root.id) || !result.replies.isEmpty else { return nil }
        if !visibleIDs.contains(root.id) { result.root = root.filteredPlaceholder }
        return result
    }

    static func group(_ comments: [ChapterComment], target: ReaderChapterCommentTarget) -> [Self] {
        var posts: [String: ChapterComment] = [:]
        var unique: [ChapterComment] = []
        var seen = Set<String>()
        for comment in comments where seen.insert(comment.id).inserted {
            unique.append(comment)
            if comment.source == .reply, let pid = comment.postID { posts[pid] = comment }
        }
        var parents: [String: String] = [:]
        let order = Dictionary(uniqueKeysWithValues: unique.enumerated().map { ($0.element.id, $0.offset) })
        for comment in unique {
            if comment.source != .reply {
                if let pid = comment.postID, let parent = posts[pid] { parents[comment.id] = parent.id }
                continue
            }
            guard let reference = comment.replyReference else { continue }
            let parent: ChapterComment?
            if let pid = reference.postID {
                parent = posts[pid]
            } else if let name = reference.authorName, let time = reference.postedAt {
                let matches = posts.values.filter {
                    $0.authorName == name && $0.postedAt == time && order[$0.id, default: 0] < order[comment.id, default: 0]
                }
                parent = matches.count == 1 ? matches.first : nil
            } else {
                parent = nil
            }
            if let parent, parent.id != comment.id { parents[comment.id] = parent.id }
        }
        let byID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) })
        // Resolve against the complete loaded chapter, before filtering, so hidden
        // intermediate replies do not detach their descendants.
        func rootID(for id: String) -> String {
            var current = id
            var visited = Set<String>()
            while let parent = parents[current] {
                guard visited.insert(current).inserted else { return id }
                current = parent
            }
            return current
        }
        var result: [Self] = []
        var indexes: [String: Int] = [:]
        for comment in unique where rootID(for: comment.id) == comment.id {
            var root = comment
            if root.replyReference?.postID == target.ownerPostID { root.quoteBlocks = nil }
            indexes[root.id] = result.count
            result.append(Self(root: root, replies: []))
        }
        for comment in unique {
            let root = rootID(for: comment.id)
            guard root != comment.id, let index = indexes[root], let parentID = parents[comment.id] else { continue }
            var child = comment
            child.quoteBlocks = nil
            let parent = parents[comment.id].flatMap { byID[$0] }
            let name = parent?.id == root ? nil : parent?.authorName
            var conversationRoot = comment.id
            while let ancestor = parents[conversationRoot], ancestor != root { conversationRoot = ancestor }
            result[index].replies.append(ChapterCommentReply(
                comment: child, replyingToName: name,
                parentCommentID: parentID, conversationRootID: conversationRoot
            ))
        }
        for index in result.indices {
            let replies = result[index].replies
            let branches = Dictionary(grouping: replies, by: \.conversationRootID)
            result[index].conversations = replies.filter { $0.id == $0.conversationRootID }.map { start in
                ChapterCommentConversation(root: start.comment, replies: branches[start.id, default: []].filter { $0.id != start.id })
            }
        }
        return result
    }
}
