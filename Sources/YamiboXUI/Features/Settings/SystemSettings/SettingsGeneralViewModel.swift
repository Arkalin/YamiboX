import Foundation
import Observation
import YamiboXCore

/// State and commands for the General settings page.
@MainActor
@Observable
final class SettingsGeneralViewModel: AppSettingsPersisting {
    var homePage: AppHomePage = .home
    var themePreset = AppThemePreset.classic

    let dependencies: SettingsDependencies
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
        homePage = settings.system.homePage
        themePreset = settings.appearance.themePreset
    }

    func updateHomePage(_ value: AppHomePage) {
        persistSettings(\.homePage, to: value, updateSettings: updateSettings) { $0.system.homePage = value }
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
        homePage = .home
        themePreset = .classic
    }
}
