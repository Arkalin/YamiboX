import SwiftUI
import YamiboXCore

struct LocalFavoriteListContent: View {
    let organizer: FavoriteLibraryOrganizer
    @ObservedObject var selection: LocalFavoriteBrowseSession
    let routes: LocalFavoritesRoutes
    let showsCover: Bool
    let derived: LocalFavoriteDerivedState
    let scope: LocalFavoritePresentationScope
    let onOpen: (FavoriteItem, FavoriteLaunchMode, FavoriteMangaReadingScope, BookOpeningTransition?) async -> Void

    var body: some View {
        List {
            Section {
                LocalFavoriteBrowseChrome(
                    organizer: organizer,
                    routes: routes,
                    cardsCount: derived.cards.count,
                    showsCategoryTabBar: scope.showsCategoryTabBar
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
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
                        .favoriteUpdateIndicator(id: collection.id, isCollection: true)
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
                        .favoriteUpdateIndicator(id: card.item.id)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(12)
        .contentMargins(.top, 12, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .sensoryFeedback(.selection, trigger: selection.selectedFavoriteIDs)
        .sensoryFeedback(.selection, trigger: selection.selectedCollectionIDs)
    }
}
