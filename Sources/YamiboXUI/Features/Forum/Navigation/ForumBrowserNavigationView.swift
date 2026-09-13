import SwiftUI
import YamiboXCore

/// Both columns project the same route, so collapsing never copies navigation state.
struct ForumBrowserNavigationView<Root: View>: View {
    @Bindable var navigator: ForumDestinationNavigator
    @ViewBuilder let root: () -> Root
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if navigator.usesSplitNavigation {
                NavigationSplitView(preferredCompactColumn: $compactColumn) {
                    NavigationStack(path: browsePath) {
                        root()
                            .navigationDestination(for: ForumDestination.self) { destination in
                                ForumDestinationScreen(destination: destination, navigator: navigator)
                            }
                    }
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
                    .environment(\.forumBrowserSourceIsList, true)
                } detail: {
                    NavigationStack(path: detailPath) {
                        Group {
                            if let destination = navigator.browserDetailPath.first {
                                ForumDestinationScreen(destination: destination, navigator: navigator)
                                    .id(destination)
                            } else {
                                ContentUnavailableView(L10n.string("forum.no_selection"), systemImage: "text.bubble")
                                    .forumPageBackground()
                            }
                        }
                        .navigationDestination(for: ForumDestination.self) { destination in
                            ForumDestinationScreen(destination: destination, navigator: navigator)
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .ignoresSafeArea(.container, edges: horizontalSizeClass == .regular ? .top : [])
                .environment(\.forumKeepsTabBarVisible, horizontalSizeClass == .regular)
                .environment(\.selectedForumThreadID, navigator.selectedBrowserThreadID)
                .onChange(of: navigator.path, initial: true) { _, _ in
                    compactColumn = navigator.browserDetailPath.isEmpty ? .sidebar : .detail
                }
                .onChange(of: navigator.browserDetailRevision) { _, _ in
                    if !navigator.browserDetailPath.isEmpty { compactColumn = .detail }
                }
                .transientMessage(navigator.transientFeedback) { navigator.transientFeedback = nil }
                .failureAlert(
                    L10n.string("forum.open_native_failed"),
                    message: navigator.actionErrorMessage,
                    details: navigator.actionErrorDetails,
                    isPresented: Binding(
                        get: { navigator.actionErrorMessage != nil },
                        set: { if !$0 { navigator.actionErrorMessage = nil } }
                    )
                ) {
                    Button(L10n.string("common.ok")) { navigator.actionErrorMessage = nil }
                }
            } else {
                ForumDestinationStackView(navigator: navigator, root: root)
            }
        }
    }

    private var browsePath: Binding<[ForumDestination]> {
        Binding(get: { navigator.browserListPath }, set: { value in
            if value != navigator.browserListPath { navigator.path = value }
        })
    }

    private var detailPath: Binding<[ForumDestination]> {
        Binding(
            get: { Array(navigator.browserDetailPath.dropFirst()) },
            set: { value in
                navigator.path = navigator.browserListPath + Array(navigator.browserDetailPath.prefix(1)) + value
            }
        )
    }
}

extension EnvironmentValues {
    @Entry var selectedForumThreadID: String? = nil
    @Entry var forumBrowserSourceIsList = false
    @Entry var forumKeepsTabBarVisible = false
}
