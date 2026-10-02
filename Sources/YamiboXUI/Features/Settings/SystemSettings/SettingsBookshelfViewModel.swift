import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class SettingsBookshelfViewModel: AppSettingsPersisting {
    var showsOnlyFavorites = false
    var continueSettings = BookshelfContinueSettings()

    let dependencies: SettingsDependencies
    var settingsStore: SettingsStore { dependencies.settingsStore }
    let activity: SystemSettingsActivity

    init(dependencies: SettingsDependencies, activity: SystemSettingsActivity) {
        self.dependencies = dependencies
        self.activity = activity
    }

    func applyLoadedSettings(_ settings: AppSettings) {
        showsOnlyFavorites = settings.system.homeShowsOnlyFavorites
        continueSettings = settings.system.bookshelfContinue
    }

    func updateShowsOnlyFavorites(_ value: Bool) {
        guard showsOnlyFavorites != value else { return }
        persistSettings(\.showsOnlyFavorites, to: value) {
            $0.system.homeShowsOnlyFavorites = value
        }
    }

    func restoreDefaultsAfterApplicationReset() {
        showsOnlyFavorites = false
        continueSettings = .init()
    }

    func updateContinueMode(_ mode: BookshelfContinueMode) {
        var settings = continueSettings
        settings.mode = mode
        updateContinueSettings(settings)
    }

    func updateNovelCount(_ count: Int) {
        var settings = continueSettings
        settings.setNovelCount(count)
        updateContinueSettings(settings)
    }

    func updateMangaCount(_ count: Int) {
        var settings = continueSettings
        settings.setMangaCount(count)
        updateContinueSettings(settings)
    }

    func updateMixedCount(_ count: Int) {
        var settings = continueSettings
        settings.setMixedCount(count)
        updateContinueSettings(settings)
    }

    private func updateContinueSettings(_ settings: BookshelfContinueSettings) {
        guard continueSettings != settings else { return }
        persistSettings(\.continueSettings, to: settings) {
            $0.system.bookshelfContinue = settings
        }
    }
}
