import SwiftUI
import YamiboXCore

struct ForumThreadReaderView: View {
    @Environment(\.forumKeepsTabBarVisible) private var keepsTabBarVisible
    @State private var model: ForumThreadReaderViewModel

    let onUserTap: (String, String?) -> Void
    let onURLTap: (URL) -> Void
    let onReaderModeSwitch: ((YamiboThreadReaderOverride) -> Void)?
    let isSwitchingReaderMode: Bool
    let submissionChange: ForumSubmissionChange?

    init(
        model: ForumThreadReaderViewModel,
        submissionChange: ForumSubmissionChange? = nil,
        onUserTap: @escaping (String, String?) -> Void,
        onURLTap: @escaping (URL) -> Void,
        onReaderModeSwitch: ((YamiboThreadReaderOverride) -> Void)? = nil,
        isSwitchingReaderMode: Bool = false
    ) {
        _model = State(wrappedValue: model)
        self.submissionChange = submissionChange
        self.onUserTap = onUserTap
        self.onURLTap = onURLTap
        self.onReaderModeSwitch = onReaderModeSwitch
        self.isSwitchingReaderMode = isSwitchingReaderMode
    }

    var body: some View {
        ForumThreadReaderBodyView(
            page: model.page,
            pageNavigation: model.pageNavigation,
            currentPage: model.currentPage,
            targetPostID: model.targetPostID,
            restoredAnchorPostID: model.restoredAnchorPostID,
            onConsumeRestoredAnchor: {
                model.consumeRestoredAnchor()
            },
            onVisibleAnchorChange: { postID in
                model.updateVisibleAnchor(postID: postID)
            },
            isLoading: model.isLoading,
            errorMessage: model.errorMessage,
            errorDetails: model.errorDetails,
            isFavorited: model.isFavorited,
            isFavoriteWorking: model.favoriteActions.isWorking,
            isReverseOrder: model.isReverseOrder,
            refresh: refresh,
            retry: model.retry,
            goToPage: goToPage,
            toggleFavorite: toggleFavorite,
            presentFavoriteLocationPicker: presentFavoriteLocationPicker,
            makeImageBrowserRequest: model.imageBrowserRequest,
            imageBrowserCoverActionsProvider: model.imageBrowserCoverActionsProvider,
            loadRatingResults: model.loadRatingResults,
            loadRateOptions: model.loadRateOptions,
            loadPollVoters: model.loadPollVoters,
            votePoll: model.votePoll,
            ratePost: model.ratePost,
            commentPost: model.commentPost,
            onUserTap: onUserTap,
            onURLTap: onURLTap,
            onAttachmentTap: { attachment in
                Task { await model.enqueueAttachment(attachment) }
            },
            onReaderModeSwitch: onReaderModeSwitch,
            isSwitchingReaderMode: isSwitchingReaderMode,
            recommendedReaderKind: model.recommendedReaderKind
        )
        .navigationTitle(model.navigationTitle)
        .yamiboInlineNavigationTitleDisplayMode()
        .toolbar(.visible, for: .navigationBar)
        // A detail column can be compact even when its containing window is regular.
        .toolbar(keepsTabBarVisible ? .visible : .hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task {
                            await model.refresh()
                        }
                    } label: {
                        Label(L10n.string("common.refresh"), systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)

                    Toggle(isOn: authorOnlyBinding) {
                        Label(L10n.string("forum.thread.author_only"), systemImage: "person")
                    }
                    .disabled(model.isLoading)

                    Toggle(isOn: reverseOrderBinding) {
                        Label(L10n.string("forum.thread.reverse_order"), systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(model.isLoading)

                    Divider()
                    OpenContentInNewWindowButton(request: YamiboWindowRequest(
                        forumURL: YamiboRoute.threadByID(
                            tid: model.context.thread.tid,
                            page: model.currentPage,
                            authorID: nil,
                            reverse: false
                        ).url
                    ))
                    ShareLink(item: YamiboRoute.threadByID(
                        tid: model.context.thread.tid, page: 1, authorID: nil, reverse: false
                    ).url) {
                        Label(L10n.string("forum.thread.share"), systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(L10n.string("common.more"))
            }
        }
        .favoriteActionInterface(model.favoriteActions, showsTransientFeedback: false)
        .task(id: submissionChange?.id) {
            await model.load(submissionChange: submissionChange)
        }
        .task {
            await model.observeBoardReaderSettings()
        }
        .onDisappear {
            model.flushReadingProgress()
        }
        .transientMessage(model.favoriteActions.transientFeedback ?? model.transientFeedback, bottomPadding: model.page == nil ? 24 : 82) {
            model.clearTransientMessage()
        }
    }

    private func refresh() async {
        await model.refresh()
    }

    private func goToPage(_ page: Int) {
        Task {
            await model.goToPage(page)
        }
    }

    private func toggleFavorite() {
        Task {
            await model.favoriteActions.toggleFavorite()
        }
    }

    private func presentFavoriteLocationPicker() {
        Task {
            await model.favoriteActions.presentLocationPicker()
        }
    }

    /// Both menu toggles read back from the model rather than local state:
    /// `setAuthorOnly` can refuse (unresolvable thread starter), and the
    /// checkmark must follow what actually loaded.
    private var authorOnlyBinding: Binding<Bool> {
        Binding(
            get: {
                model.isAuthorOnly
            },
            set: { isEnabled in
                Task {
                    await model.setAuthorOnly(isEnabled)
                }
            }
        )
    }

    private var reverseOrderBinding: Binding<Bool> {
        Binding(
            get: {
                model.isReverseOrder
            },
            set: { isEnabled in
                Task {
                    await model.setReverseOrder(isEnabled)
                }
            }
        )
    }

}
