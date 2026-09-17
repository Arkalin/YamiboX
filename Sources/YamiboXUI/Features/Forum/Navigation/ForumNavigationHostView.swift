import SwiftUI
import YamiboXCore

public struct ForumNavigationHostView: View {
    @State private var model: ForumHomeViewModel
    @State private var navigator: ForumDestinationNavigator

    private let appModel: YamiboAppModel
    private let theme: ForumTheme

    public init(
        dependencies: ForumDependencies,
        appModel: YamiboAppModel,
        theme: ForumTheme = .classic
    ) {
        self.appModel = appModel
        self.theme = theme
        _model = State(wrappedValue: ForumHomeViewModel(dependencies: dependencies))
        _navigator = State(wrappedValue: ForumDestinationNavigator(
            dependencies: dependencies,
            appModel: appModel,
            mode: .forumTab,
            usesSplitNavigation: UIDevice.current.userInterfaceIdiom == .pad
        ))
    }

    public var body: some View {
        ForumBrowserNavigationView(navigator: navigator) {
            ForumHomeView(
                model: model,
                onBoardTap: { navigator.openBoard($0, fromBrowserList: true) },
                onCarouselTap: { navigator.openCarouselItem($0, fromBrowserList: true) }
            )
            .navigationTitle(L10n.string("forum.default_title"))
            .yamiboInlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navigator.openSearch(fid: nil, fromBrowserList: true)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel(L10n.string("forum.home.search_placeholder"))
                    .keyboardShortcut("f", modifiers: .command)
                }
            }
            .forumNavigationBarStyle()
        }
        .task {
            await model.load()
        }
        .onChange(of: appModel.forumNavigationRequest?.id, initial: true) { _, _ in
            guard let request = appModel.claimForumNavigationRequest() else { return }
            navigator.route(request.url, source: request.source, title: request.title)
        }
        // `initial: true` also catches a Home Screen quick action tapped
        // before this view ever mounted (cold launch): the scene delegate
        // stamps the request while `RootTabView` is still bootstrapping, so
        // there's no prior value for a plain `.onChange` to transition from.
        .onChange(of: appModel.forumSearchRequest?.id, initial: true) { _, _ in
            guard appModel.claimForumSearchRequest() != nil else { return }
            navigator.openSearch(fid: nil, fromBrowserList: true)
        }
        .forumTheme(theme)
    }
}
