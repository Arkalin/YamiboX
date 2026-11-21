import SwiftUI
import YamiboXCore

struct LocalFavoriteCardActions {
    let open: (FavoriteCardProjection, FavoriteLaunchMode, BookOpeningTransition?) -> Void
    let select: (FavoriteItem) -> Void
    let move: (FavoriteItem) -> Void
    let editTags: (FavoriteItem) -> Void
    let toggleTextCover: (FavoriteCardProjection) -> Void
    let syncToRemote: (FavoriteItem) -> Void
    let delete: (FavoriteCardProjection) -> Void
    let viewArchivedFavorites: (FavoriteCardProjection) -> Void
    let deleteArchivedFavorites: ((FavoriteItem) -> Void)?

    @MainActor
    static func standard(
        organizer: FavoriteLibraryOrganizer,
        selection: LocalFavoriteBrowseSession,
        routes: LocalFavoritesRoutes,
        onOpen: @escaping (FavoriteItem, FavoriteLaunchMode, FavoriteMangaReadingScope, BookOpeningTransition?) async -> Void
    ) -> LocalFavoriteCardActions {
        let deleteArchivedFavorites: ((FavoriteItem) -> Void)? = organizer.smartMangaBulkDeleteEnabled
            ? { item in
                selection.toggleFavoriteSelection(id: organizer.selectionID(for: item))
                routes.dialog = .deleteSelection(organizer.makeSelectionDeletePlan())
            }
            : nil
        return LocalFavoriteCardActions(
            open: { card, mode, transition in
                let mangaScope: FavoriteMangaReadingScope = card.isModeOnMangaThread ? .boardDefault : .singleThread
                Task { await onOpen(card.item, mode, mangaScope, transition) }
            },
            select: { item in
                selection.toggleFavoriteSelection(id: organizer.selectionID(for: item))
            },
            move: { item in
                selection.toggleFavoriteSelection(id: organizer.selectionID(for: item))
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
                organizer.openMergedGroup(key: card.mangaGroupKey)
            },
            deleteArchivedFavorites: deleteArchivedFavorites
        )
    }
}

struct LocalFavoriteCardContextMenu: View {
    let card: FavoriteCardProjection
    let actions: LocalFavoriteCardActions
    let bookOpeningTransition: BookOpeningTransition

    var body: some View {
        Button {
            actions.open(card, .resume, bookOpeningTransition)
        } label: {
            Label(L10n.string("favorites.open_resume"), systemImage: "book")
        }
        Button {
            actions.open(card, .start, bookOpeningTransition)
        } label: {
            Label(L10n.string("favorites.open_from_start"), systemImage: "text.page")
        }
        Divider()
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
        if card.item.target.threadID != nil, card.item.remoteMapping?.hasResolvedFavoriteID != true {
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
