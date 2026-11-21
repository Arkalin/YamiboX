import SwiftUI
import YamiboXCore

struct LocalFavoriteBrowseChrome: View {
    @Environment(\.favoritesUsesSidebar) private var usesSidebar
    let organizer: FavoriteLibraryOrganizer
    let routes: LocalFavoritesRoutes
    let cardsCount: Int
    let showsCategoryTabBar: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsCategoryTabBar && !usesSidebar {
                LocalFavoriteCategoryTabBar(organizer: organizer, routes: routes)
            }
            if organizer.filter.hasActiveFilters {
                LocalFavoriteActiveFilterStrip(organizer: organizer)
            }
            LocalFavoriteViewOptionChips(organizer: organizer, routes: routes, cardsCount: cardsCount)
        }
    }
}
