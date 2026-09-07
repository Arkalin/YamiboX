import SwiftUI
import YamiboXCore

/// Confirmation presentations for the favorite quick actions: "sync to Yamibo?" on
/// add and "also delete from Yamibo?" on remove, each with remember-choice
/// variants. Shared by the thread reader and the detail pages.
struct FavoriteQuickActionDialogs: ViewModifier {
    @Binding var addPromptPresented: Bool
    @Binding var removePrompt: FavoriteRemovePrompt?
    let onConfirmAdd: (_ syncToRemote: Bool, _ remember: Bool) -> Void
    let onConfirmRemoval: (_ favorite: Favorite, _ removeRemote: Bool, _ remember: Bool) -> Void
    @State private var pendingAddChoice: (syncToRemote: Bool, remember: Bool)?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $addPromptPresented, onDismiss: {
                // Finish dismissal before the action can present a failure alert.
                guard let choice = pendingAddChoice else { return }
                pendingAddChoice = nil
                onConfirmAdd(choice.syncToRemote, choice.remember)
            }) {
                FavoriteAddPromptSheet { syncToRemote, remember in
                    pendingAddChoice = (syncToRemote, remember)
                    addPromptPresented = false
                } onCancel: {
                    addPromptPresented = false
                }
            }
            .favoriteRemovePromptDialog(prompt: $removePrompt) { prompt, removeRemote, remember in
                onConfirmRemoval(prompt.favorite, removeRemote, remember)
            }
    }
}

struct FavoriteAddPromptSheet: View {
    let onConfirm: (_ syncToRemote: Bool, _ remember: Bool) -> Void
    let onCancel: () -> Void
    @State private var rememberChoice = false
    @State private var contentHeight: CGFloat = 300

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    Text(L10n.string("favorites.quick.add_prompt.title"))
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("common.cancel"))
                    .accessibilityIdentifier("favorite-add-cancel")
                }

                Toggle(L10n.string("favorites.quick.add_prompt.remember"), isOn: $rememberChoice)
                    .font(.subheadline)
                    .accessibilityIdentifier("favorite-add-remember")

                VStack(spacing: 12) {
                    Button {
                        onConfirm(true, rememberChoice)
                    } label: {
                        Text(L10n.string("favorites.quick.add_prompt.sync"))
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("favorite-add-sync")

                    Button {
                        onConfirm(false, rememberChoice)
                    } label: {
                        Text(L10n.string("favorites.quick.add_prompt.local_only"))
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("favorite-add-local")
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                contentHeight = ceil($0)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationCompactAdaptation(.sheet)
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
