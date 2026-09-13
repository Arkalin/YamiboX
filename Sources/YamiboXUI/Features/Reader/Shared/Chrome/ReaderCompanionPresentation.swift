import SwiftUI

/// A page-sized modal keeps the reading viewport unchanged behind the panel.
struct ReaderCompanionPresentation<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let panel: () -> Panel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                panel()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
            }
    }
}
