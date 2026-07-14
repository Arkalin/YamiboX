import SwiftUI
import YamiboXCore

extension View {
    /// Trailing swipe-to-delete with the standard trash label. `isVisible`
    /// lets rows drop the action situationally (e.g. while multi-selecting)
    /// without giving up the shared shape.
    func deleteSwipeAction(
        allowsFullSwipe: Bool = true,
        isVisible: Bool = true,
        perform delete: @escaping () -> Void
    ) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: allowsFullSwipe) {
            if isVisible {
                Button(role: .destructive, action: delete) {
                    Label(L10n.string("common.delete"), systemImage: "trash")
                }
            }
        }
    }
}
