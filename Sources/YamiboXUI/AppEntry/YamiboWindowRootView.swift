import SwiftUI
import YamiboXCore

public struct YamiboWindowRootView: View {
    let coordinator: YamiboWindowCoordinator
    let initialTab: AppTab
    let request: YamiboWindowRequest?
    let launchScreenDeadline: ContinuousClock.Instant?

    @SceneStorage("yamibox.window.identifier") private var windowID = ""
    @SceneStorage("yamibox.window.requestHandled") private var requestHandled = false
    @State private var model: YamiboAppModel?
    @Environment(\.scenePhase) private var scenePhase

    public init(
        coordinator: YamiboWindowCoordinator,
        initialTab: AppTab,
        request: YamiboWindowRequest?,
        launchScreenDeadline: ContinuousClock.Instant? = nil
    ) {
        self.coordinator = coordinator
        self.initialTab = initialTab
        self.request = request
        self.launchScreenDeadline = launchScreenDeadline
    }

    public var body: some View {
        Group {
            if let model {
                RootTabView(appModel: model, launchScreenDeadline: launchScreenDeadline)
                    .background(YamiboWindowInputHost(coordinator: coordinator, model: model))
            } else {
                AppLaunchScreenView()
            }
        }
        .task(id: scenePhase) {
            guard model == nil else { return }
            guard !coordinator.hasPendingInitialNavigation || scenePhase == .active else { return }
            let initialNavigation = coordinator.claimInitialNavigation()
            if windowID.isEmpty { windowID = UUID().uuidString }
            let model = coordinator.makeModel(
                windowID: windowID,
                initialTab: initialNavigation?.initialTab ?? initialTab,
                initialNavigation: initialNavigation
            )
            if initialNavigation != nil {
                requestHandled = true
            } else if !requestHandled, let request {
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
