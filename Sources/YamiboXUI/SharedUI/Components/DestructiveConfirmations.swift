import SwiftUI
import YamiboXCore

extension View {
    /// Confirmation alert for a destructive action pending on `item`:
    /// dismissing the alert by any route clears the item, so the binding's
    /// setter is the single cancellation path.
    func destructiveConfirmationAlert<Item>(
        item: Binding<Item?>,
        title: @escaping (Item) -> String,
        actionTitle: @escaping (Item) -> String,
        message: @escaping (Item) -> String,
        onConfirm: @escaping (Item) -> Void
    ) -> some View {
        modifier(ReaderDestructiveItemConfirmation(item: item, title: title, actionTitle: actionTitle,
                                                   message: message, confirm: onConfirm))
    }

    func destructiveConfirmationAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        actionTitle: String,
        message: String? = nil,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(ReaderDestructiveConfirmation(title: title, actionTitle: actionTitle, message: message,
            item: isPresented, usesAlert: true, confirm: onConfirm))
    }

    func destructiveConfirmationDialog(
        _ title: String,
        isPresented: Binding<Bool>,
        actionTitle: String = L10n.string("common.delete"),
        message: String? = nil,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(ReaderDestructiveConfirmation(title: title, actionTitle: actionTitle, message: message,
            item: isPresented, usesAlert: false, confirm: onConfirm))
    }
}

private struct ReaderDestructiveItemConfirmation<Item>: ViewModifier {
    @Environment(\.readerDeviceInteraction) private var device
    @Binding var item: Item?
    let title: (Item) -> String
    let actionTitle: (Item) -> String
    let message: (Item) -> String
    let confirm: (Item) -> Void

    func body(content: Content) -> some View {
        let presented = Binding(get: { item != nil }, set: { if !$0 { item = nil } })
        if let device {
            content.onChange(of: presented.wrappedValue, initial: true) { _, _ in
                guard let value = item else { return }
                item = nil
                presentDestructiveConfirmation(on: device, title: title(value), actionTitle: actionTitle(value),
                                               message: message(value), confirm: { confirm(value) })
            }
        } else {
            content.alert(item.map(title) ?? "", isPresented: presented, presenting: item) { value in
                Button(actionTitle(value), role: .destructive) { confirm(value) }
                Button(L10n.string("common.cancel"), role: .cancel) {}
            } message: { value in
                Text(message(value))
            }
        }
    }
}

private struct ReaderDestructiveConfirmation: ViewModifier {
    @Environment(\.readerDeviceInteraction) private var device
    let title: String
    let actionTitle: String
    let message: String?
    @Binding var item: Bool
    let usesAlert: Bool
    let confirm: () -> Void

    func body(content: Content) -> some View {
        if let device {
            content.onChange(of: item, initial: true) { _, isPresented in
                guard isPresented else { return }
                item = false
                presentDestructiveConfirmation(on: device, title: title, actionTitle: actionTitle,
                                               message: message, confirm: confirm)
            }
        } else if usesAlert {
            content.alert(title, isPresented: $item) {
                Button(L10n.string("common.cancel"), role: .cancel) {}
                Button(actionTitle, role: .destructive, action: confirm)
            } message: {
                if let message { Text(message) }
            }
        } else {
            content.confirmationDialog(title, isPresented: $item, titleVisibility: .visible) {
                Button(actionTitle, role: .destructive, action: confirm)
            } message: {
                if let message { Text(message) }
            }
        }
    }
}

@MainActor
private func presentDestructiveConfirmation(
    on device: ReaderDeviceInteractionContext, title: String, actionTitle: String,
    message: String?, confirm: @escaping () -> Void
) {
    device.present { id in
        VStack(spacing: 16) {
            Text(title).font(.headline)
            if let message { Text(message).foregroundStyle(.secondary) }
            HStack {
                Button(L10n.string("common.cancel"), role: .cancel) { device.finish(id) }
                Button(actionTitle, role: .destructive) {
                    guard device.isCurrent(id) else { return }
                    device.finish(id)
                    confirm()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
