import SwiftUI
import YamiboXCore

#if os(iOS)

/// The system settings peripheral-behavior page, presented as a sheet from a
/// reader settings sheet's "Other" section so a controller or keyboard user
/// can rebind without leaving the reader.
///
/// Builds its own ``SettingsPeripheralsViewModel``: the settings tab's
/// composition root (``SystemSettingsViewModel``) is not on screen here, so
/// this view also performs the single settings read that root would otherwise
/// have done, and gets its own ``SystemSettingsActivity`` — busy state and
/// errors raised here belong to this sheet alone.
struct ReaderPeripheralSettingsSheet: View {
    let peripheralInput: ReaderPeripheralInputManager
    @Environment(\.dismiss) private var dismiss
    /// `@State` (not `@StateObject`) because the view model is `@Observable`.
    /// SwiftUI keeps the first instance for the view's lifetime; the
    /// constructions on later `init` calls are discarded, which is safe here
    /// because `SettingsPeripheralsViewModel.init` only stores its
    /// dependencies and has no side effects.
    @State private var viewModel: SettingsPeripheralsViewModel

    init(dependencies: SettingsDependencies, peripheralInput: ReaderPeripheralInputManager) {
        self.peripheralInput = peripheralInput
        _viewModel = State(
            initialValue: SettingsPeripheralsViewModel(
                dependencies: dependencies,
                activity: SystemSettingsActivity()
            )
        )
    }

    var body: some View {
        NavigationStack {
            SystemSettingsPeripheralPageTurnView(
                viewModel: viewModel,
                peripheralInput: peripheralInput
            )
            .yamiboInlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await viewModel.load()
        }
    }
}

#endif
