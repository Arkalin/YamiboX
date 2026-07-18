import SwiftUI
import YamiboXCore

struct SettingsGeneralView: View {
    @Environment(\.openURL) private var openURL
    // Plain stored reference: @Observable registers exactly the properties
    // `body` reads, so no property wrapper is needed for observation.
    let viewModel: SettingsGeneralViewModel

    var body: some View {
        Form {
            Section {
                SystemSettingsHomePageSelector(
                    homePage: viewModel.homePage,
                    isBusy: viewModel.isBusy,
                    onSelect: viewModel.updateHomePage
                )
            }

            Section {
                Button {
                    openCheckInAutomationCreator()
                } label: {
                    SystemSettingsRow(
                        title: L10n.string("settings.auto_sign_in"),
                        titleColor: .accentColor
                    )
                }
                .disabled(viewModel.isBusy)
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
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.errorMessage = nil
                }
            }
        )
    }

    private func openCheckInAutomationCreator() {
        guard let url = URL(string: "shortcuts://create-automation") else {
            viewModel.errorMessage = L10n.string("settings.shortcuts_open_failed")
            return
        }

        openURL(url) { accepted in
            guard !accepted else { return }
            viewModel.errorMessage = L10n.string("settings.shortcuts_open_failed")
        }
    }
}
