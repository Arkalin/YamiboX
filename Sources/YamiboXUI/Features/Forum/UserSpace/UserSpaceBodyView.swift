import SwiftUI
import YamiboXCore

struct UserSpaceBodyView: View {
    let profile: UserSpaceProfile?
    let selectedSubPage: UserSpaceSubPage
    let availableSubPages: [UserSpaceSubPage]
    let viewAllBlogFilter: UserSpaceViewAllBlogFilter
    let content: UserSpaceViewModel.Content?
    let pageNavigation: ForumPageNavigation?
    let currentPage: Int
    let isLoadingProfile: Bool
    let isLoadingContent: Bool
    let isSelf: Bool
    let errorMessage: String?
    let selectSubPage: (UserSpaceSubPage) -> Void
    let selectViewAllBlogFilter: (UserSpaceViewAllBlogFilter) -> Void
    let beginAddFriend: () -> Void
    let refresh: () async -> Void
    let retry: () -> Void
    let goToPage: (Int) -> Void
    let onThreadTap: (URL, String?) -> Void
    let onUserTap: (String, String?) -> Void
    let onSectionTap: (UserSpaceSection, UserSpaceSubPage) -> Void
    let onBlogTap: (UserSpaceBlogSummary) -> Void
    let onPrivateMessageTap: (String, String?) -> Void
    let onMessageCenterTap: (MessageCenterTab) -> Void
    let onWebTap: (URL) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if selectedSubPage == .profile {
                    UserSpaceProfileContentView(
                        profile: profile,
                        isSelf: isSelf,
                        isLoading: isLoadingProfile,
                        errorMessage: errorMessage,
                        onSectionTap: onSectionTap,
                        beginAddFriend: beginAddFriend,
                        onMessageCenterTap: onMessageCenterTap,
                        retry: retry,
                        onWebTap: onWebTap
                    )
                } else {
                    UserSpaceSubPageContentView(
                        selectedSubPage: selectedSubPage,
                        availableSubPages: availableSubPages,
                        viewAllBlogFilter: viewAllBlogFilter,
                        content: content,
                        pageNavigation: pageNavigation,
                        currentPage: currentPage,
                        isLoadingContent: isLoadingContent,
                        errorMessage: errorMessage,
                        selectSubPage: selectSubPage,
                        selectViewAllBlogFilter: selectViewAllBlogFilter,
                        retry: retry,
                        goToPage: goToPage,
                        onThreadTap: onThreadTap,
                        onUserTap: onUserTap,
                        onBlogTap: onBlogTap,
                        onPrivateMessageTap: onPrivateMessageTap,
                        onWebTap: onWebTap
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .refreshable {
            await refresh()
        }
        .topRefreshIndicator(isVisible: isLoadingContent && content != nil)
        .forumPageBackground()
        .tint(ForumColors.brownDeep)
    }
}

private struct UserSpaceProfileContentView: View {
    let profile: UserSpaceProfile?
    let isSelf: Bool
    let isLoading: Bool
    let errorMessage: String?
    let onSectionTap: (UserSpaceSection, UserSpaceSubPage) -> Void
    let beginAddFriend: () -> Void
    let onMessageCenterTap: (MessageCenterTab) -> Void
    let retry: () -> Void
    let onWebTap: (URL) -> Void

    var body: some View {
        if let profile {
            UserSpaceProfileHeaderView(
                profile: profile,
                isSelf: isSelf,
                onSectionTap: onSectionTap,
                beginAddFriend: beginAddFriend,
                onMessageCenterTap: onMessageCenterTap,
                onWebTap: onWebTap
            )
        } else if let errorMessage {
            UserSpaceErrorView(message: errorMessage, retry: retry)
        } else if isLoading {
            UserSpaceLoadingView()
        } else {
            UserSpaceLoadingView()
        }
    }
}

private struct UserSpaceSubPageContentView: View {
    let selectedSubPage: UserSpaceSubPage
    let availableSubPages: [UserSpaceSubPage]
    let viewAllBlogFilter: UserSpaceViewAllBlogFilter
    let content: UserSpaceViewModel.Content?
    let pageNavigation: ForumPageNavigation?
    let currentPage: Int
    let isLoadingContent: Bool
    let errorMessage: String?
    let selectSubPage: (UserSpaceSubPage) -> Void
    let selectViewAllBlogFilter: (UserSpaceViewAllBlogFilter) -> Void
    let retry: () -> Void
    let goToPage: (Int) -> Void
    let onThreadTap: (URL, String?) -> Void
    let onUserTap: (String, String?) -> Void
    let onBlogTap: (UserSpaceBlogSummary) -> Void
    let onPrivateMessageTap: (String, String?) -> Void
    let onWebTap: (URL) -> Void

    var body: some View {
        if availableSubPages.count > 1 {
            UserSpaceSubPagePickerView(
                subPages: availableSubPages,
                selectedSubPage: selectedSubPage,
                selectSubPage: selectSubPage
            )
        }

        if selectedSubPage == .viewAllBlogs {
            UserSpaceViewAllBlogFilterView(
                selectedFilter: viewAllBlogFilter,
                selectFilter: selectViewAllBlogFilter
            )
        }

        if let errorMessage, content == nil {
            UserSpaceErrorView(message: errorMessage, retry: retry)
        } else if isLoadingContent && content == nil {
            UserSpaceLoadingView()
        } else {
            UserSpaceContentView(
                selectedSubPage: selectedSubPage,
                content: content,
                pageNavigation: pageNavigation,
                currentPage: currentPage,
                goToPage: goToPage,
                onThreadTap: onThreadTap,
                onUserTap: onUserTap,
                onBlogTap: onBlogTap,
                onPrivateMessageTap: onPrivateMessageTap,
                onWebTap: onWebTap
            )
        }
    }
}
