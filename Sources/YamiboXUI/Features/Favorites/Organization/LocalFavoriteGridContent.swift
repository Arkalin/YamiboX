import SwiftUI
import YamiboXCore

/// Fixed-grid and staggered layouts for the favorites screen. Collections
/// and favorite items share one grid, merged into the sort order the user
/// picked (collections stay a pinned leading block only in manual sort
/// order — see `LocalFavoriteLibraryProjection.mixedEntries`). Column counts
/// adapt to the available width with two columns on iPhone.
struct LocalFavoriteGridContent: View {
    @ObservedObject var organizer: FavoriteLibraryOrganizer
    @ObservedObject var selection: LocalFavoriteBrowseSession
    let routes: LocalFavoritesRoutes
    let isStaggered: Bool
    /// Explicit source of truth for this instance's scope (root overview vs.
    /// the opened collection) — never read `organizer.derived` ambiently
    /// here, since root and collection-detail content can be mounted
    /// simultaneously during an interactive pop. See
    /// `FavoriteLibraryOrganizer.rootDerived`.
    let derived: LocalFavoriteDerivedState
    let isCollectionDetail: Bool
    let onOpen: (FavoriteItem, FavoriteLaunchMode, FavoriteMangaReadingScope) async -> Void

    private let gridColumns = [
        GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .top)
    ]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    LocalFavoriteBrowseChrome(
                        organizer: organizer,
                        routes: routes,
                        cardsCount: derived.cards.count,
                        showsCategoryTabBar: !isCollectionDetail
                    )
                    if isStaggered {
                        LocalFavoriteStaggeredCards(
                            entries: gridEntries,
                            columnCount: staggeredColumnCount(for: proxy.size.width),
                            organizer: organizer,
                            selection: selection,
                            routes: routes,
                            derived: derived,
                            actions: cardActions
                        )
                        .padding(.horizontal)
                    } else {
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                            ForEach(gridEntries) { entry in
                                LocalFavoriteGridEntryCell(
                                    entry: entry,
                                    organizer: organizer,
                                    selection: selection,
                                    routes: routes,
                                    derived: derived,
                                    actions: cardActions
                                )
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 12)
            }
            // ScrollView clips its content to its own bounds by default —
            // independent of `favoriteSelectionEmphasis`'s opacity group
            // (already worked around in `LocalFavoriteGridCard`/
            // `LocalFavoriteItemRow`), this cuts off the smart-card badge's
            // outward corner offset for any card whose overflow lands close
            // enough to the scroll content's own edge, which is common in
            // the fixed-grid and staggered layouts here. The badge is a
            // small (~5pt), non-interactive, accessibility-hidden overlay,
            // so the documented tradeoff — overflowed content no longer
            // participates in hit-testing — is a non-issue.
            .scrollClipDisabled()
        }
        .sensoryFeedback(.selection, trigger: selection.selectedFavoriteIDs)
        .sensoryFeedback(.selection, trigger: selection.selectedCollectionIDs)
    }

    private var gridEntries: [FavoriteMixedEntry] {
        derived.mixedEntries
    }

    /// Two waterfall columns on iPhone widths, more as the width grows.
    private func staggeredColumnCount(for width: CGFloat) -> Int {
        max(2, Int((width - 32 + 12) / (170 + 12)))
    }

    private var cardActions: LocalFavoriteCardActions {
        .standard(organizer: organizer, selection: selection, routes: routes, onOpen: onOpen)
    }
}

/// Renders one mixed-grid entry as either a collection cell or an item card.
struct LocalFavoriteGridEntryCell: View {
    let entry: FavoriteMixedEntry
    @ObservedObject var organizer: FavoriteLibraryOrganizer
    @ObservedObject var selection: LocalFavoriteBrowseSession
    let routes: LocalFavoritesRoutes
    let derived: LocalFavoriteDerivedState
    let actions: LocalFavoriteCardActions

    var body: some View {
        switch entry {
        case let .collection(collection):
            LocalFavoriteCollectionGridCard(
                collection: collection,
                itemCount: derived.collectionEntryCounts[collection.id] ?? 0,
                categories: organizer.categories,
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
            LocalFavoriteGridCard(
                card: card,
                selection: selection,
                actions: actions
            )
        }
    }
}

/// Waterfall arrangement distributing mixed entries round-robin per column.
struct LocalFavoriteStaggeredCards: View {
    let entries: [FavoriteMixedEntry]
    let columnCount: Int
    @ObservedObject var organizer: FavoriteLibraryOrganizer
    @ObservedObject var selection: LocalFavoriteBrowseSession
    let routes: LocalFavoritesRoutes
    let derived: LocalFavoriteDerivedState
    let actions: LocalFavoriteCardActions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<max(1, columnCount), id: \.self) { column in
                LazyVStack(spacing: 12) {
                    ForEach(columnEntries(column)) { entry in
                        LocalFavoriteGridEntryCell(
                            entry: entry,
                            organizer: organizer,
                            selection: selection,
                            routes: routes,
                            derived: derived,
                            actions: actions
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func columnEntries(_ column: Int) -> [FavoriteMixedEntry] {
        entries.enumerated().compactMap { index, entry in
            index % max(1, columnCount) == column ? entry : nil
        }
    }
}

extension FavoriteLibraryOrganizer {
    /// Category count badges stay visible while a search is active even when
    /// the user has hidden them, so result counts remain visible.
    var showsCategoryBadges: Bool {
        display.showsCategoryCounts || !filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
