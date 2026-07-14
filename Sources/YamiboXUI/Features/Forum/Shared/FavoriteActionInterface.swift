import SwiftUI
import YamiboXCore

extension View {
    /// Full favorite-star UI wiring for a detail page, bound to one
    /// `FavoriteActionController`: the failure alert, the add/remove decision
    /// dialogs, the location picker sheet, and the transient feedback toast.
    func favoriteActionInterface(_ actions: FavoriteActionController) -> some View {
        modifier(FavoriteActionInterfaceModifier(actions: actions))
    }
}

private struct FavoriteActionInterfaceModifier: ViewModifier {
    @Bindable var actions: FavoriteActionController

    func body(content: Content) -> some View {
        content
            .alert(
                L10n.string("forum.thread.favorite_failed"),
                isPresented: Binding(
                    get: { actions.errorMessage != nil },
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
            } message: {
                Text(actions.errorMessage ?? "")
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
            .sheet(item: $actions.locationPickerContext) { context in
                FavoriteLocationPickerSheet(
                    context: context,
                    onCancel: { actions.locationPickerContext = nil },
                    onConfirm: { locations in
                        Task { await actions.confirmLocationSelection(locations) }
                    }
                )
            }
            .transientMessage(actions.transientMessage) {
                actions.clearTransientMessage()
            }
    }
}
