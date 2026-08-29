import SwiftUI
import YamiboXCore

struct SettingsGeneralView: View {
    // Plain stored reference: @Observable registers exactly the properties
    // `body` reads, so no property wrapper is needed for observation.
    let viewModel: SettingsGeneralViewModel

    var body: some View {
        Form {
            SettingsAppearanceSection(
                selectedPreset: viewModel.themePreset,
                isBusy: viewModel.isBusy,
                onSelect: viewModel.updateThemePreset
            )

            Section {
                SystemSettingsHomePageSelector(
                    homePage: viewModel.homePage,
                    isBusy: viewModel.isBusy,
                    onSelect: viewModel.updateHomePage
                )
            }
        }
        .navigationTitle(L10n.string("settings.section.general"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.string("common.operation_failed"), isPresented: errorIsPresented, actions: {
            Button(L10n.string("common.ok")) {
                viewModel.errorMessage = nil
            }
        }, message: {
            Text(viewModel.errorMessage ?? "")
        })
    }

    private var errorIsPresented: Binding<Bool> {
        .presentation(
            isPresented: { viewModel.errorMessage != nil },
            clearOnDismiss: { viewModel.errorMessage = nil }
        )
    }
}
