import SwiftUI
import YamiboXCore

/// Reuses the feature screens, while each tab owns its navigation path.
struct OptionalTabRootView: View {
    let tab: AppTab
    let appModel: YamiboAppModel
    @State private var navigator: ForumDestinationNavigator
    @State private var account: MineHomeViewModel
    @State private var showsLogin = false

    init(tab: AppTab, appModel: YamiboAppModel) {
        self.tab = tab
        self.appModel = appModel
        _navigator = State(initialValue: ForumDestinationNavigator(
            dependencies: appModel.appContext.forumNavigationDependencies,
            actions: appModel.forumNavigationActions,
            mode: .forumTab
        ))
        _account = State(initialValue: MineHomeViewModel(dependencies: appModel.appContext.accountDependencies))
    }

    var body: some View {
        ForumDestinationStackView(navigator: navigator, appModel: appModel) {
            root
                .messageUnreadTabAccessibility(count: appModel.unreadCount(for: tab))
        }
        .task {
            guard tab == .messages else { return }
            await account.load()
            for await _ in appModel.appContext.accountDependencies.sessionStore.changes() {
                guard !Task.isCancelled else { return }
                await account.reloadAccountSnapshot()
            }
        }
        .sheet(isPresented: $showsLogin) {
            MineLoginSheet(viewModel: account, accountSwitcher: appModel.appContext.accountSwitcher) {
                showsLogin = false
            }
        }
        .onChange(of: account.isLoggedIn) { _, loggedIn in
            if !loggedIn { navigator.path = [] }
        }
    }

    @ViewBuilder
    private var root: some View {
        switch tab {
        case .messages:
            if account.isLoggedIn {
                ForumDestinationScreen(destination: .messageCenter(tab: .privateMessages), navigator: navigator, appModel: appModel)
            } else {
                ContentUnavailableView {
                    Label(L10n.string("messages.login_required_title"), systemImage: "envelope")
                } description: {
                    Text(L10n.string("messages.login_required_message"))
                } actions: {
                    Button(L10n.string("mine.login")) { showsLogin = true }.buttonStyle(.borderedProminent)
                }
                .navigationTitle(tab.title)
                .navigationBarTitleDisplayMode(.inline)
            }
        case .history:
            BrowsingHistoryView(
                dependencies: appModel.appContext.libraryDependencies.history,
                appModel: appModel,
                onOpenThread: { url, title in navigator.pushThreadLink(url: url, title: title) },
                ownsNavigation: false
            )
        case .likes:
            LikeWorkListView(
                likeDependencies: appModel.appContext.likeLibraryDependencies,
                contentCoverStore: appModel.appContext.libraryDependencies.contentCoverStore,
                favoriteLibraryStore: appModel.appContext.libraryDependencies.localFavoriteLibraryStore,
                settingsStore: appModel.appContext.settingsStore,
                appModel: appModel,
                ownsNavigation: false
            )
        default:
            EmptyView()
        }
    }
}

/// The hidden bookshelf remains accessible from Mine without nesting stacks.
struct MineBookshelfView: View {
    let appModel: YamiboAppModel
    let navigator: ForumDestinationNavigator

    var body: some View {
        BookshelfView(
            libraryDependencies: appModel.appContext.libraryDependencies,
            accountDependencies: appModel.appContext.accountDependencies,
            accountSwitcher: appModel.appContext.accountSwitcher,
            forumDependencies: appModel.appContext.forumNavigationDependencies,
            appModel: appModel,
            navigator: navigator
        )
    }
}
