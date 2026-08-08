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
        var updated = novelOfflineCache
        updated.retainsInlineImages = retainsInlineImages
        updateNovelOfflineCache(updated)
    }

    func updateNovelOfflineCacheAutoRefreshEnabled(_ isAutoRefreshEnabled: Bool) {
        var updated = novelOfflineCache
        updated.isAutoRefreshEnabled = isAutoRefreshEnabled
        updateNovelOfflineCache(updated)
    }

    private func updateNovelOfflineCache(_ updated: NovelOfflineCacheSettings) {
        persistSettings(\.novelOfflineCache, to: updated) { $0.novelOfflineCache = updated }
    }

}
