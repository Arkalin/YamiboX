import SwiftUI
import YamiboXCore

#if os(iOS)

struct ReaderPeripheralSettingsSheet: View {
    let peripheralInput: ReaderPeripheralInputManager
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SettingsPeripheralsViewModel

    init(settingsStore: SettingsStore, settingsTarget: ReaderSettingsTarget, peripheralInput: ReaderPeripheralInputManager) {
        self.peripheralInput = peripheralInput
        _viewModel = State(
            initialValue: SettingsPeripheralsViewModel(
                settingsStore: settingsStore,
                activity: SystemSettingsActivity(),
                settingsTarget: settingsTarget
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
                    Button(L10n.string("common.done")) { dismiss() }
                }
            }
        }
        .task {
            await viewModel.load()
        }
    }
}

#endif
