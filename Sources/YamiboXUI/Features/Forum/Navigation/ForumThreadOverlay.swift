import SwiftUI
import YamiboXCore

#if os(iOS)

/// A request to show a forum thread as a full-screen cover over the current
/// context (a running reader, the favorites tab) instead of rerouting the
/// forum tab.
struct ForumThreadOverlayItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let title: String?
}

/// The full-screen cover content for `ForumThreadOverlayItem`: a full forum
/// stack (`.readerOverlay` mode) rooted at the requested thread, so in-post
/// links, user profiles and boards all stay inside the overlay while the
/// presenting context keeps running underneath. A cover has no
/// swipe-to-dismiss, so the root keeps an explicit close button.
struct ForumThreadOverlayScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var navigator: ForumDestinationNavigator

    private let item: ForumThreadOverlayItem
    private let rootIsDiscussionView: Bool

    /// - Parameters:
    ///   - rootIsDiscussionView: Whether the root thread is a discussion
    ///     companion of a work being read. Readers pass `true` — the root must
    ///     not write its own browsing-history row (browsing-history decision
    ///     #14), same as the old `.readerDiscussion` dismissal route. Entry
    ///     points that open a thread as a real visit (favorites) pass `false`
    ///     so the visit is recorded as before.
    ///   - discussionWorkTIDs: Thread IDs of the work being read; links inside
    ///     the overlay resolving back to this set are forced into discussion
    ///     view. Empty when no reader is underneath.
    init(
        item: ForumThreadOverlayItem,
        dependencies: ForumDependencies,
        appModel: YamiboAppModel,
        rootIsDiscussionView: Bool,
        discussionWorkTIDs: Set<String> = []
    ) {
        self.item = item
        self.rootIsDiscussionView = rootIsDiscussionView
        _navigator = State(wrappedValue: ForumDestinationNavigator(
            dependencies: dependencies,
            appModel: appModel,
            mode: .readerOverlay,
            discussionWorkTIDs: discussionWorkTIDs
        ))
    }

    var body: some View {
        ForumDestinationStackView(navigator: navigator) {
            ForumThreadLinkScreen(
                url: item.url,
                title: item.title,
                containingFid: nil,
                authorID: nil,
                isDiscussionView: rootIsDiscussionView,
                navigator: navigator
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ReaderToolbarIconButton(
                        systemName: "xmark",
                        title: L10n.string("common.done"),
                        action: { dismiss() }
                    )
                }
            }
            .forumNavigationBarStyle()
        }
    }
}

#endif
