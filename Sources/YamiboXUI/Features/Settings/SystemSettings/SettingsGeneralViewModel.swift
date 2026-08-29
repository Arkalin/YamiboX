import Foundation
import Observation
import YamiboXCore

/// State and commands for the General settings page.
@MainActor
@Observable
final class SettingsGeneralViewModel: AppSettingsPersisting {
    typealias AtomicSettingsUpdater = @Sendable (
        _ mutate: @Sendable (inout AppSettings) -> Void
    ) async throws -> AppSettings

    var homePage: AppHomePage = .forum
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
        persistSettings(\.homePage, to: value) { $0.system.homePage = value }
    }

    func updateThemePreset(_ value: AppThemePreset) {
        guard themePreset != value else { return }
        let previous = themePreset
        themePreset = value

        Task {
            do {
                let saved = try await updateSettings { settings in
                    settings.appearance.themePreset = value
                }
                if themePreset == value {
                    themePreset = saved.appearance.themePreset
                }
            } catch {
                if themePreset == value {
                    themePreset = previous
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Mirrors what `resetApplicationData()` just persisted; see the storage
    /// page's reset action, which fans out to every page.
    func restoreDefaultsAfterApplicationReset() {
        homePage = .forum
        themePreset = .classic
    }
}
