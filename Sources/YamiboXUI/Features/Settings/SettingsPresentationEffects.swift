import SwiftUI
import YamiboXCore

struct SettingsPresentationEffects: ViewModifier {
    let state: SettingsPresentationState
    var isActive = true

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive, !state.canNavigate {
                    ProgressView(
                        state.isSigningOut ? L10n.string("mine.signing_out") : L10n.string("common.loading")
                    )
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .task(id: isActive) {
                guard isActive else { return }
                await state.loadIfIdle()
            }
            .task(id: isActive) {
                guard isActive else { return }
                await state.observeSessionChanges()
            }
            .failureAlert(
                L10n.string("common.operation_failed"),
                message: state.viewModel.errorMessage,
                details: state.viewModel.errorDetails,
                isPresented: errorIsPresented
            ) {
                Button(L10n.string("common.ok")) {
                    state.viewModel.errorMessage = nil
                }
            }
            .destructiveConfirmationAlert(
                item: confirmation,
                title: \.title,
                actionTitle: \.buttonTitle,
                message: \.message
            ) { confirmation in
                guard isActive else { return }
                Task { await state.handleConfirmation(confirmation) }
            }
    }

    private var errorIsPresented: Binding<Bool> {
        .presentation(
            isPresented: { isActive && state.viewModel.errorMessage != nil },
            clearOnDismiss: {
                guard isActive else { return }
                state.viewModel.errorMessage = nil
            }
        )
    }

    private var confirmation: Binding<SystemSettingsConfirmation?> {
        Binding {
            isActive ? state.pendingConfirmation : nil
        } set: { value in
            guard isActive else { return }
            state.pendingConfirmation = value
        }
    }
}
