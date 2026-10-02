import Foundation
import Observation
import YamiboXCore

/// State and commands for the General settings page.
@MainActor
@Observable
final class SettingsGeneralViewModel: AppSettingsPersisting {
    var navigation = AppNavigationSettings()
    var themeLibrary = AppThemeLibrary()
    var usesAccentSurfaces = true
    var launchBackground = CustomBackgroundSettings()
    var launchShowsBrand = true

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
        themeLibrary = settings.appearance.themeLibrary
        usesAccentSurfaces = settings.appearance.usesAccentSurfaces
        launchBackground = settings.appearance.launchBackground
        launchShowsBrand = settings.appearance.launchShowsBrand
    }

    func saveNavigation(_ value: AppNavigationSettings) async throws {
        let saved = try await updateSettings { $0.system.navigation = value }
        navigation = saved.system.navigation
    }

    func selectTheme(_ id: String) {
        var library = themeLibrary
        library.select(id)
        guard library != themeLibrary else { return }
        persistSettings(\.themeLibrary, to: library, updateSettings: updateSettings) {
            $0.appearance.themeLibrary.select(id)
        }
    }

    func updateUsesAccentSurfaces(_ value: Bool) {
        persistSettings(\.usesAccentSurfaces, to: value, updateSettings: updateSettings) {
            $0.appearance.usesAccentSurfaces = value
        }
    }

    func saveTheme(_ theme: AppThemeDefinition) async throws {
        let saved = try await updateSettings {
            $0.appearance.themeLibrary.save(theme)
        }
        themeLibrary = saved.appearance.themeLibrary
    }

    func deleteTheme(_ id: String) async throws {
        let saved = try await updateSettings {
            $0.appearance.themeLibrary.remove(id)
        }
        themeLibrary = saved.appearance.themeLibrary
    }

    /// Mirrors what `resetApplicationData()` just persisted; see the storage
    /// page's reset action, which fans out to every page.
    func restoreDefaultsAfterApplicationReset() {
        navigation = AppNavigationSettings()
        themeLibrary = AppThemeLibrary()
        usesAccentSurfaces = true
        launchBackground = .init()
        launchShowsBrand = true
    }
}
