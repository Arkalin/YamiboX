import SwiftUI
import YamiboXCore

/// Confirmation presentations for the favorite quick actions: "sync to Yamibo?" on
/// add and "also delete from Yamibo?" on remove, each with a remember-choice
/// toggle. Shared by the thread reader and the detail pages.
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
                FavoriteActionPromptSheet(action: .add) { syncToRemote, remember in
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

private struct FavoriteActionPromptSheet: View {
    enum Action {
        case add
        case remove

        var titleKey: String {
            self == .add ? "favorites.quick.add_prompt.title" : "favorites.quick.remove_prompt.title"
        }

        var remoteTitleKey: String {
            self == .add ? "favorites.quick.add_prompt.sync" : "favorites.quick.remove_prompt.both"
        }

        var localTitleKey: String {
            self == .add ? "favorites.quick.add_prompt.local_only" : "favorites.quick.remove_prompt.local_only"
        }

        var identifierPrefix: String { self == .add ? "favorite-add" : "favorite-remove" }
        var buttonRole: ButtonRole? { self == .remove ? .destructive : nil }
    }

    let action: Action
    let onConfirm: (_ syncToRemote: Bool, _ remember: Bool) -> Void
    let onCancel: () -> Void
    @State private var rememberChoice = false
    @State private var contentHeight: CGFloat = 300

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    Text(L10n.string(action.titleKey))
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
                    .accessibilityIdentifier("\(action.identifierPrefix)-cancel")
                }

                Toggle(L10n.string("favorites.quick.add_prompt.remember"), isOn: $rememberChoice)
                    .font(.subheadline)
                    .accessibilityIdentifier("\(action.identifierPrefix)-remember")

                VStack(spacing: 12) {
                    Button(role: action.buttonRole) {
                        onConfirm(true, rememberChoice)
                    } label: {
                        Text(L10n.string(action.remoteTitleKey))
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("\(action.identifierPrefix)-sync")

                    Button(role: action.buttonRole) {
                        onConfirm(false, rememberChoice)
                    } label: {
                        Text(L10n.string(action.localTitleKey))
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("\(action.identifierPrefix)-local")
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

private struct FavoriteRemovePromptDialog<Prompt: Identifiable>: ViewModifier {
    @Binding var prompt: Prompt?
    let onConfirm: (_ prompt: Prompt, _ removeRemote: Bool, _ remember: Bool) -> Void
    @State private var pendingChoice: (prompt: Prompt, removeRemote: Bool, remember: Bool)?

    func body(content: Content) -> some View {
        content.sheet(item: $prompt, onDismiss: {
            // Keep the confirmed subject after dismissal clears the binding.
            guard let choice = pendingChoice else { return }
            pendingChoice = nil
            onConfirm(choice.prompt, choice.removeRemote, choice.remember)
        }) { value in
            FavoriteActionPromptSheet(action: .remove) { removeRemote, remember in
                pendingChoice = (value, removeRemote, remember)
                prompt = nil
            } onCancel: {
                prompt = nil
            }
        }
    }
}

extension View {
    /// Shared removal sheet with remote/local actions and a remember-choice toggle.
    func favoriteRemovePromptDialog<Prompt: Identifiable>(
        prompt: Binding<Prompt?>,
        onConfirm: @escaping (_ prompt: Prompt, _ removeRemote: Bool, _ remember: Bool) -> Void
    ) -> some View {
        modifier(FavoriteRemovePromptDialog(prompt: prompt, onConfirm: onConfirm))
    }

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
