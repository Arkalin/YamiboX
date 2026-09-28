import SwiftUI
import YamiboXCore

extension View {
    /// Full favorite-star UI wiring for a detail page, bound to one
    /// `FavoriteActionController`: the failure alert, the add/remove decision
    /// dialogs, the location picker sheet, and the transient feedback toast.
    func favoriteActionInterface(_ actions: FavoriteActionController, showsTransientFeedback: Bool = true) -> some View {
        modifier(FavoriteActionInterfaceModifier(actions: actions, showsTransientFeedback: showsTransientFeedback))
    }

    /// Keep the host view's identity stable while a history row selects its
    /// action controller. Sheets belong to the selected subject, not each row.
    func favoriteActionInterface(_ actions: FavoriteActionController?) -> some View {
        background {
            if let actions {
                Color.clear.modifier(FavoriteActionInterfaceModifier(actions: actions, showsTransientFeedback: false))
            }
        }
        .transientMessage(actions?.management == nil ? actions?.transientFeedback : nil) {
            actions?.clearTransientMessage()
        }
    }
}

private struct FavoriteActionInterfaceModifier: ViewModifier {
    @Bindable var actions: FavoriteActionController
    var showsTransientFeedback = true
    @State private var groupChoice: (FavoriteGroupRemovalPrompt, Bool, Bool)?
    @State private var locationChoice: Set<FavoriteLocation>?

    func body(content: Content) -> some View {
        content
            .failureAlert(
                L10n.string("forum.thread.favorite_failed"),
                message: actions.errorMessage,
                details: actions.errorDetails,
                isPresented: Binding(
                    get: { actions.management == nil && actions.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            actions.clearError()
                        }
                    }
                )
            ) {
                Button(L10n.string("common.ok")) {
                    actions.clearError()
                }
            }
            .favoriteQuickActionDialogs(
                addPromptPresented: $actions.addPromptPresented,
                removePrompt: $actions.removePrompt,
                onConfirmAdd: { syncToRemote, remember in
                    Task { await actions.confirmAdd(syncToRemote: syncToRemote, remember: remember) }
                },
                onConfirmRemoval: { favorite, removeRemote, remember in
                    Task { await actions.confirmRemoval(favorite, removeRemote: removeRemote, remember: remember) }
                }
            )
            .sheet(item: $actions.locationPickerContext, onDismiss: {
                guard let choice = locationChoice else { return }
                locationChoice = nil
                Task { await actions.confirmLocationSelection(choice) }
            }) { context in
                FavoriteLocationPickerSheet(
                    context: context,
                    onCancel: { actions.locationPickerContext = nil },
                    onConfirm: { locations in
                        locationChoice = locations
                        actions.locationPickerContext = nil
                    }
                )
            }
            .sheet(item: $actions.groupRemovalPrompt, onDismiss: {
                guard let (prompt, remote, remember) = groupChoice else { return }
                groupChoice = nil
                Task { await actions.confirmGroupRemoval(prompt, removeRemote: remote, remember: remember) }
            }) { prompt in
                FavoriteWorkRemovalSheet(prompt: prompt) { remote, remember in
                    groupChoice = (prompt, remote, remember)
                    actions.groupRemovalPrompt = nil
                } onCancel: {
                    actions.groupRemovalPrompt = nil
                }
            }
            .sheet(item: $actions.management) { mode in
                FavoriteMemberManagementSheet(actions: actions, mode: mode)
            }
            .transientMessage(showsTransientFeedback && actions.management == nil ? actions.transientFeedback : nil) {
                actions.clearTransientMessage()
            }
    }
}
