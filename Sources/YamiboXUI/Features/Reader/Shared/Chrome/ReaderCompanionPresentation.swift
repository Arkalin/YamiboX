import SwiftUI

/// A page-sized modal keeps the reading viewport unchanged behind the panel.
struct ReaderCompanionPresentation<Panel: View>: ViewModifier {
    @Environment(\.readerRemoteInput) private var input
    @Binding var isPresented: Bool
    var showsDefaultClose = false
    @ViewBuilder let panel: () -> Panel

    func body(content: Content) -> some View {
        if input != nil {
            content.modifier(ReaderRemotePanel(isPresented: $isPresented, showsDefaultClose: showsDefaultClose, panel: panel))
        } else {
            content.sheet(isPresented: $isPresented) {
                panel()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
            }
        }
    }
}
