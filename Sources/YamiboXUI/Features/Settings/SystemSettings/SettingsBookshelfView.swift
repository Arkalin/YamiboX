import SwiftUI
import YamiboXCore

struct SettingsBookshelfView: View {
    let viewModel: SettingsBookshelfViewModel

    var body: some View {
        Form {
            AppThemeSwitch(
                L10n.string("settings.bookshelf.only_favorites"),
                isOn: Binding(
                    get: { viewModel.showsOnlyFavorites },
                    set: { viewModel.updateShowsOnlyFavorites($0) }
                )
            )
            .disabled(viewModel.isBusy)
            .accessibilityIdentifier("settings.bookshelf.only_favorites")
        }
        .navigationTitle(L10n.string("tab.bookshelf"))
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
