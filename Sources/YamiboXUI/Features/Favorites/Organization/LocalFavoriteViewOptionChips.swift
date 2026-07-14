import SwiftUI
import YamiboXCore

/// Context row under the category bar: the current view's item count
/// (when the "show category counts" setting is on) leading, then layout,
/// filter, and sort icon-only buttons trailing (filter moved here from the
/// navigation bar so all three view-affecting controls live together).
struct LocalFavoriteViewOptionChips: View {
    @ObservedObject var organizer: FavoriteLibraryOrganizer
    let routes: LocalFavoritesRoutes
    let cardsCount: Int

    var body: some View {
        HStack(spacing: 8) {
            if organizer.showsCategoryBadges {
                Text(L10n.string("favorites.items_count", cardsCount))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                Picker(L10n.string("favorites.layout"), selection: layoutModeBinding) {
                    ForEach(FavoriteLibraryLayoutMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImageName)
                            .tag(mode)
                    }
                }
            } label: {
                chipIcon(
                    text: L10n.string("favorites.chip.layout", organizer.display.layoutMode.title),
                    // Reflects the selected mode's own icon rather than a
                    // fixed glyph, since the icon is now this button's only
                    // visible content.
                    systemImage: organizer.display.layoutMode.systemImageName
                )
            }
            Button {
                routes.sheet = .filters
            } label: {
                chipIcon(
                    text: L10n.string("favorites.filter.title"),
                    systemImage: organizer.filter.hasActiveFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle",
                    tint: organizer.filter.hasActiveFilters ? Color.accentColor : nil
                )
            }
            Menu {
                Picker(L10n.string("favorites.sort"), selection: sortOrderBinding) {
                    ForEach(LocalFavoriteLibrarySortOrder.allCases) { order in
                        Text(order.title)
                            .tag(order)
                    }
                }
                Toggle(isOn: sortDescendingBinding) {
                    Label(L10n.string("favorites.sort.descending"), systemImage: "arrow.down")
                }
            } label: {
                chipIcon(
                    text: L10n.string(
                        "favorites.chip.sort",
                        organizer.filter.sortOrder.title,
                        organizer.filter.sortDescending ? "↓" : "↑"
                    ),
                    // Direction-specific arrow so the current sort direction
                    // still reads at a glance without visible text.
                    systemImage: organizer.filter.sortDescending ? "arrow.down" : "arrow.up"
                )
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    /// Icon-only button; `text` is still passed to `Label` so it's exposed
    /// as the accessibility label even though `.iconOnly` hides it visually.
    /// `tint` lets the filter button show its active state in accent color.
    private func chipIcon(text: String, systemImage: String, tint: Color? = nil) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.footnote.weight(.semibold))
            .frame(width: 32, height: 32)
            .background(Color.secondary.opacity(0.12), in: Circle())
            .foregroundStyle(tint ?? .primary)
            .expandedHitTarget()
    }

    private var sortOrderBinding: Binding<LocalFavoriteLibrarySortOrder> {
        Binding(
            get: { organizer.filter.sortOrder },
            set: { organizer.updateSortOrder($0) }
        )
    }

    private var sortDescendingBinding: Binding<Bool> {
        Binding(
            get: { organizer.filter.sortDescending },
            set: { organizer.updateSortDescending($0) }
        )
    }

    private var layoutModeBinding: Binding<FavoriteLibraryLayoutMode> {
        Binding(
            get: { organizer.display.layoutMode },
            set: { organizer.updateLayoutMode($0) }
        )
    }
}
