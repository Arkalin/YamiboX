import SwiftUI
import YamiboXCore

struct SettingsHomePageView: View {
    let viewModel: SettingsHomePageViewModel

    var body: some View {
        Form {
            Toggle(
                L10n.string("settings.home.only_favorites"),
                isOn: Binding(
                    get: { viewModel.showsOnlyFavorites },
                    set: { viewModel.updateShowsOnlyFavorites($0) }
                )
            )
            .disabled(viewModel.isBusy)
            .accessibilityIdentifier("settings.home.only_favorites")
        }
        .navigationTitle(L10n.string("tab.home"))
        .navigationBarTitleDisplayMode(.inline)
        .failureAlert(
            L10n.string("common.operation_failed"),
            message: viewModel.errorMessage,
            details: viewModel.errorDetails,
            isPresented: .presentation(
                isPresented: { viewModel.errorMessage != nil },
                clearOnDismiss: { viewModel.errorMessage = nil }
            )
        ) {
            Button(L10n.string("common.ok")) {
                viewModel.errorMessage = nil
            }
        }
    }
}
