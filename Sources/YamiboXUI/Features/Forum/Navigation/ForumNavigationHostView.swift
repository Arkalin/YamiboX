import SwiftUI
import YamiboXCore

public struct ForumNavigationHostView: View {
    @State private var model: ForumHomeViewModel
    @State private var navigator: ForumDestinationNavigator

    private let appModel: YamiboAppModel

    public init(dependencies: ForumDependencies, appModel: YamiboAppModel) {
        self.appModel = appModel
        _model = State(wrappedValue: ForumHomeViewModel(dependencies: dependencies))
        _navigator = State(wrappedValue: ForumDestinationNavigator(
            dependencies: dependencies,
            appModel: appModel,
            mode: .forumTab
        ))
    }

    public var body: some View {
        ForumDestinationStackView(navigator: navigator) {
            ForumHomeView(
                model: model,
                onBoardTap: { navigator.openBoard($0) },
                onCarouselTap: { navigator.openCarouselItem($0) }
            )
            .navigationTitle(L10n.string("forum.default_title"))
            .yamiboInlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navigator.push(.search(fid: nil))
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel(L10n.string("forum.home.search_placeholder"))
                }
            }
            .forumNavigationBarStyle()
        }
        .task {
            await model.load()
        }
        .onChange(of: appModel.forumNavigationRequest?.id) { _, _ in
            guard let request = appModel.forumNavigationRequest else { return }
            navigator.route(request.url, source: request.source, title: request.title)
        }
    }
}
