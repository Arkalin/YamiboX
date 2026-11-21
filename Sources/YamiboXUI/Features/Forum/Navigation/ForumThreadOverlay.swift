import SwiftUI
import YamiboXCore

#if os(iOS)

struct ForumThreadOverlayItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let title: String?
}

struct ForumThreadOverlayScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var navigator: ForumDestinationNavigator

    private let item: ForumThreadOverlayItem
    private let appModel: YamiboAppModel
    private let rootIsDiscussionView: Bool

    init(
        item: ForumThreadOverlayItem,
        dependencies: ForumNavigationDependencies,
        appModel: YamiboAppModel,
        rootIsDiscussionView: Bool,
        discussionWorkTIDs: Set<String> = []
    ) {
        self.item = item
        self.appModel = appModel
        self.rootIsDiscussionView = rootIsDiscussionView
        _navigator = State(wrappedValue: ForumDestinationNavigator(
            dependencies: dependencies,
            actions: appModel.forumNavigationActions,
            mode: .readerOverlay,
            discussionWorkTIDs: discussionWorkTIDs
        ))
    }

    var body: some View {
        ForumDestinationStackView(navigator: navigator, appModel: appModel) {
            ForumThreadLinkScreen(
                url: item.url,
                title: item.title,
                containingFid: nil,
                authorID: nil,
                isDiscussionView: rootIsDiscussionView,
                navigator: navigator,
                appModel: appModel
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
        .forumTheme(AppTheme.theme(for: appModel.appAppearanceSettings).forumTheme)
    }
}

#endif
