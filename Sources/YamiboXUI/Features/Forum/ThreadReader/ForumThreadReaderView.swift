import SwiftUI
import YamiboXCore

struct ForumThreadReaderView: View {
    @State private var model: ForumThreadReaderViewModel

    let onUserTap: (String, String?) -> Void
    let onURLTap: (URL) -> Void

    init(
        model: ForumThreadReaderViewModel,
        onUserTap: @escaping (String, String?) -> Void,
        onURLTap: @escaping (URL) -> Void
    ) {
        _model = State(wrappedValue: model)
        self.onUserTap = onUserTap
        self.onURLTap = onURLTap
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
            isFavorited: model.isFavorited,
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
            onURLTap: onURLTap
        )
        .navigationTitle(model.navigationTitle)
        .yamiboInlineNavigationTitleDisplayMode()
        // The reader's own action bar already owns the bottom edge; keeping
        // the tab bar under it would stack two bars there. No-op in the
        // reader-overlay stack, which has no tab bar to begin with.
        .toolbar(.hidden, for: .tabBar)
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(L10n.string("common.more"))
            }
        }
        .alert(
            L10n.string("forum.thread.favorite_failed"),
            isPresented: favoriteErrorBinding,
            actions: {
                Button(L10n.string("common.ok")) {
                    model.clearFavoriteError()
                }
            },
            message: {
                Text(model.favoriteErrorMessage ?? "")
            }
        )
        .favoriteQuickActionDialogs(
            addPromptPresented: Bindable(model).favoriteAddPromptPresented,
            removePrompt: Bindable(model).favoriteRemovePrompt,
            onConfirmAdd: { syncToRemote, remember in
                Task { await model.confirmFavoriteAdd(syncToRemote: syncToRemote, remember: remember) }
            },
            onConfirmRemoval: { favorite, removeRemote, remember in
                Task { await model.confirmFavoriteRemoval(favorite, removeRemote: removeRemote, remember: remember) }
            }
        )
        .sheet(item: Bindable(model).favoriteLocationPickerContext) { context in
            FavoriteLocationPickerSheet(
                context: context,
                onCancel: { model.favoriteLocationPickerContext = nil },
                onConfirm: { locations in
                    Task { await model.confirmFavoriteLocationSelection(locations) }
                }
            )
        }
        .task {
            await model.load()
        }
        .onDisappear {
            model.flushReadingProgress()
        }
        .transientMessage(model.transientMessage, bottomPadding: model.page == nil ? 24 : 82) {
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
            await model.toggleFavorite()
        }
    }

    private func presentFavoriteLocationPicker() {
        Task {
            await model.presentFavoriteLocationPicker()
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

    private var favoriteErrorBinding: Binding<Bool> {
        Binding(
            get: {
                model.favoriteErrorMessage != nil
            },
            set: { isPresented in
                if !isPresented {
                    model.clearFavoriteError()
                }
            }
        )
    }
}
