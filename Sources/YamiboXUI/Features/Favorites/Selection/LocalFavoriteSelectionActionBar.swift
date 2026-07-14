import SwiftUI
import YamiboXCore

/// Builds the selection-mode bottom bar's actions for the favorites screen —
/// rendering itself is delegated to the shared `SelectionBottomToolbar`.
/// Each action is omitted (not merely disabled) when the current selection
/// can't use it, and the whole bar disappears once nothing is available
/// (i.e. nothing is selected — every action needs at least one selected
/// entry).
struct LocalFavoriteSelectionActionBar: View {
    @ObservedObject var organizer: FavoriteLibraryOrganizer
    @ObservedObject var selection: LocalFavoriteBrowseSession
    let routes: LocalFavoritesRoutes

    var body: some View {
        if !actions.isEmpty {
            SelectionBottomToolbar(actions: actions)
        }
    }

    private var actions: [SelectionToolbarAction] {
        var actions: [SelectionToolbarAction] = []
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
                routes.dialog = .deleteSelection
            })
        }
        return actions
    }

    // MARK: - Availability

    /// Move only relocates the selected favorites; a mixed selection would
    /// silently leave any selected collection untouched.
    private var canMove: Bool {
        selection.selectedFavoriteCount > 0 && selection.selectedCollectionCount == 0
    }

    private var canCreateCollection: Bool {
        selection.canCreateCollectionFromSelection
    }

    /// Tags only apply to favorites, not collections — same pure-item
    /// requirement as move.
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

    /// When `FavoriteLibrarySettings.smartMangaBulkDeleteEnabled` is off, a
    /// smart card can be selected but contributes nothing to delete
    /// (`FavoriteLibraryOrganizer.deleteSelection` skips every smart-card
    /// id in that mode) — `hasDeletableSelection` accounts for that, so a
    /// selection made up entirely of smart cards hides this button instead
    /// of showing one that silently does nothing when tapped. When the
    /// setting is on, a smart-card-only selection is fully deletable (its
    /// whole archive), so the button shows.
    private var canDelete: Bool {
        organizer.hasDeletableSelection
    }
}

/// Marks selection state on a whole row/card instead of a leading circle:
/// an unselected item dims while multi-selection is active, and a selected
/// one stays full-color with an accent-color border (Android card-selection
/// parity).
struct LocalFavoriteSelectionEmphasis: ViewModifier {
    let isSelectionMode: Bool
    let isSelected: Bool
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .overlay {
                if isSelectionMode, isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2.5)
                }
            }
            .opacity(isSelectionMode && !isSelected ? 0.45 : 1)
            .accessibilityAddTraits(isSelectionMode && isSelected ? .isSelected : [])
    }
}

extension View {
    func favoriteSelectionEmphasis(isSelectionMode: Bool, isSelected: Bool, cornerRadius: CGFloat = 8) -> some View {
        modifier(LocalFavoriteSelectionEmphasis(isSelectionMode: isSelectionMode, isSelected: isSelected, cornerRadius: cornerRadius))
    }
}
