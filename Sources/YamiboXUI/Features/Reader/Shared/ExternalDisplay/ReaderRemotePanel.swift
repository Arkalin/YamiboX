import SwiftUI
import YamiboXCore

/// Inline presentations keep menus and panels in the cursor's render tree.
/// On the device, calls keep the existing system presentation.
struct ReaderRemotePanel<Panel: View>: ViewModifier {
    @Environment(\.readerRemoteInput) private var input
    @Environment(\.readerRemoteLayer) private var parentLayer
    @State private var id = UUID()
    @Binding var isPresented: Bool
    var maximumWidth: CGFloat = 720
    var deviceSheet = true
    var depthOverride: Int? = nil
    var showsDefaultClose = true
    @ViewBuilder let panel: () -> Panel

    func body(content: Content) -> some View {
        if let input {
            let layer = ReaderRemoteLayer(depth: depthOverride ?? parentLayer.depth + 1, id: id)
            content.overlay {
                if isPresented {
                    ZStack {
                        Color.black.opacity(0.45).ignoresSafeArea()
                        panel()
                            .frame(maxWidth: maximumWidth, maxHeight: .infinity)
                            .background(Color(.systemBackground))
                            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                                if showsDefaultClose {
                                    ReaderRemoteButton(action: close) {
                                        Image(systemName: "xmark")
                                            .font(.headline)
                                            .frame(width: 34, height: 34)
                                    }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.circle)
                                    .accessibilityLabel(L10n.string("common.close"))
                                    .padding(6)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .padding(.vertical, 18)
                            .padding(.horizontal, 24)
                    }
                    .environment(\.readerRemoteVisible, true)
                    .environment(\.readerRemoteLayer, layer)
                    .environment(\.readerRemoteDismiss, ReaderPresentationDismissal(id: id, action: close))
                    .background(ReaderRemoteLayerAttachment(registry: input.targets, layer: layer))
                }
            }
        } else if deviceSheet {
            content.sheet(isPresented: $isPresented) { panel() }
        } else {
            content
        }
    }

    private func close() { isPresented = false }
}

struct ReaderRemoteMenu<Label: View, Items: View>: View {
    @Environment(\.readerRemoteInput) private var input
    @ViewBuilder let items: () -> Items
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let input {
            ReaderRemoteButton(action: {
                input.presentMenu { items() }
            }, label: label)
        } else {
            Menu(content: items, label: label)
        }
    }
}

struct ReaderRemoteToolbarMenu<Items: View>: View {
    @Environment(\.readerRemoteInput) private var input
    let title: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        if let input {
            // Keep the cursor target in the toolbar instead of relying on a native menu to receive the click.
            ReaderRemoteButton {
                input.presentMenu { items() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel(title)
        } else {
            Menu(content: items) {
                Label(title, systemImage: "ellipsis").labelStyle(.iconOnly)
            }
            .accessibilityLabel(title)
        }
    }
}

struct ReaderRemoteButton<Label: View>: View {
    let role: ButtonRole?
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(role: ButtonRole? = nil, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.role = role
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(role: role, action: action, label: label)
            .readerRemoteActivate(action)
    }
}

extension ReaderRemoteButton where Label == Text {
    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(title) }
    }
}

extension View {
    func readerPanel<Panel: View>(isPresented: Binding<Bool>, maximumWidth: CGFloat = 720,
                                 @ViewBuilder content: @escaping () -> Panel) -> some View {
        modifier(ReaderRemotePanel(isPresented: isPresented, maximumWidth: maximumWidth, panel: content))
    }

    func readerPanel<Item: Identifiable, Panel: View>(item: Binding<Item?>, maximumWidth: CGFloat = 720,
                                                     @ViewBuilder content: @escaping (Item) -> Panel) -> some View {
        readerPanel(isPresented: Binding(get: { item.wrappedValue != nil }, set: {
            if !$0 { item.wrappedValue = nil }
        }), maximumWidth: maximumWidth) {
            if let value = item.wrappedValue { content(value).id(value.id) }
        }
    }

    func readerDeviceSheet<Item: Identifiable, Panel: View>(item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Panel) -> some View {
        modifier(ReaderDeviceSheet(item: item, panel: content))
    }

    func readerDeviceSheet<Panel: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Panel) -> some View {
        modifier(ReaderDeviceFlagSheet(isPresented: isPresented, panel: content))
    }
}

private struct ReaderDeviceFlagSheet<Panel: View>: ViewModifier {
    @Environment(\.readerDeviceInteraction) private var device
    @Binding var isPresented: Bool
    @ViewBuilder let panel: () -> Panel

    func body(content: Content) -> some View {
        if let device {
            content.onChange(of: isPresented) { _, isPresented in
                guard isPresented else { return }
                self.isPresented = false
                device.present { _ in panel() }
            }
        } else {
            content.sheet(isPresented: $isPresented) { panel() }
        }
    }
}

private struct ReaderDeviceSheet<Item: Identifiable, Panel: View>: ViewModifier {
    @Environment(\.readerDeviceInteraction) private var device
    @Binding var item: Item?
    @ViewBuilder let panel: (Item) -> Panel

    func body(content: Content) -> some View {
        if let device {
            content.onChange(of: item?.id) { _, _ in
                guard let selected = item else { return }
                item = nil
                device.present { _ in panel(selected) }
            }
        } else {
            content.sheet(item: $item) { panel($0) }
        }
    }
}
