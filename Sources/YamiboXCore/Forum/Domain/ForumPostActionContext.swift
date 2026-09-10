import Foundation

/// A verified post in the unfiltered thread, independent of reader pagination.
public struct ForumPostActionContext: Equatable, Sendable {
    public let threadID: String
    public let post: ForumThreadPost
    public let page: Int
    public let formHash: String

    public init(threadID: String, post: ForumThreadPost, page: Int, formHash: String) {
        self.threadID = threadID
        self.post = post
        self.page = page
        self.formHash = formHash
    }

    public var replyURL: URL {
        YamiboRoute.threadPostReply(tid: threadID, pid: post.postID, page: page).url
    }
}
