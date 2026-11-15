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

    /// Confirmation alert for a destructive action guarded by a plain flag.
    func destructiveConfirmationAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        actionTitle: String,
        message: String? = nil,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(ReaderRemoteDestructiveConfirmation(title: title, actionTitle: actionTitle, message: message,
            item: isPresented, usesAlert: true, confirm: onConfirm))
    }

    /// Confirmation dialog (action sheet) for a destructive action. The
    /// system supplies the cancel button.
    func destructiveConfirmationDialog(
        _ title: String,
        isPresented: Binding<Bool>,
        actionTitle: String = L10n.string("common.delete"),
        message: String? = nil,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(ReaderRemoteDestructiveConfirmation(title: title, actionTitle: actionTitle, message: message,
            item: isPresented, usesAlert: false, confirm: onConfirm))
    }
}

private struct ReaderDestructiveItemConfirmation<Item>: ViewModifier {
    @Environment(\.readerRemoteInput) private var input
    @Binding var item: Item?
    let title: (Item) -> String
    let actionTitle: (Item) -> String
    let message: (Item) -> String
    let confirm: (Item) -> Void

    func body(content: Content) -> some View {
        let presented = Binding(get: { item != nil }, set: { if !$0 { item = nil } })
        if input != nil {
            content.modifier(ReaderRemoteDestructiveConfirmation(title: item.map(title) ?? "",
                actionTitle: item.map(actionTitle) ?? "", message: item.map(message),
                item: presented, usesAlert: true, confirm: { if let item { confirm(item) } }))
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

private struct ReaderRemoteDestructiveConfirmation: ViewModifier {
    @Environment(\.readerRemoteInput) private var input
    let title: String
    let actionTitle: String
    let message: String?
    @Binding var item: Bool
    let usesAlert: Bool
    let confirm: () -> Void

    func body(content: Content) -> some View {
        if input != nil {
            content.readerPanel(isPresented: $item, maximumWidth: 440) {
                VStack(spacing: 16) {
                    Text(title).font(.headline)
                    if let message { Text(message).foregroundStyle(.secondary) }
                    HStack {
                        ReaderRemoteButton(L10n.string("common.cancel"), role: .cancel) { item = false }
                        ReaderRemoteButton(actionTitle, role: .destructive) {
                            confirm()
                            item = false
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(24)
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
