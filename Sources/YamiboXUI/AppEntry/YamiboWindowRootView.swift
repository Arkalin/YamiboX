import SwiftUI
import YamiboXCore

public struct YamiboWindowRootView: View {
    let coordinator: YamiboWindowCoordinator
    let initialTab: AppTab
    let request: YamiboWindowRequest?

    @SceneStorage("yamibox.window.identifier") private var windowID = ""
    @SceneStorage("yamibox.window.selectedTab") private var selectedTabName = ""
    @SceneStorage("yamibox.window.requestHandled") private var requestHandled = false
    @State private var model: YamiboAppModel?

    public init(coordinator: YamiboWindowCoordinator, initialTab: AppTab, request: YamiboWindowRequest?) {
        self.coordinator = coordinator
        self.initialTab = initialTab
        self.request = request
    }

    public var body: some View {
        Group {
            if let model {
                RootTabView(appModel: model)
                    .background(YamiboWindowInputHost(coordinator: coordinator, model: model))
                    .onChange(of: model.selectedTab) { _, tab in
                        selectedTabName = Self.name(for: tab)
                    }
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil else { return }
            if windowID.isEmpty { windowID = UUID().uuidString }
            let model = coordinator.makeModel(
                windowID: windowID,
                initialTab: Self.tab(named: selectedTabName) ?? initialTab
            )
            if !requestHandled, let request {
                requestHandled = true
                if let route = request.readerRoute {
                    switch route {
                    case let .novel(context): model.presentNovelReader(context)
                    case let .manga(context): model.presentMangaReader(context)
                    }
                } else if let url = request.forumURL {
                    model.openForumURL(url)
                }
            }
            self.model = model
        }
    }

    private static func name(for tab: AppTab) -> String {
        switch tab {
        case .home: "home"
        case .forum: "forum"
        case .favorites: "favorites"
        case .mine: "mine"
        }
    }

    private static func tab(named name: String) -> AppTab? {
        switch name {
        case "home": .home
        case "forum": .forum
        case "favorites": .favorites
        case "mine": .mine
        default: nil
        }
    }
}

struct OpenContentInNewWindowButton: View {
    let requestProvider: @MainActor () async -> YamiboWindowRequest?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @State private var isOpening = false

    init(request: YamiboWindowRequest) {
        requestProvider = { request }
    }

    init(requestProvider: @escaping @MainActor () async -> YamiboWindowRequest?) {
        self.requestProvider = requestProvider
    }

    var body: some View {
        if supportsMultipleWindows {
            Button {
                guard !isOpening else { return }
                isOpening = true
                Task {
                    defer { isOpening = false }
                    if let request = await requestProvider() { openWindow(value: request) }
                }
            } label: {
                Label(L10n.string("window.open_content"), systemImage: "macwindow.badge.plus")
            }
            .disabled(isOpening)
        }
    }
}
