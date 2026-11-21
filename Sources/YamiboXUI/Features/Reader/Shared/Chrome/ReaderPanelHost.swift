import SwiftUI

protocol ReaderPanelRoute: Identifiable {
    var isCompanionPanel: Bool { get }
}

struct ReaderPanelHost<Route: ReaderPanelRoute, Surface: View, Panel: View>: View {
    @Binding var item: Route?
    @ViewBuilder let surface: () -> Surface
    @ViewBuilder let panel: (Route, @escaping () -> Void) -> Panel

    var body: some View {
        surface().readerDeviceSheet(item: $item) { item in
            ReaderRootPanel(item: item, panel: panel)
        }
    }
}

private struct ReaderRootPanel<Route: ReaderPanelRoute, Panel: View>: View {
    @Environment(\.dismiss) private var dismiss
    let item: Route
    let panel: (Route, @escaping () -> Void) -> Panel

    var body: some View {
        if item.isCompanionPanel {
            panel(item, { dismiss() })
                .presentationSizing(.page)
                .presentationDetents([.large])
        } else {
            panel(item, { dismiss() })
        }
    }
}
