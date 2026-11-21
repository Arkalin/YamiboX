import SwiftUI
import YamiboXCore

enum LocalFavoriteCardDeletionTarget {
    case item(FavoriteItem)
    case projectionGroup(selectionID: String)

    init(card: FavoriteCardProjection) {
        self = card.isModeOnMangaThread ? .projectionGroup(selectionID: card.id) : .item(card.item)
    }
}

struct LocalFavoriteCardActions {
    let open: (FavoriteCardProjection, FavoriteLaunchMode, BookOpeningTransition?) -> Void
    let select: (FavoriteItem) -> Void
    let move: (FavoriteItem) -> Void
    let editTags: (FavoriteItem) -> Void
    let toggleTextCover: (FavoriteCardProjection) -> Void
    let syncToRemote: (FavoriteItem) -> Void
    let delete: (FavoriteCardProjection) -> Void
    let viewArchivedFavorites: (FavoriteCardProjection) -> Void
    private let allowsProjectionGroupDeletion: Bool

    func canDelete(_ card: FavoriteCardProjection) -> Bool {
        switch LocalFavoriteCardDeletionTarget(card: card) {
        case .item: true
        case .projectionGroup: allowsProjectionGroupDeletion
        }
    }

    @MainActor
    static func standard(
        organizer: FavoriteLibraryOrganizer,
        selection: LocalFavoriteBrowseSession,
        routes: LocalFavoritesRoutes,
        onOpen: @escaping (FavoriteItem, FavoriteLaunchMode, FavoriteMangaReadingScope, BookOpeningTransition?) async -> Void
    ) -> LocalFavoriteCardActions {
        LocalFavoriteCardActions(
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
                switch LocalFavoriteCardDeletionTarget(card: card) {
                case .item(let item):
                    routes.dialog = .deleteItem(item)
                case .projectionGroup(let selectionID):
                    guard organizer.smartMangaBulkDeleteEnabled else { return }
                    selection.clearSelection()
                    selection.enterSelectionMode()
                    selection.replaceFavoriteSelection(with: [selectionID])
                    routes.dialog = .deleteSelection(organizer.makeSelectionDeletePlan())
                }
            },
            viewArchivedFavorites: { card in
                organizer.openMergedGroup(key: card.mangaGroupKey)
            },
            allowsProjectionGroupDeletion: organizer.smartMangaBulkDeleteEnabled
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
        if card.item.remoteMapping?.hasResolvedFavoriteID != true {
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
        }
        if actions.canDelete(card) {
            Button(role: .destructive) {
                actions.delete(card)
            } label: {
                Label(L10n.string("common.delete"), systemImage: "trash")
            }
        }
    }
}
