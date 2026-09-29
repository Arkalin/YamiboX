import Foundation
import Observation
import YamiboXCore

/// State and commands for the General settings page.
@MainActor
@Observable
final class SettingsGeneralViewModel: AppSettingsPersisting {
    var navigation = AppNavigationSettings()
    var themePreset = AppThemePreset.classic

    let dependencies: SettingsDependencies
    var settingsStore: SettingsStore { dependencies.settingsStore }
    let activity: SystemSettingsActivity
    private let updateSettings: AtomicSettingsUpdater

    init(
        dependencies: SettingsDependencies,
        activity: SystemSettingsActivity,
        updateSettings: AtomicSettingsUpdater? = nil
    ) {
        self.dependencies = dependencies
        self.activity = activity
        self.updateSettings = updateSettings ?? { mutate in
            try await dependencies.settingsStore.update(mutate)
        }
    }

    /// Called by the composition root with the one `AppSettings` snapshot it
    /// loads for all pages, so opening Settings still costs a single store
    /// read instead of one per page.
    func applyLoadedSettings(_ settings: AppSettings) {
        navigation = settings.system.navigation
        themePreset = settings.appearance.themePreset
    }

    func saveNavigation(_ value: AppNavigationSettings) async throws {
        let saved = try await updateSettings { $0.system.navigation = value }
        navigation = saved.system.navigation
    }

    func updateThemePreset(_ value: AppThemePreset) {
        guard themePreset != value else { return }
        persistSettings(\.themePreset, to: value, updateSettings: updateSettings) {
            $0.appearance.themePreset = value
        }
    }

    /// Mirrors what `resetApplicationData()` just persisted; see the storage
    /// page's reset action, which fans out to every page.
    func restoreDefaultsAfterApplicationReset() {
        navigation = AppNavigationSettings()
        themePreset = .classic
    }
}
