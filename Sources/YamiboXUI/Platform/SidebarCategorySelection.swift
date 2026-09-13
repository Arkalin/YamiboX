import SwiftUI
import UIKit

extension View {
    /// Pushed sidebar lists must not fall back to an inset-grouped surface.
    func sidebarListSurface(isCompact: Bool = false) -> some View {
        listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background((isCompact ? Color(uiColor: .systemGroupedBackground) : .clear).ignoresSafeArea())
            .containerBackground(isCompact ? Color(uiColor: .systemGroupedBackground) : .clear, for: .navigation)
            .toolbarBackground(.hidden, for: .navigationBar)
    }

    /// Marks an embedded sidebar selection without driving split-view navigation.
    @ViewBuilder
    func sidebarCategorySelection(isSelected: Bool?) -> some View {
        if let isSelected {
            self
                .listRowBackground(
                    Capsule().fill(isSelected ? Color(uiColor: .tertiarySystemFill) : .clear)
                )
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            self
        }
    }
}
