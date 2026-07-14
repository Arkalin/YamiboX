import SwiftUI
import YamiboXCore

struct UserSpaceView: View {
    @State private var model: UserSpaceViewModel

    let onThreadTap: (URL, String?) -> Void
    let onUserTap: (String, String?) -> Void
    let onSectionTap: (String?, String?, UserSpaceSection, UserSpaceSubPage) -> Void
    let onBlogTap: (UserSpaceBlogSummary) -> Void
    let onPrivateMessageTap: (String, String?) -> Void
    let onMessageCenterTap: (MessageCenterTab) -> Void
    let onWebTap: (URL) -> Void

    init(
        model: UserSpaceViewModel,
        onThreadTap: @escaping (URL, String?) -> Void,
        onUserTap: @escaping (String, String?) -> Void,
        onSectionTap: @escaping (String?, String?, UserSpaceSection, UserSpaceSubPage) -> Void,
        onBlogTap: @escaping (UserSpaceBlogSummary) -> Void,
        onPrivateMessageTap: @escaping (String, String?) -> Void,
        onMessageCenterTap: @escaping (MessageCenterTab) -> Void,
        onWebTap: @escaping (URL) -> Void
    ) {
        _model = State(wrappedValue: model)
        self.onThreadTap = onThreadTap
        self.onUserTap = onUserTap
        self.onSectionTap = onSectionTap
        self.onBlogTap = onBlogTap
        self.onPrivateMessageTap = onPrivateMessageTap
        self.onMessageCenterTap = onMessageCenterTap
        self.onWebTap = onWebTap
    }

    var body: some View {
        UserSpaceBodyView(
            profile: model.profile,
            selectedSubPage: model.selectedSubPage,
            availableSubPages: model.availableSubPages,
            viewAllBlogFilter: model.viewAllBlogFilter,
            content: model.content,
            pageNavigation: model.pageNavigation,
            currentPage: model.currentPage,
            isLoadingProfile: model.isLoadingProfile,
            isLoadingContent: model.isLoadingContent,
            isSelf: model.isSelf,
            errorMessage: model.errorMessage,
            selectSubPage: selectSubPage,
            selectViewAllBlogFilter: selectViewAllBlogFilter,
            beginAddFriend: beginAddFriend,
            refresh: refresh,
            retry: retry,
            goToPage: goToPage,
            onThreadTap: onThreadTap,
            onUserTap: onUserTap,
            onSectionTap: { section, subPage in
                onSectionTap(model.uid, model.profile?.username ?? model.titleHint, section, subPage)
            },
            onBlogTap: onBlogTap,
            onPrivateMessageTap: onPrivateMessageTap,
            onMessageCenterTap: onMessageCenterTap,
            onWebTap: onWebTap
        )
        .forumPageBackground()
        .tint(ForumColors.brownDeep)
        .navigationTitle(model.navigationTitle)
        .toolbar {
            if model.canOpenBlogEditor {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onWebTap(YamiboRoute.userSpaceBlogEditor.url)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel(L10n.string("user_space.write_blog"))
                }
            }
        }
        .task {
            await model.load()
        }
        .sheet(isPresented: Binding(
            get: { model.isAddFriendSheetPresented },
            set: { isPresented in
                if !isPresented {
                    model.dismissAddFriend()
                }
            }
        )) {
            UserSpaceAddFriendSheet(
                targetName: model.addFriendTargetName,
                form: model.addFriendForm,
                isLoading: model.isLoadingAddFriendForm,
                isSubmitting: model.isSubmittingAddFriend,
                errorMessage: model.addFriendErrorMessage,
                retry: retryAddFriendForm,
                submit: submitAddFriend,
                dismiss: { model.dismissAddFriend() }
            )
        }
        .alert(
            L10n.string("user_space.add_friend_result"),
            isPresented: Binding(
                get: { model.addFriendResultMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.clearAddFriendResult()
                    }
                }
            )
        ) {
            Button(L10n.string("common.ok")) {
                model.clearAddFriendResult()
            }
        } message: {
            Text(model.addFriendResultMessage ?? "")
        }
    }

    private func selectSubPage(_ subPage: UserSpaceSubPage) {
        Task {
            await model.selectSubPage(subPage)
        }
    }

    private func selectViewAllBlogFilter(_ filter: UserSpaceViewAllBlogFilter) {
        Task {
            await model.selectViewAllBlogFilter(filter)
        }
    }

    private func beginAddFriend() {
        Task {
            await model.beginAddFriend()
        }
    }

    private func retryAddFriendForm() {
        Task {
            await model.retryAddFriendForm()
        }
    }

    private func submitAddFriend(_ note: String, _ groupID: Int) {
        Task {
            await model.submitAddFriend(note: note, groupID: groupID)
        }
    }

    private func refresh() async {
        await model.refresh()
    }

    private func retry() {
        Task {
            await model.refresh()
        }
    }

    private func goToPage(_ page: Int) {
        Task {
            await model.goToPage(page)
        }
    }
}
