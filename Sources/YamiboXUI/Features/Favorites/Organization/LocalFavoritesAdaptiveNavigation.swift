import SwiftUI
import UIKit
import YamiboXCore

extension EnvironmentValues {
    @Entry var favoritesUsesSidebar = false
}

/// Device identity chooses the container once; window resizing only changes
/// the system split view's column presentation, not the existing browse stack.
struct LocalFavoritesAdaptiveNavigation<Content: View>: View {
    let organizer: FavoriteLibraryOrganizer
    let routes: LocalFavoritesRoutes
    let navigator: ForumDestinationNavigator
    @ViewBuilder let content: () -> Content
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NavigationSplitView(preferredCompactColumn: $compactColumn) {
                LocalFavoritesSidebar(
                    organizer: organizer,
                    routes: routes,
                    navigator: navigator,
                    onSelect: { compactColumn = .detail }
                )
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
            } detail: {
                content()
            }
            .navigationSplitViewStyle(.balanced)
            .ignoresSafeArea(.container, edges: horizontalSizeClass == .regular ? .top : [])
            .environment(\.favoritesUsesSidebar, true)
            .environment(\.forumKeepsTabBarVisible, horizontalSizeClass == .regular)
        } else {
            content()
        }
    }
}

private struct LocalFavoritesSidebar: View {
    let organizer: FavoriteLibraryOrganizer
    @ObservedObject var routes: LocalFavoritesRoutes
    let navigator: ForumDestinationNavigator
    let onSelect: () -> Void
    @ObservedObject private var selection: LocalFavoriteBrowseSession

    init(
        organizer: FavoriteLibraryOrganizer,
        routes: LocalFavoritesRoutes,
        navigator: ForumDestinationNavigator,
        onSelect: @escaping () -> Void
    ) {
        self.organizer = organizer
        self.routes = routes
        self.navigator = navigator
        self.onSelect = onSelect
        self.selection = organizer.selection
    }

    var body: some View {
        // The detail stack owns navigation. Native split-view selection would
        // reset its path when a collection is opened from a content card.
        List {
            Section(L10n.string("favorites.category.select")) {
                ForEach(organizer.categories.manualOrderSorted) { category in
                    Button {
                        select(.category(category.id))
                    } label: {
                        Label(category.displayName, systemImage: "books.vertical")
                            .badge(organizer.showsCategoryBadges ? organizer.derived.categoryEntryCounts[category.id] ?? 0 : 0)
                    }
                    .sidebarCategorySelection(isSelected: destination == .category(category.id))
                }
            }
            if !organizer.currentCategoryCollections.isEmpty {
                Section(L10n.string("favorites.sidebar.collections")) {
                    ForEach(organizer.currentCategoryCollections) { collection in
                        Button {
                            select(.collection(collection.id))
                        } label: {
                            Label {
                                Text(collection.name)
                            } icon: {
                                Image(systemName: "folder")
                                    .foregroundStyle(collection.color.swiftUIColor)
                            }
                        }
                        .sidebarCategorySelection(isSelected: destination == .collection(collection.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(selection.isSelectionMode)
        .navigationTitle(L10n.string("favorites.title"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("favorites.sidebar")
    }

    private var destination: LocalFavoritesSidebarDestination {
        LocalFavoritesNavigation(organizer: organizer, routes: routes, navigator: navigator).sidebarDestination
    }

    private func select(_ destination: LocalFavoritesSidebarDestination) {
        guard !selection.isSelectionMode else { return }
        LocalFavoritesNavigation(organizer: organizer, routes: routes, navigator: navigator)
            .selectSidebarDestination(destination)
        onSelect()
    }
}
