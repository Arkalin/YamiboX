import SwiftUI
import YamiboXCore

struct SettingsGeneralView: View {
    // Plain stored reference: @Observable registers exactly the properties
    // `body` reads, so no property wrapper is needed for observation.
    let viewModel: SettingsGeneralViewModel
    @State private var editingNavigation: AppNavigationSettings?

    var body: some View {
        Form {
            SettingsAppearanceSection(
                selectedPreset: viewModel.themePreset,
                isBusy: viewModel.isBusy,
                onSelect: viewModel.updateThemePreset
            )

            Section {
                Button {
                    Task {
                        let settings = await viewModel.settingsStore.load()
                        editingNavigation = settings.system.navigation
                    }
                } label: {
                    SystemSettingsRow(title: L10n.string("settings.navigation.title"))
                        .foregroundStyle(.primary)
                }
                .disabled(viewModel.isBusy)
            }
        }
        .navigationTitle(L10n.string("settings.section.general"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { editingNavigation != nil }, set: { if !$0 { editingNavigation = nil } })) {
            if let editingNavigation {
                NavigationSettingsEditor(initial: editingNavigation, save: viewModel.saveNavigation)
            }
        }
        .failureAlert(
            L10n.string("common.operation_failed"),
            message: viewModel.errorMessage,
            details: viewModel.errorDetails,
            isPresented: errorIsPresented
        ) {
            Button(L10n.string("common.ok")) {
                viewModel.errorMessage = nil
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        .presentation(
            isPresented: { viewModel.errorMessage != nil },
            clearOnDismiss: { viewModel.errorMessage = nil }
        )
    }
}
