import SwiftUI
import YamiboXCore

/// Builds the selection-mode bottom bar's single "delete selected" action,
/// shared by both My Likes list screens (works and items) — rendering is
/// delegated to the shared `SelectionBottomToolbar`.
enum LikeSelectionActions {
    static func delete(selectedCount: Int, onDelete: @escaping () -> Void) -> [SelectionToolbarAction] {
        [
            SelectionToolbarAction(
                id: "delete",
                title: L10n.string("common.delete"),
                systemImage: "trash",
                role: .destructive,
                isEnabled: selectedCount > 0,
                accessibilityLabel: L10n.string("likes.delete_selected_format", selectedCount),
                action: onDelete
            )
        ]
    }
}
