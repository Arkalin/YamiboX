import SwiftUI
import YamiboXCore

/// Wide columns and the compact stack project the same canonical route.
struct ForumBrowserNavigationView<Root: View>: View {
    @Bindable var navigator: ForumDestinationNavigator
    @ViewBuilder let root: () -> Root
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if navigator.browserUsesSplitNavigation {
                NavigationSplitView(preferredCompactColumn: $compactColumn) {
                    NavigationStack(path: navigator.browserPathBinding(for: .list)) {
                        root()
                            .navigationDestination(for: ForumDestination.self) { destination in
                                // Destinations need the column's provenance explicitly.
                                ForumDestinationScreen(destination: destination, navigator: navigator)
                                    .environment(\.forumBrowserSourceIsList, true)
                            }
                    }
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
                    .environment(\.forumBrowserSourceIsList, true)
                } detail: {
                    NavigationStack(path: navigator.browserPathBinding(for: .detail)) {
                        Group {
                            if let destination = navigator.browserDetailPath.first {
                                ForumDestinationScreen(destination: destination, navigator: navigator)
                                    .id(destination)
                                    .environment(\.forumBrowserSourceIsList, false)
                            } else {
                                ContentUnavailableView(L10n.string("forum.no_selection"), systemImage: "text.bubble")
                                    .forumPageBackground()
                            }
                        }
                        .navigationDestination(for: ForumDestination.self) { destination in
                            ForumDestinationScreen(destination: destination, navigator: navigator)
                                .environment(\.forumBrowserSourceIsList, false)
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
                ForumDestinationStackView(
                    navigator: navigator, path: navigator.browserPathBinding(for: .stack), root: root
                )
                .environment(\.forumBrowserSourceIsList, true)
            }
        }
        .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
            navigator.updateBrowserLayout(isRegular: sizeClass == .regular)
        }
    }
}

extension EnvironmentValues {
    @Entry var selectedForumThreadID: String? = nil
    @Entry var forumBrowserSourceIsList = false
    @Entry var forumKeepsTabBarVisible = false
}
