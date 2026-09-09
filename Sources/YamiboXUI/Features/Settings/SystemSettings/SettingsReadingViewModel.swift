import Foundation
import Observation
import YamiboXCore

/// State and commands for the Reading settings page's novel offline cache
/// switches.
@MainActor
@Observable
final class SettingsReadingViewModel: AppSettingsPersisting {
    var novelOfflineCache = NovelOfflineCacheSettings()

    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity

    init(dependencies: SettingsDependencies, activity: SystemSettingsActivity) {
        self.dependencies = dependencies
        self.activity = activity
    }

    func applyLoadedSettings(_ settings: AppSettings) {
        novelOfflineCache = settings.novelOfflineCache
    }

    func restoreDefaultsAfterApplicationReset() {
        novelOfflineCache = NovelOfflineCacheSettings()
    }

    // MARK: - Novel offline cache

    func updateNovelOfflineCacheRetainsInlineImages(_ retainsInlineImages: Bool) {
        persistSettings(\.novelOfflineCache.retainsInlineImages, to: retainsInlineImages) {
            $0.novelOfflineCache.retainsInlineImages = retainsInlineImages
        }
    }

    func updateNovelOfflineCacheAutoRefreshEnabled(_ isAutoRefreshEnabled: Bool) {
        persistSettings(\.novelOfflineCache.isAutoRefreshEnabled, to: isAutoRefreshEnabled) {
            $0.novelOfflineCache.isAutoRefreshEnabled = isAutoRefreshEnabled
        }
    }

}
