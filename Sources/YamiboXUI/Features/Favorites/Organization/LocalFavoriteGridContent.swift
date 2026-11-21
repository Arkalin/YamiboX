import SwiftUI
import UIKit
import YamiboXCore

struct LocalFavoriteGridContent: View {
    let organizer: FavoriteLibraryOrganizer
    @ObservedObject var selection: LocalFavoriteBrowseSession
    let routes: LocalFavoritesRoutes
    let isStaggered: Bool
    let derived: LocalFavoriteDerivedState
    let scope: LocalFavoritePresentationScope
    let onOpen: (FavoriteItem, FavoriteLaunchMode, FavoriteMangaReadingScope, BookOpeningTransition?) async -> Void

    private static let fixedGridBaseMinimumCardWidth: Double = 130
    private static let staggeredBaseCardWidth: Double = 170

    /// Live pinch magnification relative to the gesture's start, layered on
    /// top of the committed scale while the pinch is in flight.
    /// `@GestureState` so an interrupted/cancelled pinch always snaps back
    /// to the committed value instead of freezing a half-applied zoom.
    @GestureState private var pinchMagnification: Double?

    private var gridColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: Self.fixedGridBaseMinimumCardWidth * effectiveCardScale),
            spacing: 12,
            alignment: .top
        )]
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    LocalFavoriteBrowseChrome(
                        organizer: organizer,
                        routes: routes,
                        cardsCount: derived.cards.count,
                        showsCategoryTabBar: scope.showsCategoryTabBar
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
                // Retargetable spring so the column reflow a pinch (or a
                // Settings-slider change applied on return) triggers glides
                // instead of snapping cell-by-cell. Scoped by value: inert
                // during plain scrolling and selection.
                .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.9), value: effectiveCardScale)
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
            // Two-finger card resizing rides alongside the scroll pan; the
            // `.subviews` mask keeps the gesture fully out of the way on
            // iPhone (idiom never changes at runtime, so the ternary is
            // stable for the view's whole life).
            .simultaneousGesture(
                cardResizePinchGesture,
                including: isCardScaleAdjustable ? .all : .subviews
            )
        }
        .sensoryFeedback(.selection, trigger: selection.selectedFavoriteIDs)
        .sensoryFeedback(.selection, trigger: selection.selectedCollectionIDs)
    }


    private var isCardScaleAdjustable: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// The committed scale with any in-flight pinch layered on top, clamped
    /// live so pinching past a bound stops growing/shrinking at the bound
    /// rather than overshooting and snapping back on release.
    private var effectiveCardScale: Double {
        guard isCardScaleAdjustable else { return FavoriteLibrarySettings.defaultGridCardScale }
        let committed = organizer.display.gridCardScale
        guard let pinchMagnification else { return committed }
        return FavoriteLibrarySettings.clampGridCardScale(committed * pinchMagnification)
    }

    private var cardResizePinchGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchMagnification) { value, state, _ in
                state = Double(value.magnification)
            }
            .onEnded { value in
                organizer.updateGridCardScale(
                    organizer.display.gridCardScale * Double(value.magnification)
                )
            }
    }

    private var gridEntries: [FavoriteMixedEntry] {
        derived.mixedEntries
    }

    private func staggeredColumnCount(for width: CGFloat) -> Int {
        max(2, Int((width - 32 + 12) / (Self.staggeredBaseCardWidth * effectiveCardScale + 12)))
    }

    private var cardActions: LocalFavoriteCardActions {
        .standard(organizer: organizer, selection: selection, routes: routes, onOpen: onOpen)
    }
}

struct LocalFavoriteGridEntryCell: View {
    let entry: FavoriteMixedEntry
    let organizer: FavoriteLibraryOrganizer
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
            .favoriteUpdateIndicator(id: collection.id, isCollection: true)
        case let .card(card):
            LocalFavoriteGridCard(
                card: card,
                showsSmartCardBadge: organizer.smartMangaBadgeEnabled,
                selection: selection,
                actions: actions
            )
            .favoriteUpdateIndicator(id: card.item.id)
        }
    }
}

struct LocalFavoriteStaggeredCards: View {
    let entries: [FavoriteMixedEntry]
    let columnCount: Int
    let organizer: FavoriteLibraryOrganizer
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
