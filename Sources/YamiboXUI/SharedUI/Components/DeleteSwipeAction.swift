import SwiftUI
import YamiboXCore

extension View {
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
