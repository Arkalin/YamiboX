import SwiftUI
import YamiboXCore

struct LocalFavoriteSelectionActionBar: View {
    let organizer: FavoriteLibraryOrganizer
    @ObservedObject var selection: LocalFavoriteBrowseSession
    let routes: LocalFavoritesRoutes
    @Environment(\.favoriteUnreadIndex) private var unread
    @EnvironmentObject private var updateMonitor: FavoriteUpdateMonitor
    @State private var isMarkingRead = false

    private var selectedUnreadIDs: Set<String> {
        var ids = Set<String>()
        for id in organizer.expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs) {
            ids.formUnion(unread.favorites[id, default: []])
        }
        for id in selection.selectedCollectionIDs {
            ids.formUnion(unread.collections[id, default: []])
        }
        return ids
    }

    var body: some View {
        if !actions.isEmpty {
            SelectionBottomToolbar(actions: actions)
        }
    }

    private var actions: [SelectionToolbarAction] {
        var actions: [SelectionToolbarAction] = []
        let unreadIDs = selectedUnreadIDs
        if !unreadIDs.isEmpty {
            actions.append(SelectionToolbarAction(id: "markRead", title: L10n.string("favorites.updates.read_action"), systemImage: "checkmark.circle", isEnabled: !isMarkingRead) {
                guard !isMarkingRead else { return }
                isMarkingRead = true
                Task {
                    await updateMonitor.markEventsRead(unreadIDs)
                    isMarkingRead = false
                }
            })
        }
        if canMove {
            actions.append(SelectionToolbarAction(id: "move", title: L10n.string("common.move"), systemImage: "folder") {
                routes.sheet = .selectionMove
            })
        }
        if canCreateCollection {
            actions.append(SelectionToolbarAction(id: "createCollection", title: L10n.string("favorites.create_collection"), systemImage: "folder.badge.plus") {
                routes.sheet = .collectionEditor(LocalFavoriteCollectionDraft(mode: .createFromSelection))
            })
        }
        if canEditTags {
            actions.append(SelectionToolbarAction(id: "tags", title: L10n.string("favorites.tags_action"), systemImage: "tag") {
                routes.sheet = .tagSelection(.selection(organizer.commonTagIDsForSelection))
            })
        }
        if let collection = editableCollection {
            actions.append(SelectionToolbarAction(id: "edit", title: L10n.string("common.edit"), systemImage: "pencil") {
                routes.sheet = .collectionEditor(LocalFavoriteCollectionDraft(collection: collection))
            })
        }
        if canDissolve {
            actions.append(SelectionToolbarAction(id: "dissolve", title: L10n.string("favorites.dissolve"), systemImage: "folder.badge.minus") {
                routes.dialog = .dissolveSelectedCollections
            })
        }
        if canDelete {
            actions.append(SelectionToolbarAction(id: "delete", title: L10n.string("common.delete"), systemImage: "trash", role: .destructive) {
                routes.dialog = .deleteSelection(organizer.makeSelectionDeletePlan())
            })
        }
        return actions
    }

    private var canMove: Bool {
        selection.selectedFavoriteCount > 0 && selection.selectedCollectionCount == 0
    }

    private var canCreateCollection: Bool {
        selection.canCreateCollectionFromSelection
    }

    private var canEditTags: Bool {
        selection.selectedFavoriteCount > 0 && selection.selectedCollectionCount == 0
    }

    private var editableCollection: LocalFavoriteCollection? {
        guard selection.selectedFavoriteCount == 0 else { return nil }
        return organizer.singleSelectedCollection
    }

    private var canDissolve: Bool {
        selection.selectedCollectionCount > 0 && selection.selectedFavoriteCount == 0
    }

    private var canDelete: Bool {
        organizer.hasDeletableSelection
    }
}

struct LocalFavoriteSelectionEmphasis: ViewModifier {
    let isSelectionMode: Bool
    let isSelected: Bool
    var cornerRadius: CGFloat = 8
    var contentInset: CGFloat = 0
    @Environment(\.appTheme) private var appTheme

    func body(content: Content) -> some View {
        content
            .padding(contentInset)
            .overlay {
                if isSelectionMode, isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(appTheme.controlAccent, lineWidth: 2.5)
                }
            }
            .opacity(isSelectionMode && !isSelected ? 0.45 : 1)
            .accessibilityAddTraits(isSelectionMode && isSelected ? .isSelected : [])
    }
}

extension View {
    func favoriteSelectionEmphasis(
        isSelectionMode: Bool,
        isSelected: Bool,
        cornerRadius: CGFloat = 8,
        contentInset: CGFloat = 0
    ) -> some View {
        modifier(LocalFavoriteSelectionEmphasis(
            isSelectionMode: isSelectionMode,
            isSelected: isSelected,
            cornerRadius: cornerRadius,
            contentInset: contentInset
        ))
    }
}
