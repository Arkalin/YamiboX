import Foundation

/// Read-only network capability, also used by favorite update checks.
public protocol ForumThreadPageFetching: Sendable {
    func fetchThreadPage(
        context: ThreadNovelLaunchContext,
        page: Int,
        authorID: String?,
        reverse: Bool
    ) async throws -> ForumThreadPage
}

/// Feature-facing capabilities, shared by app assembly and presentation.
public protocol ForumThreadPageLoading: ForumThreadPageFetching {
    func cachedThreadPage(
        context: ThreadNovelLaunchContext,
        page: Int,
        authorID: String?,
        reverse: Bool
    ) async -> ForumThreadPage?
    func fetchPostActionContext(threadID: String, postID: String) async throws -> ForumPostActionContext
    func fetchRatingResults(threadID: String, postID: String) async throws -> ForumThreadRatingResultsPage
    func fetchRateOptions(threadID: String, postID: String) async throws -> ForumThreadRateOptionsPage
    func fetchPollVoters(threadID: String, optionID: String?, page: Int) async throws -> ForumThreadPollVotersPage
    func votePoll(forumID: String, threadID: String, optionIDs: [String], formHash: String) async throws -> String
    func ratePost(
        threadID: String,
        postID: String,
        score: Int,
        reason: String,
        formHash: String,
        noticeAuthor: Bool
    ) async throws -> String
    func commentPost(threadID: String, postID: String, message: String, formHash: String, page: Int) async throws -> String
}

public protocol UserSpacePageLoading: Sendable {
    func fetchProfile(uid: String?, titleHint: String?) async throws -> UserSpaceProfile
    func fetchThreads(uid: String?, page: Int) async throws -> UserSpaceThreadPage
    func fetchReplies(uid: String?, page: Int) async throws -> UserSpaceReplyPage
    func fetchBlogs(uid: String?, page: Int) async throws -> UserSpaceBlogPage
    func fetchMyBlogs(uid: String?, page: Int) async throws -> UserSpaceBlogPage
    func fetchFriendBlogs(page: Int) async throws -> UserSpaceBlogPage
    func fetchViewAllBlogs(filter: UserSpaceViewAllBlogFilter, page: Int) async throws -> UserSpaceBlogPage
    func fetchFriendPage(type: UserSpaceFriendType, page: Int) async throws -> UserSpaceFriendPage
    func fetchAddFriendForm(uid: String, nameHint: String?) async throws -> UserSpaceAddFriendForm
    func addFriend(uid: String, formHash: String, note: String, groupID: Int) async throws -> String
}

public protocol PrivateMessagePageLoading: Sendable {
    func fetchPrivateMessagePage(uid: String, page: Int?, titleHint: String?) async throws -> PrivateMessagePage
    func sendPrivateMessage(privateMessageID: String, uid: String, formHash: String, message: String) async throws -> String
}

public protocol MessageCenterPageLoading: Sendable {
    func fetchPrivateMessages(page: Int) async throws -> UserSpacePrivateMessagePage
    func fetchNotices(page: Int) async throws -> UserSpaceNoticePage
}

public protocol CreditLogPageLoading: Sendable {
    func fetchCreditLog(filter: CreditLogFilter, page: Int) async throws -> CreditLogPage
}

public protocol BlogReaderPageLoading: Sendable {
    func fetchBlogPage(blogID: String, uid: String?, page: Int) async throws -> BlogReaderPage
    func postBlogComment(blogID: String, uid: String, message: String, formHash: String) async throws -> String
}

public typealias ForumUserSpacePageLoading = UserSpacePageLoading
    & PrivateMessagePageLoading & MessageCenterPageLoading & CreditLogPageLoading
