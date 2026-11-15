import SwiftUI


extension View {
    func readerDeviceSheet<Item: Identifiable, Panel: View>(item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Panel) -> some View {
        modifier(ReaderDeviceSheet(item: item, panel: content))
    }

}

private struct ReaderDeviceSheet<Item: Identifiable, Panel: View>: ViewModifier {
    @Environment(\.readerDeviceInteraction) private var device
    @Binding var item: Item?
    @ViewBuilder let panel: (Item) -> Panel

    func body(content: Content) -> some View {
        if let device {
            content.onChange(of: item?.id, initial: true) { _, _ in
                guard let selected = item else { return }
                item = nil
                device.present { _ in
                    ReaderDevicePanel { panel(selected) }
                }
            }
        } else {
            content.sheet(item: $item) { panel($0) }
        }
    }
}

/// Evaluate the panel in its own view body so live model reads are observed on the device.
private struct ReaderDevicePanel<Panel: View>: View {
    @ViewBuilder let panel: () -> Panel

    var body: some View { panel() }
}
