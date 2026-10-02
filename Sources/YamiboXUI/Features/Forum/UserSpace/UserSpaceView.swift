import SwiftUI
import YamiboXCore

struct UserSpaceView: View {
    @Environment(\.forumTheme) private var theme
    @Environment(\.forumBlacklist) private var blacklist
    @State private var model: UserSpaceViewModel
    @State private var pendingBlockUID: String?
    @State private var blockErrorMessage: String?
    @State private var blockErrorDetails: LoadFailureDetails?
    @State private var blockFeedback: TransientFeedback?

    let onThreadTap: (URL, String?) -> Void
    let onUserTap: (String, String?) -> Void
    let onSectionTap: (String?, String?, UserSpaceSection, UserSpaceSubPage) -> Void
    let onBlogTap: (UserSpaceBlogSummary) -> Void
    let onPrivateMessageTap: (String, String?) -> Void
    let onMessageCenterTap: (MessageCenterTab) -> Void
    let onCreditLogTap: () -> Void
    let onWebTap: (URL) -> Void
    let refreshRevision: UUID?

    init(
        model: UserSpaceViewModel,
        refreshRevision: UUID? = nil,
        onThreadTap: @escaping (URL, String?) -> Void,
        onUserTap: @escaping (String, String?) -> Void,
        onSectionTap: @escaping (String?, String?, UserSpaceSection, UserSpaceSubPage) -> Void,
        onBlogTap: @escaping (UserSpaceBlogSummary) -> Void,
        onPrivateMessageTap: @escaping (String, String?) -> Void,
        onMessageCenterTap: @escaping (MessageCenterTab) -> Void,
        onCreditLogTap: @escaping () -> Void,
        onWebTap: @escaping (URL) -> Void
    ) {
        _model = State(wrappedValue: model)
        self.refreshRevision = refreshRevision
        self.onThreadTap = onThreadTap
        self.onUserTap = onUserTap
        self.onSectionTap = onSectionTap
        self.onBlogTap = onBlogTap
        self.onPrivateMessageTap = onPrivateMessageTap
        self.onMessageCenterTap = onMessageCenterTap
        self.onCreditLogTap = onCreditLogTap
        self.onWebTap = onWebTap
    }

    var body: some View {
        UserSpaceBodyView(
            profile: model.profile,
            spaceUID: model.profile?.uid ?? model.uid,
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
            errorDetails: model.errorDetails,
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
            onCreditLogTap: onCreditLogTap,
            onWebTap: onWebTap
        )
        .forumPageBackground()
        .tint(theme.accentText)
        .navigationTitle(model.navigationTitle)
        .yamiboInlineNavigationTitleDisplayMode()
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if model.selectedSubPage == .profile, !model.isSelf,
               let uid = model.profile?.uid, blacklist?.accountUID != uid {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if blacklist?.contains(uid) == true {
                            Button {
                                changeBlockState(false, uid: uid)
                            } label: {
                                Label(L10n.string("blacklist.unblock"), systemImage: "person.crop.circle.badge.checkmark")
                            }
                        } else {
                            Button(role: .destructive) {
                                if blacklist?.isLoggedIn == true {
                                    pendingBlockUID = uid
                                } else {
                                    blockErrorMessage = L10n.string("blacklist.login_required")
                                }
                            } label: {
                                Label(L10n.string("blacklist.block"), systemImage: "person.slash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(blacklist == nil || blacklist?.isWorking == true)
                    .accessibilityLabel(L10n.string("common.more"))
                }
            }
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
        .task(id: refreshRevision) {
            await model.load()
        }
        .alert(
            L10n.string("blacklist.confirm", model.profile?.username ?? model.titleHint ?? ""),
            isPresented: Binding(get: { pendingBlockUID != nil }, set: { if !$0 { pendingBlockUID = nil } }),
            presenting: pendingBlockUID
        ) { uid in
            Button(L10n.string("blacklist.block"), role: .destructive) {
                pendingBlockUID = nil
                changeBlockState(true, uid: uid)
            }
            Button(L10n.string("common.cancel"), role: .cancel) { pendingBlockUID = nil }
        }
        .failureAlert(
            L10n.string("common.operation_failed"), message: blockErrorMessage, details: blockErrorDetails,
            isPresented: Binding(get: { blockErrorMessage != nil }, set: {
                if !$0 { blockErrorMessage = nil; blockErrorDetails = nil }
            })
        ) {
            Button(L10n.string("common.ok")) { blockErrorMessage = nil; blockErrorDetails = nil }
        }
        .transientMessage(blockFeedback) { blockFeedback = nil }
        .onChange(of: blacklist?.accountUID) { _, _ in
            pendingBlockUID = nil
            blockErrorMessage = nil
            blockErrorDetails = nil
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
                errorDetails: model.addFriendErrorDetails,
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

    private func changeBlockState(_ blocked: Bool, uid: String) {
        guard let blacklist else { return }
        Task {
            do {
                try await blacklist.setBlocked(blocked, uid: uid)
                blockFeedback = TransientFeedback(message: L10n.string(blocked ? "blacklist.blocked" : "blacklist.unblocked"))
            } catch {
                guard !LoadDiagnosticError.isCancellation(error) else { return }
                blockErrorMessage = LoadDiagnosticError.classificationError(error) as? YamiboError == .notAuthenticated
                    ? L10n.string("blacklist.login_required") : error.localizedDescription
                blockErrorDetails = LoadFailureDetails(error: error)
            }
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
