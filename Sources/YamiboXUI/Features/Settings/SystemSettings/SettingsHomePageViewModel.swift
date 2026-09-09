import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class SettingsHomePageViewModel: AppSettingsPersisting {
    var showsOnlyFavorites = false

    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity

    init(dependencies: SettingsDependencies, activity: SystemSettingsActivity) {
        self.dependencies = dependencies
        self.activity = activity
    }

    func applyLoadedSettings(_ settings: AppSettings) {
        showsOnlyFavorites = settings.system.homeShowsOnlyFavorites
    }

    func updateShowsOnlyFavorites(_ value: Bool) {
        guard showsOnlyFavorites != value else { return }
        persistSettings(\.showsOnlyFavorites, to: value) {
            $0.system.homeShowsOnlyFavorites = value
        }
    }

    func restoreDefaultsAfterApplicationReset() {
        showsOnlyFavorites = false
    }
}
