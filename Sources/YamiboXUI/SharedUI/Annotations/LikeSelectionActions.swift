import SwiftUI
import YamiboXCore

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
