import SwiftUI
import YamiboXCore

/// Row-card layout for the favorites screen. Collections and favorite items
/// share one list section, merged into the sort order the user picked
/// (collections stay a pinned leading block only in manual sort order — see
/// `LocalFavoriteLibraryProjection.mixedEntries`).
struct LocalFavoriteListContent: View {
    let organizer: FavoriteLibraryOrganizer
    @ObservedObject var selection: LocalFavoriteBrowseSession
    let routes: LocalFavoritesRoutes
    let showsCover: Bool
    /// Explicit source of truth for this instance's scope (root overview vs.
    /// the opened collection) — never read `organizer.derived` ambiently
    /// here, since root and collection-detail content can be mounted
    /// simultaneously during an interactive pop. See
    /// `FavoriteLibraryOrganizer.rootDerived`.
    let derived: LocalFavoriteDerivedState
    let isCollectionDetail: Bool
    let onOpen: (FavoriteItem, FavoriteLaunchMode, FavoriteMangaReadingScope) async -> Void

    var body: some View {
        List {
            Section {
                LocalFavoriteBrowseChrome(
                    organizer: organizer,
                    routes: routes,
                    cardsCount: derived.cards.count,
                    showsCategoryTabBar: !isCollectionDetail
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                // The chrome is one plain content block, not a list row:
                // suppress the row/section separator lines List draws
                // around it by default (grid mode has no such line).
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
            }
            Section {
                ForEach(derived.mixedEntries) { entry in
                    switch entry {
                    case let .collection(collection):
                        LocalFavoriteCollectionRow(
                            collection: collection,
                            itemCount: derived.collectionEntryCounts[collection.id] ?? 0,
                            categories: organizer.categories,
                            showsCover: showsCover,
                            isSelectionMode: selection.isSelectionMode,
                            isSelected: selection.selectedCollectionIDs.contains(collection.id),
                            previewTiles: derived.collectionPreviewTiles[collection.id] ?? [],
                            onOpen: { organizer.openCollection(id: collection.id) },
                            onToggleSelection: { organizer.toggleCollectionSelection(id: collection.id) },
                            onEdit: { routes.sheet = .collectionEditor(LocalFavoriteCollectionDraft(collection: collection)) },
                            onDissolve: { routes.dialog = .dissolveCollection(collection) },
                            onMove: { direction in
                                await organizer.moveCollection(id: collection.id, direction: direction)
                            },
                            onMoveToCategory: { categoryID in
                                await organizer.moveCollection(id: collection.id, toCategoryID: categoryID)
                            }
                        )
                    case let .card(card):
                        LocalFavoriteItemRow(
                            card: card,
                            showsCover: showsCover,
                            showsSmartCardBadge: organizer.smartMangaBadgeEnabled,
                            isSelectionMode: selection.isSelectionMode,
                            isSelected: selection.selectedFavoriteIDs.contains(card.id),
                            onToggleSelection: { selection.toggleFavoriteSelection(id: card.id) },
                            actions: .standard(organizer: organizer, selection: selection, routes: routes, onOpen: onOpen)
                        )
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        // Grid mode is a plain `ScrollView` whose LazyVStack has an explicit
        // 12pt top inset (`.padding(.vertical, 12)`). List's own implicit top
        // inset above the first section doesn't match that value, so pin it
        // explicitly instead of relying on List's default.
        .listStyle(.plain)
        .listSectionSpacing(12)
        .contentMargins(.top, 12, for: .scrollContent)
        // Lets `LocalFavoritesRootBackground`'s `FavoriteBackgroundLayer`
        // show through instead of List's opaque default row/canvas fills.
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .sensoryFeedback(.selection, trigger: selection.selectedFavoriteIDs)
        .sensoryFeedback(.selection, trigger: selection.selectedCollectionIDs)
    }
}
