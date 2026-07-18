import Foundation
import Observation
import YamiboXCore

/// State and commands for the General settings page.
@MainActor
@Observable
final class SettingsGeneralViewModel: AppSettingsPersisting {
    var homePage: AppHomePage = .forum

    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity

    init(dependencies: SettingsDependencies, activity: SystemSettingsActivity) {
        self.dependencies = dependencies
        self.activity = activity
    }

    /// Called by the composition root with the one `AppSettings` snapshot it
    /// loads for all pages, so opening Settings still costs a single store
    /// read instead of one per page.
    func applyLoadedSettings(_ settings: AppSettings) {
        homePage = settings.system.homePage
    }

    func updateHomePage(_ value: AppHomePage) {
        persistSettings(\.homePage, to: value) { $0.system.homePage = value }
    }

    /// Mirrors what `resetApplicationData()` just persisted; see the storage
    /// page's reset action, which fans out to every page.
    func restoreDefaultsAfterApplicationReset() {
        homePage = .forum
    }
}
