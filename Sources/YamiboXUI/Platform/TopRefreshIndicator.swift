import SwiftUI

private struct TopRefreshIndicatorModifier: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isVisible {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 8)
                }
            }
    }
}

extension View {
    /// The small spinner pinned to the top edge while a screen refreshes
    /// content it is already showing (initial loads use a full placeholder
    /// instead).
    func topRefreshIndicator(isVisible: Bool) -> some View {
        modifier(TopRefreshIndicatorModifier(isVisible: isVisible))
    }
}
