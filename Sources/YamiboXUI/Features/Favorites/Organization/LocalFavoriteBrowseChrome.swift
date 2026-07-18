import SwiftUI
import YamiboXCore

/// Chrome shared by every layout mode: the category tab bar, the active
/// filter strip, and the layout/sort chips row. Every content view (grid,
/// staggered, row-card, row-card-text) renders this exact same component so
/// their spacing and visibility rules cannot drift apart again.
///
/// Each piece is gated at this level (not inside its own body) so an
/// inactive filter strip is a genuinely absent child, not an empty one —
/// otherwise the enclosing stack's spacing would still open a gap on both
/// sides of it.
struct LocalFavoriteBrowseChrome: View {
    let organizer: FavoriteLibraryOrganizer
    let routes: LocalFavoritesRoutes
    let cardsCount: Int
    /// Passed explicitly by the caller (root vs. collection detail) rather
    /// than read from `organizer.selectedCollection`: both screens' chrome
    /// can be mounted at once during an interactive pop, and at that point
    /// they'd otherwise both read the same (stale) shared value. See
    /// `FavoriteLibraryOrganizer.rootDerived`.
    let showsCategoryTabBar: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsCategoryTabBar {
                LocalFavoriteCategoryTabBar(organizer: organizer, routes: routes)
            }
            if organizer.filter.hasActiveFilters {
                LocalFavoriteActiveFilterStrip(organizer: organizer)
            }
            LocalFavoriteViewOptionChips(organizer: organizer, routes: routes, cardsCount: cardsCount)
        }
    }
}
