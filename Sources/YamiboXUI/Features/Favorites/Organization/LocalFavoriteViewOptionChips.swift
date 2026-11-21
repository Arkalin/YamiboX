import SwiftUI
import YamiboXCore

struct LocalFavoriteViewOptionChips: View {
    let organizer: FavoriteLibraryOrganizer
    let routes: LocalFavoritesRoutes
    let cardsCount: Int
    @Environment(\.appTheme) private var appTheme

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
                    tint: organizer.filter.hasActiveFilters ? appTheme.controlAccent : nil
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
                    systemImage: organizer.filter.sortDescending ? "arrow.down" : "arrow.up"
                )
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    /// Icon-only button; `text` is still passed to `Label` so it's exposed
    /// as the accessibility label even though `.iconOnly` hides it visually.
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
