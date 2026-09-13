import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class SettingsPresentationState {
    let viewModel: SystemSettingsViewModel
    let dependencies: SettingsDependencies
    let peripheralInput: ReaderPeripheralInputManager?
    let accountSwitcher: AccountSwitchCoordinator?
    var pendingConfirmation: SystemSettingsConfirmation?
    private(set) var isSigningOut = false

    private let onSignOut: @MainActor () async -> LoadFailureDetails?
    private let onApplicationReset: @MainActor () async -> Void
    private let onClose: () -> Void

    init(
        dependencies: SettingsDependencies,
        peripheralInput: ReaderPeripheralInputManager? = nil,
        onSignOut: @escaping @MainActor () async -> LoadFailureDetails?,
        onApplicationReset: @escaping @MainActor () async -> Void,
        onClose: @escaping () -> Void,
        accountSwitcher: AccountSwitchCoordinator? = nil
    ) {
        self.dependencies = dependencies
        self.peripheralInput = peripheralInput
        self.onSignOut = onSignOut
        self.onApplicationReset = onApplicationReset
        self.onClose = onClose
        self.accountSwitcher = accountSwitcher
        viewModel = SystemSettingsViewModel(dependencies: dependencies)
    }

    var canNavigate: Bool { !viewModel.isBusy && !isSigningOut }

    func loadIfIdle() async {
        // Reappearing after a tab switch must not replace another page's action.
        guard canNavigate, !Task.isCancelled else { return }
        await viewModel.load()
    }

    var aboutTitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return L10n.string(
            "settings.about_app_with_version",
            version?.isEmpty == false ? version! : "--"
        )
    }

    func observeSessionChanges() async {
        for await _ in dependencies.sessionStore.changes() {
            guard !Task.isCancelled else { return }
            await viewModel.refreshSessionState()
        }
    }

    func handleConfirmation(_ confirmation: SystemSettingsConfirmation) async {
        guard confirmation == .signOut, canNavigate else { return }
        isSigningOut = true
        let failureDetails = await onSignOut()
        isSigningOut = false
        if let failureDetails {
            viewModel.errorMessage = failureDetails.summary
            viewModel.errorDetails = failureDetails
        } else {
            onClose()
        }
    }

    func handleApplicationReset() async {
        onClose()
        await onApplicationReset()
    }
}
