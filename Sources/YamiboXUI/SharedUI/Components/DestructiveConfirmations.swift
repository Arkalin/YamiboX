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
        alert(
            item.wrappedValue.map(title) ?? "",
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented {
                        item.wrappedValue = nil
                    }
                }
            ),
            presenting: item.wrappedValue
        ) { value in
            Button(actionTitle(value), role: .destructive) {
                onConfirm(value)
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: { value in
            Text(message(value))
        }
    }

    /// Confirmation alert for a destructive action guarded by a plain flag.
    func destructiveConfirmationAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        actionTitle: String,
        message: String? = nil,
        onConfirm: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button(L10n.string("common.cancel"), role: .cancel) {}
            Button(actionTitle, role: .destructive, action: onConfirm)
        } message: {
            if let message {
                Text(message)
            }
        }
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
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(actionTitle, role: .destructive, action: onConfirm)
        } message: {
            if let message {
                Text(message)
            }
        }
    }
}
