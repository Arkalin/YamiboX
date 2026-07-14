import SwiftUI
import YamiboXCore

/// Item actions reachable from a card's context menu and swipe actions.
/// Cards carry no visible buttons: tap continues reading, long-press opens
/// the menu (mirroring the Android cards, expressed as the iOS context menu).
struct LocalFavoriteCardActions {
    /// Takes the whole card (not just `card.item`) so `standard(...)` can
    /// derive the manga reading scope from the card's own display semantics:
    /// a card rendered as a plain non-smart card opens as the plain single
    /// thread it shows. In particular the "查看归档收藏" archive page's
    /// member cards — deliberately built non-smart by the projection — open
    /// the tapped chapter itself instead of bouncing back into the merged
    /// directory every member shares.
    let open: (FavoriteCardProjection, FavoriteLaunchMode) -> Void
    let select: (FavoriteItem) -> Void
    let move: (FavoriteItem) -> Void
    let editTags: (FavoriteItem) -> Void
    /// Takes the whole card (like `open`) because the cover key to toggle
    /// follows the card's display semantics (`FavoriteCardProjection
    /// .contentCoverKey`): a resolved-directory smart card toggles the
    /// shared `.smartManga` cover it displays, while the same item's
    /// "查看归档收藏" member card toggles its own `.thread` cover.
    let toggleTextCover: (FavoriteCardProjection) -> Void
    let syncToRemote: (FavoriteItem) -> Void
    /// Only ever invoked for a non-smart-card (`!isModeOnMangaThread`) card —
    /// smart cards route their card actions to `viewArchivedFavorites`
    /// instead, at every call site (context menu, swipe actions), so this
    /// always targets `card.item` directly with no smart-card branching of
    /// its own.
    let delete: (FavoriteCardProjection) -> Void
    /// A smart card's replacement for `delete`: opens the "查看归档收藏" detail
    /// page listing every individual member currently sharing this card's
    /// effective title (`resolvedTitle`) — one item for a still-solitary
    /// smart card, 2+ for an actually merged one — where per-item
    /// delete/move/tag management actually happens through the existing
    /// single-item card UI.
    let viewArchivedFavorites: (FavoriteCardProjection) -> Void
    /// A smart card's delete entry, gated by `FavoriteLibrarySettings
    /// .smartMangaBulkDeleteEnabled` — nil (and hidden at every call site)
    /// when the setting is off. Mirrors `move`'s "select this card alone,
    /// then open the shared bulk dialog" pattern instead of reusing
    /// `delete`'s own contract (`delete` is documented as never invoked for
    /// a smart card): selects just this card and opens the SAME
    /// `.deleteSelection` dialog the multi-select toolbar's delete button
    /// already drives, which in turn expands to every archived member via
    /// `FavoriteLibraryOrganizer.expandedSelectionFavoriteIDs` — so deleting
    /// an archive here and via multi-select share one implementation.
    let deleteArchivedFavorites: ((FavoriteItem) -> Void)?

    /// Standard wiring shared by the list and grid containers.
    @MainActor
    static func standard(
        organizer: FavoriteLibraryOrganizer,
        selection: LocalFavoriteBrowseSession,
        routes: LocalFavoritesRoutes,
        onOpen: @escaping (FavoriteItem, FavoriteLaunchMode, FavoriteMangaReadingScope) async -> Void
    ) -> LocalFavoriteCardActions {
        let deleteArchivedFavorites: ((FavoriteItem) -> Void)? = organizer.smartMangaBulkDeleteEnabled
            ? { item in
                selection.toggleFavoriteSelection(id: item.id)
                routes.dialog = .deleteSelection
            }
            : nil
        return LocalFavoriteCardActions(
            open: { card, mode in
                // A card opens with the scope its rendering promises: the
                // smart-card treatment (merged title, sparkles badge) follows
                // the board's Smart Comic Mode; a plain card — every
                // archive-page member card, and any mode-off manga card —
                // opens as the single thread it displays. Deriving this from
                // `isModeOnMangaThread` (the projection's single smart-card
                // gate) rather than re-reading settings keeps display and
                // open behavior permanently in agreement.
                let mangaScope: FavoriteMangaReadingScope = card.isModeOnMangaThread ? .boardDefault : .singleThread
                Task { await onOpen(card.item, mode, mangaScope) }
            },
            select: { item in
                selection.toggleFavoriteSelection(id: item.id)
            },
            move: { item in
                selection.toggleFavoriteSelection(id: item.id)
                routes.sheet = .selectionMove
            },
            editTags: { item in
                routes.sheet = .tagSelection(.favorite(item.id, initialTagIDs: Set(item.tagIDs)))
            },
            toggleTextCover: { card in
                Task { await organizer.toggleTextCover(for: card) }
            },
            syncToRemote: { item in
                Task { await organizer.pushItemToYamibo(item) }
            },
            delete: { card in
                routes.dialog = .deleteItem(card.item)
            },
            viewArchivedFavorites: { card in
                // `resolvedTitle` already IS the correct scope key in every
                // case — whether or not `mangaDirectory` is actually
                // resolved yet — since it's the same effective-title
                // computation `cards(in:query:...)`'s member-scope filter
                // groups by (see `FavoriteCardProjection.resolvedTitle`'s
                // doc comment), so no `mangaDirectory` fallback is needed.
                organizer.openMergedGroup(cleanBookName: card.resolvedTitle)
            },
            deleteArchivedFavorites: deleteArchivedFavorites
        )
    }
}

/// Shared context-menu content for a favorite item card.
struct LocalFavoriteCardContextMenu: View {
    let card: FavoriteCardProjection
    let actions: LocalFavoriteCardActions

    var body: some View {
        Button {
            actions.open(card, .resume)
        } label: {
            Label(L10n.string("favorites.open_resume"), systemImage: "book")
        }
        Button {
            actions.open(card, .start)
        } label: {
            Label(L10n.string("favorites.open_from_start"), systemImage: "text.page")
        }
        Divider()
        // Both buttons are offered for a smart card too: selecting or moving
        // one is equivalent to selecting/moving every favorite currently
        // archived under it (the same membership its "查看归档收藏" page
        // lists), expanded transparently at execution time by
        // `FavoriteLibraryOrganizer.expandedSelectionFavoriteIDs` — neither
        // `actions.select`/`actions.move`'s own closures need to know or
        // care that `card.item` might be a smart card's representative
        // member. Delete is offered below too when
        // `actions.deleteArchivedFavorites` is non-nil (the setting is on);
        // otherwise "查看归档收藏" remains the only supported way to delete
        // an individual archived member.
        Button {
            actions.select(card.item)
        } label: {
            Label(L10n.string("common.select"), systemImage: "checkmark.circle")
        }
        Button {
            actions.move(card.item)
        } label: {
            Label(L10n.string("favorites.move_action"), systemImage: "folder")
        }
        Button {
            actions.editTags(card.item)
        } label: {
            Label(L10n.string("favorites.tags_action"), systemImage: "tag")
        }
        Button {
            actions.toggleTextCover(card)
        } label: {
            if card.textCoverForced {
                Label(L10n.string("cover.use_image_cover"), systemImage: "photo")
            } else {
                Label(L10n.string("cover.use_text_cover"), systemImage: "textformat")
            }
        }
        if card.item.target.threadID != nil, card.item.remoteMapping?.yamiboFavoriteID == nil {
            Button {
                actions.syncToRemote(card.item)
            } label: {
                Label(L10n.string("favorites.quick.add_prompt.sync"), systemImage: "arrow.triangle.2.circlepath")
            }
        }
        Divider()
        if card.isModeOnMangaThread {
            Button {
                actions.viewArchivedFavorites(card)
            } label: {
                Label(L10n.string("favorites.view_archived_favorites"), systemImage: "archivebox")
            }
            if let deleteArchivedFavorites = actions.deleteArchivedFavorites {
                Button(role: .destructive) {
                    deleteArchivedFavorites(card.item)
                } label: {
                    Label(L10n.string("common.delete"), systemImage: "trash")
                }
            }
        } else {
            Button(role: .destructive) {
                actions.delete(card)
            } label: {
                Label(L10n.string("common.delete"), systemImage: "trash")
            }
        }
    }
}
