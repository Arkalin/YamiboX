import SwiftUI
import YamiboXCore

/// Confirmation dialogs for the favorite quick actions: "sync to Yamibo?" on
/// add and "also delete from Yamibo?" on remove, each with remember-choice
/// variants. Shared by the thread reader and the detail pages.
struct FavoriteQuickActionDialogs: ViewModifier {
    @Binding var addPromptPresented: Bool
    @Binding var removePrompt: FavoriteRemovePrompt?
    let onConfirmAdd: (_ syncToRemote: Bool, _ remember: Bool) -> Void
    let onConfirmRemoval: (_ favorite: Favorite, _ removeRemote: Bool, _ remember: Bool) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                L10n.string("favorites.quick.add_prompt.title"),
                isPresented: $addPromptPresented,
                titleVisibility: .visible
            ) {
                Button(L10n.string("favorites.quick.add_prompt.sync")) {
                    onConfirmAdd(true, false)
                }
                Button(L10n.string("favorites.quick.add_prompt.local_only")) {
                    onConfirmAdd(false, false)
                }
                Button(L10n.string("favorites.quick.add_prompt.sync_remember")) {
                    onConfirmAdd(true, true)
                }
                Button(L10n.string("favorites.quick.add_prompt.local_remember")) {
                    onConfirmAdd(false, true)
                }
                Button(L10n.string("common.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("favorites.quick.add_prompt.message"))
            }
            .favoriteRemovePromptDialog(prompt: $removePrompt) { prompt, removeRemote, remember in
                onConfirmRemoval(prompt.favorite, removeRemote, remember)
            }
    }
}

extension View {
    /// The four-way "also remove from Yamibo?" prompt (both/local-only, each
    /// with a remember variant). Generic over the pending-prompt type so
    /// flows that resolve the favorite elsewhere can reuse it.
    func favoriteRemovePromptDialog<Prompt>(
        prompt: Binding<Prompt?>,
        onConfirm: @escaping (_ prompt: Prompt, _ removeRemote: Bool, _ remember: Bool) -> Void
    ) -> some View {
        confirmationDialog(
            L10n.string("favorites.quick.remove_prompt.title"),
            isPresented: Binding(
                get: { prompt.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented {
                        prompt.wrappedValue = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: prompt.wrappedValue
        ) { value in
            Button(L10n.string("favorites.quick.remove_prompt.both"), role: .destructive) {
                onConfirm(value, true, false)
            }
            Button(L10n.string("favorites.quick.remove_prompt.local_only"), role: .destructive) {
                onConfirm(value, false, false)
            }
            Button(L10n.string("favorites.quick.remove_prompt.both_remember"), role: .destructive) {
                onConfirm(value, true, true)
            }
            Button(L10n.string("favorites.quick.remove_prompt.local_remember"), role: .destructive) {
                onConfirm(value, false, true)
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(L10n.string("favorites.quick.remove_prompt.message"))
        }
    }
}

extension View {
    func favoriteQuickActionDialogs(
        addPromptPresented: Binding<Bool>,
        removePrompt: Binding<FavoriteRemovePrompt?>,
        onConfirmAdd: @escaping (_ syncToRemote: Bool, _ remember: Bool) -> Void,
        onConfirmRemoval: @escaping (_ favorite: Favorite, _ removeRemote: Bool, _ remember: Bool) -> Void
    ) -> some View {
        modifier(FavoriteQuickActionDialogs(
            addPromptPresented: addPromptPresented,
            removePrompt: removePrompt,
            onConfirmAdd: onConfirmAdd,
            onConfirmRemoval: onConfirmRemoval
        ))
    }
}
