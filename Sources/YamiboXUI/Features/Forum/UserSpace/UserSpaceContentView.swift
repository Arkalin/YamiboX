import SwiftUI
import YamiboXCore

struct UserSpaceContentView: View {
    @Environment(\.forumBlacklist) private var blacklist
    let selectedSubPage: UserSpaceSubPage
    let spaceUID: String?
    let content: UserSpaceViewModel.Content?
    let pageNavigation: ForumPageNavigation?
    let currentPage: Int
    let goToPage: (Int) -> Void
    let onThreadTap: (URL, String?) -> Void
    let onUserTap: (String, String?) -> Void
    let onBlogTap: (UserSpaceBlogSummary) -> Void
    let onPrivateMessageTap: (String, String?) -> Void
    let onWebTap: (URL) -> Void

    var body: some View {
        switch selectedSubPage {
        case .profile:
            EmptyView()
        case .threads:
            if case let .threads(page) = content {
                let threads = page.threads.filter { blacklist?.contains(spaceUID ?? $0.authorID) != true }
                if page.threads.isEmpty {
                    UserSpaceEmptyView(message: L10n.string("user_space.empty_threads"))
                } else if threads.isEmpty {
                    ForumBlacklistEmptyView()
                } else {
                    ForEach(threads) { thread in
                        ForumThreadSummaryRowView(
                            thread: thread,
                            onThreadTap: { onThreadTap(thread.url, thread.title) },
                            onAuthorTap: onUserTap
                        )
                    }
                }
                ForumPageNavigationBar(navigation: pageNavigation, currentPage: currentPage, goToPage: goToPage, hidesOnSinglePage: true)
            }
        case .replies:
            if case let .replies(page) = content {
                if page.replies.isEmpty {
                    UserSpaceEmptyView(message: L10n.string("user_space.empty_replies"))
                } else if blacklist?.contains(spaceUID) == true {
                    ForumBlacklistEmptyView()
                } else {
                    ForEach(page.replies) { reply in
                        UserSpaceReplyRowView(reply: reply) {
                            onThreadTap(reply.threadURL, reply.threadTitle)
                        }
                    }
                }
                ForumPageNavigationBar(navigation: pageNavigation, currentPage: currentPage, goToPage: goToPage, hidesOnSinglePage: true)
            }
        case .myBlogs, .friendBlogs, .viewAllBlogs:
            if case let .blogs(page) = content {
                if page.blogs.isEmpty {
                    UserSpaceEmptyView(message: L10n.string("user_space.empty_blogs"))
                } else {
                    ForEach(page.blogs) { blog in
                        UserSpaceBlogRowView(blog: blog, onUserTap: onUserTap) {
                            onBlogTap(blog)
                        }
                    }
                    ForumPageNavigationBar(navigation: pageNavigation, currentPage: currentPage, goToPage: goToPage, hidesOnSinglePage: true)
                }
            }
        case .friends, .online, .visitors, .traces:
            if case let .friends(page) = content {
                if page.friends.isEmpty {
                    UserSpaceEmptyView(message: emptyFriendsMessage)
                } else {
                    ForEach(page.friends) { friend in
                        UserSpaceFriendRowView(
                            friend: friend,
                            onPrivateMessageTap: onPrivateMessageTap,
                            onWebTap: onWebTap
                        ) {
                            onUserTap(friend.uid, friend.name)
                        }
                    }
                    ForumPageNavigationBar(navigation: pageNavigation, currentPage: currentPage, goToPage: goToPage, hidesOnSinglePage: true)
                }
            }
        }
    }

    private var emptyFriendsMessage: String {
        switch selectedSubPage {
        case .online:
            L10n.string("user_space.empty_online")
        case .visitors:
            L10n.string("user_space.empty_visitors")
        case .traces:
            L10n.string("user_space.empty_traces")
        default:
            L10n.string("user_space.empty_friends")
        }
    }
}
